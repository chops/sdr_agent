defmodule SdrAgent.Sales.Changes.AccountDomainIdentity do
  @moduledoc """
  An Account's company identity under the shared identity keys (ADR-0009
  C3-02 amendment item 4; plan r8 sections 2.6, 2.7, 5.4 A.4; packet
  section 3 Account; D-174 Q-O1 = A).

  Key inputs, for `SdrAgent.Audit.Changes.IdentityKeyLock` (raw inputs;
  `IdentityKeys` strips a domain key once):

    * `entry_keys/1` (`:create`, `:seed`): `[{:domain, c}]`, the stored
      company form `c` that `NormalizeDomain` set;
    * `update_keys/1` (`:update`), for every pending domain write (G2-1,
      Codex 1b78e40: never inferred from the caller's old key alone), where
      `old` is the stored domain of the changeset's data (the caller's
      struct, before the row lock) and `c_new` the normalized new value:
      * a rename (`strip(old) != c_new`): `[{:domain, old}, {:domain, c_new}]`;
      * a restatement (`strip(old) == c_new`, e.g. a legacy `www.` row
        restated canonically): `[{:domain, c_new}]`, the one identity it
        restates;
      * `:none` when no domain write is pending (the ordinary edit path,
        and an input equal to the stored domain, which Ash drops as no
        change).

  Both return `:none` for an actor without a tenant; `SetTenant` then
  refuses the create (its before_action) before anything is written.

  The change itself, on `:update` after `get_and_lock_for_update()`, for
  every pending domain write:

    * at build time: the old indexed value `c_old = strip(old)` must be a
      valid company fixed point (`Domain.canonical(c_old) == {:ok, c_old}`;
      the section 2.7 runtime check, defensive after the migration
      pre-check), else a fixed refusal on `:domain` before any key; a
      pending write over an absent old value cannot be verified and is
      refused (typed conflict); a write of `nil` cannot change the row
      (`allow_nil? false`, NOT NULL) and is left to those refusals;
    * in a before_action on the locked row: the locked domain must still
      have the keyed key form (`strip(locked) == strip(old)`), else the
      typed conflict on `:domain`. So a write from a stale struct can never
      change the locked row's company identity, a restatement included.
    * A.4, for a rename only: a `domain` suppression of the tenant equal to
      `c_new` refuses it on `:domain`
      (`SdrAgent.Sales.SuppressionFacts.domain?/2`). A restatement that
      passed the locked check keeps the locked row's company identity and
      changes only its stored form, so it is not an A.4 rename and a
      suppression of that identity does not refuse it.

  Every refusal writes nothing, appends no event and is a fixed
  `InvalidAttribute` with no value.
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

      :unverifiable ->
        refuse(changeset, @conflict)

      {kind, old, new} ->
        if valid_indexed?(old),
          do: Ash.Changeset.before_action(changeset, &locked_checks(&1, kind, old, new)),
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
    case {tenant?(changeset), domain_change(changeset)} do
      {true, {:rename, old, new}} -> [{:domain, old}, {:domain, new}]
      {true, {:restate, _old, new}} -> [{:domain, new}]
      _no_key -> :none
    end
  end

  # Every pending domain write is a rename or a restatement of the caller's
  # key form; neither is ever treated as no write.
  defp domain_change(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :domain),
      do:
        pending(
          Map.get(changeset.data, :domain),
          Ash.Changeset.get_attribute(changeset, :domain)
        ),
      else: :none
  end

  # A nil write cannot change the row (`allow_nil? false` and the column's
  # NOT NULL refuse it as before); a write over an absent old value cannot
  # be verified and is refused.
  defp pending(_old, nil), do: :none

  defp pending(old, new) do
    if value?(old) do
      {old, new} = {to_string(old), to_string(new)}
      if Normalize.strip(old) == new, do: {:restate, old, new}, else: {:rename, old, new}
    else
      :unverifiable
    end
  end

  defp value?(value), do: is_binary(value) or is_struct(value, Ash.CiString)

  defp valid_indexed?(old) do
    indexed = Normalize.strip(old)
    Domain.canonical(indexed) == {:ok, indexed}
  end

  defp locked_checks(changeset, kind, old, new) do
    locked = changeset.data |> Map.get(:domain) |> to_string()
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    cond do
      Normalize.strip(locked) != Normalize.strip(old) ->
        refuse(changeset, @conflict)

      kind == :rename and SuppressionFacts.domain?(tenant_id, new) ->
        refuse(changeset, @suppressed)

      true ->
        changeset
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
