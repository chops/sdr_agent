defmodule Mix.Tasks.Sdr.Prototype.Serve do
  @shortdoc "D-237 prototype serve process (queues, provider claude_cli, endpoint on 4120)"

  @moduledoc """
  `mix sdr.prototype.serve`: the D-237 serve process kind (interfaces r6
  IF-2 "Process kinds"): the full application tree, whose
  `SdrAgent.Prototype.BootCheck` child (after the Repo, before the model
  provider) fixes prototype runtime or fails the start; the Oban queues as
  configured (on); and the endpoint on port 4120.

    * `preflight/1` decides the start from the configured provider and the
      `lsof -nP -iTCP:4120 -sTCP:LISTEN` listing: the provider must already
      be `SdrAgent.AI.ModelProvider.ClaudeCLI` (this task never selects,
      switches or defaults one), and the port must be free. A busy port, or
      a listing that cannot be read, refuses: unknown is not free. The task
      never stops, signals or takes over another listener;
    * `overrides/0` is the endpoint configuration applied before the
      application starts (port 4120, serving); it never touches the queues
      or the provider.

  Bounded stage (D-237 S4, Codex 9086e6a8): `run/1` is not implemented yet
  and returns `{:error, :not_implemented}`.
  """
  use Mix.Task

  @port 4120
  @claude_cli SdrAgent.AI.ModelProvider.ClaudeCLI

  @doc """
  `:ok` when `provider:` is the ClaudeCLI provider and `listeners:` (a
  zero-arity function returning the `lsof -nP -iTCP:4120 -sTCP:LISTEN`
  listing, `""` when nothing listens, anything else when unreadable) shows
  the port free; otherwise `{:error, :provider_not_claude_cli | :port_busy |
  :port_unknown}`.
  """
  @spec preflight(keyword()) :: :ok | {:error, atom()}
  def preflight(opts) do
    listeners = Keyword.fetch!(opts, :listeners)

    if Keyword.get(opts, :provider) == @claude_cli,
      do: port(listeners.()),
      else: {:error, :provider_not_claude_cli}
  end

  @doc "The configuration applied before the application starts: the endpoint on 4120, serving."
  @spec overrides() :: keyword()
  def overrides, do: [{SdrAgentWeb.Endpoint, [http: [port: @port], server: true]}]

  @impl Mix.Task
  def run(_argv), do: red({:error, :not_implemented})

  defp port(""), do: :ok
  defp port(listing) when is_binary(listing), do: {:error, :port_busy}
  defp port(_unreadable), do: {:error, :port_unknown}

  # RED stub result for the not-yet-bounded start, typed dynamic() so
  # callers compile against it; nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
