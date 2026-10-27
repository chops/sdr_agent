defmodule SdrAgent.Agents.Checks.DelegatedGrant do
  @moduledoc """
  Policy check (C2* S2; plan `claude-c2star-s2-provisioning-plan-r1.md` §5
  and scope correction Q7): the grant a write concerns is delegated.

    * On a `ModelCallGrant` write: the subject record is delegated. This is
      the pre-lock check of the caller's record; after the row lock
      `SdrAgent.Agents.Changes.RequireOwnerForm` refuses a delegated row
      again, so a forged owner-form struct gains nothing.
    * On a `ModelCallAllocation` write: its parent grant, read by its stable
      id in the allocation's tenant (a plain read), is delegated. A parent
      that cannot be read there is never taken for an owner-form parent:
      the check then holds too (fail-closed).
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant

  @impl true
  def describe(_opts), do: "the grant is delegated (or its parent cannot be read)"

  @impl true
  def match?(_actor, %{subject: %Ash.Changeset{resource: ModelCallGrant} = changeset}, _opts),
    do: changeset.data.provisioning == :delegated

  def match?(_actor, %{subject: %Ash.Changeset{resource: ModelCallAllocation} = changeset}, _opts) do
    case parent(changeset) do
      {:ok, %ModelCallGrant{provisioning: :owner_form}} -> false
      _delegated_or_unread -> true
    end
  end

  def match?(_actor, _context, _opts), do: true

  @doc """
  The parent grant of an allocation changeset, read by the allocation's
  `grant_id` in its `tenant_id` without a lock: `{:ok, grant}` or `:error`.
  """
  @spec parent(Ash.Changeset.t()) :: {:ok, ModelCallGrant.t()} | :error
  def parent(%Ash.Changeset{} = changeset) do
    grant_id = Ash.Changeset.get_attribute(changeset, :grant_id)
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    with true <- is_binary(grant_id) and is_binary(tenant_id),
         {:ok, %ModelCallGrant{} = grant} <-
           ModelCallGrant
           |> Ash.Query.filter(id == ^grant_id and tenant_id == ^tenant_id)
           |> Ash.read_one(authorize?: false) do
      {:ok, grant}
    else
      _other -> :error
    end
  end
end
