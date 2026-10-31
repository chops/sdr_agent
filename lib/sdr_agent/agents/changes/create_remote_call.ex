defmodule SdrAgent.Agents.Changes.CreateRemoteCall do
  @moduledoc """
  `ModelInvocation :reserve` (S-B2; plan P1): the only creator of a pending
  `SdrAgent.Agents.RemoteModelCall`, and the owner of the reservation scope
  that authorizes `RemoteModelCall :create`
  (`SdrAgent.Agents.Checks.RemoteReservationScope`).

  `SdrAgent.Agents` runs each `:reserve` create inside
  `with_reservation/1`, which binds a fresh reservation reference to the
  calling process with no invocation recorded yet. This change's
  `after_action`, which runs inside the reservation's own transaction:

    1. re-reads the trusted transport (`SdrAgent.Agents.RemoteCalls.remote?/0`:
       Application config, never caller input; default local) and requires a
       real-profile ClaudeCLI invocation; otherwise it creates nothing;
    2. requires the bound reservation scope, inside a transaction and with
       no invocation recorded yet, and fails closed without it;
    3. records the id of the invocation that this `:reserve` changeset just
       created into that scope (privately; there is no public recorder);
    4. creates the RemoteModelCall for that invocation with the
       reservation reference in its context (`claim_deadline` =
       `reserved_at + 120 s`).

  `reserved?/2` passes only for that reference, on the bound process,
  inside a transaction, under the `:remote` transport, and for the
  recorded invocation id. A direct `RemoteModelCall :create` outside a
  reservation, or for another invocation, is therefore Forbidden. Both rows
  commit or roll back together.
  """
  use Ash.Resource.Change

  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Agents.RemoteCalls
  alias SdrAgent.Agents.RemoteModelCall
  alias SdrAgent.Repo

  @key :sdr_agent_remote_reservation_scope
  @claim_window 120

  @doc """
  Runs `fun.()` with a fresh reservation scope bound to the calling process
  and restores the previous binding afterwards. It grants nothing by
  itself: only this change's `after_action` on a `:reserve` create records
  the invocation that the scope may create a RemoteModelCall for.
  """
  @spec with_reservation((-> result)) :: result when result: term()
  def with_reservation(fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, %{ref: make_ref(), invocation_id: nil})

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc """
  Whether `context` carries this process's bound reservation reference,
  inside a transaction, under the `:remote` transport, with `invocation_id`
  being the invocation recorded by this reservation's `:reserve`.
  """
  @spec reserved?(term(), term()) :: boolean()
  def reserved?(context, invocation_id) when is_map(context) and is_binary(invocation_id) do
    case Process.get(@key) do
      %{ref: ref, invocation_id: ^invocation_id} when is_reference(ref) ->
        Map.get(context, @key) == ref and Repo.in_transaction?() and RemoteCalls.remote?()

      _other ->
        false
    end
  end

  def reserved?(_context, _invocation_id), do: false

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, invocation ->
      if remote_call?(invocation),
        do: create_for(invocation, context.actor),
        else: {:ok, invocation}
    end)
  end

  defp create_for(invocation, actor) do
    with {:ok, ref} <- record(invocation),
         {:ok, _call} <- create(invocation, ref, actor),
         do: {:ok, invocation}
  end

  defp remote_call?(invocation) do
    invocation.provider == :claude_cli and ModelProfiles.real?(invocation.profile_id) and
      RemoteCalls.remote?()
  end

  defp record(invocation) do
    case Process.get(@key) do
      %{ref: ref, invocation_id: nil} = scope when is_reference(ref) ->
        if Repo.in_transaction?() do
          Process.put(@key, %{scope | invocation_id: invocation.id})
          {:ok, ref}
        else
          {:error, "remote call outside the reservation transaction"}
        end

      _other ->
        {:error, "remote call outside a reservation scope"}
    end
  end

  defp create(invocation, ref, actor) do
    RemoteModelCall
    |> Ash.Changeset.for_create(
      :create,
      %{
        model_invocation_id: invocation.id,
        request_sha256: invocation.request_sha256,
        profile_id: invocation.profile_id,
        model_id: invocation.model_id,
        claim_deadline: DateTime.add(invocation.reserved_at, @claim_window, :second)
      },
      actor: actor,
      context: %{@key => ref}
    )
    |> Ash.create()
  end
end
