defmodule SdrAgent.SDR.SettingsFailClosedTest do
  @moduledoc """
  B1-04/B1-05 fail closed on an unreadable settings snapshot (Codex r1 M4;
  plan `claude-b1-research-draft-plan-r2.md`; C4-R5): when
  `SdrAgent.Agents.run_settings/2` refuses the run's snapshot, each
  consumer (`BuildEvidenceBundle`, `DraftEmail`) stops the run before its
  model call as `:crash` with the one fixed failure reason
  `"run settings unavailable"`. No rich error term is forwarded, and no
  settings text reaches the failure, the Failure row, an AuditEvent, a log
  or a ToolInvocation Payload, although the offering and guide carry the
  privacy canary.

  The fault: a raw database-administrator write inside the test's sandbox
  (triggers disabled, as `SdrAgent.SettingsFixtures.withhold_offering!/1`)
  points the snapshot's built-in research-brief slot at a version that was
  never released, so `run_settings/2` returns
  `{:error, :settings_default_unavailable}` (checked first as a setup
  control). It is never an application path.

  RED: neither consumer reads settings, so research and the draft make
  their model calls and succeed.
  """
  use SdrAgent.SDRCase, async: false

  import ExUnit.CaptureLog

  import SdrAgent.SettingsFixtures,
    only: [
      canary: 0,
      content: 2,
      observe: 1,
      run_settings: 2,
      save!: 3,
      snapshot_of!: 2,
      table_contains?: 2
    ]

  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Research
  alias SdrAgent.SDR.Actions.DraftEmail
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.SDRAgent

  @moduletag :b1_04
  @moduletag :b1_05

  @reason "run settings unavailable"

  setup ctx do
    c = canary()
    save!(:offering_profile, content(:offering_profile, %{summary: "Summary #{c}"}), ctx.admin)
    save!(:writing_guide, %{text: "Ask one clear question. Guide #{c}."}, ctx.admin)
    :ok
  end

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  # Test-only fault (see the moduledoc): the built-in research-brief slot
  # names an unreleased version.
  defp withhold_brief_default!(ctx, run) do
    assert snapshot_of!(run, ctx.agent).research_brief_source == :code_default,
           "setup: the run's research brief is not a built-in default slot"

    {:ok, _} =
      Repo.transaction(fn ->
        SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

        SQL.query!(
          Repo,
          "UPDATE run_settings_snapshots SET research_brief_code_default_version = '999' " <>
            "WHERE id = $1",
          [Ecto.UUID.dump!(run.settings_snapshot_id)]
        )

        SQL.query!(Repo, "SET LOCAL session_replication_role = origin", [])
      end)

    assert run_settings(run, ctx.agent) == {:error, :settings_default_unavailable},
           "setup: the fault did not make the snapshot unreadable"
  end

  defp tool_payloads_contain?(run, text) do
    [[n]] =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM tool_invocations t JOIN payloads p " <>
          "ON p.sha256 = t.input_sha256 OR p.sha256 = t.output_sha256 " <>
          "WHERE t.agent_run_id = $1 AND position($2::bytea in p.content) > 0",
        [Ecto.UUID.dump!(run.id), text]
      ).rows

    n > 0
  end

  defp assert_failed_closed!(ctx, run, log, label) do
    c = canary()
    run = run!(ctx, run)

    assert {run.status, run.status_reason} == {:failed, :crash},
           "#{label}: the run went on with an unreadable settings snapshot " <>
             "(#{run.status}, #{inspect(run.status_reason)})"

    assert run.failure_reason == @reason

    refute log =~ c, "#{label}: settings text reached a log"
    refute table_contains?("failures", c), "#{label}: settings text reached a Failure"
    refute table_contains?("audit_events", c), "#{label}: settings text reached an AuditEvent"
    refute table_contains?("agent_runs", c), "#{label}: settings text reached the run row"

    refute tool_payloads_contain?(run, c),
           "#{label}: settings text reached a ToolInvocation Payload"

    run
  end

  test "research stops before the extraction call when the snapshot cannot be read", ctx do
    %{run: run, lead: lead} = assign!(ctx, "01")
    withhold_brief_default!(ctx, run)

    log = capture_log([level: :debug], fn -> drain!() end)
    run = assert_failed_closed!(ctx, run, log, "B1-04")

    assert invocations!(ctx, run) == [], "B1-04: a model call followed the settings refusal"
    refute Enum.any?(decisions!(ctx, run), &(&1.kind == :research_caps))

    {:ok, claims} =
      Research.list_records(Research.EvidenceClaim, filter: [lead_id: lead.id], actor: ctx.admin)

    assert claims == []
    refute "sdr.research.completed" in signal_types(ctx.tenant, run)
  end

  test "the draft stops before the proposal call when the snapshot cannot be read", ctx do
    lead = fixture_lead!(ctx, "01")
    {:ok, definition} = SDRAgent.register(ctx.tenant.id)

    attrs =
      definition
      |> AgentsFixtures.run_attrs()
      |> Map.merge(%{lead_id: lead.id, campaign_id: ctx.campaign_id})

    {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    withhold_brief_default!(ctx, run)

    sdr = %Context{
      actor: ctx.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      signal_id: "sig-b1-fail-closed"
    }

    claim = %{id: Ecto.UUID.generate(), claim: "Brightpath Freight Systems is hiring SDRs."}

    params = %{
      lead_id: lead.id,
      claims: [claim],
      triggers: [claim],
      plan: %{
        contact: %{first_name: "Avery", title: "VP Operations"},
        company: %{name: "Brightpath Freight Systems"},
        sender: %{name: "Demo SDR"},
        step: %{id: Ecto.UUID.generate(), instructions: "Introduce yourself briefly."},
        campaign_id: ctx.campaign_id
      }
    }

    {result, log} =
      with_log([level: :debug], fn ->
        observe(fn -> DraftEmail.run(params, %{sdr: sdr, agent_state: %{phase: :draft}}) end)
      end)

    assert result == {:error, {:halt, :crash}},
           "B1-05: DraftEmail did not stop on an unreadable snapshot: #{short(result)}"

    run = assert_failed_closed!(ctx, run, log, "B1-05")
    assert invocations!(ctx, run) == [], "B1-05: a model call followed the settings refusal"
    refute Enum.any?(decisions!(ctx, run), &(&1.kind in [:angle, :draft_proposal]))
  end
end
