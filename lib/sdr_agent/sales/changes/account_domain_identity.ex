defmodule SdrAgent.Sales.Changes.AccountDomainIdentity do
  @moduledoc """
  An Account's company identity under the shared identity keys (ADR-0009
  C3-02 amendment item 4; plan r8 sections 2.6, 2.7, 5.4 A.4; packet
  section 3 Account; D-174 Q-O1 = A).

  Key inputs, for `SdrAgent.Audit.Changes.IdentityKeyLock` (raw inputs;
  `IdentityKeys` strips a domain key once):

    * `entry_keys/1` (`:create`, `:seed`): `[{:domain, c}]`, the stored
      company form `c` that `NormalizeDomain` set;
    * `update_keys/1` (`:update`): `:none` when the domain does not change
      its key form (`strip(old) == c_new`, e.g. no domain input, or a
      legacy `www.` row restated canonically); otherwise
      `[{:domain, old}, {:domain, c_new}]`, where `old` is the stored domain
      of the changeset's data (the caller's struct, before the row lock), so
      its key is the row's `canonical_domain` as read by the caller.

  Both return `:none` for an actor without a tenant; `SetTenant` then
  refuses the create (its before_action) before anything is written.

  The change itself, on `:update` after `get_and_lock_for_update()`:

    * at build time, when the domain changes key form: the old indexed
      value `c_old = strip(old)` must be a valid company fixed point
      (`Domain.canonical(c_old) == {:ok, c_old}`; the section 2.7 runtime
      check, defensive after the migration pre-check), else a fixed refusal
      on `:domain` before any key;
    * in a before_action on the locked row: the locked domain must still
      have the keyed key form (`strip(locked) == strip(old)`), else the
      typed conflict on `:domain`; then A.4: a `domain` suppression of the
      tenant equal to `c_new` refuses the rename on `:domain`
      (`SdrAgent.Sales.SuppressionFacts.domain?/2`). Both refusals write
      nothing and append no event.

  Every refusal is a fixed `InvalidAttribute` with no value.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Audit.IdentityKeys.Normalize
  alias SdrAgent.Sales.Domain
  alias SdrAgent.Sales.SuppressionFacts

  @conflict "changed since it was read (conflict); reload and retry"
  @invalid_stored "is not a valid stored company domain"
  @suppressed "is suppressed"

  @impl true
  def change(changeset, _opts, _context) do
    case domain_change(changeset) do
      :none ->
        changeset

      {old, new} ->
        if valid_indexed?(old),
          do: Ash.Changeset.before_action(changeset, &locked_checks(&1, old, new)),
          else: refuse(changeset, @invalid_stored)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the domain re-check runs on the locked row"}

  @doc "Key inputs of `:create` and `:seed` (see the moduledoc)."
  @spec entry_keys(Ash.Changeset.t()) :: [{:domain, String.t()}] | :none
  def entry_keys(changeset) do
    domain = Ash.Changeset.get_attribute(changeset, :domain)

    if tenant?(changeset) and not is_nil(domain),
      do: [{:domain, to_string(domain)}],
      else: :none
  end

  @doc "Key inputs of `:update` (see the moduledoc)."
  @spec update_keys(Ash.Changeset.t()) :: [{:domain, String.t()}] | :none
  def update_keys(changeset) do
    case domain_change(changeset) do
      {old, new} -> if tenant?(changeset), do: [{:domain, old}, {:domain, new}], else: :none
      :none -> :none
    end
  end

  defp domain_change(changeset) do
    with true <- Ash.Changeset.changing_attribute?(changeset, :domain),
         new when not is_nil(new) <- Ash.Changeset.get_attribute(changeset, :domain),
         old when not is_nil(old) <- Map.get(changeset.data, :domain),
         {old, new} = {to_string(old), to_string(new)},
         false <- Normalize.strip(old) == new do
      {old, new}
    else
      _unchanged -> :none
    end
  end

  defp valid_indexed?(old) do
    indexed = Normalize.strip(old)
    Domain.canonical(indexed) == {:ok, indexed}
  end

  defp locked_checks(changeset, old, new) do
    locked = changeset.data |> Map.get(:domain) |> to_string()
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    cond do
      Normalize.strip(locked) != Normalize.strip(old) -> refuse(changeset, @conflict)
      SuppressionFacts.domain?(tenant_id, new) -> refuse(changeset, @suppressed)
      true -> changeset
    end
  end

  defp tenant?(changeset), do: is_binary(Ash.Changeset.get_attribute(changeset, :tenant_id))

  defp refuse(changeset, message),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :domain, message: message)
      )
end
