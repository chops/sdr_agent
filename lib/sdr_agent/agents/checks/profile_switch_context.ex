defmodule SdrAgent.Agents.Checks.ProfileSwitchContext do
  @moduledoc """
  Phase-bound authorization of the internal model profile setting and
  switch actions (C2-02a, `docs/product/r0/c2-02a-interface.md`, "The
  internal setting write path").

  A phase is opened only by the domain's own orchestration,
  `SdrAgent.Agents.ProfileSwitches`, with a private function: no exported
  function opens one (a test build alone adds a test seam). It registers a
  binding (phase, action, tenant, switch, generation, actor) under a fresh
  reference in the calling process and hands the action a context carrying
  only that reference. A caller-supplied context map can't name a binding,
  so a forged marker (any phase, action, tenant or switch) is refused before
  any lock or write.

  Phases:

    * `:initialize` — `request`, after the current-admin check: the
      setting's `:initialize` upsert and the switch's `:request` create,
      for the actor's tenant;
    * `:transition` — `complete`, `fail` or `block`, actor
      `model_runtime`: the `:lock_for_transition` reads (setting, then
      switch) for one switch, and the switch's `:fail` or `:block` write;
    * `:apply` — `complete` only, entered from `:transition`: the setting's
      `:apply_switch` and the switch's `:complete` write.

  This check binds only the phase, the actor and the target. The writes'
  own guard (`SdrAgent.Agents.Changes.ProfileSwitchGuard`) re-locks and
  re-checks the stored rows, so the phase is never the only proof.

  Policy options: `phase:` (required), `action:` (the orchestrating
  action, default any of the phase's) and `target:` — `:switch_id`
  (the `switch_id` argument), `:subject` (the switch row being updated) or
  `:tenant` (the created row's `tenant_id`).
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Agents.Checks.CurrentAdmin
  alias SdrAgent.Agents.ProfileSwitches

  @impl true
  def describe(opts),
    do: "inside the #{inspect(opts[:phase])} phase of a model profile switch action"

  @impl true
  def match?(actor, %{subject: %{context: context} = subject}, opts) do
    case ProfileSwitches.phase(context) do
      {:ok, binding} ->
        binding.phase == Keyword.fetch!(opts, :phase) and
          action?(binding, opts[:action]) and
          actor?(binding, actor) and
          target?(binding, subject, Keyword.fetch!(opts, :target))

      :error ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp action?(_binding, nil), do: true
  defp action?(binding, actions), do: binding.action in List.wrap(actions)

  # The actor must be the binding's own actor, of the phase's kind: a
  # current human admin of the tenant for `:initialize`, `model_runtime`
  # of the tenant for `:transition` and `:apply`.
  defp actor?(%{phase: :initialize, actor: bound, tenant_id: tenant_id}, actor) do
    match?(%SdrAgent.Accounts.User{}, actor) and actor.id == bound.id and
      actor.tenant_id == tenant_id and CurrentAdmin.match?(actor, %{}, [])
  end

  defp actor?(%{actor: bound, tenant_id: tenant_id}, actor) do
    match?(%SdrAgent.Actor{type: :model_runtime}, actor) and actor == bound and
      is_binary(tenant_id) and actor.tenant_id == tenant_id
  end

  defp target?(binding, subject, :switch_id),
    do: is_binary(binding.switch_id) and argument(subject, :switch_id) == binding.switch_id

  defp target?(binding, %Ash.Changeset{data: %{id: id}}, :subject),
    do: is_binary(binding.switch_id) and id == binding.switch_id

  defp target?(binding, %Ash.Changeset{} = changeset, :tenant),
    do: Ash.Changeset.get_attribute(changeset, :tenant_id) == binding.tenant_id

  defp target?(_binding, _subject, _target), do: false

  defp argument(%{arguments: arguments}, name) when is_map(arguments),
    do: Map.get(arguments, name)

  defp argument(_subject, _name), do: nil
end
