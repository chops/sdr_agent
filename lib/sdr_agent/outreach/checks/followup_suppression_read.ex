defmodule SdrAgent.Outreach.Checks.FollowupSuppressionRead do
  @moduledoc """
  Policy check: the follow-up scheduler (SCH) reads its tenant's covering
  suppressions through `Suppression :followup_matching`, and nothing else
  (D-206, plan r3 §3).

  True only for a `%SdrAgent.Actor{type: :scheduler}` whose `tenant_id` is
  canonical UUID text — `Ecto.UUID.cast/1` returns it unchanged; a raw
  16-byte binary or upper-case text casts to *different* text and is
  refused — running the `:followup_matching` read. Any other actor, a plain
  map, a tenantless or malformed scheduler, or any other action is false, so
  adding this check to the generic read policy admits the scheduler to that
  one action only.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Actor

  @action :followup_matching

  @impl true
  def describe(_opts),
    do: "actor is the follow-up scheduler with a canonical tenant, running #{@action}"

  @impl true
  def match?(actor, %{action: %{name: @action}}, _opts), do: scheduler_tenant(actor) != :error
  def match?(_actor, _context, _opts), do: false

  @doc """
  The canonical tenant id of a follow-up scheduler actor, `{:ok, tenant_id}`,
  or `:error` for anything else — the one rule this check and the
  `:followup_matching` tenant scope share.
  """
  @spec scheduler_tenant(term()) :: {:ok, Ecto.UUID.t()} | :error
  def scheduler_tenant(%Actor{type: :scheduler, tenant_id: tenant_id})
      when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, ^tenant_id} -> {:ok, tenant_id}
      _other -> :error
    end
  end

  def scheduler_tenant(_actor), do: :error
end
