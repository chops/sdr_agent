defmodule SdrAgent.Audit.ReleaseHashVerificationTest do
  @moduledoc """
  C2* slice S3 RED-2, record-hash verification of releases across the
  demo-exception migration (plan r2 §5, §8 T-H3, T-H4, T-H5; ADR-0009 C2*
  record-hash continuity amendment, accepted as D-226, obligations (a)-(d)).

    * T-H3 (d), control: an ordinary withheld decide's event commits the
      pre-S3 twelve-key formula. Its `record_sha256` is `Canonical.sha256/1`
      of the twelve stored attributes, computed independently of
      `RecordHash`; its create `changes` keys are those twelve; the chain
      verifies. It passes at this pre-S3 head (observed) and must stay green
      after the migration.
    * T-H4 (a, b): an ordinary row inserted raw with the four exception
      columns SQL NULL, and a kernel event whose `record_sha256` is the
      independently computed twelve-key hash, verifies; tampering with
      `reason`, `decided_at` (withheld row) or `evidence_sha256` (calibration
      row) is reported `:record_hash_mismatch`.
    * T-H5 (c, new): a demo-exception row inserted raw (CHECK-valid), with a
      kernel event of its row hash, commits all sixteen keys, its hash differs
      from the twelve-key formula, the chain verifies, and tampering with each
      member to another CHECK-valid value is reported. This is not claimed as
      a kill of the "any member nil" mutant: every member of a demo row is
      non-nil (binding correction 2).

  T-H6 (c, old) runs in the migration campaign only (Codex OQ5): dropping
  `model_result_releases_pair` to tamper an ordinary row's member is DDL
  under a schema lock, so it stays out of the ordinary suite. The ordinary
  suite keeps its two halves without DDL: the pure partial-group vectors
  (`SdrAgent.Audit.RecordHashContinuityTest`, T-H2) and the CHECK backstop
  (`SdrAgent.Agents.DemoExceptionConstraintsTest`, T-S1: a non-NULL member,
  the empty string or JSON `null` on an ordinary row is rejected).

  Every expected SQL error runs in a savepoint (`raw_error/2`, rolled-back
  transactions); tampering runs in a rolled-back savepoint per case.

  RED report labels: `control` passes now and after GREEN; T-H4 and T-H5
  fail on their guard (structural: the four columns are absent at this
  head).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash

  @twelve [
    :id,
    :disposition,
    :reason,
    :projection_version,
    :method,
    :evidence_sha256,
    :decided_at,
    :trace_id,
    :span_id,
    :tenant_id,
    :model_invocation_id,
    :wire_witness_link_id
  ]
  @members [
    :exception_policy_id,
    :exception_expires_at,
    :exception_basis,
    :exception_basis_sha256
  ]
  @v4 "claude-message-json/4+prompt-builder/1"
  @subject "SdrAgent.Agents.ModelResultRelease"

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    %{tenant: tenant, run: run, agent: agent, rec: rec}
  end

  ## Fixtures and helpers

  defp invocation!(ctx, key), do: AgentsFixtures.claude_completed!(ctx.run, ctx.agent, key)

  defp twelve_hex(row) do
    @twelve
    |> Map.new(&{&1, Map.fetch!(row, &1)})
    |> Canonical.sha256()
    |> Base.encode16(case: :lower)
  end

  defp reload!(ctx, id) do
    {:ok, row} = Ash.get(ModelResultRelease, id, Kernel.integrity_opts(ctx.tenant.id))
    row
  end

  defp verify(ctx) do
    {:ok, report} = Audit.verify_chain(actor: human(:admin, ctx.tenant))
    report
  end

  defp issue_types(report, id),
    do: for(%{subject_id: ^id, type: type} <- report.issues, do: type)

  defp exception_columns! do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'model_result_releases' " <>
          "AND column_name = ANY($1)",
        [Enum.map(@members, &Atom.to_string/1)]
      )

    present = rows |> List.flatten() |> Enum.map(&String.to_existing_atom/1)

    assert Enum.sort(present) == Enum.sort(@members),
           "C2* S3: columns model_result_releases.#{inspect(@members -- present)} are not implemented"
  end

  # Inserts one row (every column given; the four members default to SQL
  # NULL) and returns its id. Parameters are text, cast in SQL.
  defp insert!(ctx, invocation, attrs) do
    id = Ash.UUIDv7.generate()

    row =
      Map.merge(
        %{
          "id" => id,
          "tenant_id" => ctx.tenant.id,
          "model_invocation_id" => invocation.id,
          "wire_witness_link_id" => nil,
          "projection_version" => nil,
          "method" => nil,
          "evidence_sha256" => nil,
          "decided_at" => "2026-10-28 12:00:00.000000",
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
          "exception_policy_id" => nil,
          "exception_expires_at" => nil,
          "exception_basis" => nil,
          "exception_basis_sha256" => nil
        },
        attrs
      )

    types = %{
      "id" => "uuid",
      "tenant_id" => "uuid",
      "model_invocation_id" => "uuid",
      "wire_witness_link_id" => "uuid",
      "decided_at" => "timestamp",
      "exception_expires_at" => "timestamp",
      "exception_basis" => "jsonb"
    }

    columns = Map.keys(row)

    values =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {c, i} -> "$#{i}::text::#{Map.get(types, c, "text")}" end)

    Repo.query!(
      "INSERT INTO model_result_releases (#{Enum.join(columns, ", ")}) VALUES (#{values})",
      Enum.map(columns, &Map.fetch!(row, &1))
    )

    id
  end

  # A kernel-appended `model.result.*` event for `row` committing
  # `record_sha256` and the create `changes` (the canonical JSON form).
  defp append_event!(ctx, row, event_type, record_sha256, changes) do
    {:ok, _event} =
      Audit.append(
        %{
          event_type: event_type,
          category: :model,
          subject_resource: @subject,
          subject_id: row.id,
          action: "decide",
          model_invocation_id: row.model_invocation_id,
          payload: %{
            action: "decide",
            changes: Canonical.normalize(changes),
            arguments: %{},
            record_sha256: record_sha256
          }
        },
        actor: system_actor(:kernel, ctx.tenant)
      )

    :ok
  end

  # Runs `sql` with triggers off (`tamper!/2`) and verifies, all inside a
  # rolled-back savepoint; returns the subject's issue types. The savepoint
  # is opened with `Audit.transaction/1`: `verify_chain` is a guarded call,
  # refused inside any other transaction (`SdrAgent.Audit.Guard`).
  defp tampered_issues(ctx, id, sql, params) do
    {:error, {:issues, types}} =
      Audit.transaction(fn ->
        tamper!(sql, params)
        Repo.rollback({:issues, issue_types(verify(ctx), id)})
      end)

    types
  end

  defp demo_basis(policy_id \\ "c2star-demo-v4/1") do
    %{
      "schema" => "c2star-basis/1",
      "policy" => %{
        "id" => policy_id,
        "entry_sha256" => hex(digest("entry")),
        "acceptance_ref" => "D-223"
      },
      "evidence" => %{"response_thinking_count" => 1}
    }
  end

  ## T-H3

  test "T-H3 control: an ordinary decide commits the pre-S3 twelve-key formula and changes",
       ctx do
    invocation = invocation!(ctx, "h3-withheld")

    assert {:ok, release} =
             Agents.decide_result_release(
               %{
                 model_invocation_id: invocation.id,
                 disposition: :withheld,
                 reason: :witness_missing
               },
               actor: ctx.agent
             )

    row = reload!(ctx, release.id)
    assert [event] = events_of_type(ctx.tenant, "model.result.withheld")
    assert event.subject_id == row.id
    assert event.payload["record_sha256"] == twelve_hex(row)

    assert event.payload["changes"] |> Map.keys() |> Enum.sort() ==
             @twelve |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    report = verify(ctx)
    assert report.valid?, inspect(report.issues)
  end

  ## T-H4

  test "T-H4 (a, b): a pre-S3-hashed ordinary row verifies; tampering a pre-S3 attribute is reported",
       ctx do
    withheld_invocation = invocation!(ctx, "h4-withheld")
    calibration_invocation = invocation!(ctx, "h4-calibration")

    exception_columns!()

    withheld =
      reload!(
        ctx,
        insert!(ctx, withheld_invocation, %{
          "disposition" => "withheld",
          "reason" => "witness_missing"
        })
      )

    calibration =
      reload!(
        ctx,
        insert!(ctx, calibration_invocation, %{
          "disposition" => "calibration",
          "reason" => "calibration",
          "evidence_sha256" => hex(digest("calibration evidence"))
        })
      )

    for {row, type} <- [
          {withheld, "model.result.withheld"},
          {calibration, "model.result.calibration"}
        ] do
      assert Enum.all?(@members, &is_nil(Map.fetch!(row, &1))), "the four members load nil"
      append_event!(ctx, row, type, twelve_hex(row), Map.new(@twelve, &{&1, Map.fetch!(row, &1)}))
    end

    report = verify(ctx)
    assert report.valid?, inspect(report.issues)

    for {label, row, sql, params} <- [
          {"reason", withheld,
           "UPDATE model_result_releases SET reason = 'witness_timeout' WHERE id = $1", []},
          {"decided_at", withheld,
           "UPDATE model_result_releases SET decided_at = decided_at + interval '1 second' WHERE id = $1",
           []},
          {"evidence_sha256", calibration,
           "UPDATE model_result_releases SET evidence_sha256 = $2 WHERE id = $1",
           [hex(digest("other evidence"))]}
        ] do
      types = tampered_issues(ctx, row.id, sql, [Ecto.UUID.dump!(row.id) | params])
      assert types == [:record_hash_mismatch], "#{label}: #{inspect(types)}"
    end
  end

  ## T-H5

  test "T-H5 (c): a demo-exception row commits all four members; tampering any is reported",
       ctx do
    invocation = invocation!(ctx, "h5-demo")
    link = AgentsFixtures.reconciled_link!(invocation, ctx.rec, link_status: :inferred)

    exception_columns!()

    id =
      insert!(ctx, invocation, %{
        "disposition" => "demo_exception",
        "reason" => "v4_uncalibrated",
        "wire_witness_link_id" => link.id,
        "projection_version" => @v4,
        "method" => "propagated_id",
        "exception_policy_id" => "c2star-demo-v4/1",
        "exception_expires_at" => "2026-11-01 06:00:00.000000",
        "exception_basis" => Jason.encode!(demo_basis()),
        "exception_basis_sha256" => hex(digest("basis"))
      })

    row = reload!(ctx, id)
    map = RecordHash.canonical_map(row)
    assert map |> Map.keys() |> Enum.sort() == Enum.sort(@twelve ++ @members)

    assert Enum.all?(@members, &(not is_nil(Map.fetch!(row, &1)))),
           "the four members load non-nil"

    assert RecordHash.hex(row) != twelve_hex(row), "the members enter the hash"

    append_event!(ctx, row, "model.result.demo_exception", RecordHash.hex(row), map)
    [event] = events_of_type(ctx.tenant, "model.result.demo_exception")

    assert event.payload["changes"] |> Map.keys() |> Enum.sort() ==
             (@twelve ++ @members) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    report = verify(ctx)
    assert report.valid?, inspect(report.issues)

    for {label, sql, params} <- [
          {"exception_policy_id (with the basis policy id it must equal)",
           "UPDATE model_result_releases SET exception_policy_id = 'c2star-demo-v4/2', " <>
             "exception_basis = $2::text::jsonb WHERE id = $1",
           [Jason.encode!(demo_basis("c2star-demo-v4/2"))]},
          {"exception_expires_at",
           "UPDATE model_result_releases SET exception_expires_at = exception_expires_at - " <>
             "interval '1 day' WHERE id = $1", []},
          {"exception_basis",
           "UPDATE model_result_releases SET exception_basis = " <>
             "jsonb_set(exception_basis, '{evidence,response_thinking_count}', '2') WHERE id = $1",
           []},
          {"exception_basis_sha256",
           "UPDATE model_result_releases SET exception_basis_sha256 = $2 WHERE id = $1",
           [hex(digest("other basis"))]}
        ] do
      types = tampered_issues(ctx, id, sql, [Ecto.UUID.dump!(id) | params])
      assert types == [:record_hash_mismatch], "#{label}: #{inspect(types)}"
    end
  end
end
