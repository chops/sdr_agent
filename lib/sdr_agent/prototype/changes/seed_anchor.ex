defmodule SdrAgent.Prototype.Changes.SeedAnchor do
  @moduledoc """
  The creator of the D-237 seed revision (`SdrAgent.Agents.SettingsRevision
  :seed_prototype`; supplement 1 r2 §4, Codex R7, 969bf261).
  `SettingsRevision.created_by_id` is a NOT NULL User foreign key, and the
  acting operator is a delegation, never a User, so the anchor User is used
  as that foreign key value only. The event actor stays the delegation.

  In a `before_action`, after authorization and inside the action's
  transaction, it requires ALL of:

  - the acting operator still resolves live: `SdrAgent.Prototype.check_live/0`
    and `SdrAgent.Prototype.operator_actor/1` returning exactly that actor;
  - the new row's tenant (set by `SetTenant` from that actor) is the live
    binding's tenant;
  - the binding's `operator_user_id` is one User row, read through the
    kernel filtered by id AND that tenant AND role `:agent_operator`.

  Only then is `created_by_id` set to it. A failed live check or no such
  anchor row adds a value-free error on `created_by_id`; a returned error of
  the anchor read is not treated as absence: it is added as itself, so the
  action fails with that error and writes nothing. A creator is never taken from the caller (the
  action does not accept one). In a build without the prototype authority
  every seed revision is refused the same way.
  """
  use Ash.Resource.Change

  @message "is not the live binding's agent_operator anchor"

  @impl true
  def change(changeset, _opts, context),
    do: Ash.Changeset.before_action(changeset, &anchor(&1, Map.get(context, :actor)))

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    require Ash.Query

    alias SdrAgent.Accounts.User
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Prototype

    defp anchor(changeset, %SdrAgent.Actor{type: :prototype_operator, id: id} = actor)
         when is_binary(id) do
      tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

      case live_wrap(fn -> live_anchor(actor, id, tenant_id) end) do
        {:ok, user_id} -> bind_anchor(changeset, user_id, tenant_id)
        :not_live -> refuse(changeset)
      end
    end

    defp anchor(changeset, _actor), do: refuse(changeset)

    # The live check, unchanged: the operator still resolves live to exactly
    # this actor, and the binding's tenant is the row's; then its anchor id.
    defp live_anchor(actor, id, tenant_id) do
      with :ok <- Prototype.check_live(),
           {:ok, ^actor} <- Prototype.operator_actor(id),
           {:ok, %{tenant_id: ^tenant_id, operator_user_id: user_id}} when is_binary(tenant_id) <-
             Prototype.binding() do
        {:ok, user_id}
      else
        _not_live -> :not_live
      end
    end

    # The in-action live-check site (Codex d8fc857a): declared, not yet
    # instrumented. Every build runs the real check exactly once, here; a
    # test-build `{__MODULE__, :live_wrap}` is not consulted until its own
    # reviewed GREEN.
    defp live_wrap(inner), do: inner.()

    defp bind_anchor(changeset, user_id, tenant_id) do
      case anchor_user(user_id, tenant_id) do
        {:ok, %User{id: ^user_id}} ->
          Ash.Changeset.force_change_attribute(changeset, :created_by_id, user_id)

        # No such anchor row (missing, wrong role or tenant): the business
        # refusal.
        {:ok, _none} ->
          refuse(changeset)

        # A returned read error is not evidence that the anchor is absent
        # (Codex 3ad0a105): it keeps its own identity, through Ash's own
        # error path, and nothing is written.
        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end

    defp anchor_user(user_id, tenant_id) do
      User
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^user_id and tenant_id == ^tenant_id and role == :agent_operator)
      |> read_one()
    end

    # Test-seam builds only: a read result a test put under
    # `{__MODULE__, :read_fault}` in the calling process replaces the read, so
    # no query runs (fault controls, Codex 3ad0a105). Other builds always read.
    if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
      defp read_one(query) do
        case Process.get({__MODULE__, :read_fault}) do
          nil -> Ash.read_one(query)
          # Declared, not yet instrumented (Codex d8fc857a): a real SQL abort
          # at this read site. Until its own reviewed GREEN it is the real read.
          {:abort, ref} when is_reference(ref) -> Ash.read_one(query)
          fault -> fault
        end
      end
    else
      defp read_one(query), do: Ash.read_one(query)
    end
  else
    defp anchor(changeset, _actor), do: refuse(changeset)
  end

  defp refuse(changeset),
    do: Ash.Changeset.add_error(changeset, field: :created_by_id, message: @message)
end
