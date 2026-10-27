defmodule SdrAgent.SDR.SettingsTextPrivacyTest do
  @moduledoc """
  B1-04 and B1-05 settings-text privacy (map row N4 "settings-text privacy
  in logs"; `docs/product/c4/readiness.md` C4-R12 and test 23, here for
  the first consumers): a full hermetic run whose research brief and
  writing guide carry the privacy canary
  (`SdrAgent.SettingsFixtures.canary/0`) sends that text to the model only
  through the model-payload seam.

  With Logger at `:debug`, `otel_capture_content: true` (as in dev) and the
  in-memory span exporter, the brief reaches the evidence-extraction
  request Payload and the guide the outreach-proposal request Payload, and
  neither reaches a log, a span, an AuditEvent, a Failure, a snapshot, a
  Decision or ModelInvocation row, a research, evidence or draft row, or
  the Payload of any ToolInvocation input or output or Decision input of
  the run. Settings text is read inside the action from the run's
  snapshot, never passed through Flow params, outputs or agent state, and
  a request carrying it is built with `content_capture: :off`.

  RED: neither request carries the brief or the guide (the agent reads no
  settings), so the payload assertions fail first.
  """
  use SdrAgent.SDRCase, async: false

  import ExUnit.CaptureLog
  import SdrAgent.SettingsFixtures, only: [canary: 0, content: 2, save!: 3, table_contains?: 2]

  alias Ecto.Adapters.SQL
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Telemetry.InMemoryExporter

  @moduletag :b1_04
  @moduletag :b1_05

  @tables ~w(audit_events failures run_settings_snapshots decisions model_invocations
             research_artifacts evidence_claims drafts draft_revisions)

  setup do
    level = Logger.level()
    capture = Application.get_env(:sdr_agent, :otel_capture_content)
    Logger.configure(level: :debug)
    Application.put_env(:sdr_agent, :otel_capture_content, true)
    InMemoryExporter.reset()

    on_exit(fn ->
      Logger.configure(level: level)
      Application.put_env(:sdr_agent, :otel_capture_content, capture)
      InMemoryExporter.reset()
    end)

    :ok
  end

  defp rendered_spans do
    # The simple processor exports on span end; give it a moment.
    Process.sleep(50)
    inspect(InMemoryExporter.spans(), limit: :infinity, printable_limit: :infinity)
  end

  defp count!(sql, params) do
    [[n]] = SQL.query!(SdrAgent.Repo, sql, params).rows
    n
  end

  defp request_contains?(run, purpose, text) do
    count!(
      "SELECT count(*) FROM model_invocations m JOIN payloads p ON p.sha256 = m.request_sha256 " <>
        "WHERE m.agent_run_id = $1 AND m.purpose = $2 AND position($3::bytea in p.content) > 0",
      [Ecto.UUID.dump!(run.id), Atom.to_string(purpose), text]
    ) > 0
  end

  defp tool_payloads_contain?(run, text) do
    count!(
      "SELECT count(*) FROM tool_invocations t JOIN payloads p " <>
        "ON p.sha256 = t.input_sha256 OR p.sha256 = t.output_sha256 " <>
        "WHERE t.agent_run_id = $1 AND position($2::bytea in p.content) > 0",
      [Ecto.UUID.dump!(run.id), text]
    ) > 0
  end

  defp decision_payloads_contain?(run, text) do
    count!(
      "SELECT count(*) FROM decisions d JOIN payloads p ON p.sha256 = d.inputs_sha256 " <>
        "WHERE d.agent_run_id = $1 AND position($2::bytea in p.content) > 0",
      [Ecto.UUID.dump!(run.id), text]
    ) > 0
  end

  test "brief and guide text reach only the model request payloads of a full run", ctx do
    c = canary()
    brief = "#{c} brief"
    guide = "#{c} guide"

    save!(:offering_profile, Fixtures.offering_profile(), ctx.admin)

    save!(
      :research_brief,
      content(:research_brief, %{guidance: "Look for synthetic dock scheduling needs. #{brief}."}),
      ctx.admin
    )

    save!(:writing_guide, %{text: "Ask one clear question. #{guide}."}, ctx.admin)

    {%{run: run}, log} =
      with_log([level: :debug], fn ->
        assignment = assign!(ctx, "01")
        drain!()
        assignment
      end)

    run = run!(ctx, run)

    assert request_contains?(run, :evidence_extraction, brief),
           "B1-04: the evidence-extraction request Payload does not carry the research brief"

    assert request_contains?(run, :outreach_proposal, guide),
           "B1-05: the outreach-proposal request Payload does not carry the writing guide"

    assert run.status == :succeeded, "the run did not succeed: #{inspect(run.status_reason)}"

    refute log =~ c, "B1-04/05: settings text reached a log"
    refute rendered_spans() =~ c, "B1-04/05: settings text reached a span"

    for table <- @tables do
      refute table_contains?(table, c), "B1-04/05: settings text reached a #{table} row"
    end

    refute tool_payloads_contain?(run, c),
           "B1-04/05: settings text reached a ToolInvocation input or output Payload"

    refute decision_payloads_contain?(run, c),
           "B1-04/05: settings text reached a Decision input Payload"

    assert table_contains?("settings_revisions", c), "the revision row is the allowed copy"
  end
end
