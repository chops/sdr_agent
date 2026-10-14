defmodule SdrAgent.AI.LaunchBoundaryTest do
  @moduledoc """
  C9-03 sent boundary (R0 readiness packet, "`ModelProvider` facade"): for
  ClaudeCLI the facade reserves and hands the provider the reserved
  invocation id; it never marks the call sent itself. The row becomes sent
  only inside `Agents.admit_launch/3`, which the server calls once per
  dispatch just before it opens the port, and the facade re-reads the row
  before settling. A call refused at launch is failed and never sent; a
  call that never reached admission is failed, never sent; the Fake keeps
  its order (reserved → sent → provider).
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Operations.Failure

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    # R0-07 slice B: real calls are admitted only with a promoted tuple and
    # a trusted store (`SdrAgent.AdmissionFixtures`).
    SdrAgent.AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    grant = AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, admin: admin, grant: grant, run: run, agent: agent}
  end

  describe "the facade's sent boundary" do
    test "a ClaudeCLI invocation is still reserved when the provider is called", ctx do
      Process.put(:launch_boundary_test, self())

      assert {:ok, result} = complete(ctx, "observed", provider: __MODULE__.Observing)
      assert_received {:status_during_call, :reserved}
      assert result.invocation.status == :completed
      assert result.invocation.sent_at != nil
    end

    test "the Fake is still marked sent before its provider call", ctx do
      Process.put(:launch_boundary_test, self())

      assert {:ok, result} = complete(ctx, "fake-observed", provider: __MODULE__.FakeObserving)
      assert_received {:status_during_call, :sent}
      assert result.invocation.status == :completed
    end

    test "a ClaudeCLI result that never passed launch admission is failed, never sent", ctx do
      assert {:error, :launch_not_admitted} =
               complete(ctx, "unadmitted", provider: __MODULE__.Unadmitted)

      assert [invocation] = invocations(ctx)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      assert invocation.error["reason"] == "launch_not_admitted"
    end

    test "a refusal before admission leaves the call failed and never sent", ctx do
      for {provider, reason} <- [
            {__MODULE__.QueueTimeout, :provider_queue_timeout},
            {__MODULE__.ExitsBeforeAdmission, :provider_exit}
          ] do
        assert {:error, ^reason} = complete(ctx, "refused-#{reason}", provider: provider)
      end

      for invocation <- invocations(ctx) do
        assert {invocation.status, invocation.sent_at} == {:failed, nil}
      end
    end

    test "a known failure after admission (deterministic spawn failure) is failed", ctx do
      assert {:error, :spawn_failed} =
               complete(ctx, "spawn-failed", provider: __MODULE__.FailsAfterAdmission)

      assert [invocation] = invocations(ctx)
      assert invocation.status == :failed
      assert invocation.sent_at != nil
    end

    test "an unknown outcome after admission is unknown", ctx do
      assert {:error, :provider_outcome_unknown} =
               complete(ctx, "unknown-after", provider: __MODULE__.UnknownAfterAdmission)

      assert [%{status: :unknown}] = invocations(ctx)
    end
  end

  describe "the ClaudeCLI server admits each launch" do
    setup do
      dump = Path.join(System.tmp_dir!(), "sdr-launch-#{System.unique_integer([:positive])}")
      on_exit(fn -> (dump <> ".*") |> Path.wildcard() |> Enum.each(&File.rm/1) end)
      %{dump: dump}
    end

    test "an admitted call is sent, launched and completed", ctx do
      server = server!(["env_dump", ctx.dump])

      assert {:ok, result} = complete(ctx, "launched", provider_options: [server: server])
      assert result.invocation.status == :completed
      assert [launch] = dumps(ctx.dump)
      assert launch["SDR_MODEL_INVOCATION_ID"] == result.invocation.id

      types =
        ctx.tenant
        |> events()
        |> Enum.filter(&(&1.model_invocation_id == result.invocation.id))
        |> Enum.map(& &1.event_type)

      assert types == [
               "model.invocation.reserved",
               "model.invocation.sent",
               "model.invocation.completed"
             ]
    end

    test "a call queued behind a running one is refused at launch after its run stopped",
         ctx do
      server = server!(["env_dump", ctx.dump, "1500"])
      other = AgentsFixtures.running_run(ctx.tenant)

      first = Task.async(fn -> complete(ctx, "running", provider_options: [server: server]) end)
      await_status!(ctx, "running", :sent)

      queued_ctx = %{ctx | run: other.run, agent: other.agent}

      second =
        Task.async(fn -> complete(queued_ctx, "stopped", provider_options: [server: server]) end)

      await_reserved!(ctx, "stopped")
      assert eventually(fn -> queued?(server, second.pid) end)

      {:ok, _} = Agents.cancel_run(other.run, actor: ctx.admin)

      assert {:ok, %{invocation: %{status: :completed}}} = Task.await(first, 20_000)
      assert {:error, :run_not_running_at_launch} = Task.await(second, 20_000)

      refused = invocation!(ctx, "stopped")
      assert {refused.status, refused.sent_at} == {:failed, nil}
      assert launch_failures(ctx, refused.agent_run_id) == []
      assert length(dumps(ctx.dump)) == 1
    end

    test "a call queued behind a running one is refused at launch after a revocation", ctx do
      server = server!(["env_dump", ctx.dump, "1500"])

      first = Task.async(fn -> complete(ctx, "first", provider_options: [server: server]) end)
      first_id = await_status!(ctx, "first", :sent)

      second = Task.async(fn -> complete(ctx, "second", provider_options: [server: server]) end)
      await_reserved!(ctx, "second")
      assert eventually(fn -> queued?(server, second.pid) end)

      {:ok, _} = Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)

      # The launched call is not killed by the revocation; the queued one never launches.
      assert {:ok, %{invocation: %{id: ^first_id, status: :completed}}} =
               Task.await(first, 20_000)

      assert {:error,
              %SdrAgent.Agents.Admission.Refused{
                stage: :launch,
                reason: :grant_ineligible_at_launch
              }} =
               Task.await(second, 20_000)

      refused = invocation!(ctx, "second")
      assert {refused.status, refused.sent_at} == {:failed, nil}
      assert [_] = launch_failures(ctx, refused.agent_run_id)
      assert length(dumps(ctx.dump)) == 1
    end

    test "a replayed admission of a running call is refused and the call settles normally",
         ctx do
      server = server!(["env_dump", ctx.dump, "1000"])

      call = Task.async(fn -> complete(ctx, "in-flight", provider_options: [server: server]) end)
      id = await_status!(ctx, "in-flight", :sent)
      before = Ash.get!(ModelInvocation, id, authorize?: false)

      assert {:error, :invocation_not_reserved} =
               Agents.admit_launch(id, :claude_cli_opus, actor: ctx.agent)

      assert Ash.get!(ModelInvocation, id, authorize?: false) == before
      assert {:ok, %{invocation: %{status: :completed}}} = Task.await(call, 20_000)
      assert launch_failures(ctx, id) == []
    end
  end

  defp server!(args) do
    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        test_launcher: true,
        command_args: [@fake | args],
        timeout: 20_000
      )

    server
  end

  defp complete(ctx, id, opts) do
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

    ModelProvider.complete(
      %{
        id: id,
        run: ctx.run,
        actor: ctx.agent,
        operation: "model.complete",
        prompt: "Qualify the fixture lead",
        schema: @schema,
        audit: audit
      },
      Keyword.put_new(opts, :provider, ClaudeCLI)
    )
  end

  defp invocations(ctx) do
    {:ok, invocations} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    invocations
  end

  defp invocation!(ctx, key) do
    ModelInvocation
    |> Ash.Query.filter(idempotency_key == ^key and tenant_id == ^ctx.tenant.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp await_reserved!(ctx, key) do
    assert eventually(fn -> invocation!(ctx, key) != nil end)
  end

  defp await_status!(ctx, key, status) do
    assert eventually(fn -> match?(%{status: ^status}, invocation!(ctx, key)) end)
    invocation!(ctx, key).id
  end

  defp launch_failures(ctx, id) do
    Failure
    |> Ash.Query.filter(class == :provider_error and subject_id == ^id)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))
  end

  defp dumps(dump) do
    (dump <> ".*")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
  end

  defp queued?(server, pid) do
    {:messages, messages} = Process.info(server, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", {^pid, _tag}, _request} -> true
      _ -> false
    end)
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  # --- test-only providers -------------------------------------------------

  defmodule Observing do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.AI.ModelProvider.ClaudeCLI

    def prepare(_request, _opts), do: {:ok, ClaudeCLI.provenance()}

    def complete(request, _opts) do
      id = request.witness.model_invocation_id
      status = Ash.get!(ModelInvocation, id, authorize?: false).status
      send(Process.get(:launch_boundary_test), {:status_during_call, status})
      {:ok, _sent} = SdrAgent.Agents.admit_launch(id, :claude_cli_opus, actor: request.actor)
      SdrAgent.AI.LaunchBoundaryTest.Unadmitted.complete(request, [])
    end
  end

  defmodule FakeObserving do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.AI.ModelProvider.Fake

    def prepare(request, opts), do: Fake.prepare(request, opts)

    def complete(request, opts) do
      status = Ash.get!(ModelInvocation, request.witness.model_invocation_id, authorize?: false)
      send(Process.get(:launch_boundary_test), {:status_during_call, status.status})
      Fake.complete(request, opts)
    end
  end

  defmodule Unadmitted do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    alias SdrAgent.AI.ModelProvider.ClaudeCLI

    def prepare(_request, _opts), do: {:ok, ClaudeCLI.provenance()}

    def complete(request, _opts) do
      output = %{answer: "qualified", score: 7}

      {:ok,
       %{
         output: output,
         provider: :claude_cli,
         model: "claude-opus-5-5",
         request_id: request.id,
         raw_response: Jason.encode!(%{output: output}),
         usage: %{input_tokens: 1, output_tokens: 1, plan_calls: 1}
       }}
    end
  end

  defmodule QueueTimeout do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, SdrAgent.AI.ModelProvider.ClaudeCLI.provenance()}
    def complete(_request, _opts), do: {:error, :provider_queue_timeout}
  end

  defmodule ExitsBeforeAdmission do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, SdrAgent.AI.ModelProvider.ClaudeCLI.provenance()}
    def complete(_request, _opts), do: exit(:server_crashed)
  end

  defmodule FailsAfterAdmission do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, SdrAgent.AI.ModelProvider.ClaudeCLI.provenance()}

    def complete(request, _opts) do
      {:ok, _sent} =
        SdrAgent.Agents.admit_launch(request.witness.model_invocation_id, :claude_cli_opus,
          actor: request.actor
        )

      {:error, :spawn_failed}
    end
  end

  defmodule UnknownAfterAdmission do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, SdrAgent.AI.ModelProvider.ClaudeCLI.provenance()}

    def complete(request, _opts) do
      {:ok, _sent} =
        SdrAgent.Agents.admit_launch(request.witness.model_invocation_id, :claude_cli_opus,
          actor: request.actor
        )

      {:unknown, :reaper_down}
    end
  end
end
