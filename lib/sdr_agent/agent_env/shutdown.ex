defmodule SdrAgent.AgentEnv.Shutdown do
  @moduledoc """
  The agent environment's run exit, phase P5 (P5 correction
  `claude-c2star-s1-prb-p5-correction-r1.md` section 2; Codex `e01021f5`
  binding details 2-5, `c9a6f6c7` Q8-Q10 and the `804340e1` review). The
  only writer of the run receipt `instance.<nonce>.exit`, and only the
  application callbacks call it, in run mode:

    * `plan(top)` — `SdrAgent.Application.prep_stop/1`, while the tree is
      still alive. It requires the configured run nonce, the current boot
      binding (`:persistent_term` `{#{inspect(__MODULE__)}, :boot}`, set by
      `SdrAgent.AgentEnv.Instance`) and the on-disk boot marker to agree,
      the top supervisor alive, and the model tree in its expected shape:
      the `ProfileSupervisor` child for ClaudeCLI; for the Fake, no such
      child and the ClaudeCLI server name unregistered. Then it monitors
      the top and the model tree and returns `{:ok, plan}`; anything else
      (the crash path included) is `:not_orderly`.
    * `complete(planned)` — `SdrAgent.Application.stop/1`, after the tree
      has exited. It re-validates the plan against the current binding and
      marker, then requires, within ONE monotonic 30 s deadline across
      every wait and poll: the top's `DOWN` with `:shutdown`; the model
      tree's `DOWN` with `:shutdown` or `{:shutdown, _}` (or `:none`); the
      server name unregistered; and the Reaper lease clear (polled; the
      Reaper's cleanup receipt). Only then does it exclusively create the
      receipt (`nonce`, `boot_id`, `completed_at`). Otherwise it returns
      `{:error, reason}` — `:not_orderly`, `:instance_not_terminated`,
      `:model_tree_not_terminated`, `:server_still_registered`,
      `:reaper_cleanup_unconfirmed` or `:receipt_write_failed` — writes no
      receipt and logs one fixed line with only that reason. It never
      kills, signals, releases or reclaims anything, and never removes a
      file, so an uncertain stop leaves the lease (quarantine).

  Test-seam builds only (`:claude_cli_test_seams`, as
  `SdrAgent.AI.ModelProvider.Runtime`): `plan/2` and `complete/2` take the
  seams `model_tree_id:`, `provider:`, `server_name:`, `reaper_lease:`
  (`fn -> nil | {:held, pid} end`), `budget_ms:`, `boot:` and `root:`.
  Other builds compile neither function, and nothing here reads
  application configuration for them: `plan/1` and `complete/1` always use
  the fixed values.
  """

  require Logger

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.AI.ModelProvider.Runtime

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @budget_ms 30_000
  @poll_ms 20
  @boot_binding {__MODULE__, :boot}

  @type plan :: %{
          nonce: String.t(),
          boot_id: String.t(),
          root: Path.t(),
          top: {pid(), reference()},
          model_tree: :none | {pid(), reference()}
        }

  @doc "Plans the orderly run exit of `top` (see the moduledoc)."
  @spec plan(atom() | pid()) :: {:ok, plan()} | :not_orderly
  def plan(top), do: plan_with(top, fixed())

  @doc "Completes a planned run exit (see the moduledoc); always a result, never a raise."
  @spec complete({:ok, plan()} | :not_orderly | term()) ::
          :ok
          | {:error,
             :not_orderly
             | :instance_not_terminated
             | :model_tree_not_terminated
             | :server_still_registered
             | :reaper_cleanup_unconfirmed
             | :receipt_write_failed}
  def complete(planned), do: complete_with(planned, fixed())

  if @test_seams do
    @seams [:model_tree_id, :provider, :server_name, :reaper_lease, :budget_ms, :boot, :root]

    @doc false
    # Test-seam builds only (see the moduledoc).
    def plan(top, seams) when is_list(seams), do: plan_with(top, seamed(seams))

    @doc false
    # Test-seam builds only (see the moduledoc).
    def complete(planned, seams) when is_list(seams), do: complete_with(planned, seamed(seams))

    defp seamed(seams), do: Map.merge(fixed(), Map.new(Keyword.take(seams, @seams)))
  end

  # The production values; nothing here reads configuration for them.
  defp fixed do
    %{
      model_tree_id: ProfileSupervisor,
      provider: Runtime.provider(),
      server_name: ClaudeCLI.server(),
      reaper_lease: fn -> Reaper.lease(ClaudeCLI.server()) end,
      budget_ms: @budget_ms,
      boot: :persistent_term.get(@boot_binding, nil),
      root: configured_root()
    }
  end

  defp configured_root do
    case State.root() do
      {:ok, root} -> root
      {:error, _reason} -> nil
    end
  end

  ## plan

  defp plan_with(top, s) do
    with {:ok, %{nonce: nonce, boot_id: boot_id}} <- authoritative_binding(s),
         pid when is_pid(pid) <- whereis(top),
         true <- Process.alive?(pid),
         {:ok, tree} <- model_tree(pid, s) do
      top_ref = Process.monitor(pid)

      {:ok,
       %{
         nonce: nonce,
         boot_id: boot_id,
         root: s.root,
         top: {pid, top_ref},
         model_tree: monitored(tree)
       }}
    else
      _not_orderly -> :not_orderly
    end
  end

  # The authoritative binding: the configured run nonce, the current boot
  # binding and the on-disk marker all agree.
  defp authoritative_binding(%{boot: %{nonce: nonce, boot_id: boot_id} = boot, root: root})
       when is_binary(nonce) and is_binary(boot_id) and is_binary(root) do
    with :run <- AgentEnv.mode(),
         ^nonce <- Keyword.get(AgentEnv.config(), :nonce),
         {:valid, _sha256, %{"boot_id" => ^boot_id}} <- State.read(root, {:boot, nonce}) do
      {:ok, Map.take(boot, [:nonce, :boot_id])}
    else
      _mismatch -> :error
    end
  end

  defp authoritative_binding(_seams), do: :error

  defp whereis(pid) when is_pid(pid), do: pid
  defp whereis(name) when is_atom(name), do: Process.whereis(name)
  defp whereis(_other), do: nil

  defp model_tree(top, s) do
    tree = child(top, s.model_tree_id)

    cond do
      s.provider == ClaudeCLI and is_pid(tree) ->
        {:ok, tree}

      s.provider == Fake and tree == :absent and Process.whereis(s.server_name) == nil ->
        {:ok, :none}

      true ->
        :error
    end
  end

  defp child(top, id) do
    top
    |> Supervisor.which_children()
    |> Enum.find_value(:absent, fn
      {^id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  catch
    :exit, _reason -> :error
  end

  defp monitored(:none), do: :none
  defp monitored(pid), do: {pid, Process.monitor(pid)}

  ## complete

  defp complete_with({:ok, %{} = plan}, s) do
    deadline = System.monotonic_time(:millisecond) + s.budget_ms

    result =
      with :ok <- current(plan, s),
           :ok <- await_down(Map.get(plan, :top), [:shutdown], deadline, :instance_not_terminated),
           :ok <- await_tree(Map.get(plan, :model_tree), deadline),
           :ok <-
             poll(
               fn -> Process.whereis(s.server_name) == nil end,
               deadline,
               :server_still_registered
             ),
           :ok <- poll(fn -> s.reaper_lease.() == nil end, deadline, :reaper_cleanup_unconfirmed),
           do: receipt(plan)

    demonitor(plan)
    outcome(result)
  end

  defp complete_with(_not_orderly, _seams), do: outcome({:error, :not_orderly})

  # The plan still names the authoritative binding and its own root.
  defp current(plan, s) do
    with %{nonce: nonce, boot_id: boot_id, root: root} <- plan,
         {:ok, %{nonce: ^nonce, boot_id: ^boot_id}} <- authoritative_binding(s),
         ^root <- s.root do
      :ok
    else
      _mismatch -> {:error, :not_orderly}
    end
  end

  defp await_tree(:none, _deadline), do: :ok

  defp await_tree(tree, deadline),
    do: await_down(tree, [:shutdown, {:shutdown, :_}], deadline, :model_tree_not_terminated)

  defp await_down({pid, ref}, accepted, deadline, failure)
       when is_pid(pid) and is_reference(ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        if accepted?(reason, accepted), do: :ok, else: {:error, failure}
    after
      remaining(deadline) -> {:error, failure}
    end
  end

  defp await_down(_malformed, _accepted, _deadline, failure), do: {:error, failure}

  defp accepted?(:shutdown, _accepted), do: true
  defp accepted?({:shutdown, _detail}, accepted), do: {:shutdown, :_} in accepted
  defp accepted?(_reason, _accepted), do: false

  defp poll(done?, deadline, failure) do
    cond do
      done?.() -> :ok
      remaining(deadline) == 0 -> {:error, failure}
      true -> wait_and_poll(done?, deadline, failure)
    end
  end

  defp wait_and_poll(done?, deadline, failure) do
    Process.sleep(min(@poll_ms, remaining(deadline)))
    poll(done?, deadline, failure)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp receipt(plan) do
    receipt = %{
      "nonce" => plan.nonce,
      "boot_id" => plan.boot_id,
      "completed_at" => DateTime.utc_now()
    }

    case State.create(plan.root, {:run_receipt, plan.nonce}, receipt) do
      {:ok, _sha256} -> :ok
      {:error, _reason} -> {:error, :receipt_write_failed}
    end
  end

  defp demonitor(plan) do
    for {_pid, ref} <- [Map.get(plan, :top), Map.get(plan, :model_tree)], is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp outcome(:ok), do: :ok

  defp outcome({:error, reason}) do
    Logger.error("agent environment run exit: no receipt (#{reason})")
    {:error, reason}
  end
end
