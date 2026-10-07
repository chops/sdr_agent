defmodule SdrAgent.Test.Human do
  @moduledoc """
  Test-only stand-in for a signed-in operator until slice S5 adds `role` and
  `tenant_id` to `SdrAgent.Accounts.User`.

  Audit and Agents policies read `actor.role`, `actor.id` and
  `actor.tenant_id` from any map, so this struct exercises exactly the fields
  a real User will carry. S5 must re-run the policy suites with real Users.
  """
  defstruct [:id, :role, :tenant_id, display_name: "Test Human"]
end
