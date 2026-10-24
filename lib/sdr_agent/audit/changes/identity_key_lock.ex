defmodule SdrAgent.Audit.Changes.IdentityKeyLock do
  @moduledoc """
  Shared change (ADR-0009 C3 amendment items 2-4; plan r8 sections 2.6 and
  8.1): an identity-key writer's keys, as a prepended `before_action`, so
  they come before every other before_action and therefore before any
  domain row lock or append of the action.

  Options:

    * `mode` (required): `:entry` takes the application scope's pass
      (`SdrAgent.Audit.IdentityKeys.pass/2`); `:held` only requires keys an
      enclosing entry point already passed (`require_held/2`); `:none`
      takes and requires no key (used with `held_when`).
    * `held_when` (optional): a module whose `context?/1` is given the
      changeset's context map. When it returns true, the action runs inside
      an enclosing entry point that has already passed its keys (C3-02:
      the lead admission's `LeadAdmissionContext` marker, passed by the
      resource, so this Audit change names no higher-domain module): the
      keys are then only required held (`require_held/2`), whatever
      `mode` says, never acquired, and a missing or different pass fails
      closed (`MissingPass`, `LateAcquisition`); there is no fallback to
      entry mode. Otherwise `mode` applies.
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

  @modes [:entry, :held, :none]

  @impl true
  def init(opts) do
    with mode when mode in @modes <- Keyword.get(opts, :mode),
         true <- keys_option?(Keyword.get(opts, :keys)),
         true <- held_when_option?(Keyword.get(opts, :held_when)) do
      {:ok, opts}
    else
      _invalid ->
        {:error,
         "IdentityKeyLock needs mode: :entry | :held | :none, keys: {module, function} " <>
           "and an optional held_when: module"}
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
    case mode(changeset, opts) do
      :none -> changeset
      mode -> lock(changeset, mode, Keyword.fetch!(opts, :keys))
    end
  end

  defp lock(changeset, mode, keys_option) do
    case keys(changeset, keys_option) do
      :none ->
        changeset

      keys when is_list(keys) ->
        tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
        :ok = request(mode, tenant_id, keys)
        changeset
    end
  end

  defp mode(changeset, opts) do
    case Keyword.get(opts, :held_when) do
      nil ->
        Keyword.fetch!(opts, :mode)

      module ->
        if module.context?(changeset.context), do: :held, else: Keyword.fetch!(opts, :mode)
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

  defp held_when_option?(nil), do: true
  defp held_when_option?(module), do: is_atom(module)
end
