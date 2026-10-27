# Shared by the C2* slice S3 release-migration campaign's probe scripts
# (`release_migration/{baseline,probe,demo}.exs`; S3 plan r2 section 9;
# `SdrAgent.Agents.ReleaseMigrationTest`, `:external`). Each script runs in
# its own BEAM under `MIX_ENV=test`, against the one disposable database the
# parent campaign claimed, only after `SdrAgent.WitnessMigration.start!/1`
# validated that target and started the application.
#
# The OLD (pre-S3) baseline build loads these bytes too, so this module
# uses only APIs present in both builds and reads the release table through
# SQL that names its columns explicitly. Every check is a predicate over
# stored rows, events, catalogs or the chain verifier, never a fixed string:
# "permitted" when the property holds (or a tampered state went unnoticed),
# "refused:<code>" when the verifier or the database refused.
defmodule SdrAgent.ReleaseMigration do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo

  # The pre-S3 table's twelve columns and the four S3 exception columns.
  @twelve ~w(id disposition reason projection_version method evidence_sha256 decided_at
             trace_id span_id tenant_id model_invocation_id wire_witness_link_id)
  @members ~w(exception_policy_id exception_expires_at exception_basis exception_basis_sha256)
  @member_atoms [
    :exception_policy_id,
    :exception_expires_at,
    :exception_basis,
    :exception_basis_sha256
  ]
  # The only events a probe itself commits: its own chain verification and,
  # on the first append under a new build identity, the provenance record.
  @probe_appends ~w(audit.access.chain_verify system.provenance.recorded)
  @subject "SdrAgent.Agents.ModelResultRelease"
  @v4 "claude-message-json/4+prompt-builder/1"
  @s3_suffix "_c2star_s3_demo_exception_release.exs"

  @doc "Writes one probe result for the harness (`Harness.probe_checks/3`)."
  def write_result!(out, database, label, checks) do
    File.write!(
      out,
      JSON.encode!(%{"database" => database, "label" => label, "checks" => checks})
    )
  end

  ## DB #1, "predecessor": the OLD build writes and verifies the baseline

  @doc """
  Decides one withheld and one released ordinary release through the
  domain API of the running (OLD) build, verifies the chain, and records
  everything later states compare against in `path`.
  """
  def baseline!("predecessor", path) do
    tenant = AuditCase.bootstrap!()
    AgentsFixtures.grant!(tenant, %{}, AuditCase.human(:admin, tenant))
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    AgentsFixtures.put_allowlist!()
    rec = Actor.system(:reconciler, tenant.id)
    withheld = AgentsFixtures.claude_completed!(run, agent, "release-migration-withheld")
    released = AgentsFixtures.claude_completed!(run, agent, "release-migration-released")
    link = AgentsFixtures.reconciled_link!(released, rec)

    {:ok, withheld_release} =
      Agents.decide_result_release(
        %{model_invocation_id: withheld.id, disposition: :withheld, reason: :witness_missing},
        actor: agent
      )

    {:ok, released_release} =
      Agents.decide_result_release(
        %{
          model_invocation_id: released.id,
          disposition: :released,
          reason: :reconciled,
          wire_witness_link_id: link.id
        },
        actor: agent
      )

    chain = verify(tenant.id)
    releases = %{"withheld" => withheld_release.id, "released" => released_release.id}

    capture = %{
      "tenant_id" => tenant.id,
      "releases" =>
        Map.new(releases, fn {name, id} ->
          {name,
           %{"id" => id, "columns" => columns!(id), "record_sha256" => record_hex(tenant.id, id)}}
        end),
      "events" => events!(),
      "heads" => heads!(),
      "constraints" => constraints!()
    }

    File.write!(path, JSON.encode!(capture))

    written? =
      withheld_release.disposition == :withheld and released_release.disposition == :released and
        path |> File.read!() |> JSON.decode!() == capture

    %{
      "baseline_written" => permitted(written?),
      "chain_valid" => chain,
      "withheld_event_record_hash" =>
        event_hash(tenant.id, withheld_release.id, "model.result.withheld"),
      "released_event_record_hash" =>
        event_hash(tenant.id, released_release.id, "model.result.released"),
      "exception_columns_absent" => permitted(exception_columns!() == [])
    }
  end

  ## DB #1, "up" / "down" / "up_again": what the baseline committed is retained

  @doc """
  Compares the stored baseline with its capture, verifies the chain,
  accounts for every later event, and runs each tamper in a rolled-back
  transaction; plus the state's schema facts.
  """
  def probe!(label, path) when label in ["up", "down", "up_again"] do
    capture = path |> File.read!() |> JSON.decode!()
    tenant_id = capture["tenant_id"]
    events = captured_events_unchanged(capture)
    records = captured_records_unchanged(capture)
    chain = verify(tenant_id)
    withheld = capture["releases"]["withheld"]["id"]

    tamper =
      tampered(tenant_id, withheld, [
        {"UPDATE model_result_releases SET reason = 'witness_timeout' WHERE id = $1",
         [uuid(withheld)]}
      ])

    Map.merge(
      %{
        "chain_valid" => chain,
        "captured_events_unchanged" => events,
        "captured_record_hashes_unchanged" => records,
        "appends_accounted" => appends_accounted(capture),
        "tamper_reason_detected" => tamper
      },
      state_checks(label, capture)
    )
  end

  defp state_checks("down", capture) do
    %{
      "exception_columns_absent" => permitted(exception_columns!() == []),
      "predecessor_constraints_restored" => permitted(constraints!() == capture["constraints"])
    }
  end

  defp state_checks(_up, capture) do
    tenant_id = capture["tenant_id"]
    released = capture["releases"]["released"]["id"]
    withheld = capture["releases"]["withheld"]["id"]

    %{
      "exception_columns_present" => permitted(exception_columns!() == Enum.sort(@members)),
      "old_row_exception_member_detected" => old_row_member(tenant_id, released),
      "old_row_json_null_refused" =>
        attempt(
          "UPDATE model_result_releases SET exception_basis = 'null'::jsonb WHERE id = $1",
          [uuid(withheld)]
        )
    }
  end

  # T-H6 (campaign only): with `_pair` dropped inside the rolled-back
  # transaction, one exception member on an ordinary row, as a policy id and
  # as the empty string, must each be reported.
  defp old_row_member(tenant_id, id) do
    results =
      for value <- ["c2star-demo-v4/1", ""] do
        tampered(tenant_id, id, [
          {"ALTER TABLE model_result_releases DROP CONSTRAINT model_result_releases_pair", []},
          {"UPDATE model_result_releases SET exception_policy_id = $2 WHERE id = $1",
           [uuid(id), value]}
        ])
      end

    Enum.find(results, hd(results), &(&1 != "refused:record_hash_mismatch"))
  end

  defp captured_events_unchanged(capture) do
    current = Map.new(events!(), &{&1["id"], &1})
    changed = Enum.reject(capture["events"], &(current[&1["id"]] == &1))
    if changed == [], do: "permitted", else: "refused:event_changed"
  end

  defp captured_records_unchanged(capture) do
    tenant_id = capture["tenant_id"]

    same? =
      Enum.all?(capture["releases"], fn {_name, release} ->
        columns!(release["id"]) == release["columns"] and
          record_hex(tenant_id, release["id"]) == release["record_sha256"]
      end)

    if same?, do: "permitted", else: "refused:record_changed"
  end

  # Every event now stored is a captured one, or comes after its tenant's
  # captured head and is one of the probes' own appends.
  defp appends_accounted(capture) do
    captured = MapSet.new(capture["events"], & &1["id"])
    heads = Map.new(capture["heads"], &{&1["tenant_id"], &1["last_sequence"]})

    accounted? =
      Enum.all?(events!(), fn event ->
        MapSet.member?(captured, event["id"]) or
          (is_integer(heads[event["tenant_id"]]) and event["sequence"] > heads[event["tenant_id"]] and
             event["event_type"] in @probe_appends)
      end)

    if accounted?, do: "permitted", else: "refused:unaccounted_append"
  end

  ## DB #2: a demo row makes `down` refuse; the refusal rolls back fully

  @doc """
  "up": commits one CHECK-valid demo row (raw insert) and its kernel event,
  verifies, detects a rolled-back tamper and records the state in `path`.
  "after_refusal": proves that state is exactly retained.
  """
  def demo!("up", path) do
    tenant = AuditCase.bootstrap!()
    AgentsFixtures.grant!(tenant, %{}, AuditCase.human(:admin, tenant))
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    AgentsFixtures.put_allowlist!()
    rec = Actor.system(:reconciler, tenant.id)
    invocation = AgentsFixtures.claude_completed!(run, agent, "release-migration-demo")
    link = AgentsFixtures.reconciled_link!(invocation, rec, link_status: :inferred)
    id = insert_demo!(tenant.id, invocation.id, link.id)
    {:ok, row} = Ash.get(ModelResultRelease, id, Kernel.integrity_opts(tenant.id))
    append_demo_event!(tenant.id, row)

    committed? =
      row.disposition == :demo_exception and
        Enum.all?(@member_atoms, &(not is_nil(Map.fetch!(row, &1))))

    chain = verify(tenant.id)

    tamper =
      tampered(tenant.id, id, [
        {"UPDATE model_result_releases SET exception_basis_sha256 = $2 WHERE id = $1",
         [uuid(id), String.duplicate("0", 64)]}
      ])

    File.write!(
      path,
      JSON.encode!(%{
        "tenant_id" => tenant.id,
        "demo" => %{
          "id" => id,
          "columns" => columns!(id, @twelve ++ @members),
          "record_sha256" => RecordHash.hex(row)
        },
        "constraints" => constraints!(),
        "table" => table_columns!(),
        "migrations" => migrations!()
      })
    )

    %{
      "demo_row_committed" => permitted(committed?),
      "chain_valid" => chain,
      "tamper_basis_sha256_detected" => tamper
    }
  end

  def demo!("after_refusal", path) do
    capture = path |> File.read!() |> JSON.decode!()
    tenant_id = capture["tenant_id"]
    id = capture["demo"]["id"]
    migrations = migrations!()

    row_same? =
      columns!(id, @twelve ++ @members) == capture["demo"]["columns"] and
        record_hex(tenant_id, id) == capture["demo"]["record_sha256"]

    checks = %{
      "migration_still_applied" =>
        permitted(migrations == capture["migrations"] and s3_version!() in migrations),
      "exception_columns_present" => permitted(exception_columns!() == Enum.sort(@members)),
      "constraints_unchanged" =>
        permitted(
          constraints!() == capture["constraints"] and table_columns!() == capture["table"]
        ),
      "demo_row_unchanged" => permitted(row_same?)
    }

    Map.put(checks, "chain_valid", verify(tenant_id))
  end

  defp insert_demo!(tenant_id, invocation_id, link_id) do
    id = Ash.UUIDv7.generate()

    basis = %{
      "schema" => "c2star-basis/1",
      "policy" => %{"id" => "c2star-demo-v4/1", "acceptance_ref" => "D-223"},
      "campaign" => "release-migration DB #2"
    }

    row = [
      {"id", id, "uuid"},
      {"tenant_id", tenant_id, "uuid"},
      {"model_invocation_id", invocation_id, "uuid"},
      {"wire_witness_link_id", link_id, "uuid"},
      {"disposition", "demo_exception", "text"},
      {"reason", "v4_uncalibrated", "text"},
      {"projection_version", @v4, "text"},
      {"method", "propagated_id", "text"},
      {"decided_at", "2026-10-28 12:00:00.000000", "timestamp"},
      {"trace_id", "0123456789abcdef0123456789abcdef", "text"},
      {"span_id", "0123456789abcdef", "text"},
      {"exception_policy_id", "c2star-demo-v4/1", "text"},
      {"exception_expires_at", "2026-11-01 06:00:00.000000", "timestamp"},
      {"exception_basis", JSON.encode!(basis), "jsonb"},
      {"exception_basis_sha256", basis |> Canonical.sha256() |> Base.encode16(case: :lower),
       "text"}
    ]

    columns = Enum.map_join(row, ", ", &elem(&1, 0))

    values =
      row
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{_column, _value, type}, i} -> "$#{i}::text::#{type}" end)

    SQL.query!(
      Repo,
      "INSERT INTO model_result_releases (#{columns}) VALUES (#{values})",
      Enum.map(row, &elem(&1, 1))
    )

    id
  end

  defp append_demo_event!(tenant_id, row) do
    {:ok, _event} =
      Audit.append(
        %{
          event_type: "model.result.demo_exception",
          category: :model,
          subject_resource: @subject,
          subject_id: row.id,
          action: "decide",
          model_invocation_id: row.model_invocation_id,
          payload: %{
            action: "decide",
            changes: Canonical.normalize(RecordHash.canonical_map(row)),
            arguments: %{},
            record_sha256: RecordHash.hex(row)
          }
        },
        actor: Actor.system(:kernel, tenant_id)
      )

    :ok
  end

  defp s3_version! do
    [version] =
      for file <- File.ls!(Path.join(File.cwd!(), "priv/repo/migrations")),
          String.ends_with?(file, @s3_suffix),
          do: file |> String.split("_", parts: 2) |> hd() |> String.to_integer()

    version
  end

  ## Shared predicates and reads (SQL; columns named explicitly)

  defp permitted(true), do: "permitted"
  defp permitted(false), do: "refused:mismatch"

  defp auditor(tenant_id), do: struct(Actor, type: :auditor_cli, tenant_id: tenant_id)

  # Verifies (committing the verification's own access event).
  defp verify(tenant_id) do
    {:ok, report} = Audit.verify_chain(actor: auditor(tenant_id))
    if report.valid?, do: "permitted", else: "refused:#{hd(report.issues).type}"
  end

  # Runs `statements` with triggers off, then verifies, all inside a
  # rolled-back transaction (`Audit.transaction/1`: verification is a
  # guarded call); the subject's first issue type, or "permitted".
  defp tampered(tenant_id, id, statements) do
    {:error, {:issues, types}} =
      Audit.transaction(fn ->
        Enum.each(statements, fn {sql, params} -> AuditCase.tamper!(sql, params) end)
        {:ok, report} = Audit.verify_chain(actor: auditor(tenant_id))
        Repo.rollback({:issues, for(%{subject_id: ^id, type: type} <- report.issues, do: type)})
      end)

    case types do
      [] -> "permitted"
      [type | _] -> "refused:#{type}"
    end
  end

  # One raw statement with triggers off, always rolled back: "permitted" or
  # "refused:<postgres code>".
  defp attempt(sql, params) do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

      case SQL.query(Repo, sql, params) do
        {:ok, %{num_rows: 1}} -> Repo.rollback(:permitted)
        {:ok, other} -> Repo.rollback({:unexpected, other.num_rows})
        {:error, %Postgrex.Error{postgres: %{code: code}}} -> Repo.rollback({:refused, code})
      end
    end)
    |> case do
      {:error, :permitted} -> "permitted"
      {:error, {:refused, code}} -> "refused:#{code}"
      other -> "unexpected:#{inspect(other)}"
    end
  end

  defp event_hash(tenant_id, id, event_type) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT payload->>'record_sha256' FROM audit_events " <>
          "WHERE subject_resource = $1 AND subject_id = $2 AND event_type = $3",
        [@subject, id, event_type]
      )

    if rows == [[record_hex(tenant_id, id)]],
      do: "permitted",
      else: "refused:record_hash_mismatch"
  end

  defp record_hex(tenant_id, id) do
    {:ok, row} = Ash.get(ModelResultRelease, id, Kernel.integrity_opts(tenant_id))
    RecordHash.hex(row)
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp columns!(id, names \\ @twelve) do
    fields = Enum.map_join(names, ", ", &"'#{&1}', #{&1}")

    %{rows: [[json]]} =
      SQL.query!(
        Repo,
        "SELECT json_build_object(#{fields})::text FROM model_result_releases WHERE id = $1",
        [uuid(id)]
      )

    json
  end

  defp events! do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT id::text, tenant_id::text, sequence, event_type, encode(event_hash, 'hex'), " <>
          "encode(sha256(convert_to(row_to_json(e)::text, 'UTF8')), 'hex') " <>
          "FROM audit_events e ORDER BY tenant_id, sequence",
        []
      )

    for [id, tenant_id, sequence, type, hash, row] <- rows do
      %{
        "id" => id,
        "tenant_id" => tenant_id,
        "sequence" => sequence,
        "event_type" => type,
        "event_hash" => hash,
        "row_sha256" => row
      }
    end
  end

  defp heads! do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT tenant_id::text, last_sequence, encode(last_event_hash, 'hex') " <>
          "FROM audit_chain_heads ORDER BY tenant_id",
        []
      )

    for [tenant_id, sequence, hash] <- rows,
        do: %{"tenant_id" => tenant_id, "last_sequence" => sequence, "last_event_hash" => hash}
  end

  defp constraints! do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT conname::text, pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conrelid = 'model_result_releases'::regclass AND contype = 'c' ORDER BY conname",
        []
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp exception_columns! do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name::text FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'model_result_releases' " <>
          "AND column_name = ANY($1) ORDER BY column_name",
        [@members]
      )

    List.flatten(rows)
  end

  defp table_columns! do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name::text, data_type::text FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'model_result_releases' " <>
          "ORDER BY ordinal_position",
        []
      )

    rows
  end

  defp migrations! do
    %{rows: rows} = SQL.query!(Repo, "SELECT version FROM schema_migrations ORDER BY version", [])
    List.flatten(rows)
  end
end
