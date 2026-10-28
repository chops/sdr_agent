defmodule Mix.Tasks.Sdr.Prototype.Serve do
  @shortdoc "D-237 prototype serve process (queues, provider claude_cli, endpoint on 4120)"

  @moduledoc """
  `mix sdr.prototype.serve`: the D-237 serve process kind (interfaces r6
  IF-2 "Process kinds"): the full application tree with the
  `SdrAgent.Prototype.BootCheck` child, Oban queues on, the model provider
  `claude_cli`, and the endpoint on port 4120 only if `lsof` shows that port
  free. It never stops or signals another listener.

    * `preflight/1` decides the port check from the listener listing;
    * `overrides/0` is the configuration it applies before the start.

  RED stage (D-237 S4): the contract surface only.
  """
  use Mix.Task

  @doc "`:ok` when no listener holds port 4120, else `{:error, :port_busy}`."
  @spec preflight(keyword()) :: :ok | {:error, atom()}
  def preflight(_opts), do: red({:error, :not_implemented})

  @doc "The configuration applied before the application starts."
  @spec overrides() :: keyword() | {:error, atom()}
  def overrides, do: red({:error, :not_implemented})

  @impl Mix.Task
  def run(_argv), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so callers compile against the stub
  # (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
