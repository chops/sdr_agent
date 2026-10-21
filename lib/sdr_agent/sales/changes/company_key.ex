defmodule SdrAgent.Sales.Changes.CompanyKey do
  @moduledoc """
  The company key of Lead `:seed` and `:reopen` (C3-02 G7; plan r8
  sections 2.6, 4.3, 4.4 and 17; ADR-0009 C3-02 amendment item 4): the
  application scope's one pass over the lead's account's company identity,
  before any domain row lock or append, and the locked re-check of that
  identity.

  Two before_actions:

    1. **Prepended** (so before every other before_action of the action):
       the target account's `canonical_domain` `c`, read unlocked by
       account id and tenant (`SdrAgent.Sales.CompanyLock.company/2`; on
       `:seed` the changeset's `account_id`, on `:reopen` the stored
       lead's); then `SdrAgent.Audit.IdentityKeys.pass(tenant, [{:domain, c}])`;
       the keyed account id and `c` are kept in the changeset context
       (`keyed/1`).
    2. **At its declaration position**: the account `FOR SHARE`
       (`CompanyLock.lock_company/2`) and the re-check: its locked
       `canonical_domain` must equal the keyed `c`. Declared after
       `LeadAccount` on `:seed` (whose own `FOR SHARE` it re-takes in the
       same mode) and before `get_and_lock_for_update()` on `:reopen`
       (account before lead).

  A company that cannot be read (C1, Codex G7 pre-rulings):

    * `:seed`: no pass; the existing `LeadAccount` refusal applies. If the
      action nevertheless reaches the re-check (`LeadAccount` did not
      refuse), the write is refused there, so no lead is ever seeded
      without its company key;
    * `:reopen`: refused at once, before any key.

  A failed re-check, a locked read that returns nothing, and an unreadable
  company on `:reopen` are one fixed refusal: `InvalidAttribute` on
  `:account_id` with no value (`refuse_changed/1`). No further key is
  requested. Identity-key exceptions and database errors are raised, never
  converted. An actor without a tenant takes no key here; `SetTenant`
  refuses it as before.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Audit.IdentityKeys
  alias SdrAgent.Sales.CompanyLock

  @changed "the account's company changed; retry"

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&pass/1, prepend?: true)
    |> Ash.Changeset.before_action(&recheck/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the company key is taken in a before_action"}

  @doc """
  The keyed `{account_id, company}` of this changeset's pass, `:missing`
  for a `:seed` whose company could not be read, or `nil` (no pass here).
  """
  @spec keyed(Ash.Changeset.t()) :: {String.t(), String.t()} | :missing | nil
  def keyed(changeset), do: Map.get(changeset.context, __MODULE__)

  @doc "The fixed company-changed refusal on `:account_id` (see the moduledoc)."
  @spec refuse_changed(Ash.Changeset.t()) :: Ash.Changeset.t()
  def refuse_changed(changeset),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :account_id, message: @changed)
      )

  defp pass(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    account_id = account_id(changeset)

    cond do
      not is_binary(tenant_id) ->
        changeset

      company = CompanyLock.company(tenant_id, account_id) ->
        :ok = IdentityKeys.pass(tenant_id, [{:domain, company}])
        Ash.Changeset.set_context(changeset, %{__MODULE__ => {account_id, company}})

      changeset.action_type == :create ->
        Ash.Changeset.set_context(changeset, %{__MODULE__ => :missing})

      true ->
        refuse_changed(changeset)
    end
  end

  defp recheck(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    case keyed(changeset) do
      {account_id, company} ->
        if CompanyLock.lock_company(tenant_id, account_id) == company,
          do: changeset,
          else: refuse_changed(changeset)

      :missing ->
        refuse_changed(changeset)

      nil ->
        # Only an actor without a tenant takes no pass (SetTenant refuses
        # it); any other unkeyed arrival fails closed.
        if is_binary(tenant_id), do: refuse_changed(changeset), else: changeset
    end
  end

  defp account_id(%{action_type: :create} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :account_id)

  defp account_id(changeset), do: Map.get(changeset.data, :account_id)
end
