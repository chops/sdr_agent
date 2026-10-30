# Compiled only with the D-237 prototype authority; absent in production.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
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

    Mix loads app.config through the requirement before SafeLog attaches and
    the terminal launch (ADR-0022). The body starts only OpenTelemetry,
    accepts no argument, checks the real serve guard, then the preflight,
    and only then applies the overrides and starts the application tree.
    It then serves until the operator stops the VM. Every refusal (an
    argument, the guard, the provider or the port) is returned tagged to
    TaskBoundary, which prints its one fixed abort line; no other line is
    printed here.
    """
    use Mix.Task

    alias SdrAgent.ChildEnv
    alias SdrAgent.Prototype.ContainmentGuard
    alias SdrAgent.Prototype.SafeLog
    alias SdrAgent.Prototype.TaskBoundary

    @requirements ["app.config"]

    @port 4120
    @claude_cli SdrAgent.AI.ModelProvider.ClaudeCLI
    @lsof "/usr/sbin/lsof"

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
    def run(argv) do
      attached = SafeLog.attach(file: nil)
      TaskBoundary.launch(:serve, attached, fn -> body(argv) end)
    end

    defp body(argv) do
      {:ok, _started} = Application.ensure_all_started(:opentelemetry)

      with [] <- argv,
           {:guard, :ok} <- {:guard, ContainmentGuard.guard(:serve)},
           :ok <-
             preflight(
               provider: Application.get_env(:sdr_agent, :model_provider),
               listeners: &listeners/0
             ) do
        Enum.each(overrides(), &override/1)
        Mix.Task.run("app.start")
        serve()
      else
        {:guard, _result} = guard_refusal -> guard_refusal
        {:error, code} -> {:serve, code}
        _argv -> {:serve, :invalid_arguments}
      end
    end

    # Merges one override into the loaded configuration; the endpoint's
    # :http list is merged key by key so its other keys are kept.
    defp override({module, opts}) do
      current = Application.get_env(:sdr_agent, module, [])
      http = Keyword.merge(Keyword.get(current, :http, []), Keyword.fetch!(opts, :http))
      merged = current |> Keyword.merge(opts) |> Keyword.put(:http, http)
      :ok = Application.put_env(:sdr_agent, module, merged)
    end

    # lsof's no-match result is exit 1 with no output; a listing is exit 0.
    # Any other result is an unreadable listing.
    defp listeners do
      case System.cmd(@lsof, ["-nP", "-iTCP:4120", "-sTCP:LISTEN"],
             env: ChildEnv.cmd([]),
             stderr_to_stdout: true
           ) do
        {"", 1} -> ""
        {listing, 0} when listing != "" -> listing
        _unreadable -> :unreadable
      end
    catch
      _kind, _reason -> :unreadable
    end

    # The application runs under its own supervisors; this body only waits.
    defp serve do
      receive do
        :never -> :ok
      end
    end

    defp port(""), do: :ok
    defp port(listing) when is_binary(listing), do: {:error, :port_busy}
    defp port(_unreadable), do: {:error, :port_unknown}
  end
end
