defmodule SdrAgent.Agents.DemoExceptionConstraintsTest do
  @moduledoc """
  C2* slice S3 RED-2, the `model_result_releases` CHECKs of the demo
  exception (plan r2 §7, §8 T-S1, T-S2, T-S3, T-S4 constraint level, T-S6;
  ADR-0005 C2* amendment item 8; draft r4 §7 item 1).

  Rows are inserted raw (every column named, parameters cast in SQL), each
  expected rejection in a rolled-back savepoint:

    * T-S1: each new or changed CHECK rejects its violation. That includes
      the T-H6 CHECK backstop: any non-NULL member on an ordinary row (the
      empty string and JSON `null` included) is rejected by
      `model_result_releases_pair`.
    * T-S2: the disposition and reason CHECK lists are exactly the 4 and 8
      values, equal to the Ash attribute lists, and the 4 × 8 pair matrix
      accepts exactly the 8 allowed pairs. The list parity alone is a control.
    * T-S3: the append-only triggers reject UPDATE and DELETE of a demo row.
    * T-S4 (constraint level, no DDL): the predecessor bodies of
      `_disposition`, `_reason` and `_pair`, read from the predecessor
      snapshot, evaluate FALSE on a demo row and on no ordinary row. A CHECK
      can be re-added exactly when no row evaluates it FALSE, so `down`
      re-creating them fails while a demo row exists and succeeds without
      one. This replaces the plan's in-savepoint re-add: re-adding a CHECK is
      DDL under a schema lock, which Codex OQ5 keeps out of the ordinary
      suite. The actual `down` refusal is the campaign's DB #2.
    * T-S6: an otherwise-valid demo row is rejected for each non-object or
      incomplete basis (`{}`, no schema, no policy, policy without id,
      policy as a string, JSON `null`, `1`, `"x"`, `[]`), a wrong schema
      literal or a policy id other than the column's, and for a NULL
      `projection_version`, `method` or `exception_expires_at` (the UNKNOWN
      case). The valid demo row is accepted (control inside each test).

  `async: false`: it commits rows inside the sandbox and reads table-wide
  catalog state.

  RED report labels: `control` passes now and after GREEN; every other test
  fails on its guard (structural: the four columns are absent at this
  head).
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Resource.Info
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures

  @members ~w(exception_policy_id exception_expires_at exception_basis exception_basis_sha256)
  @v4 "claude-message-json/4+prompt-builder/1"
  @snapshot "priv/resource_snapshots/repo/model_result_releases/20261012214849.json"
  @dispositions ~w(released withheld calibration demo_exception)
  @reasons ~w(reconciled calibration witness_mismatch witness_missing witness_timeout
              store_unreadable gate_interrupted v4_uncalibrated)
  @withheld_reasons ~w(witness_mismatch witness_missing witness_timeout store_unreadable
                       gate_interrupted)
  @valid_pairs [
                 {"released", "reconciled"},
                 {"calibration", "calibration"},
                 {"demo_exception", "v4_uncalibrated"}
               ] ++
                 for(reason <- @withheld_reasons, do: {"withheld", reason})
  @release_checks ~w(model_result_releases_disposition model_result_releases_reason
                     model_result_releases_pair model_result_releases_exception_window
                     model_result_releases_exception_basis_sha256
                     model_result_releases_exception_basis_shape)

  @types %{
    "id" => "uuid",
    "tenant_id" => "uuid",
    "model_invocation_id" => "uuid",
    "wire_witness_link_id" => "uuid",
    "decided_at" => "timestamp",
    "exception_expires_at" => "timestamp",
    "exception_basis" => "jsonb"
  }

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    invocation = AgentsFixtures.claude_completed!(run, agent, "s-demo")
    link = AgentsFixtures.reconciled_link!(invocation, rec, link_status: :inferred)
    %{tenant: tenant, run: run, agent: agent, rec: rec, invocation: invocation, link: link}
  end

  ## Rows

  defp basis(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "c2star-basis/1",
        "policy" => %{"id" => "c2star-demo-v4/1", "acceptance_ref" => "D-223"},
        "window" => %{"decided_at" => "2026-10-28T12:00:00.000000Z"}
      },
      overrides
    )
  end

  defp base(ctx, invocation, link) do
    %{
      "id" => Ash.UUIDv7.generate(),
      "tenant_id" => ctx.tenant.id,
      "model_invocation_id" => invocation.id,
      "wire_witness_link_id" => link && link.id,
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
    }
  end

  # The valid shape of each disposition, with its (first) allowed reason.
  defp row(ctx, disposition, invocation \\ nil, link \\ :default) do
    invocation = invocation || ctx.invocation
    link = if link == :default, do: ctx.link, else: link

    case disposition do
      "released" ->
        Map.merge(base(ctx, invocation, link), %{
          "disposition" => "released",
          "reason" => "reconciled",
          "projection_version" => "claude-message-json/3+prompt-builder/1",
          "method" => "propagated_id"
        })

      "withheld" ->
        Map.merge(base(ctx, invocation, nil), %{
          "disposition" => "withheld",
          "reason" => "witness_missing"
        })

      "calibration" ->
        Map.merge(base(ctx, invocation, nil), %{
          "disposition" => "calibration",
          "reason" => "calibration",
          "evidence_sha256" => hex(digest("calibration evidence"))
        })

      "demo_exception" ->
        Map.merge(base(ctx, invocation, link), %{
          "disposition" => "demo_exception",
          "reason" => "v4_uncalibrated",
          "projection_version" => @v4,
          "method" => "propagated_id",
          "exception_policy_id" => "c2star-demo-v4/1",
          "exception_expires_at" => "2026-11-01 06:00:00.000000",
          "exception_basis" => Jason.encode!(basis()),
          "exception_basis_sha256" => hex(digest("basis"))
        })
    end
  end

  defp insert_sql(row) do
    columns = Map.keys(row)

    values =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {c, i} -> "$#{i}::text::#{Map.get(@types, c, "text")}" end)

    {"INSERT INTO model_result_releases (#{Enum.join(columns, ", ")}) VALUES (#{values})",
     Enum.map(columns, &Map.fetch!(row, &1))}
  end

  # :inserted, or {:check_violation, constraint} / {code, constraint}; always
  # rolled back.
  defp outcome(row) do
    {sql, params} = insert_sql(row)

    case raw_error(sql, params) do
      {:error, {:unexpected_success, _result}} -> :inserted
      {:error, %Postgrex.Error{postgres: %{code: code} = pg}} -> {code, pg[:constraint]}
    end
  end

  defp insert!(row) do
    {sql, params} = insert_sql(row)
    Repo.query!(sql, params)
    row["id"]
  end

  defp exception_columns! do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'model_result_releases' " <>
          "AND column_name = ANY($1)",
        [@members]
      )

    present = List.flatten(rows)

    assert Enum.sort(present) == Enum.sort(@members),
           "C2* S3: columns model_result_releases.#{inspect(@members -- present)} are not implemented"
  end

  defp constraint_def(name) do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
          "WHERE c.conrelid = 'model_result_releases'::regclass AND c.conname = $1",
        [name]
      )

    definition
  end

  defp quoted_values(definition),
    do: ~r/'([a-z0-9_]+)'/ |> Regex.scan(definition) |> Enum.map(&List.last/1) |> Enum.sort()

  defp ash_values(attribute) do
    ModelResultRelease
    |> Info.attribute(attribute)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  defp rejected?({:check_violation, constraint}), do: constraint in @release_checks
  defp rejected?(_outcome), do: false

  defp assert_rejected(cases) do
    for {label, row} <- cases do
      result = outcome(row)

      assert rejected?(result),
             "#{label}: must be rejected by a release CHECK; got #{inspect(result)}"
    end
  end

  defp assert_valid_rows(ctx) do
    for disposition <- @dispositions do
      result = outcome(row(ctx, disposition))
      assert result == :inserted, "valid #{disposition} row: #{inspect(result)}"
    end
  end

  ## T-S2 parity control

  test "control: the disposition and reason CHECK lists equal the Ash attribute lists" do
    assert quoted_values(constraint_def("model_result_releases_disposition")) ==
             ash_values(:disposition)

    assert quoted_values(constraint_def("model_result_releases_reason")) == ash_values(:reason)
  end

  ## T-S1

  test "T-S1: each new or changed CHECK rejects its violation; ordinary rows keep all four NULL",
       ctx do
    exception_columns!()
    assert_valid_rows(ctx)
    demo = row(ctx, "demo_exception")

    demo_cases =
      [
        {"demo with reason reconciled", %{demo | "reason" => "reconciled"}},
        {"demo without a link", %{demo | "wire_witness_link_id" => nil}},
        {"demo with projection v3",
         %{demo | "projection_version" => "claude-message-json/3+prompt-builder/1"}},
        {"demo with method time_window", %{demo | "method" => "time_window"}},
        {"demo with an evidence digest", %{demo | "evidence_sha256" => hex(digest("e"))}},
        {"demo decided at its expiry", %{demo | "decided_at" => demo["exception_expires_at"]}},
        {"demo decided after its expiry", %{demo | "decided_at" => "2026-11-02 00:00:00.000000"}},
        {"demo with an uppercase basis digest",
         %{demo | "exception_basis_sha256" => String.upcase(hex(digest("basis")))}},
        {"demo with a short basis digest", %{demo | "exception_basis_sha256" => "abc"}},
        {"unknown disposition", %{demo | "disposition" => "demo"}},
        {"unknown reason", %{demo | "reason" => "v5_uncalibrated"}},
        {"withheld with reason v4_uncalibrated",
         %{row(ctx, "withheld") | "reason" => "v4_uncalibrated"}}
      ] ++ for(m <- @members, do: {"demo with #{m} NULL", %{demo | m => nil}})

    member_values = %{
      "exception_policy_id" => ["c2star-demo-v4/1", ""],
      "exception_expires_at" => ["2026-11-01 06:00:00.000000"],
      "exception_basis" => [Jason.encode!(basis()), "null", "{}"],
      "exception_basis_sha256" => [hex(digest("basis"))]
    }

    ordinary_cases =
      for disposition <- ~w(released withheld calibration),
          {member, values} <- member_values,
          value <- values do
        {"#{disposition} with #{member} = #{inspect(value)}",
         %{row(ctx, disposition) | member => value}}
      end

    assert_rejected(demo_cases ++ ordinary_cases)
  end

  ## T-S2

  test "T-S2: the CHECK lists are exactly 4 and 8 values; the 4 × 8 matrix accepts the 8 allowed pairs",
       ctx do
    exception_columns!()

    assert quoted_values(constraint_def("model_result_releases_disposition")) ==
             Enum.sort(@dispositions)

    assert quoted_values(constraint_def("model_result_releases_reason")) == Enum.sort(@reasons)
    assert ash_values(:disposition) == Enum.sort(@dispositions)
    assert ash_values(:reason) == Enum.sort(@reasons)

    accepted =
      for disposition <- @dispositions,
          reason <- @reasons,
          outcome(%{row(ctx, disposition) | "reason" => reason}) == :inserted,
          do: {disposition, reason}

    assert Enum.sort(accepted) == Enum.sort(@valid_pairs)
    assert length(@valid_pairs) == 8
  end

  ## T-S3

  test "T-S3: the append-only triggers reject UPDATE and DELETE of a demo row", ctx do
    exception_columns!()
    id = Ecto.UUID.dump!(insert!(row(ctx, "demo_exception")))

    for sql <- [
          "UPDATE model_result_releases SET reason = 'v4_uncalibrated' WHERE id = $1",
          "UPDATE model_result_releases SET exception_expires_at = exception_expires_at - " <>
            "interval '1 hour' WHERE id = $1",
          "UPDATE model_result_releases SET exception_basis_sha256 = repeat('a', 64) WHERE id = $1",
          "DELETE FROM model_result_releases WHERE id = $1"
        ] do
      result = raw_error(sql, [id])

      assert match?({:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}}, result),
             "#{sql}: #{inspect(result)}"
    end
  end

  ## T-S4

  test "T-S4 (constraint level): the predecessor CHECK bodies reject a demo row and no ordinary row",
       ctx do
    previous =
      @snapshot
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("check_constraints")
      |> Map.new(&{&1["name"], &1["check"]})

    bodies =
      Map.take(previous, ~w(model_result_releases_disposition model_result_releases_reason
                            model_result_releases_pair))

    assert map_size(bodies) == 3

    ordinary =
      for {disposition, key} <- [
            {"released", "s4-released"},
            {"withheld", "s4-withheld"},
            {"calibration", "s4-calibration"}
          ] do
        invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, key)
        link = AgentsFixtures.reconciled_link!(invocation, ctx.rec)
        {invocation, link, disposition}
      end

    exception_columns!()

    ordinary_ids =
      for {invocation, link, disposition} <- ordinary,
          do: Ecto.UUID.dump!(insert!(row(ctx, disposition, invocation, link)))

    false_rows = fn ids ->
      Map.new(bodies, fn {name, body} ->
        %{rows: [[count]]} =
          Repo.query!(
            "SELECT count(*) FROM model_result_releases WHERE id = ANY($1) AND (#{body}) IS FALSE",
            [ids]
          )

        {name, count}
      end)
    end

    assert false_rows.(ordinary_ids) == Map.new(bodies, fn {name, _} -> {name, 0} end),
           "down re-creates the predecessor CHECKs over ordinary rows"

    demo_id = Ecto.UUID.dump!(insert!(row(ctx, "demo_exception")))

    assert false_rows.([demo_id | ordinary_ids]) ==
             Map.new(bodies, fn {name, _} -> {name, 1} end),
           "each predecessor CHECK evaluates FALSE on the demo row, so down fails"
  end

  ## T-S6

  test "T-S6: a demo row is rejected for a non-object or incomplete basis, or an UNKNOWN predicate",
       ctx do
    exception_columns!()
    demo = row(ctx, "demo_exception")
    assert outcome(demo) == :inserted, "control: the valid demo row is accepted"

    basis_cases =
      for {label, json} <- [
            {"{}", "{}"},
            {"no schema", Jason.encode!(Map.delete(basis(), "schema"))},
            {"no policy", Jason.encode!(Map.delete(basis(), "policy"))},
            {"policy without id",
             Jason.encode!(basis(%{"policy" => %{"acceptance_ref" => "D-223"}}))},
            {"policy as a string", Jason.encode!(basis(%{"policy" => "c2star-demo-v4/1"}))},
            {"JSON null", "null"},
            {"1", "1"},
            {"\"x\"", ~s("x")},
            {"[]", "[]"},
            {"schema c2star-basis/2", Jason.encode!(basis(%{"schema" => "c2star-basis/2"}))},
            {"policy id other than the column's",
             Jason.encode!(basis(%{"policy" => %{"id" => "c2star-demo-v4/2"}}))}
          ],
          do: {"basis #{label}", %{demo | "exception_basis" => json}}

    unknown_cases = [
      {"NULL projection_version", %{demo | "projection_version" => nil}},
      {"NULL method", %{demo | "method" => nil}},
      {"NULL exception_expires_at", %{demo | "exception_expires_at" => nil}}
    ]

    assert_rejected(basis_cases ++ unknown_cases)
  end
end
