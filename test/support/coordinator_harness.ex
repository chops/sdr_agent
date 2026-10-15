defmodule SdrAgent.Test.CoordinatorHarness do
  @moduledoc """
  C2-02b2α: the switch's `complete`, `fail` and `block` run only in the
  registered coordinator, fenced on the latest start of its boot
  (`docs/product/r0/c2-02b2-interface.md` section 1a). Slice a and b1 tests
  call them through this harness, with their own assertions unchanged:

    * `start!/0` starts the profile tree in manual mode (test builds only),
      from the test process;
    * `finalize/4` runs the finalizer in the coordinator (`test_run/2`),
      after preparing the start its prerequisite needs: a ready activation
      for `complete` (at the switch's `to`), a ready rollback for `fail` (at
      its `from`), the latest start for `block`. The start is prepared as
      `model_runtime` of the switch's tenant; the finalizer runs as the
      test's actor. `own_connection: true` runs it on the coordinator's own
      non-sandboxed connection, and `report: {pid, tag}` first sends that
      connection's backend pid as `{tag, backend_pid}`.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Repo

  @finalizers %{
    complete_profile_switch: :complete,
    fail_profile_switch: :fail,
    block_profile_switch: :block
  }

  @doc "Starts the profile tree in manual mode; returns the coordinator's binding."
  def start! do
    start_supervised!({ProfileSupervisor, manual: true}, id: :coordinator_harness)
    Coordinator.test_run(& &1, 5_000)
  end

  @doc """
  Runs `fun` (`:complete_profile_switch`, `:fail_profile_switch` or
  `:block_profile_switch`) on `switch` in the coordinator, with `attrs`
  plus the coordinator's `boot_id` and the prepared `start_id`.
  """
  def finalize(fun, switch, attrs, opts) when is_map_key(@finalizers, fun) do
    {harness, opts} = Keyword.split(opts, [:own_connection, :report])

    Coordinator.test_run(
      fn binding ->
        connection(harness, fn ->
          start = prepare!(Map.fetch!(@finalizers, fun), switch, binding)
          attrs = attrs |> Map.new() |> Map.merge(%{boot_id: binding.boot_id, start_id: start.id})
          apply(Agents, fun, [switch, attrs, opts])
        end)
      end,
      30_000
    )
  end

  defp connection(harness, fun) do
    if harness[:own_connection] do
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        report(harness[:report])
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    else
      fun.()
    end
  end

  defp report({pid, tag}) do
    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(pid, {tag, backend})
  end

  defp report(nil), do: :ok

  # The latest start of this boot that the action's prerequisite needs.
  defp prepare!(action, switch, binding) do
    runtime = SdrAgent.Actor.system(:model_runtime, switch.tenant_id)

    {reason, profile, switch_id} =
      case action do
        :complete -> {:activation, switch.to_profile_id, switch.id}
        :fail -> {:rollback, switch.from_profile_id, switch.id}
        :block -> {:replacement, switch.from_profile_id, nil}
      end

    case reusable(runtime, binding, action, reason, profile, switch_id) do
      %{} = start -> start
      nil -> prepare_new!(runtime, binding, switch, reason, profile, switch_id)
    end
  end

  # This boot's latest start, when it already meets the prerequisite, is
  # reused, as the coordinator reuses its bound start: a replay prepares
  # nothing new.
  defp reusable(runtime, binding, action, reason, profile, switch_id) do
    {:ok, starts} = Agents.list_server_starts(actor: runtime)

    case List.last(starts) do
      %{boot_id: boot} = latest when boot == binding.boot_id ->
        if action == :block or
             (latest.status == :ready and latest.reason == reason and
                latest.profile_id == profile and latest.switch_id == switch_id),
           do: latest

      _other ->
        nil
    end
  end

  defp prepare_new!(runtime, binding, switch, reason, profile, switch_id) do
    attrs =
      %{boot_id: binding.boot_id, profile_id: profile, reason: reason}
      |> then(&if(switch_id, do: Map.put(&1, :switch_id, switch_id), else: &1))

    # A switch that doesn't exist (a refusal test) gets a replacement start.
    {:ok, start} =
      with {:error, _} <- Agents.allocate_server_start(attrs, actor: runtime) do
        attrs
        |> Map.merge(%{reason: :replacement, profile_id: switch.from_profile_id})
        |> Map.delete(:switch_id)
        |> Agents.allocate_server_start(actor: runtime)
      end

    reaper = spawn(fn -> :ok end)
    observed = %{boot_id: binding.boot_id, pid: self(), node: node(), reaper_pid: reaper}
    {:ok, start} = Agents.mark_server_start(start, :started, observed, actor: runtime)

    {:ok, start} =
      Agents.mark_server_start(
        start,
        :ready,
        %{boot_id: binding.boot_id, pid: self(), ready_evidence: :spawn_preflight},
        actor: runtime
      )

    start
  end
end
