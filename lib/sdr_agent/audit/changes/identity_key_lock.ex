defmodule SdrAgent.Audit.Changes.IdentityKeyLock do
  @moduledoc """
  Shared change (ADR-0009 C3 amendment items 2-4; plan r8 sections 2.6 and
  8.1): an identity-key writer's keys, as a prepended `before_action`, so
  they come before every other before_action and therefore before any
  domain row lock or append of the action.

  Options:

    * `mode` (required): `:entry` takes the application scope's pass
      (`SdrAgent.Audit.IdentityKeys.pass/2`); `:held` only requires keys an
      enclosing entry point already passed (`require_held/2`).
    * `keys` (required): `{module, function}` or `{module, function, args}`,
      called as `apply(module, function, [changeset | args])` inside the
      before_action; it returns the raw key inputs `[{kind, raw}]` (never
      stripped values or ids), or `:none` when the action changes no
      identity value and takes no key.

  The tenant is the changeset's `tenant_id` attribute (set by
  `SetTenant` on create, the stored value on update). An identity-key
  exception is raised, not converted, so the action fails closed and
  nothing of it is written. The change has no atomic form: an update that
  uses it is not atomic.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.IdentityKeys

  @modes [:entry, :held]

  @impl true
  def init(opts) do
    with mode when mode in @modes <- Keyword.get(opts, :mode),
         true <- keys_option?(Keyword.get(opts, :keys)) do
      {:ok, opts}
    else
      _invalid ->
        {:error, "IdentityKeyLock needs mode: :entry | :held and keys: {module, function}"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &lock(&1, opts), prepend?: true)
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "identity keys are taken in a before_action"}

  defp lock(changeset, opts) do
    case keys(changeset, Keyword.fetch!(opts, :keys)) do
      :none ->
        changeset

      keys when is_list(keys) ->
        tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
        :ok = request(Keyword.fetch!(opts, :mode), tenant_id, keys)
        changeset
    end
  end

  defp request(:entry, tenant_id, keys), do: IdentityKeys.pass(tenant_id, keys)
  defp request(:held, tenant_id, keys), do: IdentityKeys.require_held(tenant_id, keys)

  defp keys(changeset, {module, function}), do: apply(module, function, [changeset])
  defp keys(changeset, {module, function, args}), do: apply(module, function, [changeset | args])

  defp keys_option?({module, function}) when is_atom(module) and is_atom(function), do: true

  defp keys_option?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: true

  defp keys_option?(_other), do: false
end
