if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.CalibrationConsole.Authority do
    @moduledoc """
    The sealed one-shot calibration authority (R0-07 slice E, packet 8.2
    steps 4-7, `CalibrationAuthority` in 8.7). It exists only in test-seam
    builds: in every other build the module is not compiled, so no
    staging exemption can be issued.

    A registry process owns a protected ETS table and generates the console
    instance id (`instance/0`) at start.

      * `issue/1` registers one entry under an unguessable key binding the
        invocation, run, tenant and profile ids, the command pid, the
        private server pid, the prompt and schema SHA-256 commitments and
        the console instance; it returns only an opaque reference. A
        malformed binding is `{:error, :invalid_binding}`.
      * `consume/2` is called in the server process. It succeeds only for
        an unconsumed entry when `self()` is the bound server, the claimed
        caller is the bound command and every claimed id, hash and the
        instance equal the bound ones; the entry is then consumed before
        any launch. Anything else is `{:error, :real_model_staged}` and
        leaves the entry unconsumed. A consumed entry is never usable
        again.
      * `revoke/1` removes the entry; the registry also removes it when the
        command or the server dies.

    Every check and state change is serialized in the registry process.
    Threat model: a trusted in-process boundary (other callers, workers,
    second invocations, second servers and replays in the same VM); not
    arbitrary code run by the owner inside the console VM.
    """
    use GenServer

    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @sha256 ~r/\A[0-9a-f]{64}\z/
    @keys ~w(invocation_id run_id tenant_id profile_id command_pid server_pid prompt_sha256
             schema_sha256 instance)a
    @claims ~w(caller invocation_id run_id tenant_id profile_id prompt_sha256 schema_sha256
               instance)a
    @staged {:error, :real_model_staged}

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @doc "This console VM's instance id, generated when the registry started."
    def instance, do: GenServer.call(__MODULE__, :instance)

    @doc "The registry's protected table (inspection only)."
    def table, do: GenServer.call(__MODULE__, :table)

    @doc "`{:ok, opaque_ref}` or `{:error, :invalid_binding}` (see the moduledoc)."
    def issue(binding), do: GenServer.call(__MODULE__, {:issue, binding})

    @doc "`:ok`, consuming the entry, or `{:error, :real_model_staged}`."
    def consume(ref, claims), do: GenServer.call(__MODULE__, {:consume, ref, claims, self()})

    @doc "Removes the entry, if any: `:ok`."
    def revoke(ref), do: GenServer.call(__MODULE__, {:revoke, ref})

    @impl true
    def init(_opts) do
      table = :ets.new(__MODULE__, [:set, :protected])
      instance = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      {:ok, %{table: table, instance: instance, monitors: %{}}}
    end

    @impl true
    def handle_call(:instance, _from, state), do: {:reply, state.instance, state}
    def handle_call(:table, _from, state), do: {:reply, state.table, state}

    def handle_call({:issue, binding}, _from, state) do
      if binding?(binding, state.instance) do
        key = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        :ets.insert(state.table, {key, binding, :unconsumed})
        state = watch(state, key, [binding.command_pid, binding.server_pid])
        {:reply, {:ok, {__MODULE__, key}}, state}
      else
        {:reply, {:error, :invalid_binding}, state}
      end
    end

    def handle_call({:consume, {__MODULE__, key}, claims, server}, _from, state)
        when is_binary(key) do
      with [{^key, binding, :unconsumed}] <- :ets.lookup(state.table, key),
           true <- server == binding.server_pid,
           true <- claims?(claims, binding) do
        :ets.insert(state.table, {key, binding, :consumed})
        {:reply, :ok, state}
      else
        _ -> {:reply, @staged, state}
      end
    end

    def handle_call({:consume, _forged, _claims, _server}, _from, state),
      do: {:reply, @staged, state}

    def handle_call({:revoke, {__MODULE__, key}}, _from, state) when is_binary(key),
      do: {:reply, :ok, forget(state, key)}

    def handle_call({:revoke, _forged}, _from, state), do: {:reply, :ok, state}

    # The command or the server died: every entry bound to it is removed.
    @impl true
    def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
      case Map.pop(state.monitors, monitor) do
        {nil, _monitors} -> {:noreply, state}
        {key, monitors} -> {:noreply, forget(%{state | monitors: monitors}, key)}
      end
    end

    defp watch(state, key, pids) do
      monitors = Map.new(pids, &{Process.monitor(&1), key})
      %{state | monitors: Map.merge(state.monitors, monitors)}
    end

    defp forget(state, key) do
      :ets.delete(state.table, key)
      {gone, monitors} = Enum.split_with(state.monitors, fn {_monitor, k} -> k == key end)
      Enum.each(gone, fn {monitor, _key} -> Process.demonitor(monitor, [:flush]) end)
      %{state | monitors: Map.new(monitors)}
    end

    defp binding?(%{} = binding, instance) do
      Enum.sort(Map.keys(binding)) == Enum.sort(@keys) and
        Enum.all?([:invocation_id, :run_id, :tenant_id], &uuid?(binding[&1])) and
        is_atom(binding.profile_id) and not is_nil(binding.profile_id) and
        is_pid(binding.command_pid) and is_pid(binding.server_pid) and
        sha?(binding.prompt_sha256) and sha?(binding.schema_sha256) and
        binding.instance == instance
    end

    defp binding?(_binding, _instance), do: false

    defp claims?(%{} = claims, binding) do
      Enum.sort(Map.keys(claims)) == Enum.sort(@claims) and
        claims.caller == binding.command_pid and
        Map.take(claims, @claims -- [:caller]) == Map.take(binding, @claims -- [:caller])
    end

    defp claims?(_claims, _binding), do: false

    defp uuid?(value), do: is_binary(value) and value =~ @uuid
    defp sha?(value), do: is_binary(value) and value =~ @sha256
  end
end
