defmodule SdrAgent.Discovery.Limiter do
  @moduledoc """
  Owner-wide single-action admission and cooldown for interactive Exa discovery.
  Only the monitored worker's private completion exit releases its permit and
  delivers data. Cancellation, deadline and receiver death kill the task first;
  its DOWN then releases the permit. State holds no queries, keys or results.
  """
  use GenServer

  alias SdrAgent.Discovery.Config

  @codes ~w(timeout cancelled rate_limited quota_exceeded provider_auth provider_unavailable invalid_response too_large unsafe_url source_mismatch invalid_input unavailable internal)a

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def start(owner, request), do: GenServer.call(__MODULE__, {:start, owner, request})

  @doc false
  def cancel(owner, id), do: GenServer.call(__MODULE__, {:cancel, owner, id})

  @impl true
  def init(_) do
    Process.flag(:sensitive, true)
    :logger.update_process_metadata(%{sdr_sensitive_input: true})
    {:ok, %{active: %{}, cooldown: %{}}}
  end

  @impl true
  def handle_call({:start, owner, request}, {receiver, _}, state) do
    now = System.monotonic_time(:millisecond)
    cooldown = Map.filter(state.cooldown, fn {_, until} -> until > now end)
    state = %{state | cooldown: cooldown}

    cond do
      Map.has_key?(state.active, owner) -> {:reply, {:error, :busy}, state}
      Map.has_key?(cooldown, owner) -> {:reply, {:error, :cooldown}, state}
      true -> launch(owner, receiver, request, state)
    end
  end

  def handle_call({:cancel, owner, id}, {caller, _}, state) do
    case state.active[owner] do
      %{id: ^id, receiver: ^caller} = entry ->
        Process.exit(entry.worker, :kill)
        {:reply, :ok, put_in(state.active[owner].resolution, :cancelled)}

      _ ->
        {:reply, {:error, :forbidden}, state}
    end
  end

  defp launch(owner, receiver, request, state) do
    token = make_ref()
    client = Config.client()

    case Task.Supervisor.start_child(
           SdrAgent.Discovery.Tasks,
           fn ->
             Process.flag(:sensitive, true)
             :logger.update_process_metadata(%{sdr_sensitive_input: true})

             receive do
               {:run, ^token} ->
                 outcome = execute(client, request)
                 exit({:shutdown, {:completed, token, outcome}})
             end
           end,
           shutdown: :brutal_kill
         ) do
      {:ok, worker} ->
        id = Ecto.UUID.generate()

        entry = %{
          id: id,
          worker: worker,
          worker_ref: Process.monitor(worker),
          receiver: receiver,
          receiver_ref: Process.monitor(receiver),
          token: token,
          timer: Process.send_after(self(), {:deadline, owner, token}, Config.timeout()),
          resolution: nil
        }

        send(worker, {:run, token})
        {:reply, {:ok, id}, put_in(state.active[owner], entry)}

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  defp execute(client, request) do
    case client.execute(request) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, code} when code in @codes -> {:error, code}
      _ -> {:error, :internal}
    end
  rescue
    _ -> {:error, :internal}
  catch
    _, _ -> {:error, :internal}
  end

  @impl true
  def handle_info({:deadline, owner, token}, state) do
    case state.active[owner] do
      %{token: ^token, resolution: nil} = entry ->
        Process.exit(entry.worker, :kill)
        {:noreply, put_in(state.active[owner].resolution, :timeout)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.active, fn {_, e} -> e.worker_ref == ref and e.worker == pid end) do
      {owner, entry} -> finish(owner, entry, reason, state)
      nil -> receiver_down(ref, pid, state)
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp receiver_down(ref, pid, state) do
    case Enum.find(state.active, fn {_, e} -> e.receiver_ref == ref and e.receiver == pid end) do
      {owner, entry} ->
        Process.exit(entry.worker, :kill)
        {:noreply, put_in(state.active[owner].resolution, :cancelled)}

      nil ->
        {:noreply, state}
    end
  end

  defp finish(owner, entry, reason, state) do
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.receiver_ref, [:flush])
    outcome = outcome(entry, reason)
    send(entry.receiver, {:prospect_search_result, entry.id, outcome})
    observe(outcome)

    {:noreply,
     %{
       state
       | active: Map.delete(state.active, owner),
         cooldown:
           Map.put(state.cooldown, owner, System.monotonic_time(:millisecond) + Config.cooldown())
     }}
  end

  defp outcome(%{resolution: code}, _) when not is_nil(code), do: {:error, code}
  defp outcome(%{token: token}, {:shutdown, {:completed, token, outcome}}), do: outcome
  defp outcome(_, _), do: {:error, :internal}

  defp observe({:ok, result}) do
    :telemetry.execute(
      [:sdr_agent, :prospect_search, :completed],
      %{
        count: 1,
        result_count: length(Map.get(result, :candidates, [])),
        cost_dollars: Map.get(result, :cost_dollars)
      },
      %{outcome: :ok, kind: Map.get(result, :kind)}
    )
  end

  defp observe({:error, code}),
    do:
      :telemetry.execute([:sdr_agent, :prospect_search, :completed], %{count: 1}, %{outcome: code})
end
