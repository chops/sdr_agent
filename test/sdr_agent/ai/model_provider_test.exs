defmodule SdrAgent.AI.ModelProviderTest do
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Telemetry.InMemoryExporter

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, run: run, agent: agent}
  end

  test "Fake is deterministic and persists the S3 invocation lifecycle", ctx do
    assert Application.fetch_env!(:sdr_agent, :model_provider) == Fake
    assert {:ok, result} = ModelProvider.complete(request(ctx, "fake-1"))
    assert result.output == %{answer: "qualified", score: 42}
    assert result.invocation.status == :completed
    assert result.invocation.provider == :fake
    assert result.invocation.validation_status == :valid
    assert [_] = events_of_type(ctx.tenant, "model.invocation.reserved")
    assert [_] = events_of_type(ctx.tenant, "model.invocation.sent")
    assert [_] = events_of_type(ctx.tenant, "model.invocation.completed")
  end

  test "invalid structured output is persisted as failed, never completed", ctx do
    assert {:error, {:validation_failed, errors}} =
             ModelProvider.complete(request(ctx, "invalid"),
               provider: Fake,
               provider_options: [output: %{answer: "qualified", score: "42"}]
             )

    assert errors != []
    assert {:ok, [invocation]} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    assert invocation.status == :failed
    assert invocation.validation_status == :invalid
    assert invocation.error == %{"kind" => "validation_failed"}
    assert events_of_type(ctx.tenant, "model.invocation.completed") == []
  end

  test "the persisted run cap rejects call 21 before provider invocation", ctx do
    for index <- 1..20 do
      assert {:ok, _} = ModelProvider.complete(request(ctx, "run-#{index}"))
    end

    assert {:error, %Ash.Error.Invalid{}} = ModelProvider.complete(request(ctx, "run-21"))
    assert {:ok, invocations} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    assert length(invocations) == 20
  end

  describe "Q0.1: the public call path resolves the runtime provider" do
    setup do
      previous = Application.fetch_env!(:sdr_agent, :model_provider)
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      on_exit(fn -> Application.put_env(:sdr_agent, :model_provider, previous) end)
    end

    test "ClaudeCLI selected without its server is refused before any reservation", ctx do
      assert {:error, :provider_not_running} = ModelProvider.complete(request(ctx, "cli-absent"))
      assert {:ok, []} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)

      assert {:error, :provider_not_running} =
               ModelProvider.complete(request(ctx, "cli-named"),
                 provider: ClaudeCLI
               )

      assert {:ok, []} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    end
  end

  describe "Q0.1 delta review: health is checked whatever the server reference" do
    setup do
      name = :"sdr_q0_health_#{System.unique_integer([:positive])}"
      on_exit(fn -> ClaudeCLI.Reaper.release(name) end)
      %{name: name}
    end

    defp complete_via(ctx, reference) do
      ModelProvider.complete(request(ctx, "health-#{inspect(reference)}"),
        provider: ClaudeCLI,
        provider_options: [server: reference]
      )
    end

    defp assert_no_reservation(ctx) do
      {:ok, invocations} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
      assert invocations == [], "a known-unhealthy server consumed a reservation"
    end

    test "a launcher-less named server is refused before reservation by name and by pid", ctx do
      pid =
        start_supervised!({ClaudeCLI, name: ctx.name, command: nil})

      for reference <- [ctx.name, pid] do
        assert {:error, :llm_proxy_shim_not_found} = complete_via(ctx, reference)
        assert_no_reservation(ctx)
      end
    end

    test "a lease-blocked named server is refused before reservation by name and by pid", ctx do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}
      :persistent_term.put({ClaudeCLI.Reaper, ctx.name}, {:held, dead})

      pid =
        start_supervised!({ClaudeCLI, name: ctx.name, command: System.find_executable("elixir")})

      for reference <- [ctx.name, pid] do
        assert {:error, :provider_not_quiescent} = complete_via(ctx, reference)
        assert_no_reservation(ctx)
      end
    end
  end

  test "an ambiguous provider outcome is persisted as unknown", ctx do
    assert {:error, :provider_outcome_unknown} =
             ModelProvider.complete(request(ctx, "unknown"), provider: __MODULE__.UnknownProvider)

    assert {:ok, [invocation]} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    assert invocation.status == :unknown
    assert [_] = events_of_type(ctx.tenant, "model.invocation.unknown")
  end

  test "GenAI SDK span wraps and correlates a persisted invocation", ctx do
    InMemoryExporter.reset()
    assert {:ok, _} = ModelProvider.complete(request(ctx, "span"))

    assert eventually(fn ->
             InMemoryExporter.spans()
             |> Enum.any?(&(inspect(&1, limit: :infinity) =~ "gen_ai.model.complete"))
           end)
  end

  defp request(ctx, id) do
    attrs = AgentsFixtures.model_attrs(id)

    audit =
      Map.take(attrs, [
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
      run: ctx.run,
      actor: ctx.agent,
      operation: "model.complete",
      prompt: "Qualify the fixture lead",
      schema: @schema,
      audit: audit
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defmodule UnknownProvider do
    @behaviour SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.Fake

    def prepare(request, opts), do: Fake.prepare(request, opts)
    def complete(_request, _opts), do: {:unknown, :ambiguous_transport_failure}
  end
end
