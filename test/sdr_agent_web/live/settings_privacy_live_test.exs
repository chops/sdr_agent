defmodule SdrAgentWeb.SettingsPrivacyLiveTest do
  @moduledoc """
  C4-01b (`docs/product/c4/readiness.md`, section 5 test 23, LiveView part;
  sections 3.6 and 11 obligation 3; C4-R12): a privacy canary placed in
  every settings text field submitted through the settings form — on
  change, review and confirmation, for each of the five kinds and their
  notes, plus refused saves (secret-shaped and over-size) — is absent from
  the captured logs (application, Phoenix, LiveView, SQL), from every
  exported span's attributes, events and status, from AuditEvent payloads,
  AuditAccess rows, Failure rows and snapshot rows. It is present only in
  the revision rows (the allowed copy; the settings page itself is the
  authorized settings UI seam).

  As in the C4-01a privacy tests: Logger at `:debug`,
  `otel_capture_content: true` (as in dev) and the in-memory span exporter.
  The LiveView lifecycle of `SdrAgentWeb.SettingsLive` is not logged at all
  (`log: false`, packet section 3.6); its form params live under
  `settings_content`, which `config :phoenix, :filter_parameters` filters.

  RED: `/settings` is not routed (asserted after the fixtures).
  """
  use SdrAgentWeb.OperatorCase, async: false

  import ExUnit.CaptureLog
  import SdrAgent.SettingsFixtures, only: [canary: 0, latest_number: 2, table_contains?: 2]
  import SdrAgentWeb.SettingsLiveHelpers

  require Record

  alias SdrAgent.Telemetry.InMemoryExporter
  alias SdrAgent.Test.SecretShapes

  @moduletag :c4_01b

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

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

  # One valid submission per kind, with the canary in every text field.
  defp submissions(c) do
    [
      offering_profile: %{
        name: "Offer #{c}",
        summary: "Summary #{c}",
        audience: "Audience #{c}",
        items: %{"0" => %{id: "canary_item", kind: "feature", text: "Item #{c}"}},
        note: "Note #{c}"
      },
      booking_link: %{url: "https://book.example.test/#{c}", note: "Note #{c}"},
      writing_guide: %{text: "Guide #{c}", note: "Note #{c}"},
      research_brief: %{guidance: "Brief #{c}", depth: "standard", note: "Note #{c}"},
      operational_limits: %{run_max_tool_calls: "50", note: "Note #{c}"}
    ]
  end

  # Each exported span's attributes, events and status, rendered separately.
  defp span_parts do
    # The simple processor exports on span end; give it a moment.
    Process.sleep(50)
    render = &inspect(&1, limit: :infinity, printable_limit: :infinity)

    for record <- InMemoryExporter.spans() do
      %{
        name: span(record, :name),
        attributes: render.(span(record, :attributes)),
        events: render.(span(record, :events)),
        status: render.(span(record, :status))
      }
    end
  end

  test "a canary submitted through the settings form reaches no log, span, event or failure",
       %{conn: conn} = ctx do
    c = canary()
    secret = SecretShapes.provider_key()

    log =
      capture_log([level: :debug], fn ->
        view = open_settings(conn, :admin)

        for {kind, params} <- submissions(c) do
          view |> edit(kind) |> change(params) |> review(params)
          confirm(view)
        end

        # Refused saves: secret-shaped and over-size.
        edit(view, :writing_guide)

        for text <- ["Guide #{c} #{secret}", "Guide #{c} " <> String.duplicate("abcd ", 1_300)] do
          params = %{text: text, note: "Note #{c}"}
          view |> change(params) |> review(params)
          confirm(view)
        end
      end)

    refute log =~ c, "C4-01b: the canary reached a log"
    refute log =~ secret, "C4-01b: the refused secret reached a log"

    refute log =~ ~r/(MOUNT|HANDLE PARAMS|HANDLE EVENT)[^\n]*SdrAgentWeb\.SettingsLive/,
           "C4-01b: SettingsLive lifecycle events are logged (log: false)"

    for part <- span_parts(), field <- [:attributes, :events, :status] do
      refute Map.fetch!(part, field) =~ c,
             "C4-01b: the canary reached span #{inspect(part.name)} #{field}"
    end

    for table <- ["audit_events", "audit_accesses", "failures", "run_settings_snapshots"] do
      refute table_contains?(table, c), "C4-01b: the canary reached #{table}"
    end

    # The allowed copy: every valid submission was saved once; the refused
    # ones wrote nothing.
    for kind <- @kinds do
      assert latest_number(ctx.tenant.id, kind) == 1,
             "C4-01b: the #{kind} form submission was not saved exactly once"
    end

    assert table_contains?("settings_revisions", c), "the revision row is the allowed copy"
  end
end
