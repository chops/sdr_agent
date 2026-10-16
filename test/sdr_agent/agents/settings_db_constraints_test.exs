defmodule SdrAgent.Agents.SettingsDbConstraintsTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 5 tests 4, 5, 16 and 17,
  and the database part of 7a; implementation obligations 1 and 2): the
  database itself enforces the settings contracts, whatever the
  application does — append-only revisions and snapshots, the per-kind
  checks and composite foreign keys of section 3.2, the AgentRun cutover
  trigger, and no orphan snapshot when the run insert fails.

  Rows are written with raw SQL (each refusal in its own savepoint via
  `SdrAgent.AuditCase.raw_error/2`); a foreign tenant's rows are written
  with triggers disabled (`tamper!/2`), since the singleton tenant table
  holds one tenant. Every negative case has a positive control first, so a
  refusal is attributable to the rule under test.

  RED: the tables and columns do not exist; each test fails on an explicit
  `C4-01a:` table or column assertion after its fixtures.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.SettingsFixtures

  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures

  @moduletag :c4_01a

  setup do
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant), agent: system_actor(:agent_runtime, tenant)}
  end

  ## Raw rows

  defp u(nil), do: nil
  defp u(id), do: Ecto.UUID.dump!(id)

  defp rand_hex(bytes), do: to_hex(:crypto.strong_rand_bytes(bytes))

  defp now_sql, do: {:sql, "(now() AT TIME ZONE 'utc')"}

  defp insert_sql(table, columns) do
    {names, placeholders, params, _} =
      Enum.reduce(columns, {[], [], [], 1}, fn
        {name, {:sql, expr}}, {ns, ps, vs, i} -> {[name | ns], [expr | ps], vs, i}
        {name, value}, {ns, ps, vs, i} -> {[name | ns], ["$#{i}" | ps], [value | vs], i + 1}
      end)

    sql =
      "INSERT INTO #{table} (#{names |> Enum.reverse() |> Enum.join(", ")}) " <>
        "VALUES (#{placeholders |> Enum.reverse() |> Enum.join(", ")})"

    {sql, Enum.reverse(params)}
  end

  defp insert!(table, columns) do
    {sql, params} = insert_sql(table, columns)
    result = SQL.query(SdrAgent.Repo, sql, params)

    assert match?({:ok, _}, result),
           "C4-01a: positive control on #{table} refused: #{inspect(result)}"
  end

  defp insert_tampered!(table, columns) do
    {sql, params} = insert_sql(table, columns)
    tamper!(sql, params)
  end

  defp refused?(table, columns) do
    {sql, params} = insert_sql(table, columns)
    refused_by_db?(raw_error(sql, params))
  end

  defp revision_row(ctx, kind, overrides \\ []) do
    id = Ash.UUIDv7.generate()

    contents =
      Map.new(kinds(), fn k -> {k, if(k == kind, do: stored_content(kind), else: nil)} end)

    base = [
      id: u(id),
      tenant_id: u(ctx.tenant.id),
      kind: Atom.to_string(kind),
      number: 1,
      supersedes_id: nil,
      raised_fields: [],
      offering_profile: contents.offering_profile,
      booking_link: contents.booking_link,
      writing_guide: contents.writing_guide,
      research_brief: contents.research_brief,
      operational_limits: contents.operational_limits,
      content_sha256: rand_hex(32),
      note: nil,
      created_by_id: u(ctx.admin.id),
      inserted_at: now_sql(),
      trace_id: rand_hex(16),
      span_id: rand_hex(8)
    ]

    {id, Keyword.merge(base, overrides)}
  end

  defp stored_content(:offering_profile),
    do: %{
      "name" => "Example Widgets Scheduler",
      "summary" => "Synthetic.",
      "audience" => "",
      "items" => [%{"id" => "calendar_sync", "kind" => "feature", "text" => "Syncs."}]
    }

  defp stored_content(:booking_link), do: %{"url" => "https://book.example.test/demo/intro"}
  defp stored_content(:writing_guide), do: %{"text" => "Synthetic guide."}
  defp stored_content(:research_brief), do: %{"guidance" => "Synthetic.", "depth" => "standard"}
  defp stored_content(:operational_limits), do: limits_map(limit_defaults())

  defp code_default_slot(kind),
    do: [
      {:"#{kind}_source", "code_default"},
      {:"#{kind}_revision_id", nil},
      {:"#{kind}_code_default_version", "1"},
      {:"#{kind}_content_sha256", rand_hex(32)}
    ]

  defp absent_slot(kind),
    do: [
      {:"#{kind}_source", "absent"},
      {:"#{kind}_revision_id", nil},
      {:"#{kind}_code_default_version", nil},
      {:"#{kind}_content_sha256", nil}
    ]

  defp revision_slot(kind, id, sha),
    do: [
      {:"#{kind}_source", "revision"},
      {:"#{kind}_revision_id", u(id)},
      {:"#{kind}_code_default_version", nil},
      {:"#{kind}_content_sha256", sha}
    ]

  defp snapshot_row(tenant_id, overrides \\ []) do
    id = Ash.UUIDv7.generate()

    base =
      [id: u(id), tenant_id: u(tenant_id)] ++
        absent_slot(:offering_profile) ++
        absent_slot(:booking_link) ++
        code_default_slot(:writing_guide) ++
        code_default_slot(:research_brief) ++
        code_default_slot(:operational_limits) ++
        [
          limits: limits_map(limit_defaults()),
          safeguards_version: "1",
          hash_version: "c4-run-settings-snapshot/1",
          snapshot_sha256: rand_hex(32),
          inserted_at: now_sql(),
          trace_id: rand_hex(16),
          span_id: rand_hex(8)
        ]

    {id, Keyword.merge(base, overrides)}
  end

  # A copy of agent run `run_id` with a new id and `settings_snapshot_id`.
  defp copy_run_sql do
    """
    INSERT INTO agent_runs
    SELECT (jsonb_populate_record(NULL::agent_runs, to_jsonb(r) || jsonb_build_object(
      'id', $2::uuid, 'trigger_signal_id', $3::text, 'operation_id', NULL,
      'retry_of_id', NULL, 'attention_failure_id', NULL,
      'settings_snapshot_id', $4::uuid))).*
    FROM agent_runs r WHERE r.id = $1
    """
  end

  defp copy_run(run_id, snapshot_id) do
    raw_error(copy_run_sql(), [
      u(run_id),
      u(Ash.UUIDv7.generate()),
      "copy-#{System.unique_integer([:positive])}",
      u(snapshot_id)
    ])
  end

  defp reply_run!(ctx) do
    definition = AgentsFixtures.definition!(ctx.tenant)
    attrs = AgentsFixtures.run_attrs(definition, usage_origin: :reply)
    {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
    run
  end

  defp snapshot_id!(run) do
    id = Map.get(run, :settings_snapshot_id)
    assert is_binary(id), "C4-01a: run #{run.id} has no settings_snapshot_id"
    id
  end

  # The ADR-0009 append-only trigger (`SdrAgent.Audit.SQL.append_only/1`).
  defp append_only_refusal?({:error, %Postgrex.Error{postgres: %{message: message}}})
       when is_binary(message),
       do: message =~ "append-only"

  defp append_only_refusal?(_result), do: false

  defp truncate_trigger?(table) do
    SQL.query!(
      SdrAgent.Repo,
      "SELECT count(*) FROM pg_trigger WHERE tgrelid = to_regclass($1) AND NOT tgisinternal " <>
        "AND tgenabled = 'O' AND (tgtype & 32) <> 0",
      [table]
    ).rows != [[0]]
  end

  ## Test 4

  describe "test 4: append-only" do
    test "UPDATE, DELETE and TRUNCATE on revisions and snapshots are refused", ctx do
      require_table!("settings_revisions")
      require_table!("run_settings_snapshots")

      revision = save!(:writing_guide, content(:writing_guide), ctx.admin)
      snapshot_id = ctx |> reply_run!() |> snapshot_id!()

      for {table, id, column} <- [
            {"settings_revisions", revision.id, "note"},
            {"run_settings_snapshots", snapshot_id, "safeguards_version"}
          ] do
        update = raw_error("UPDATE #{table} SET #{column} = #{column} WHERE id = $1", [u(id)])
        assert append_only_refusal?(update), "C4-01a: UPDATE on #{table}: #{inspect(update)}"

        delete = raw_error("DELETE FROM #{table} WHERE id = $1", [u(id)])
        assert append_only_refusal?(delete), "C4-01a: DELETE on #{table}: #{inspect(delete)}"

        assert truncate_trigger?(table), "C4-01a: #{table} has no TRUNCATE trigger"
      end
    end
  end

  ## Test 5

  describe "test 5: revision constraints" do
    test "the embedded attribute must match the kind", ctx do
      require_table!("settings_revisions")
      {_id, valid} = revision_row(ctx, :writing_guide)
      insert!("settings_revisions", valid)

      {_id, wrong} =
        revision_row(ctx, :writing_guide,
          writing_guide: nil,
          booking_link: stored_content(:booking_link)
        )

      assert refused?("settings_revisions", wrong), "wrong embedded attribute for the kind"

      {_id, both} =
        revision_row(ctx, :booking_link, writing_guide: stored_content(:writing_guide))

      assert refused?("settings_revisions", both), "two embedded attributes"

      {_id, none} = revision_row(ctx, :research_brief, research_brief: nil)
      assert refused?("settings_revisions", none), "no embedded attribute"
    end

    test "number and supersedes_id agree; one root per kind; superseded at most once", ctx do
      require_table!("settings_revisions")
      {root, root_row} = revision_row(ctx, :writing_guide)
      insert!("settings_revisions", root_row)

      {_id, orphan} = revision_row(ctx, :writing_guide, number: 2)
      assert refused?("settings_revisions", orphan), "number 2 without supersedes_id"

      {_id, rooted} = revision_row(ctx, :writing_guide, number: 1, supersedes_id: u(root))
      assert refused?("settings_revisions", rooted), "number 1 with supersedes_id"

      {_id, second_root} = revision_row(ctx, :writing_guide)
      assert refused?("settings_revisions", second_root), "a second root of the kind"

      {_id, successor} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(root))
      insert!("settings_revisions", successor)

      {_id, again} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(root))
      assert refused?("settings_revisions", again), "a revision superseded twice"
    end

    test "supersedes_id may not cross kinds or tenants", ctx do
      require_table!("settings_revisions")
      {booking, booking_row} = revision_row(ctx, :booking_link)
      insert!("settings_revisions", booking_row)
      {guide, guide_row} = revision_row(ctx, :writing_guide)
      insert!("settings_revisions", guide_row)

      {_id, cross_kind} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(booking))
      assert refused?("settings_revisions", cross_kind), "cross-kind supersedes_id"

      foreign_tenant = Ash.UUIDv7.generate()
      {foreign, foreign_row} = revision_row(ctx, :research_brief, tenant_id: u(foreign_tenant))
      insert_tampered!("settings_revisions", foreign_row)

      {_id, cross_tenant} =
        revision_row(ctx, :research_brief, number: 2, supersedes_id: u(foreign))

      assert refused?("settings_revisions", cross_tenant), "cross-tenant supersedes_id"

      # Positive control: same tenant, same kind.
      {_id, same} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(guide))
      insert!("settings_revisions", same)
    end

    test "test 7a: raised_fields is refused on a non-limits kind", ctx do
      require_table!("settings_revisions")

      {_id, limits} =
        revision_row(ctx, :operational_limits, raised_fields: ["run_max_model_calls"])

      insert!("settings_revisions", limits)

      {_id, guide} = revision_row(ctx, :writing_guide, raised_fields: ["run_max_model_calls"])
      assert refused?("settings_revisions", guide), "raised_fields on writing_guide"
    end
  end

  describe "test 5: snapshot constraints" do
    setup ctx do
      require_table!("run_settings_snapshots")
      {offering, offering_row} = revision_row(ctx, :offering_profile)
      insert!("settings_revisions", offering_row)
      {guide, guide_row} = revision_row(ctx, :writing_guide)
      insert!("settings_revisions", guide_row)

      {foreign, foreign_row} =
        revision_row(ctx, :offering_profile, tenant_id: u(Ash.UUIDv7.generate()))

      insert_tampered!("settings_revisions", foreign_row)

      %{
        offering: {offering, Keyword.fetch!(offering_row, :content_sha256)},
        guide: {guide, Keyword.fetch!(guide_row, :content_sha256)},
        foreign: {foreign, Keyword.fetch!(foreign_row, :content_sha256)}
      }
    end

    test "a revision slot must reference its own tenant, kind and content hash", ctx do
      {offering, offering_sha} = ctx.offering
      {guide, guide_sha} = ctx.guide
      {foreign, foreign_sha} = ctx.foreign

      {_id, valid} =
        snapshot_row(ctx.tenant.id, revision_slot(:offering_profile, offering, offering_sha))

      insert!("run_settings_snapshots", valid)

      cases = [
        {"wrong kind", revision_slot(:offering_profile, guide, guide_sha)},
        {"wrong content hash", revision_slot(:offering_profile, offering, rand_hex(32))},
        {"wrong tenant", revision_slot(:offering_profile, foreign, foreign_sha)}
      ]

      for {label, slot} <- cases do
        {_id, row} = snapshot_row(ctx.tenant.id, slot)
        assert refused?("run_settings_snapshots", row), "C4-01a: slot with #{label} accepted"
      end
    end

    test "slot column combinations outside the per-kind checks are refused", ctx do
      {offering, offering_sha} = ctx.offering

      cases = [
        {"revision without hash", revision_slot(:offering_profile, offering, nil)},
        {"revision without id", revision_slot(:offering_profile, nil, offering_sha)},
        {"revision with a version",
         revision_slot(:offering_profile, offering, offering_sha) ++
           [offering_profile_code_default_version: "1"]},
        {"code_default with a revision id",
         code_default_slot(:writing_guide) ++ [writing_guide_revision_id: u(offering)]},
        {"code_default without version",
         code_default_slot(:writing_guide) ++ [writing_guide_code_default_version: nil]},
        {"code_default without hash",
         code_default_slot(:writing_guide) ++ [writing_guide_content_sha256: nil]},
        {"code_default for offering", code_default_slot(:offering_profile)},
        {"code_default for booking link", code_default_slot(:booking_link)},
        {"absent writing guide", absent_slot(:writing_guide)},
        {"absent research brief", absent_slot(:research_brief)},
        {"absent operational limits", absent_slot(:operational_limits)},
        {"absent with a hash",
         absent_slot(:booking_link) ++ [booking_link_content_sha256: rand_hex(32)]},
        {"unknown source", [offering_profile_source: "bogus"]},
        {"caller-written kind column", [offering_profile_kind: "writing_guide"]}
      ]

      for {label, slot} <- cases do
        {_id, row} = snapshot_row(ctx.tenant.id, slot)
        assert refused?("run_settings_snapshots", row), "C4-01a: #{label} accepted"
      end

      {_id, valid} = snapshot_row(ctx.tenant.id)
      insert!("run_settings_snapshots", valid)
    end

    test "an AgentRun may not reference another tenant's snapshot", ctx do
      require_column!("agent_runs", "settings_snapshot_id")
      run = reply_run!(ctx)

      {own, own_row} = snapshot_row(ctx.tenant.id)
      insert!("run_settings_snapshots", own_row)
      {foreign, foreign_row} = snapshot_row(Ash.UUIDv7.generate())
      insert_tampered!("run_settings_snapshots", foreign_row)

      assert match?({:error, {:unexpected_success, _}}, copy_run(run.id, own)),
             "C4-01a: positive control: a run copy with its own tenant's snapshot"

      assert refused_by_db?(copy_run(run.id, foreign)), "C4-01a: cross-tenant snapshot accepted"
    end
  end

  ## Test 16

  describe "test 16: AgentRun cutover trigger" do
    test "INSERT with a null snapshot is refused", ctx do
      require_column!("agent_runs", "settings_snapshot_id")
      run = reply_run!(ctx)
      snapshot = snapshot_id!(run)

      assert match?({:error, {:unexpected_success, _}}, copy_run(run.id, snapshot)),
             "positive control: a copy with a snapshot inserts"

      assert refused_by_db?(copy_run(run.id, nil)), "C4-01a: a run without a snapshot inserted"
    end

    test "attaching, replacing or clearing a snapshot by UPDATE is refused", ctx do
      require_column!("agent_runs", "settings_snapshot_id")
      first = reply_run!(ctx)
      second = reply_run!(ctx)
      historical = reply_run!(ctx)
      first_snapshot = snapshot_id!(first)
      second_snapshot = snapshot_id!(second)
      refute first_snapshot == second_snapshot, "each run creation builds its own snapshot"

      tamper!("UPDATE agent_runs SET settings_snapshot_id = NULL WHERE id = $1", [
        u(historical.id)
      ])

      update = "UPDATE agent_runs SET settings_snapshot_id = $2 WHERE id = $1"

      assert refused_by_db?(raw_error(update, [u(historical.id), u(first_snapshot)])),
             "C4-01a: a snapshot was attached to a historical null run"

      assert refused_by_db?(raw_error(update, [u(first.id), u(second_snapshot)])),
             "C4-01a: a run's snapshot was replaced"

      assert refused_by_db?(raw_error(update, [u(first.id), nil])),
             "C4-01a: a run's snapshot was cleared"
    end

    test "historical null-snapshot runs stay readable and still transition", ctx do
      require_column!("agent_runs", "settings_snapshot_id")
      run = reply_run!(ctx)
      tamper!("UPDATE agent_runs SET settings_snapshot_id = NULL WHERE id = $1", [u(run.id)])

      {:ok, historical} = Agents.get_run(run.id, actor: ctx.agent)
      assert historical.settings_snapshot_id == nil
      assert {:ok, %{status: :running} = running} = Agents.start_run(historical, actor: ctx.agent)
      assert {:ok, %{status: :cancelled}} = Agents.cancel_run(running, actor: ctx.agent)
    end
  end

  ## Test 17

  describe "test 17: snapshot rollback" do
    test "a failed run insert leaves no snapshot row", ctx do
      require_table!("run_settings_snapshots")
      before = count_rows("run_settings_snapshots")
      _run = reply_run!(ctx)

      assert count_rows("run_settings_snapshots") == before + 1,
             "C4-01a: :create built no snapshot"

      runs = count_rows("agent_runs")
      definition = AgentsFixtures.definition!(ctx.tenant)

      attrs =
        definition
        |> AgentsFixtures.run_attrs(usage_origin: :reply)
        |> Map.put(:agent_definition_id, Ash.UUIDv7.generate())

      result = observe(fn -> Agents.create_run(attrs, actor: ctx.agent) end)
      refute match?({:ok, _}, result), "the run with a dangling definition was created"
      assert count_rows("run_settings_snapshots") == before + 1, "an orphan snapshot remained"
      assert count_rows("agent_runs") == runs
    end
  end
end
