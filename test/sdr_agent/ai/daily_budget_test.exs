defmodule SdrAgent.AI.DailyBudgetTest do
  @moduledoc """
  ADR-0004 "200 per UTC day", persisted (S6a follow-up, S7): the daily
  aggregate is the count of the tenant's ModelInvocations reserved in the
  current UTC day (`SdrAgent.Clock`), checked inside the reservation
  transaction, before the provider runs. Attempts are never refunded.
  Configuration may lower the limit, never raise it.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.Clock

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})

  setup do
    previous = Application.get_env(:sdr_agent, :daily_model_call_limit)
    Application.put_env(:sdr_agent, :daily_model_call_limit, 3)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, :daily_model_call_limit, previous),
        else: Application.delete_env(:sdr_agent, :daily_model_call_limit)
    end)

    Clock.freeze(~U[2026-03-10 23:59:00.000000Z])
    on_exit(&Clock.unfreeze/0)
    %{tenant: bootstrap!()}
  end

  defp request(run, agent, id) do
    audit =
      id
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

    %{
      id: id,
      run: run,
      actor: agent,
      operation: "model.complete",
      prompt: "Qualify the fixture lead",
      schema: @schema,
      audit: audit
    }
  end

  test "the limit counts every run of the tenant and refuses before the provider", ctx do
    %{run: first, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    %{run: second} = AgentsFixtures.running_run(ctx.tenant)

    assert {:ok, _} = ModelProvider.complete(request(first, agent, "d-1"))
    assert {:ok, _} = ModelProvider.complete(request(second, agent, "d-2"))

    # A failed (invalid) attempt still counts: attempts are never refunded.
    assert {:error, {:validation_failed, _}} =
             ModelProvider.complete(request(first, agent, "d-3"),
               provider_options: [output: %{answer: "x", score: "not an integer"}]
             )

    assert {:error, {:budget_exhausted, :daily}} =
             ModelProvider.complete(request(second, agent, "d-4"),
               provider: __MODULE__.MustNotRun
             )

    {:ok, invocations} = Agents.list_model_invocations(second.id, actor: agent)
    assert Enum.map(invocations, & &1.idempotency_key) == ["d-2"]

    # The refused reservation rolled back the run counter too.
    {:ok, reloaded} = Agents.get_run(second.id, actor: agent)
    assert reloaded.budget.model_calls_reserved == 1
  end

  test "the next UTC day starts a new count", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

    for n <- 1..3, do: {:ok, _} = ModelProvider.complete(request(run, agent, "day1-#{n}"))

    assert {:error, {:budget_exhausted, :daily}} =
             ModelProvider.complete(request(run, agent, "day1-4"))

    Clock.freeze(~U[2026-03-11 00:00:01.000000Z])
    assert {:ok, _} = ModelProvider.complete(request(run, agent, "day2-1"))
    assert Agents.daily_model_calls(ctx.tenant.id) == 1
  end

  test "configuration may lower the ADR-0004 limit but never raise it" do
    Application.put_env(:sdr_agent, :daily_model_call_limit, 500)
    assert Agents.daily_model_call_limit() == 200
    Application.put_env(:sdr_agent, :daily_model_call_limit, 7)
    assert Agents.daily_model_call_limit() == 7
    Application.delete_env(:sdr_agent, :daily_model_call_limit)
    assert Agents.daily_model_call_limit() == 200
  end

  test "the volatile in-memory day guard is gone" do
    refute Code.ensure_loaded?(SdrAgent.AI.BudgetStore.InMemory)
    refute Code.ensure_loaded?(SdrAgent.AI.BudgetStore)
  end

  defmodule MustNotRun do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.Fake

    def prepare(request, opts), do: Fake.prepare(request, opts)
    def complete(_request, _opts), do: raise("the provider must not be invoked")
  end
end
