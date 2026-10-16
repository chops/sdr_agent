defmodule SdrAgent.Agents.SettingsPrivacyTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 5 test 23 without its
  LiveView part, which is C4-01b; sections 3.6 and 7; obligation 3):
  privacy canaries. With Logger at `:debug`, `otel_capture_content: true`
  (as in dev) and the in-memory span exporter, a canary placed in every
  settings text field is absent from captured logs (application and SQL),
  span attributes and events, AuditEvent payloads, snapshot rows and
  Failure rows; it is present only in the revision row and in the model
  request Payload (the authorized model-payload seam).

  RED: the settings API is presence-guarded; the model-call, GenAI and SQL
  canaries fail because content capture and SQL parameter logging are not
  yet suppressed.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog
  import SdrAgent.SettingsFixtures

  require Record

  alias Ecto.Adapters.SQL
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.RunSettings.ContentRules
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.Operations.Redactor
  alias SdrAgent.Telemetry.GenAI
  alias SdrAgent.Telemetry.InMemoryExporter
  alias SdrAgent.Test.SecretShapes

  @moduletag :c4_01a

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    tenant = bootstrap!()
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

    %{tenant: tenant, admin: human(:admin, tenant), agent: system_actor(:agent_runtime, tenant)}
  end

  defp rendered_spans do
    # The simple processor exports on span end; give it a moment.
    Process.sleep(50)
    inspect(InMemoryExporter.spans(), limit: :infinity, printable_limit: :infinity)
  end

  # Each exported span's attributes, events and status, rendered separately.
  defp span_parts do
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

  defp assert_no_canary_in_spans(label) do
    c = canary()

    for part <- span_parts(), field <- [:attributes, :events, :status] do
      refute Map.fetch!(part, field) =~ c,
             "C4-01a: #{label}: the canary reached span #{inspect(part.name)} #{field}"
    end

    refute rendered_spans() =~ c, "C4-01a: #{label}: the canary reached a span"
  end

  defp assert_no_canary(log, label) do
    c = canary()
    refute log =~ c, "C4-01a: #{label}: the canary reached a log"
    refute rendered_spans() =~ c, "C4-01a: #{label}: the canary reached a span"

    refute table_contains?("audit_events", c),
           "C4-01a: #{label}: the canary reached an AuditEvent"

    refute table_contains?("failures", c), "C4-01a: #{label}: the canary reached a Failure"

    refute table_contains?("run_settings_snapshots", c),
           "C4-01a: #{label}: the canary reached a snapshot row"
  end

  test "valid and refused saves, a snapshot and its resolution copy no settings text", ctx do
    c = canary()

    log =
      capture_log([level: :debug], fn ->
        offering =
          content(:offering_profile, %{
            name: "Offer #{c}",
            summary: "Summary #{c}",
            audience: "Audience #{c}",
            items: [%{id: "canary_item", kind: :feature, text: "Item #{c}"}]
          })

        save!(:offering_profile, offering, ctx.admin, note: "Note #{c}")
        save!(:booking_link, %{url: "https://book.example.test/#{c}"}, ctx.admin)
        save!(:writing_guide, %{text: "Guide #{c}"}, ctx.admin)
        save!(:research_brief, content(:research_brief, %{guidance: "Brief #{c}"}), ctx.admin)

        for {kind, content} <- [
              {:writing_guide, %{text: "Guide #{c} " <> SecretShapes.provider_key()}},
              {:writing_guide, %{text: "Guide #{c} " <> String.duplicate("abcd ", 1_300)}},
              {:offering_profile,
               content(:offering_profile, %{name: c <> " " <> String.duplicate("name ", 24)})}
            ] do
          result =
            observe(fn ->
              create_revision(revision_attrs(kind, content, ctx.admin), ctx.admin)
            end)

          assert invalid_errors(result), "C4-01a: the invalid #{kind} save was not refused"
          refute inspect(result, limit: :infinity) =~ c, "C4-01a: the refusal echoed the content"
        end

        definition = AgentsFixtures.definition!(ctx.tenant)
        attrs = AgentsFixtures.run_attrs(definition, usage_origin: :assignment)
        {:ok, run} = SdrAgent.Agents.create_run(attrs, actor: ctx.agent)
        assert {:ok, _settings} = run_settings(run, ctx.agent)
      end)

    assert_no_canary(log, "saves and snapshot")
    assert table_contains?("settings_revisions", c), "the revision row is the allowed copy"
  end

  test "a model call carrying settings emits no content spans; only its Payload keeps it", ctx do
    c = canary()
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :reply)

    audit =
      "c4-privacy"
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    request = %{
      id: "c4-privacy-1",
      run: run,
      actor: agent,
      operation: "model.complete",
      prompt: "Fixed rules.\n\n<settings>Guide #{c}</settings>",
      schema: @schema,
      audit: audit,
      content_capture: :off
    }

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _} =
                 ModelProvider.complete(request, provider: SdrAgent.AI.ModelProvider.Fake)
      end)

    spans = rendered_spans()
    assert spans =~ "gen_ai.input.sha256", "the span keeps its metadata and hashes"
    refute spans =~ c, "C4-01a: content_capture: :off did not suppress the GenAI content event"
    assert_no_canary_in_spans("model call")
    refute log =~ c, "C4-01a: the canary reached a log (SQL parameters)"
    refute table_contains?("audit_events", c)
    assert payloads_contain?(c), "the model request Payload is the allowed copy"
  end

  test "content_capture: :off dominates a conflicting provider option along the request path",
       ctx do
    c = canary()
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :reply)

    audit =
      "c4-conflict"
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    request = %{
      id: "c4-conflict-1",
      run: run,
      actor: agent,
      operation: "model.complete",
      prompt: "Fixed rules.\n\n<settings>Brief #{c}</settings>",
      schema: @schema,
      audit: audit,
      content_capture: :off
    }

    # The provider options ask for capture; dev config asks for capture too.
    conflicting = [content_capture: :inherit, otel_capture_content: true, capture_content: true]

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _} =
                 ModelProvider.complete(request,
                   provider: SdrAgent.AI.ModelProvider.Fake,
                   provider_options: conflicting
                 )
      end)

    assert_no_canary_in_spans("conflicting provider option")
    refute log =~ c, "C4-01a: the canary reached a log"
    assert payloads_contain?(c), "the model request Payload is the allowed copy"
  end

  test "GenAI.with_span/3 honours content_capture: :off whatever otel_capture_content says" do
    c = canary()

    payload = GenAI.telemetry_payload("chat", %{id: "c4", input: c, content_capture: :off})

    assert match?({_attributes, []}, payload),
           "C4-01a: content events built despite content_capture: :off"

    GenAI.with_span("chat", %{id: "c4-span", input: c, output: c, content_capture: :off}, fn ->
      :ok
    end)

    refute rendered_spans() =~ c, "C4-01a: content_capture: :off did not suppress span content"

    # Allowed baseline: :inherit keeps today's dev behaviour (content events).
    {_attributes, events} =
      GenAI.telemetry_payload("chat", %{id: "c4", input: c, content_capture: :inherit})

    assert events != []
  end

  test "database logging and query spans carry no query parameters" do
    c = canary()

    log =
      capture_log([level: :debug], fn -> SQL.query!(SdrAgent.Repo, "SELECT $1::text", [c]) end)

    refute log =~ c, "C4-01a: a query parameter reached the SQL log"
    assert_no_canary_in_spans("query parameter")
  end

  test "database logging and query spans carry no raw SQL text (literals or comments)" do
    c = canary()

    log =
      capture_log([level: :debug], fn ->
        SQL.query!(SdrAgent.Repo, "SELECT '#{c}'::text AS literal /* #{c} */", [])
      end)

    refute log =~ c, "C4-01a: raw SQL text with a literal or comment reached the SQL log"
    assert_no_canary_in_spans("raw SQL text")
  end

  test "database error values and raised exceptions reach no log, span event or span status" do
    c = canary()

    log =
      capture_log([level: :debug], fn ->
        parameter = fn ->
          SdrAgent.Repo.rollback(SQL.query(SdrAgent.Repo, "SELECT $1::text::integer", [c]))
        end

        literal = fn ->
          SdrAgent.Repo.rollback(SQL.query(SdrAgent.Repo, "SELECT '#{c}'::integer", []))
        end

        raised = fn ->
          try do
            SQL.query!(SdrAgent.Repo, "SELECT '#{c}'::integer", [])
          rescue
            error in Postgrex.Error -> SdrAgent.Repo.rollback({:raised, error})
          end
        end

        for {label, fun} <- [parameter: parameter, literal: literal] do
          assert match?({:error, {:error, %Postgrex.Error{}}}, SdrAgent.Repo.transaction(fun)),
                 "C4-01a setup: the #{label} query did not fail"
        end

        assert match?({:error, {:raised, %Postgrex.Error{}}}, SdrAgent.Repo.transaction(raised)),
               "C4-01a setup: the raising query did not raise"
      end)

    refute log =~ c, "C4-01a: a database error value reached the log"
    assert_no_canary_in_spans("database error")
  end

  # Codex review of 38fd09d (codex-c401a-38fd09d-green-review.md): its five
  # regression probes, kept verbatim as permanent tests.
  describe "Codex 38fd09d review regressions" do
    test "raw provider-key shape remains refused despite a repeated suffix", ctx do
      value = "sk-" <> String.duplicate("a", 40)
      assert Redactor.redact(value) != value

      result =
        Agents.create_settings_revision(
          %{kind: :writing_guide, content: %{text: value}, expected_number: 0},
          actor: ctx.admin
        )

      assert match?({:error, {:invalid, _}}, result),
             "provider-shaped key was accepted by the save"
    end

    test "a mixed long run cannot be shortened past the redactor threshold" do
      value = "ab" <> String.duplicate("x", 40) <> "cd"
      assert Redactor.redact(value) != value
      assert ContentRules.secret_shaped?(value)
    end

    test "wrong-shaped content has a typed refusal without leaking into Ash span status", ctx do
      value = "c4 wrong shaped private content ZQXJ7"

      assert {:error, {:invalid, _}} =
               Agents.create_settings_revision(
                 %{kind: :writing_guide, content: value, expected_number: 0},
                 actor: ctx.admin
               )

      Process.sleep(50)
      assert leaking_status_spans(value) == []
    end

    test "wrong-shaped note has a typed refusal without leaking into Ash span status", ctx do
      value = "c4 wrong shaped private note ZQXJ7"

      assert {:error, {:invalid, _}} =
               Agents.create_settings_revision(
                 %{
                   kind: :writing_guide,
                   content: %{text: "Plain guide."},
                   note: %{text: value},
                   expected_number: 0
                 },
                 actor: ctx.admin
               )

      Process.sleep(50)
      assert leaking_status_spans(value) == []
    end

    test "unknown Postgrex condition atoms are not treated as allowlisted metadata" do
      fields =
        SdrAgent.Repo.SafeMetadata.fields(%{}, %{
          repo: SdrAgent.Repo,
          source: "settings_revisions",
          result: {:error, %Postgrex.Error{postgres: %{code: :c4_unknown_condition_canary}}}
        })

      assert fields.pg_code == "other"
    end
  end

  # Codex 54aac3c re-review: an atom/string key alias must not let the
  # validated and the cast representation differ.
  describe "Codex 54aac3c review regressions" do
    test "an atom/string key alias is refused and its value reaches no span status", ctx do
      value = "private shape alias c4 ZQXJ7"
      content = Map.put(%{text: "Plain guide."}, "text", %{private: value})

      result =
        Agents.create_settings_revision(
          %{kind: :writing_guide, content: content, expected_number: 0},
          actor: ctx.admin
        )

      assert match?({:error, {:invalid, _}}, result), "C4-01a: the alias was not refused"
      refute inspect(result, limit: :infinity) =~ value
      Process.sleep(50)
      assert leaking_status_spans(value) == []
      assert leaking_status_spans("Plain guide.") == []
    end

    test "aliases inside offering items are refused too", ctx do
      value = "private item alias c4 ZQXJ7"
      item = Map.put(%{id: "item_a", kind: :feature, text: "Item."}, "text", %{private: value})
      content = content(:offering_profile, %{items: [item]})

      result =
        Agents.create_settings_revision(
          %{kind: :offering_profile, content: content, expected_number: 0},
          actor: ctx.admin
        )

      assert match?({:error, {:invalid, _}}, result), "C4-01a: the item alias was not refused"
      refute inspect(result, limit: :infinity) =~ value
      Process.sleep(50)
      assert leaking_status_spans(value) == []
    end

    test "string keys alone are accepted as the same content", ctx do
      saved =
        save!(:writing_guide, %{"text" => "String keyed guide."}, ctx.admin, expected_number: 0)

      assert saved.writing_guide.text == "String keyed guide."
    end

    test "an aliased content map on the action itself is refused without leaking", ctx do
      value = "private direct alias c4 ZQXJ7"
      content = Map.put(%{text: "Plain guide."}, "text", %{private: value})

      result =
        SdrAgent.Agents.SettingsRevision
        |> Ash.Changeset.for_create(
          :create_revision,
          %{kind: :writing_guide, content: content, expected_number: 0},
          actor: ctx.admin
        )
        |> Ash.create()

      assert match?({:error, %Ash.Error.Invalid{}}, result)
      refute inspect(result, limit: :infinity) =~ value
      Process.sleep(50)
      assert leaking_status_spans(value) == []
    end
  end

  # Postgrex.ErrorCode.code_to_name/1 is internal: upgrade checks.
  describe "SafeMetadata pg_code upgrade checks" do
    defp pg(postgres),
      do:
        SdrAgent.Repo.SafeMetadata.fields(%{}, %{
          repo: SdrAgent.Repo,
          result: {:error, %Postgrex.Error{postgres: postgres}}
        }).pg_code

    test "a known SQLSTATE and its own name are kept" do
      assert pg(%{code: :unique_violation, pg_code: "23505"}) == "unique_violation"
      assert pg(%{code: :check_violation, pg_code: "23514"}) == "check_violation"
    end

    test "an unknown SQLSTATE is other" do
      assert pg(%{code: :unique_violation, pg_code: "ZZ999"}) == "other"
    end

    test "a name that is not its SQLSTATE's name is other" do
      assert pg(%{code: :check_violation, pg_code: "23505"}) == "other"
    end

    test "a missing SQLSTATE or postgres map is other" do
      assert pg(%{code: :unique_violation}) == "other"
      assert pg(nil) == "other"
    end
  end

  defp leaking_status_spans(value) do
    for record <- InMemoryExporter.spans(),
        inspect(elem(record, 13), limit: :infinity, printable_limit: :infinity) =~ value,
        do: elem(record, 6)
  end
end
