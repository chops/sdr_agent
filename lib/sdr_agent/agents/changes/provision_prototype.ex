defmodule SdrAgent.Agents.Changes.ProvisionPrototype do
  @moduledoc """
  The in-action validation of `SdrAgent.Agents.ModelCallGrant
  :provision_prototype` (D-237 interfaces r6 IF-2; closure note r2, Codex
  3e05314f). Everything that makes the prototype grant legitimate runs
  inside the action, on server-derived values, so a raw call is as safe as
  the domain wrapper:

  - at build, any caller-supplied server-derived argument
    (`budget_worksheet_sha256`, `funding_id`, `delegation_id`,
    `binding_id`, `allocations`), even one equal to the server's value, is
    refused (`ProvisionRefused` `:forged_metadata`, class `:invalid`);
    the exact funding-entry terms are set;
  - in a `before_action` (the action's transaction), in this order: the
    boot snapshot and the live operator (`operator_actor/1` resolves to
    exactly the actor); the binding-row lock; the original-event lookup
    (any trusted or untrusted provenance is `:grant_exists`: the action
    never renews); the separately detected ordinary name conflict
    (`:grant_exists`); the full `check_worksheet/3` with its evidence;
    only then the anchor as creator and updater, and the server-derived
    arguments recorded on `model.grant.provisioned` and the entry's
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
    :delegation_id,
    :binding_id,
    :allocations
  ]

  @impl true
  def change(changeset, _opts, context) do
    if Enum.any?(@server_derived, &Map.has_key?(changeset.arguments, &1)),
      do: refuse(changeset, :forged_metadata),
      else: provision(changeset, context.actor)
  end

  defp refuse(changeset, reason),
    do: Ash.Changeset.add_error(changeset, ProvisionRefused.exception(reason: reason))

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.Authority
    alias SdrAgent.Prototype.Provisioning

    defp provision(changeset, actor) do
      changeset
      |> Ash.Changeset.force_change_attributes(Provisioning.terms())
      |> Ash.Changeset.before_action(&mint(&1, actor))
    end

    defp mint(changeset, actor) do
      worksheet = Ash.Changeset.get_argument(changeset, :worksheet)
      digest = Base.encode16(:crypto.hash(:sha256, worksheet), case: :lower)

      with {:ok, snapshot} <- live_operator(actor),
           :ok <- Provisioning.lock_binding(snapshot),
           :ok <- no_prior_grant(snapshot),
           {:ok, %{}} <- check(worksheet, digest, changeset) do
        changeset
        |> Ash.Changeset.force_change_attributes(%{
          created_by_id: snapshot.operator_user_id,
          updated_by_id: snapshot.operator_user_id
        })
        |> Ash.Changeset.force_set_argument(:funding_id, Provisioning.name())
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
  end
end
