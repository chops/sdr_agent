defmodule SdrAgent.AgentsFixtures do
  @moduledoc "Builders for Agents-domain rows created through the domain API."

  import SdrAgent.AuditCase, only: [system_actor: 2, digest: 1, human: 2]

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
      usage_origin: Keyword.get(opts, :usage_origin, :assignment),
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

  @doc """
  `attrs` reserved under `provider`, with that provider's model profile
  (C9): `:claude_cli_opus` for ClaudeCLI (reserving it needs an eligible
  grant, `grant!/2`); the Fake records `:fake` itself.
  """
  def with_provider(attrs, :claude_cli),
    do: Map.merge(attrs, %{provider: :claude_cli, profile_id: :claude_cli_opus})

  def with_provider(attrs, provider), do: Map.put(attrs, :provider, provider)

  @doc """
  Attributes for a ClaudeCLI (real-provider) reservation: `model_attrs/1`
  with the reviewed ClaudeCLI provenance. Reserving it needs an eligible
  grant (`grant!/2`).
  """
  def claude_attrs(idempotency_key) do
    idempotency_key
    |> model_attrs()
    |> Map.merge(SdrAgent.AI.ModelProvider.ClaudeCLI.provenance())
  end

  @doc """
  Creates, as the tenant's admin, an active real-model call grant (C9) wide
  enough for synthetic ClaudeCLI tests: both profiles, a window around any
  frozen test clock, and one allocation funding every usage bucket.
  `overrides` replace grant terms (including `:allocations`); `admin` (an
  active admin `SdrAgent.Accounts.User`) defaults to a new test admin.
  """
  def grant!(tenant, overrides \\ %{}, admin \\ nil) do
    attrs =
      Map.merge(
        %{
          name: "G-TEST",
          purpose: "Synthetic test calls",
          profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
          total_attempts: 1_000,
          starts_at: ~U[2000-01-01 00:00:00.000000Z],
          expires_at: ~U[2100-01-01 00:00:00.000000Z],
          allocations: [
            %{
              key: :daily_use,
              applies_to: SdrAgent.Agents.ModelCallAllocation.buckets(),
              attempts: 1_000
            }
          ]
        },
        Map.new(overrides)
      )

    {:ok, grant} = SdrAgent.Agents.create_grant(attrs, actor: admin || human(:admin, tenant))
    grant
  end
end
