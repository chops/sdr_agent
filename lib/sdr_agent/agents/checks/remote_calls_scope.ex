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
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the request carries the open RemoteCalls scope of this process"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts) when is_map(context),
    do: SdrAgent.Agents.RemoteCalls.scoped?(context)

  def match?(_actor, _authorizer, _opts), do: false
end
