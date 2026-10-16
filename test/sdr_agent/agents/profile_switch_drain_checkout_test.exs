defmodule SdrAgent.Agents.ProfileSwitchDrainCheckoutTest do
  @moduledoc """
  The b1 drain's busy-connection retry under the shared SQL sandbox (C2-02c
  triage, Codex c084e5a0). `ProfileSwitchDrain` checks out with `queue:
  false` and retries only the queue-disabled refusal. Under the sandbox,
  DBConnection prefixes that refusal with its owner-redirect text, which an
  exact-message match missed: a drain that coincided with another process
  using the one shared connection failed at once
  (`:drain_observation_failed`, so the coordinator blocked the switch with
  `drain_failed`).

    * control: the shared connection free, the drain succeeds;
    * held: another process holds the shared connection for 150 ms; the
      drain waits and succeeds within its deadline;
    * negative: any other `DBConnection.ConnectionError` (plain, or with the
      sandbox prefix and another reason) is not retried and fails closed,
      after exactly one checkout (a failing test pool behind a dynamic repo).

  Shared SQL sandbox; no model call.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Test.CoordinatorHarness

  defmodule FailingPool do
    @moduledoc false
    # A DBConnection pool whose every checkout fails with the configured
    # `ConnectionError` message, counting the attempts.
    use Agent

    def child_spec({_conn_mod, opts}) do
      state = {Keyword.fetch!(opts, :failing_message), Keyword.fetch!(opts, :failing_attempts)}
      %{id: __MODULE__, start: {Agent, :start_link, [fn -> state end]}}
    end

    def checkout(pool, _callers, _opts) do
      {message, attempts} = Agent.get(pool, & &1)
      :counters.add(attempts, 1, 1)
      {:error, DBConnection.ConnectionError.exception(message)}
    end
  end

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    # C2-02b2α: the switch finalizers run in the coordinator (manual mode).
    CoordinatorHarness.start!()
    admin = human(:admin, tenant)
    %{agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, admin: admin, agent: agent}
  end

  test "control: with the shared connection free, the drain succeeds", ctx do
    switch = request!(ctx)
    {result, _elapsed} = ctx |> drain_task(switch) |> Task.await(10_000)
    assert {:ok, %{refused: 0}} = result
  end

  test "held: another process holds the shared connection; the drain waits, then succeeds within its deadline",
       ctx do
    switch = request!(ctx)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT 1")
          send(parent, :held)

          receive do
            :release -> :ok
          after
            5_000 -> :timeout
          end
        end)
      end)

    assert_receive :held, 5_000
    drainer = drain_task(ctx, switch)
    Process.sleep(150)
    send(holder.pid, :release)
    Task.await(holder, 5_000)
    {result, elapsed} = Task.await(drainer, 10_000)

    assert {:ok, %{refused: 0}} = result, "a busy shared connection is retried, never failed"
    assert elapsed >= 100, "the drain waited for the held connection (#{elapsed} ms)"
    assert elapsed < 2_000, "the drain returned within its deadline (#{elapsed} ms)"
  end

  test "negative: another ConnectionError is not retried and fails closed after one checkout",
       ctx do
    switch = request!(ctx)

    for message <- [
          "tcp connect (localhost:1): connection refused - :econnrefused",
          "could not checkout the connection owned by #PID<0.1.0>. When using the sandbox, " <>
            "connections are shared, so this may imply another process is using a connection. " <>
            "Reason: owner #PID<0.1.0> exited"
        ] do
      attempts = :counters.new(1, [])

      {:ok, repo} =
        Repo.start_link(
          name: nil,
          pool: FailingPool,
          failing_message: message,
          failing_attempts: attempts
        )

      try do
        {result, elapsed} = ctx |> drain_task(switch, repo) |> Task.await(10_000)

        assert result == {:error, :drain_observation_failed}, inspect({message, result})
        assert :counters.get(attempts, 1) == 1, "not retried: #{message}"
        assert elapsed < 1_000, "failed closed at once (#{elapsed} ms): #{message}"
      after
        Supervisor.stop(repo)
      end
    end
  end

  defp request!(ctx) do
    assert {:ok, switch} =
             Agents.request_profile_switch(
               %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: 1},
               actor: ctx.admin
             )

    switch
  end

  # The drain in its own process (`repo`: a dynamic repo for that process).
  defp drain_task(ctx, switch, repo \\ nil) do
    Task.async(fn ->
      if repo, do: Repo.put_dynamic_repo(repo)
      started = System.monotonic_time(:millisecond)

      result =
        Agents.drain_profile_switch(switch, %{server_generation: 1, timeout_ms: 2_000},
          actor: ctx.agent
        )

      {result, System.monotonic_time(:millisecond) - started}
    end)
  end
end
