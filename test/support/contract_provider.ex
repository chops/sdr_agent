defmodule SdrAgent.AI.ContractProvider do
  @moduledoc """
  R0-04 test-only, in-process model provider. It is synthetic, uses Fake's
  `:fake` provenance, and does no I/O and no model call. Each test chooses
  the replies through `provider_options`:

    * `:prepare` — the `prepare/2` return (default: Fake's provenance);
    * `:reply` — the `complete/2` return, or a 0-arity function returning
      it (so a test can raise, exit or act between send and settlement);
    * `:notify` — a pid sent `{:contract_provider, :prepare | :complete}`
      on every callback, so a test can count calls (no automatic retry).

  It proves the callback and facade seam within the closed ledger classes,
  not a new real provider (`docs/product/r0/r0-04-seam.md`, R0-04-4).
  """
  @behaviour SdrAgent.AI.ModelProvider

  alias SdrAgent.AI.ModelProvider.Fake

  @impl true
  def prepare(request, opts) do
    notify(opts, :prepare)

    case Keyword.fetch(opts, :prepare) do
      {:ok, reply} -> reply
      :error -> Fake.prepare(request, opts)
    end
  end

  @impl true
  def complete(_request, opts) do
    notify(opts, :complete)

    case Keyword.fetch!(opts, :reply) do
      reply when is_function(reply, 0) -> reply.()
      reply -> reply
    end
  end

  defp notify(opts, callback) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, {:contract_provider, callback})
      _ -> :ok
    end
  end
end
