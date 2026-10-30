defmodule SdrAgent.MacAgent.Agent do
  @moduledoc """
  One-call-at-a-time outbound Mac worker orchestration (ADR-0024 S-B7).

  Claims are journaled before launch; no restart or rejected completion can
  replay a launching call. Uncertain result delivery is retried with identical
  IDs/content in memory only, bounded by the deadline; never a second model
  launch. The server owns admission,
  budget, attestation, deadline expiry and settlement.
  """

  alias SdrAgent.MacAgent.Client
  alias SdrAgent.MacAgent.Config
  alias SdrAgent.MacAgent.Journal
  alias SdrAgent.MacAgent.Launch

  @doc "Perform a heartbeat, one claim and at most one local CLI launch."
  def run_once(%Config{} = config, options \\ []) do
    with :ok <- Config.verify(config),
         :ok <- Journal.prepare(config.journal_dir),
         {:ok, client} <- Client.new(config, options),
         :ok <- Client.heartbeat(client),
         {:ok, nonce} <- Journal.next_nonce(config.journal_dir),
         {:ok, call} <- Client.claim(client, nonce) do
      dispatch(config, client, call, nonce)
    end
  end

  defp dispatch(config, _client, nil, nonce) do
    with :ok <- Journal.close_nonce(config.journal_dir, nonce), do: {:ok, :idle}
  end

  defp dispatch(config, client, call, nonce) do
    with {:ok, _} <- Launch.argv(call),
         true <- call["profile_id"] == config.pins["profile_id"],
         true <- call["model_id"] == config.pins["model_id"],
         :ok <- Journal.launch_once(config.journal_dir, call["call_id"], nonce),
         {:ok, transcript} <-
           Launch.run(config, call, heartbeat: fn -> Client.heartbeat(client, :inflight) end),
         {:ok, status} <- Client.deliver(client, call, nonce, transcript) do
      finish(config, call, nonce, status)
    else
      false -> retire_invalid(config, nonce)
      {:error, :invalid_call} -> retire_invalid(config, nonce)
      error -> error
    end
  end

  defp retire_invalid(config, nonce) do
    with :ok <- Journal.close_nonce(config.journal_dir, nonce), do: {:error, :invalid_call}
  end

  defp finish(config, call, nonce, status) when status in [:accepted, :duplicate_same] do
    with :ok <- Journal.reported(config.journal_dir, call["call_id"], nonce),
         do: {:ok, :completed}
  end

  defp finish(_, _, _, :late), do: {:error, :late_result}
  defp finish(_, _, _, :conflict), do: {:error, :result_conflict}
end
