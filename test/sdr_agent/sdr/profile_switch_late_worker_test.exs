defmodule SdrAgent.SDR.ProfileSwitchLateWorkerTest do
  @moduledoc """
  C2-02b1 (#52, slice b1), the late worker's producer path, end to end
  (`docs/product/r0/c2-02b1-interface.md`, "A concurrent ordinary
  worker"). An assignment run on ClaudeCLI (the hermetic fake CLI behind
  the named server) has reserved its call. Just before launch, a switch is
  requested and drained, so the drain refuses the reserved row, stops the
  run and settles its Operation. The server's launch admission then finds
  the row not reserved. The worker's own path (server, facade, `SDR.Model`
  and `AgentWorker`) must leave exactly one live attention item: the
  drain's. It must not settle the Operation with another cause, and it
  must launch no port.

  RED: `drain_profile_switch/3` doesn't exist on the base; presence is
  asserted before the server starts.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup ctx do
    AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    AdmissionFixtures.admit_tuples!()
    put_env!(:model_provider, ClaudeCLI)
    :ok
  end

  defp server!(opts) do
    start_supervised!(
      {ClaudeCLI,
       [
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         test_launcher: true,
         command_args: [@fake, "sdr"]
       ] ++ opts}
    )
  end

  defp attention!(ctx) do
    {:ok, items} = Operations.list_attention(actor: ctx.admin)
    items
  end

  test "a row the drain refused: the late worker opens no second item and launches nothing",
       ctx do
    assert function_exported?(Agents, :drain_profile_switch, 3),
           "C2-02b1: Agents.drain_profile_switch/3 is not implemented"

    parent = self()
    admin = ctx.admin
    agent = ctx.agent

    # Runs in the server process, between the reservation and the launch.
    admit = fn id, profile, opts ->
      drained =
        with {:ok, switch} <-
               Agents.request_profile_switch(
                 %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: 1},
                 actor: admin
               ) do
          Agents.drain_profile_switch(switch, %{server_generation: 1, timeout_ms: 5_000},
            actor: agent
          )
        end

      send(parent, {:drained, drained})
      Agents.admit_launch(id, profile, opts)
    end

    server!(launch_admission: admit)
    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    assert_received {:drained, {:ok, %{refused: 1}}}

    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :model_not_admitted}
    assert [invocation] = invocations!(ctx, run)
    assert {invocation.status, invocation.sent_at} == {:failed, nil}
    assert invocation.error["reason"] == "profile_switch_fenced"
    assert events_of_type(ctx.tenant, "model.invocation.sent") == []

    assert [failure] = attention!(ctx) -- before
    assert failure.id == run.attention_failure_id
    assert {failure.class, failure.subject_id} == {:provider_error, run.id}

    {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
    assert operation.status in [:failed, :discarded]
    assert operation.last_failure_id == failure.id
    refute Enum.any?(attention!(ctx), &(&1.class == :run_stopped))
  end
end
