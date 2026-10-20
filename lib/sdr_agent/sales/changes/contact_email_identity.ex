defmodule SdrAgent.Sales.Changes.ContactEmailIdentity do
  @moduledoc """
  A Contact's person identity under the shared identity keys (ADR-0009
  C3-02 amendment item 4; plan r8 sections 2.6 and 5.4 OQ6; packet section 3
  Contact; D-174 Q-O2 = refuse, OQ6 (ii)).

  Key inputs, for `SdrAgent.Audit.Changes.IdentityKeyLock` (raw inputs;
  `IdentityKeys` trims and lowercases an email key):

    * `entry_keys/1` (`:create`, `:seed`): `[{:email, new}]`;
    * `change_email_keys/1` (`:change_email`): `[{:email, old}, {:email,
      new}, {:domain, host}]`, where `old` is the email of the changeset's
      data (the caller's struct, before the row lock) and `host` the domain
      part of the normalised new address (the email-domain key a domain
      suppression of that host takes).

  Both return `:none` for an actor without a tenant; `SetTenant` (create)
  or the policies refuse such a write before anything is written.

  The change itself, on `:change_email` after `get_and_lock_for_update()`,
  is a before_action on the locked row: the locked email must still be the
  keyed old address (trimmed, lowercase), else the typed conflict on
  `:email`; then OQ6 (ii): when the new address or its domain is suppressed
  in the tenant (`SdrAgent.Sales.SuppressionFacts.address?/2`, the
  `SuppressionMatch` rule), the change is refused on `:email`. Both
  refusals write nothing and append no event, and are fixed
  `InvalidAttribute`s with no value.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Sales.SuppressionFacts

  @conflict "changed since it was read (conflict); reload and retry"
  @suppressed "is suppressed"

  @impl true
  def change(changeset, _opts, _context) do
    case emails(changeset) do
      {old, new} -> Ash.Changeset.before_action(changeset, &locked_checks(&1, old, new))
      :none -> changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the email re-check runs on the locked row"}

  @doc "Key inputs of `:create` and `:seed` (see the moduledoc)."
  @spec entry_keys(Ash.Changeset.t()) :: [{:email, String.t()}] | :none
  def entry_keys(changeset) do
    email = Ash.Changeset.get_attribute(changeset, :email)

    if tenant?(changeset) and not is_nil(email),
      do: [{:email, to_string(email)}],
      else: :none
  end

  @doc "Key inputs of `:change_email` (see the moduledoc)."
  @spec change_email_keys(Ash.Changeset.t()) :: [{:email | :domain, String.t()}] | :none
  def change_email_keys(changeset) do
    case emails(changeset) do
      {old, new} ->
        if tenant?(changeset),
          do: [{:email, old}, {:email, new}, {:domain, host(new)}],
          else: :none

      :none ->
        :none
    end
  end

  defp emails(changeset) do
    with new when not is_nil(new) <- Ash.Changeset.get_attribute(changeset, :email),
         old when not is_nil(old) <- Map.get(changeset.data, :email) do
      {to_string(old), to_string(new)}
    else
      _absent -> :none
    end
  end

  defp locked_checks(changeset, old, new) do
    locked = changeset.data |> Map.get(:email) |> to_string()
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    cond do
      normalize(locked) != normalize(old) -> refuse(changeset, @conflict)
      SuppressionFacts.address?(tenant_id, new) -> refuse(changeset, @suppressed)
      true -> changeset
    end
  end

  defp host(email), do: email |> normalize() |> String.split("@") |> List.last()

  defp normalize(email), do: email |> String.trim() |> String.downcase()

  defp tenant?(changeset), do: is_binary(Ash.Changeset.get_attribute(changeset, :tenant_id))

  defp refuse(changeset, message),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :email, message: message)
      )
end
