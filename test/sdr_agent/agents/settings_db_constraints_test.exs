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
  holds one tenant. Every negative case has a positive control and is
  otherwise valid (no competing violation), and each refusal is pinned to its
  SQLSTATE and constraint (or trigger function) name, so it is attributable
  to the rule under test. The constraint and trigger names are C4-01a
  interface choices (Ash/ADR-0009 naming); they are listed in the RED notes.

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

  @rev "settings_revisions"
  @snap "run_settings_snapshots"

  defp u(nil), do: nil
  defp u(id), do: Ecto.UUID.dump!(id)

  defp rand_hex(bytes), do: to_hex(:crypto.strong_rand_bytes(bytes))

  defp now_sql, do: {:sql, "(now() AT TIME ZONE 'utc')"}

  # Unique-key overrides: each override replaces the base column in place.
  defp put_all(row, overrides),
    do: Enum.reduce(overrides, row, fn {key, value}, acc -> Keyword.put(acc, key, value) end)

  defp insert_sql(table, columns) do
    names = Keyword.keys(columns)
    assert names == Enum.uniq(names), "fixture bug: duplicate INSERT columns #{inspect(names)}"

    {placeholders, params, _} =
      Enum.reduce(columns, {[], [], 1}, fn
        {_name, {:sql, expr}}, {ps, vs, i} -> {[expr | ps], vs, i}
        {_name, value}, {ps, vs, i} -> {["$#{i}" | ps], [value | vs], i + 1}
      end)

    sql =
      "INSERT INTO #{table} (#{Enum.join(names, ", ")}) " <>
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

  defp attempt(table, columns) do
    {sql, params} = insert_sql(table, columns)
    raw_error(sql, params)
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

    {id, put_all(base, overrides)}
  end

  defp stored_content(:offering_profile),
    do: %{
      "name" => "Example Widgets Scheduler",
      "summary" => "Synthetic.",
      "audience" => "Synthetic audience.",
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

    {id, put_all(base, overrides)}
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

  # The ADR-0009 append-only trigger (`SdrAgent.Audit.SQL.append_only/1`):
  # restrict_violation "<table> is append-only: <op> rejected".
  defp assert_append_only(result, table, op) do
    message = trigger_message(result)

    assert is_binary(message) and message =~ "#{table} is append-only" and message =~ op,
           "C4-01a: #{op} on #{table} was not refused by its append-only trigger: " <>
             inspect(result, limit: 6, printable_limit: 300)
  end

  # The cutover trigger on agent_runs (section 3.2 AgentRun row).
  defp assert_cutover(result, label) do
    message = trigger_message(result)

    assert is_binary(message) and message =~ "settings_snapshot_id",
           "C4-01a: #{label}: not refused by the cutover trigger: " <>
             inspect(result, limit: 6, printable_limit: 300)
  end

  # The enabled TRUNCATE trigger `<table>_guard_truncate` runs exactly the
  # append-only function `<table>_append_only()`.
  defp truncate_guard_function(table) do
    SQL.query!(
      SdrAgent.Repo,
      "SELECT p.proname FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid " <>
        "WHERE t.tgrelid = to_regclass($1) AND t.tgname = $2 AND NOT t.tgisinternal " <>
        "AND t.tgenabled = 'O' AND (t.tgtype & 32) <> 0",
      [table, "#{table}_guard_truncate"]
    ).rows
  end

  ## Test 4

  describe "test 4: append-only" do
    test "UPDATE, DELETE and TRUNCATE on revisions and snapshots are refused", ctx do
      require_table!(@rev)
      require_table!(@snap)

      revision = save!(:writing_guide, content(:writing_guide), ctx.admin)
      snapshot_id = ctx |> reply_run!() |> snapshot_id!()

      for {table, id, column} <- [
            {@rev, revision.id, "note"},
            {@snap, snapshot_id, "safeguards_version"}
          ] do
        update = raw_error("UPDATE #{table} SET #{column} = #{column} WHERE id = $1", [u(id)])
        assert_append_only(update, table, "UPDATE")

        delete = raw_error("DELETE FROM #{table} WHERE id = $1", [u(id)])
        assert_append_only(delete, table, "DELETE")

        # Executed in the disposable test database inside a savepoint that
        # always rolls back. The table's own BEFORE TRUNCATE trigger fires
        # first (named table, then the cascade), so its refusal is the one
        # reported.
        truncate = raw_error("TRUNCATE #{table} CASCADE")
        assert_append_only(truncate, table, "TRUNCATE")

        assert truncate_guard_function(table) == [["#{table}_append_only"]],
               "C4-01a: #{table}_guard_truncate does not run #{table}_append_only()"
      end

      assert count_rows(@rev) >= 1 and count_rows(@snap) >= 1
    end
  end

  ## Test 5

  describe "test 5: revision constraints" do
    test "the embedded attribute must match the kind", ctx do
      require_table!(@rev)
      {_id, valid} = revision_row(ctx, :writing_guide)
      insert!(@rev, valid)

      # Each case is a first root of a kind not yet saved here: its only
      # violation is the content rule.
      cases = [
        {"wrong embedded attribute",
         revision_row(ctx, :research_brief,
           research_brief: nil,
           booking_link: stored_content(:booking_link)
         )},
        {"two embedded attributes",
         revision_row(ctx, :booking_link, writing_guide: stored_content(:writing_guide))},
        {"no embedded attribute", revision_row(ctx, :offering_profile, offering_profile: nil)}
      ]

      for {label, {_id, row}} <- cases do
        assert_db_refusal(
          attempt(@rev, row),
          :check_violation,
          "settings_revisions_content_matches_kind",
          label
        )
      end
    end

    test "number and supersedes_id agree; one root per kind; superseded at most once", ctx do
      require_table!(@rev)
      {root, root_row} = revision_row(ctx, :writing_guide)
      insert!(@rev, root_row)

      {_id, orphan} = revision_row(ctx, :research_brief, number: 2)

      assert_db_refusal(
        attempt(@rev, orphan),
        :check_violation,
        "settings_revisions_root_number",
        "number 2 without supersedes_id"
      )

      {_id, rooted} = revision_row(ctx, :writing_guide, number: 1, supersedes_id: u(root))

      assert_db_refusal(
        attempt(@rev, rooted),
        :check_violation,
        "settings_revisions_root_number",
        "number 1 with supersedes_id"
      )

      {_id, second_root} = revision_row(ctx, :writing_guide)

      assert_db_refusal(
        attempt(@rev, second_root),
        :unique_violation,
        "settings_revisions_one_root_per_kind_index",
        "a second root of the kind"
      )

      {_id, successor} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(root))
      insert!(@rev, successor)

      # Number 3, so the (tenant, kind, number) identity does not compete.
      {_id, again} = revision_row(ctx, :writing_guide, number: 3, supersedes_id: u(root))

      assert_db_refusal(
        attempt(@rev, again),
        :unique_violation,
        "settings_revisions_supersedes_once_index",
        "a revision superseded twice"
      )
    end

    test "supersedes_id may not cross kinds or tenants", ctx do
      require_table!(@rev)
      {booking, booking_row} = revision_row(ctx, :booking_link)
      insert!(@rev, booking_row)
      {guide, guide_row} = revision_row(ctx, :writing_guide)
      insert!(@rev, guide_row)

      {_id, cross_kind} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(booking))

      assert_db_refusal(
        attempt(@rev, cross_kind),
        :foreign_key_violation,
        "settings_revisions_supersedes_fkey",
        "cross-kind supersedes_id"
      )

      {foreign, foreign_row} =
        revision_row(ctx, :research_brief, tenant_id: u(Ash.UUIDv7.generate()))

      insert_tampered!(@rev, foreign_row)

      {_id, cross_tenant} =
        revision_row(ctx, :research_brief, number: 2, supersedes_id: u(foreign))

      assert_db_refusal(
        attempt(@rev, cross_tenant),
        :foreign_key_violation,
        "settings_revisions_supersedes_fkey",
        "cross-tenant supersedes_id"
      )

      # Positive control: same tenant, same kind.
      {_id, same} = revision_row(ctx, :writing_guide, number: 2, supersedes_id: u(guide))
      insert!(@rev, same)
    end

    test "test 7a: raised_fields is refused on a non-limits kind", ctx do
      require_table!(@rev)

      {_id, limits} =
        revision_row(ctx, :operational_limits, raised_fields: ["run_max_model_calls"])

      insert!(@rev, limits)

      {_id, guide} = revision_row(ctx, :writing_guide, raised_fields: ["run_max_model_calls"])

      assert_db_refusal(
        attempt(@rev, guide),
        :check_violation,
        "settings_revisions_raised_fields_limits_only",
        "raised_fields on writing_guide"
      )
    end
  end

  describe "test 5: snapshot constraints" do
    setup ctx do
      require_table!(@snap)
      {offering, offering_row} = revision_row(ctx, :offering_profile)
      insert!(@rev, offering_row)
      {guide, guide_row} = revision_row(ctx, :writing_guide)
      insert!(@rev, guide_row)

      {foreign, foreign_row} =
        revision_row(ctx, :offering_profile, tenant_id: u(Ash.UUIDv7.generate()))

      insert_tampered!(@rev, foreign_row)

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

      insert!(@snap, valid)

      cases = [
        {"wrong kind", revision_slot(:offering_profile, guide, guide_sha)},
        {"wrong content hash", revision_slot(:offering_profile, offering, rand_hex(32))},
        {"wrong tenant", revision_slot(:offering_profile, foreign, foreign_sha)}
      ]

      for {label, slot} <- cases do
        {_id, row} = snapshot_row(ctx.tenant.id, slot)

        assert_db_refusal(
          attempt(@snap, row),
          :foreign_key_violation,
          "run_settings_snapshots_offering_profile_revision_fkey",
          "slot with #{label}"
        )
      end
    end

    test "slot column combinations outside the per-kind checks are refused", ctx do
      {offering, offering_sha} = ctx.offering
      {guide, guide_sha} = ctx.guide
      code_default = &put_all(code_default_slot(&1), &2)

      # Every revision reference here is to a real row of that kind with its
      # real hash, so no foreign key competes with the slot check.
      cases = [
        {:offering_profile, "revision without hash",
         revision_slot(:offering_profile, offering, nil)},
        {:offering_profile, "revision without id",
         revision_slot(:offering_profile, nil, offering_sha)},
        {:offering_profile, "revision with a version",
         put_all(revision_slot(:offering_profile, offering, offering_sha),
           offering_profile_code_default_version: "1"
         )},
        {:writing_guide, "code_default with a revision id",
         code_default.(:writing_guide,
           writing_guide_revision_id: u(guide),
           writing_guide_content_sha256: guide_sha
         )},
        {:writing_guide, "code_default without version",
         code_default.(:writing_guide, writing_guide_code_default_version: nil)},
        {:writing_guide, "code_default without hash",
         code_default.(:writing_guide, writing_guide_content_sha256: nil)},
        {:offering_profile, "code_default for offering", code_default_slot(:offering_profile)},
        {:booking_link, "code_default for booking link", code_default_slot(:booking_link)},
        {:writing_guide, "absent writing guide", absent_slot(:writing_guide)},
        {:research_brief, "absent research brief", absent_slot(:research_brief)},
        {:operational_limits, "absent operational limits", absent_slot(:operational_limits)},
        {:booking_link, "absent with a hash",
         put_all(absent_slot(:booking_link), booking_link_content_sha256: rand_hex(32))},
        {:offering_profile, "unknown source", [offering_profile_source: "bogus"]}
      ]

      for {kind, label, slot} <- cases do
        {_id, row} = snapshot_row(ctx.tenant.id, slot)

        assert_db_refusal(
          attempt(@snap, row),
          :check_violation,
          "run_settings_snapshots_#{kind}_slot",
          label
        )
      end

      {_id, kind_written} = snapshot_row(ctx.tenant.id, offering_profile_kind: "writing_guide")

      assert_db_refusal(
        attempt(@snap, kind_written),
        :generated_always,
        nil,
        "caller-written kind column"
      )

      {_id, valid} = snapshot_row(ctx.tenant.id)
      insert!(@snap, valid)
    end

    test "an AgentRun may not reference another tenant's snapshot", ctx do
      require_column!("agent_runs", "settings_snapshot_id")
      run = reply_run!(ctx)

      {own, own_row} = snapshot_row(ctx.tenant.id)
      insert!(@snap, own_row)
      {foreign, foreign_row} = snapshot_row(Ash.UUIDv7.generate())
      insert_tampered!(@snap, foreign_row)

      assert match?({:error, {:unexpected_success, _}}, copy_run(run.id, own)),
             "C4-01a: positive control: a run copy with its own tenant's snapshot"

      assert_db_refusal(
        copy_run(run.id, foreign),
        :foreign_key_violation,
        "agent_runs_settings_snapshot_fkey",
        "cross-tenant snapshot"
      )
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

      assert_cutover(copy_run(run.id, nil), "a run without a snapshot")
    end

    test "attaching, replacing or clearing a snapshot is refused; null runs still transition",
         ctx do
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

      assert_cutover(
        raw_error(update, [u(historical.id), u(first_snapshot)]),
        "attach to a historical null run"
      )

      assert_cutover(raw_error(update, [u(first.id), u(second_snapshot)]), "replace")
      assert_cutover(raw_error(update, [u(first.id), nil]), "clear")

      # Historical null runs stay readable and keep every transition.
      {:ok, historical} = Agents.get_run(historical.id, actor: ctx.agent)
      assert historical.settings_snapshot_id == nil
      assert {:ok, %{status: :running} = running} = Agents.start_run(historical, actor: ctx.agent)
      assert {:ok, %{status: :cancelled}} = Agents.cancel_run(running, actor: ctx.agent)
    end
  end

  ## Test 17

  describe "test 17: snapshot rollback" do
    test "a failed run insert leaves no snapshot row", ctx do
      require_table!(@snap)
      before = count_rows(@snap)
      _run = reply_run!(ctx)
      assert count_rows(@snap) == before + 1, "C4-01a: :create built no snapshot"

      runs = count_rows("agent_runs")
      definition = AgentsFixtures.definition!(ctx.tenant)

      attrs =
        definition
        |> AgentsFixtures.run_attrs(usage_origin: :reply)
        |> Map.put(:agent_definition_id, Ash.UUIDv7.generate())

      assert match?({:error, _}, Agents.create_run(attrs, actor: ctx.agent)),
             "the run with a dangling definition was created"

      assert count_rows(@snap) == before + 1, "C4-01a: an orphan snapshot remained"
      assert count_rows("agent_runs") == runs
    end
  end
end
