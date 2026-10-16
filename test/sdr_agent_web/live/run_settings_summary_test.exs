defmodule SdrAgentWeb.RunSettingsSummaryTest do
  @moduledoc """
  C4-01b (`docs/product/c4/readiness.md`, section 5 test 31, run-page part;
  C4-R4, C4-R10, C4-R11, C4-R14; obligation 6): the run page shows the
  run's settings snapshot — per setting the revision number, the built-in
  default version or "not set" — and its limits, labelled "limit at
  snapshot" separately from "allowed now" (the run's frozen allowance,
  `SdrAgent.Agents.RunSettings.allowance/2`). A later save never changes
  what the page shows for an existing run. A run created before C4 (no
  snapshot) says so and is still served. An auditor's view of the snapshot
  is recorded through `SdrAgentWeb.AuditedView` and fails closed.

  Fixture: limits revision 1 lowers `run_max_model_calls` to 8 and
  `run_max_tool_calls` to 40; the lead is assigned with `max_model_calls: 5`
  (frozen budget 5); afterwards limits revision 2 raises
  `run_max_model_calls` to 30 and writing guide revision 1 is saved.

  RED: the run page has no settings summary.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.SettingsFixtures,
    only: [content: 2, limit_fields: 0, save!: 3, save!: 4, snapshot_of!: 2]

  alias Ecto.Adapters.SQL
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo

  @moduletag :c4_01b

  setup ctx do
    limits = content(:operational_limits, %{run_max_model_calls: 8, run_max_tool_calls: 40})
    save!(:operational_limits, limits, ctx.admin)
    %{run: run} = SdrAgent.SDRCase.assign!(ctx, "1", max_model_calls: 5)

    assert match?(%{max_model_calls: 5, max_tool_calls: 40}, run.budget),
           "C4-01b setup: the run's frozen budget is #{inspect(run.budget)}"

    raised = content(:operational_limits, %{run_max_model_calls: 30, run_max_tool_calls: 40})
    save!(:operational_limits, raised, ctx.admin, confirm_raised: [:run_max_model_calls])
    save!(:writing_guide, %{text: "A guide saved after the run was created."}, ctx.admin)

    %{run: run, snapshot: snapshot_of!(run, ctx.agent)}
  end

  defp open_run(conn, role, run) do
    {:ok, view, _html} = conn |> sign_in(role) |> live(~p"/runs/#{run.id}")
    view
  end

  test "the run page shows the run's snapshot, not the current settings", %{conn: conn} = ctx do
    view = open_run(conn, :admin, ctx.run)

    assert has_element?(view, "#run-settings"), "C4-01b: the run page has no settings summary"

    assert has_element?(
             view,
             "#run-setting-offering_profile[data-source='revision']",
             "revision 1"
           )

    assert has_element?(view, "#run-setting-booking_link[data-source='absent']", "not set")

    for kind <- [:writing_guide, :research_brief] do
      version = Map.fetch!(ctx.snapshot, :"#{kind}_code_default_version")

      assert has_element?(
               view,
               "#run-setting-#{kind}[data-source='code_default']",
               "built-in default version #{version}"
             ),
             "C4-01b: #{kind} does not show the snapshot's built-in default"
    end

    # Revision 2 of the limits and revision 1 of the guide came later.
    assert has_element?(
             view,
             "#run-setting-operational_limits[data-source='revision']",
             "revision 1"
           )

    refute has_element?(view, "#run-setting-operational_limits", "revision 2")
    refute has_element?(view, "#run-setting-writing_guide[data-source='revision']")
  end

  test "limits are labelled 'limit at snapshot' separately from 'allowed now'",
       %{conn: conn} = ctx do
    view = open_run(conn, :admin, ctx.run)

    assert has_element?(view, "#run-settings", "limit at snapshot"),
           "C4-01b: the run page does not label the limit at snapshot"

    assert has_element?(view, "#run-settings", "allowed now")

    for field <- limit_fields() do
      at_snapshot = Map.fetch!(ctx.snapshot.limits, field)

      assert has_element?(view, "#run-limit-#{field}[data-at-snapshot='#{at_snapshot}']"),
             "C4-01b: limit #{field} does not show its snapshot value #{at_snapshot}"
    end

    # Frozen at 5 by the assignment, under a snapshot value of 8.
    assert has_element?(
             view,
             "#run-limit-run_max_model_calls[data-at-snapshot='8'][data-allowed-now='5']"
           ),
           "C4-01b: 'allowed now' is not the run's frozen allowance"

    assert has_element?(
             view,
             "#run-limit-run_max_tool_calls[data-at-snapshot='40'][data-allowed-now='40']"
           )

    refute has_element?(view, "#run-settings [data-at-snapshot='30']")
    refute has_element?(view, "#run-settings [data-allowed-now='30']")
  end

  test "a reviewer sees the snapshot summary", %{conn: conn} = ctx do
    view = open_run(conn, :reviewer, ctx.run)

    assert has_element?(view, "#run-setting-operational_limits[data-source='revision']"),
           "C4-01b: the reviewer's run page has no settings summary"

    assert has_element?(view, "#run-limit-run_max_model_calls[data-at-snapshot='8']")
  end

  test "a run created before C4 says it has no settings snapshot and is still served",
       %{conn: conn} = ctx do
    Repo.transaction(fn ->
      AuditCase.tamper!("UPDATE agent_runs SET settings_snapshot_id = NULL WHERE id = $1", [
        Ecto.UUID.dump!(ctx.run.id)
      ])
    end)

    view = open_run(conn, :admin, ctx.run)

    refute has_element?(view, "#withheld")
    assert has_element?(view, "#run-header")

    assert has_element?(view, "#run-settings-none"),
           "C4-01b: a run without a snapshot does not say so"

    refute has_element?(view, "#run-settings [data-source]")
    refute has_element?(view, "#run-limit-run_max_model_calls")
  end

  test "an auditor's view records the snapshot shown and fails closed without the record",
       %{conn: conn} = ctx do
    auditor = user!(ctx, :auditor)
    view = open_run(conn, :auditor, ctx.run)

    assert has_element?(view, "#run-setting-operational_limits[data-source='revision']"),
           "C4-01b: the auditor's run page has no settings summary"

    snapshot_id = ctx.snapshot.id

    assert Enum.any?(
             accesses_of(ctx, auditor),
             &(&1.access_kind == :record_view and
                 &1.target_resource == "SdrAgent.Agents.RunSettingsSnapshot" and
                 &1.target_ref == snapshot_id)
           ),
           "C4-01b: the auditor's view of the snapshot was not recorded"

    refuse_snapshot_accesses!()
    view = open_run(build_conn(), :auditor, ctx.run)

    refute has_element?(view, "#run-settings [data-source]"),
           "C4-01b: the snapshot was shown although its access was not recorded"

    refute has_element?(view, "#run-limit-run_max_model_calls")
  end

  # Refuses only AuditAccess rows naming a run settings snapshot, so the run
  # view's own record still succeeds.
  defp refuse_snapshot_accesses! do
    SQL.query!(Repo, """
    CREATE FUNCTION c4_01b_refuse_snapshot_access() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.target_resource = 'SdrAgent.Agents.RunSettingsSnapshot' THEN
        RAISE EXCEPTION 'access store unavailable';
      END IF;
      RETURN NEW;
    END; $$
    """)

    SQL.query!(
      Repo,
      "CREATE TRIGGER c4_01b_refuse_snapshot_access BEFORE INSERT ON audit_accesses " <>
        "FOR EACH ROW EXECUTE FUNCTION c4_01b_refuse_snapshot_access()"
    )
  end
end
