defmodule SdrAgent.Audit.HumanAuthority.Unavailable do
  @moduledoc """
  Fail-closed default for a prototype build lacking its configured human
  authority implementation. It grants neither legacy roles nor User writes.
  """
  @behaviour SdrAgent.Audit.HumanAuthority

  @impl true
  def role_allowed?(_actor), do: false

  @impl true
  def valid_write_scope?(_actor, _subject), do: false

  @impl true
  def human_read?(_actor), do: false

  @impl true
  def hosted_owner?(_actor), do: false
end
