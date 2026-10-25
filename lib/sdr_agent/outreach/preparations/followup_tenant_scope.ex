defmodule SdrAgent.Outreach.Preparations.FollowupTenantScope do
  @moduledoc """
  The tenant scope of `Suppression :followup_matching` (D-206): the read is
  bound to the scheduler's own tenant (`tenant_id == actor.tenant_id`) when
  the actor is the follow-up scheduler with a canonical tenant
  (`SdrAgent.Outreach.Checks.FollowupSuppressionRead.scheduler_tenant/1`),
  and to nothing (`false`) otherwise.

  A preparation, not an `actor(:tenant_id)` action filter: that template
  fails an absent or malformed actor at `for_read` with an *invalid* query
  (`ReadActionRequiresActor`, `InvalidFilterValue`) before any policy runs,
  whereas the contract is a strict-policy refusal, `Ash.Error.Forbidden`.
  Here every caller keeps a valid query; the policy refuses the wrong ones,
  a scheduler of another tenant reads `[]`, and no caller reads another
  tenant's rows.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias SdrAgent.Outreach.Checks.FollowupSuppressionRead

  @impl true
  def prepare(query, _opts, %{actor: actor}) do
    case FollowupSuppressionRead.scheduler_tenant(actor) do
      {:ok, tenant_id} -> Ash.Query.filter(query, tenant_id == ^tenant_id)
      :error -> Ash.Query.filter(query, false)
    end
  end
end
