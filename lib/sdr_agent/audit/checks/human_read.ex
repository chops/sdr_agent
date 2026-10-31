defmodule SdrAgent.Audit.Checks.HumanRead do
  @moduledoc """
  Lower-owned strict human metadata check. The compile-time authority
  implementation supplies fresh identity eligibility; this check does not
  grant reads or change resource-owned tenant/global row semantics.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the human retains fresh persisted metadata authority"

  @impl true
  def match?(actor, _authorizer, _opts), do: SdrAgent.Audit.HumanAuthority.human_read?(actor)
end
