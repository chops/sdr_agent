defmodule SdrAgent.Agents.Changes.ProvisionPrototype do
  @moduledoc """
  The in-action validation of `SdrAgent.Agents.ModelCallGrant
  :provision_prototype` (D-237 interfaces r6 IF-2; closure note r2, Codex
  3e05314f). Everything that makes the prototype grant legitimate runs
  inside the action, on server-derived values, so a raw call is as safe as
  the domain wrapper:

  - at build, any caller-supplied server-derived argument
    (`budget_worksheet_sha256`, `funding_id`, `funding_entry_sha256`,
    `decision_refs`, `delegation_id`, `binding_id`, `allocations`), even one equal to the server's value, is
    refused (`ProvisionRefused` `:forged_metadata`, class `:invalid`);
    the exact funding-entry terms are set;
  - in a `before_action` (the action's transaction), in this order: the
    boot snapshot and the live operator (`operator_actor/1` resolves to
    exactly the actor); the binding-row lock; the original-event lookup
    (any trusted or untrusted provenance is `:grant_exists`: the action
    never renews); the separately detected ordinary name conflict
    (`:grant_exists`); the full `check_worksheet/3` with its evidence;
    only then the anchor as creator and updater, and the server-derived
    arguments recorded on `model.grant.provisioned` (the funding id, the
    funding entry's digest and decision refs, the worksheet digest, the
    delegation and the binding: amendment r6 item 4) and the entry's
    allocation set for `SdrAgent.Agents.Changes.GrantBundle`.

  It must be listed before `GrantBundle`, whose `before_action` reads the
  allocation set. In a build without the prototype authority (the
  production build) every call is refused.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Errors.ProvisionRefused

  @server_derived [
    :budget_worksheet_sha256,
    :funding_id,
    :funding_entry_sha256,
    :decision_refs,
    :delegation_id,
    :binding_id,
    :allocations
  ]

  @impl true
  def change(changeset, opts, context) do
    cond do
      Keyword.get(opts, :stage) == :finish ->
        finish(changeset)

      Enum.any?(@server_derived, &Map.has_key?(changeset.arguments, &1)) ->
        refuse(changeset, :forged_metadata)

      true ->
        provision(changeset, context.actor)
    end
  end

  defp refuse(changeset, reason),
    do: Ash.Changeset.add_error(changeset, ProvisionRefused.exception(reason: reason))

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.Authority
    alias SdrAgent.Prototype.ProvisionScope
    alias SdrAgent.Prototype.Provisioning

    @ref_key :sdr_prototype_provision_ref

    # The scope lifecycle (design note r2, Codex 17a870c0): a fresh private
    # ref at build (it overwrites any caller value); the scope is established
    # in the before_action only after every check, bound to the inserted
    # grant in an after_action listed before GrantBundle's (which fetches
    # the bound scope by this ref and forwards it whole), and released by an
    # around_transaction try/after that calls the action exactly once.
    defp provision(changeset, actor) do
      ref = make_ref()

      changeset
      |> Ash.Changeset.put_context(@ref_key, ref)
      |> Ash.Changeset.force_change_attributes(Provisioning.terms())
      |> Ash.Changeset.before_action(&mint(&1, actor))
      |> Ash.Changeset.after_action(fn _changeset, grant -> bind(ref, grant) end)
      |> Ash.Changeset.around_transaction(fn changeset, callback ->
        try do
          callback.(changeset)
        after
          ProvisionScope.release(ref)
        end
      end)
    end

    defp bind(ref, grant) do
      case ProvisionScope.bind_grant(ref, grant) do
        %ProvisionScope{} = bound ->
          seam(:scope_bound, bound)
          {:ok, grant}

        {:error, _refused} ->
          {:error, ProvisionRefused.exception(reason: :binding_mismatch)}
      end
    end

    # Listed after GrantBundle: the allocation writes are done.
    defp finish(changeset) do
      Ash.Changeset.after_action(changeset, fn changeset, grant ->
        seam(:after_allocations, ProvisionScope.fetch(changeset.context[@ref_key]))
        {:ok, grant}
      end)
    end

    defp establish(changeset, snapshot, actor) do
      bindings = %{
        tenant_id: snapshot.tenant_id,
        binding_id: snapshot.id,
        delegation_id: actor.id,
        anchor_id: snapshot.operator_user_id,
        planned: Provisioning.allocations()
      }

      case ProvisionScope.establish(changeset.context[@ref_key], bindings) do
        %ProvisionScope{} = scope ->
          seam(:scope_established, scope)
          :ok

        {:error, _refused} ->
          {:error, :binding_mismatch}
      end
    end

    if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do
      # Test-build-only, process-local hooks (Codex e006f70a D2):
      # `{SdrAgent.Agents.Changes.ProvisionPrototype, name}`, a one-argument
      # function; its result is ignored.
      defp seam(name, arg) do
        case Process.get({__MODULE__, name}) do
          hook when is_function(hook, 1) -> hook.(arg)
          _none -> nil
        end

        :ok
      end
    else
      defp seam(_name, _arg), do: :ok
    end

    defp mint(changeset, actor) do
      worksheet = Ash.Changeset.get_argument(changeset, :worksheet)
      digest = Base.encode16(:crypto.hash(:sha256, worksheet), case: :lower)

      with {:ok, snapshot} <- live_operator(actor),
           :ok <- Provisioning.lock_binding(snapshot),
           :ok <- no_prior_grant(snapshot),
           {:ok, %{}} <- check(worksheet, digest, changeset),
           :ok <- establish(changeset, snapshot, actor) do
        changeset
        |> Ash.Changeset.force_change_attributes(%{
          created_by_id: snapshot.operator_user_id,
          updated_by_id: snapshot.operator_user_id
        })
        |> Ash.Changeset.force_set_argument(:funding_id, Provisioning.name())
        |> Ash.Changeset.force_set_argument(
          :funding_entry_sha256,
          Authority.funding_entry_sha256()
        )
        |> Ash.Changeset.force_set_argument(:decision_refs, Provisioning.decision_refs())
        |> Ash.Changeset.force_set_argument(:budget_worksheet_sha256, digest)
        |> Ash.Changeset.force_set_argument(:delegation_id, actor.id)
        |> Ash.Changeset.force_set_argument(:binding_id, snapshot.id)
        |> Ash.Changeset.force_set_argument(:allocations, Provisioning.allocations())
      else
        {:error, reason} -> refuse(changeset, reason)
      end
    end

    defp live_operator(%SdrAgent.Actor{id: id} = actor) do
      with {:ok, snapshot} <- Prototype.binding(),
           {:ok, ^actor} <- Prototype.operator_actor(id) do
        {:ok, snapshot}
      else
        _other -> {:error, :binding_mismatch}
      end
    end

    defp live_operator(_actor), do: {:error, :binding_mismatch}

    # The raw action never renews: any provisioned event of this tenant
    # (trusted or not) is `:grant_exists`, and so is any grant currently
    # named `d237-funding/1` (locked after the binding row).
    defp no_prior_grant(snapshot) do
      with :none <- Provisioning.lookup(snapshot),
           {:ok, []} <- Provisioning.lock_name_conflicts(snapshot, nil) do
        :ok
      else
        _prior -> {:error, :grant_exists}
      end
    end

    defp check(worksheet, digest, changeset) do
      Authority.check_worksheet(
        worksheet,
        digest,
        Ash.Changeset.get_argument(changeset, :evidence_root)
      )
    end
  else
    defp provision(changeset, _actor), do: refuse(changeset, :binding_mismatch)
    defp finish(changeset), do: changeset
  end
end
