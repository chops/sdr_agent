defmodule SdrAgent.Outreach.Changes.SuppressionKey do
  @moduledoc """
  A Suppression's identity key (ADR-0009 C3-02 amendment; plan r8 sections
  2.6, 2.7 and 16.2; packet section 6 "Writers that take keys"): its value.

  `keys/1`, for `SdrAgent.Audit.Changes.IdentityKeyLock`, returns the raw
  key input `[{scope, value}]`: the normalised stored `value`
  (`NormalizeSuppression`: trimmed, lowercase), never pre-stripped, with
  the kind equal to the scope (`:email` or `:domain`; `IdentityKeys`
  strips a domain key once and trims and lowercases an email key). The
  key therefore serializes the suppression with every writer of the same
  email, email domain or company domain.

  `:manual`, `:seed` and `:from_classification` take it as their entry
  point's pass (`mode: :entry`); `:from_webhook` only requires it held by
  the webhook's pass (`mode: :held`, membership of the key, not a scope
  rule). A replay (the value exists) takes the key too, since the key
  precedes the upsert; an invalid changeset runs no before_action and so
  takes none. Returns `:none` when the changeset has no tenant, scope or
  value (nothing is written then).
  """

  @doc "Key inputs of a Suppression create (see the moduledoc)."
  @spec keys(Ash.Changeset.t()) :: [{:email | :domain, String.t()}] | :none
  def keys(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    scope = Ash.Changeset.get_attribute(changeset, :scope)
    value = Ash.Changeset.get_attribute(changeset, :value)

    if is_binary(tenant_id) and scope in [:email, :domain] and not is_nil(value),
      do: [{scope, to_string(value)}],
      else: :none
  end
end
