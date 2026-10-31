defmodule SdrAgent.Agents.Checks.RemoteCallsScope do
  @moduledoc """
  Policy check for every action of the S-B2 remote-call resources
  (`SdrAgent.Operations.MacWorker` `:touch_last_seen` and reads,
  `SdrAgent.Agents.RemoteModelCall`, `ClaimNonce`, `RemoteCallResult`,
  `RemoteCallReceipt`): the domain-private RemoteCalls scope.

  It passes only when the request context carries the scope reference that
  `SdrAgent.Agents.RemoteCalls` bound to the CURRENT process, while that
  process is inside the transaction RemoteCalls opened for it
  (`SdrAgent.Agents.RemoteCalls.scoped?/1`). A context captured and reused
  after the scope closed, used from another process, or hand-built with a
  fresh reference never matches; there is no public grant. The actor's
  type (`:mac_worker` included) grants nothing by itself.

  The option `read: :settlement` (S-B3 plan r3 D1; only the
  `RemoteCallResult` `:transcript` field policy) passes only when, in
  addition, RemoteCalls registered its internal settlement marker against
  that same open scope (`SdrAgent.Agents.RemoteCalls.settlement?/1`): only
  inside the settler's locked settlement of one completed call. The plain
  open scope, any context key and any other process never pass it. Any
  other `:read` option never matches.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts) do
    case Keyword.get(opts, :read) do
      :settlement -> "the request carries the open RemoteCalls settlement scope of this process"
      _plain -> "the request carries the open RemoteCalls scope of this process"
    end
  end

  @impl true
  def match?(_actor, %{subject: %{context: context}}, opts) when is_map(context) do
    case Keyword.get(opts, :read) do
      nil -> SdrAgent.Agents.RemoteCalls.scoped?(context)
      :settlement -> SdrAgent.Agents.RemoteCalls.settlement?(context)
      _unknown -> false
    end
  end

  def match?(_actor, _authorizer, _opts), do: false
end
