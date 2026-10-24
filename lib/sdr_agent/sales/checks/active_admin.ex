defmodule SdrAgent.Sales.Checks.ActiveAdmin do
  @moduledoc """
  Policy check for the lead admission's marked writes (C3-02 G5; plan r8
  section 15 item 3): the actor is an active human admin, an
  `SdrAgent.Accounts.User` whose `role` is `:admin` and whose `status` is
  `:active`. Used only by Lead `:create` and `LeadAdmission :record`, after
  `SdrAgent.Sales.Checks.LeadAdmissionContext`; the shared
  `SdrAgent.Audit.Checks.ActorRole` (role only) is unchanged. It reads the
  actor struct it is given; the admission re-reads its requester under its
  existing `FOR SHARE` lock and passes that row (no new lock here).
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Accounts.User

  @impl true
  def describe(_opts), do: "actor is an active human admin"

  @impl true
  def match?(%User{role: :admin, status: :active}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
