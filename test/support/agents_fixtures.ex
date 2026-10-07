defmodule SdrAgent.AgentsFixtures do
  @moduledoc "Builders for Agents-domain rows created through the domain API."

  import SdrAgent.AuditCase, only: [system_actor: 2, digest: 1]

  @doc "Registers a definition and starts a run for it; returns the rows and the agent actor."
  def running_run(tenant, opts \\ []) do
    agent = system_actor(:agent_runtime, tenant)
    definition = definition!(tenant)

    {:ok, run} =
      SdrAgent.Agents.create_run(run_attrs(definition, opts), actor: agent)

    {:ok, run} = SdrAgent.Agents.start_run(run, actor: agent)
    %{run: run, agent: agent, definition: definition}
  end

  @doc "Registers (or returns) the fixture agent definition."
  def definition!(tenant) do
    {:ok, definition} =
      SdrAgent.Agents.register_definition(
        %{
          name: "SDRAgent",
          version: 1,
          module: "SdrAgent.SDRAgent",
          definition: %{
            "allowed_actions" => [%{"module" => "Research", "version" => "1"}],
            "model_policy" => %{"provider" => "fake", "max_model_calls_per_run" => 20}
          }
        },
        actor: system_actor(:kernel, tenant)
      )

    definition
  end

  @doc "Attributes for a queued run."
  def run_attrs(definition, opts \\ []) do
    %{
      agent_definition_id: definition.id,
      lead_id: Ecto.UUID.generate(),
      trigger_signal_type: "sdr.lead.assigned",
      trigger_signal_id: "sig-#{System.unique_integer([:positive])}",
      correlation_id: Ecto.UUID.generate(),
      phase: :research,
      max_tool_calls: Keyword.get(opts, :max_tool_calls, 10),
      max_model_calls: Keyword.get(opts, :max_model_calls, 20)
    }
  end

  @doc "Attributes for a model invocation reservation."
  def model_attrs(idempotency_key) do
    %{
      purpose: :qualification,
      provider: :fake,
      provider_version: "0.0.0",
      model_id: "fake-qualifier",
      model_catalog_entry: %{"id" => "fake-qualifier", "context_window" => 8000},
      account_mode_ref: "fake:none",
      data_control_setting: "synthetic-only",
      parameters: %{"temperature" => 0},
      prompt_template_id: "qualify_lead",
      prompt_template_version: "1",
      prompt_template_sha256: digest("prompt"),
      output_schema_id: "qualification_result",
      output_schema_version: "1",
      output_schema_sha256: digest("schema"),
      request: ~s({"jsonrpc":"2.0","method":"turn","params":{"input":"qualify"}}),
      idempotency_key: idempotency_key
    }
  end

  @doc "Attributes completing a model invocation with a valid parsed output."
  def completion do
    %{
      response: ~s({"jsonrpc":"2.0","result":{"qualified":true,"score":82}}),
      parsed_output: %{"qualified" => true, "score" => 82, "criteria" => %{"industry" => "pass"}},
      validation_status: :valid,
      validation_errors: [],
      usage: %{input_tokens: 120, output_tokens: 30, plan_calls: 1},
      latency_ms: 42
    }
  end
end
