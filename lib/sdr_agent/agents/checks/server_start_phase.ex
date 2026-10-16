defmodule SdrAgent.Agents.Checks.ServerStartPhase do
  @moduledoc """
  Phase-bound authorization of the model server start ledger writes
  (C2-02b2α, `docs/product/r0/c2-02b2-interface.md` section 1a; Codex
  review MF3 at `bce5653`), as `SdrAgent.Agents.Checks.ProfileSwitchContext`
  does for slice a.

  A phase is opened only by `SdrAgent.Agents.ServerStarts`, with a private
  function, inside the registered coordinator, after the boot fence and the
  per-action prerequisites. It registers a binding (the resource action,
  tenant, actor and, for a transition, the start) under a fresh reference
  in the calling process and hands the action a context carrying only that
  reference. So a direct Ash action, even in the coordinator, names no
  binding and is refused: it can't allocate past the counter, bump the
  counter or rewrite a start's observed identity.

  Policy option: `action:` (the resource action, or a list of them).
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Agents.ServerStarts

  @impl true
  def describe(opts), do: "inside a #{inspect(opts[:action])} phase of the server start ledger"

  @impl true
  def match?(actor, %{subject: %{context: context} = subject}, opts) do
    case ServerStarts.phase(context) do
      {:ok, binding} ->
        binding.action in List.wrap(Keyword.fetch!(opts, :action)) and
          actor == binding.actor and
          target?(binding, subject)

      :error ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp target?(%{start_id: start_id}, %Ash.Changeset{action_type: :update, data: %{id: id}})
       when is_binary(start_id),
       do: id == start_id

  defp target?(%{tenant_id: tenant_id}, %Ash.Changeset{data: %{tenant_id: tenant}})
       when is_binary(tenant),
       do: tenant == tenant_id

  defp target?(%{tenant_id: tenant_id}, %Ash.Changeset{action_type: :create} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :tenant_id) in [nil, tenant_id]

  defp target?(_binding, _subject), do: false
end
