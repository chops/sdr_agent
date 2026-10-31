defmodule SdrAgent.Agents.RemoteSettler do
  @moduledoc """
  Oban cron worker (queue `default`, every minute; S-B3, entity/plan r1 +
  r2): one settlement pass over the singleton tenant's remote ClaudeCLI
  calls, `SdrAgent.Agents.RemoteCalls.settle_due/1`, as that tenant's
  kernel actor with the `:remote_settler` KernelMarker context
  (`SdrAgent.Prototype.Checks.KernelMarker`).

  The pass expires unclaimed calls at their claim deadline, expires claimed
  calls at their result deadline, and settles completed calls whose
  invocation is still `sent` from their stored transcript, in bounded
  batches; it is idempotent (a settled call is never selected again) and
  takes only the locks `RemoteCalls` documents (never the worker's). It
  decides no result release and re-sends nothing.

  In a build without the prototype authority (`:prototype_authority_compiled`
  unset, the production build) the marker does not exist and the pass
  returns `:ok` without settling. A tenant that is not bootstrapped is
  `:ok`; an error of the pass is returned through the worker error boundary
  (`SdrAgent.Workers.ErrorBoundary`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1
  use SdrAgent.Workers.ErrorBoundary

  alias SdrAgent.Audit.Kernel

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl Oban.Worker
  def perform(_job) do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> settle(tenant_id)
      {:error, _not_bootstrapped} -> :ok
    end
  end

  if @compiled do
    # Aliased inside the compiled branch only (no unused alias in the
    # production build under --warnings-as-errors).
    alias SdrAgent.Actor
    alias SdrAgent.Agents.RemoteCalls
    alias SdrAgent.Prototype.Checks.KernelMarker

    defp settle(tenant_id) do
      opts = [
        actor: Actor.system(:kernel, tenant_id),
        context: KernelMarker.context(:remote_settler)
      ]

      case RemoteCalls.settle_due(opts) do
        {:ok, _counts} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  else
    defp settle(_tenant_id), do: :ok
  end
end
