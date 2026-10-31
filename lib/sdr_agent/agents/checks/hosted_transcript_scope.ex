defmodule SdrAgent.Agents.Checks.HostedTranscriptScope do
  @moduledoc """
  Explicit diagnostic-transcript read policy: the exact named-action query
  must carry RemoteTranscripts' registered process/transaction/actor/call
  scope and a fresh owner. A role, copied context or hand-built reference
  grants nothing. This is independent of internal settlement access.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the exact audited owner transcript-reader scope is open"

  @impl true
  def match?(actor, %{subject: subject}, _opts),
    do: SdrAgent.Agents.RemoteTranscripts.scoped?(actor, subject)

  def match?(_actor, _authorizer, _opts), do: false
end
