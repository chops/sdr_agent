defmodule SdrAgent.Agents.ResultGate do
  @moduledoc """
  The per-invocation result gate (R0-07 slice C; REQ-07-4; packet section
  2, "Commit and lock boundaries").

  `await/3` is step 2's wait: after a generation-2 ClaudeCLI call is
  validated and stored (step 1, committed), the gate reconciles **that**
  invocation in-process with `SdrAgent.Agents.Witness.reconcile/2` and its
  `gate:` option, as REC, polling until the outcome settles or the bound
  passes. It holds no lock and no transaction of its own while it waits:
  each reconcile commits its own short transaction, and `await/3` refuses
  to start inside an open transaction (`{:error, :in_transaction}`). An
  interrupted wait leaves nothing locked or half-written.

  The bound is `wait_ms/0` — 120 s, which configuration may only lower
  (`config :sdr_agent, SdrAgent.Agents.ResultGate, wait_ms:, poll_ms:`).

  Outcomes (the reconcile receipt `%{status, link_id, cause_id}`):

    * `{:ok, receipt}` once settled — reconciled, mismatch, an unconfigured
      or unreadable store, or any other final classification;
    * `{:timeout, receipt}` when the bound passes while the capture is
      still pending — no exchange yet, an open exchange or an incomplete
      capture;
    * `{:error, reason}` — e.g. `:invalid_gate`, `:in_transaction`.
  """

  alias SdrAgent.Actor
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Repo

  @max_wait_ms 120_000
  @default_poll_ms 1_000
  # Observation warnings that mean the capture may still arrive.
  @pending ["witness_missing", "no_primary_exchange", "exchange_open", "capture_incomplete"]

  @doc "The effective wait bound: `min(config, 120_000)` ms; invalid config is ignored."
  @spec wait_ms() :: pos_integer()
  def wait_ms do
    case Keyword.get(config(), :wait_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_wait_ms)
      _ -> @max_wait_ms
    end
  end

  defp poll_ms do
    case Keyword.get(config(), :poll_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_poll_ms
    end
  end

  defp config, do: Application.get_env(:sdr_agent, __MODULE__, [])

  @doc """
  Waits, bounded and holding no lock, for the gate reconcile of
  `invocation` under `gate` (`%{run_id, operation_id}`). `opts` are passed
  to `Witness.reconcile/2` (`store_root:`, test-only `methods:`).
  """
  @spec await(struct(), map(), keyword()) ::
          {:ok, map()} | {:timeout, map()} | {:error, term()}
  def await(invocation, gate, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :in_transaction}
    else
      actor = Actor.system(:reconciler, invocation.tenant_id)

      opts =
        opts |> Keyword.take([:store_root, :methods]) |> Keyword.merge(actor: actor, gate: gate)

      deadline = System.monotonic_time(:millisecond) + wait_ms()
      poll(invocation.id, opts, deadline)
    end
  end

  defp poll(invocation_id, opts, deadline) do
    case Witness.reconcile(invocation_id, opts) do
      {:ok, %{receipt: receipt} = result} ->
        cond do
          not pending?(result) -> {:ok, receipt}
          expired?(deadline) -> {:timeout, receipt}
          true -> again(invocation_id, opts, deadline)
        end

      # The store changed under the observation: observe again.
      {:error, :stale_observation} ->
        if expired?(deadline),
          do: {:timeout, %{status: :unwitnessed, link_id: nil, cause_id: nil}},
          else: again(invocation_id, opts, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp again(invocation_id, opts, deadline) do
    Process.sleep(min(poll_ms(), max(deadline - System.monotonic_time(:millisecond), 0)))
    poll(invocation_id, opts, deadline)
  end

  defp pending?(%{status: status, attention: attention}) when status in [:unwitnessed, :inferred],
    do: Enum.any?(attention, &(&1 in @pending))

  defp pending?(_result), do: false

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline
end
