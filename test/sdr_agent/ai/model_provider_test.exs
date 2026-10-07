defmodule SdrAgent.AI.ModelProviderTest do
  use ExUnit.Case, async: false

  alias SdrAgent.AI.BudgetStore.InMemory, as: BudgetStore
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Telemetry.InMemoryExporter

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})

  setup do
    assert Code.ensure_loaded?(ModelProvider), "S6a must define the model-provider facade"
    assert Code.ensure_loaded?(BudgetStore), "S6a must define its volatile budget store"
    :ok = BudgetStore.reset()
    :ok
  end

  test "Fake is deterministic, is the test default, and returns only validated output" do
    assert Application.fetch_env!(:sdr_agent, :model_provider) == Fake

    request = request("fake-1")
    assert {:ok, first} = ModelProvider.complete(request)
    assert {:ok, second} = ModelProvider.complete(%{request | id: "fake-2"})
    assert first.output == %{answer: "qualified", score: 42}
    assert second.output == first.output
    assert first.provider == :fake
  end

  test "invalid structured output is rejected by Zoi" do
    assert {:error, {:validation_failed, errors}} =
             ModelProvider.complete(request("invalid"),
               provider: Fake,
               provider_options: [output: %{answer: "qualified", score: "42"}]
             )

    assert errors != []
  end

  test "run and daily budgets reject before provider invocation" do
    for index <- 1..20 do
      assert {:ok, _} = ModelProvider.complete(request("run-#{index}"))
    end

    assert {:error, {:budget_exhausted, :run}} =
             ModelProvider.complete(request("run-21"))

    :ok = BudgetStore.reset()

    for index <- 1..200 do
      assert {:ok, _} =
               ModelProvider.complete(%{request("day-#{index}") | run_id: "run-#{index}"})
    end

    assert {:error, {:budget_exhausted, :day}} =
             ModelProvider.complete(%{request("day-201") | run_id: "run-201"})
  end

  test "budget persistence seam is replaceable" do
    assert {:error, {:budget_exhausted, :replacement}} =
             ModelProvider.complete(request("replacement"),
               budget_store: SdrAgent.AI.ModelProviderTest.RejectingBudgetStore
             )
  end

  test "GenAI SDK span wraps a Fake invocation" do
    InMemoryExporter.reset()
    assert {:ok, _} = ModelProvider.complete(request("span"))

    assert eventually(fn ->
             InMemoryExporter.spans()
             |> Enum.any?(&(inspect(&1, limit: :infinity) =~ "gen_ai.model.complete"))
           end)
  end

  defp request(id) do
    %{
      id: id,
      run_id: "run-1",
      operation: "model.complete",
      prompt: "Qualify the fixture lead",
      schema: @schema
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defmodule RejectingBudgetStore do
    @behaviour SdrAgent.AI.BudgetStore

    def reserve(_run_id, _now), do: {:error, {:budget_exhausted, :replacement}}
    def settle(_reservation, _outcome), do: :ok
  end
end
