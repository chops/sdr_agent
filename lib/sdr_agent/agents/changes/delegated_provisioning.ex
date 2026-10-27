defmodule SdrAgent.Agents.Changes.DelegatedProvisioning do
  @moduledoc """
  The body of `ModelCallGrant :provision_delegated` (C2* S2; plan
  `claude-c2star-s2-provisioning-plan-r1.md` §2 AC3 and §5; Codex OQ2, OQ8,
  OQ9, Q4 and the B ruling). Must come before `GrantBundle` (mode
  `:delegated`) and `AppendEvent`.

  **Inputs.** The only public input is `authorization_id`. The private
  arguments `authorization_sha256`, `claim_nonce` and `decision_refs` are
  derived here. If a caller supplied any of them (in the params, atom or
  string key, or through `private_arguments:`), whatever its value, the
  action is refused with `ProvisioningRefused` `:inputs_refused` before
  anything else.

  **Before the insert** (after authorization, inside the transaction), in
  order, each refusal a `ProvisioningRefused` with nothing written:

    1. the calling process's provisioning attestation
       (`SdrAgent.AgentEnv.Provisioning`) still verifies, at level
       `:provisioning` or `:spend_ready`, for this id, and the compiled
       registry entry of that id has the attested digest (otherwise
       `Ash.Error.Forbidden`; the policy has already required this);
    2. the live database's name and oid and the creating tenant are the
       attested environment's (`:binding_mismatch`);
    3. the entry is valid, `SdrAgent.AgentEnv.Registry.validate/1`
       (`:authorization_invalid`);
    4. now is before the entry's `expires_at` (`:authorization_expired`);
    5. no delegated grant of another authorization exists in the tenant,
       by a plain read (`:another_authorization_provisioned`, OQ8).

  It then sets the grant's terms from the entry (`name` = the id; `purpose`
  = "Delegated agent-environment authorization <id> (<environment>;
  <decision refs, comma-separated>)", OQ2), `provisioning: :delegated`,
  the authorization id and digest, and the private arguments, and hands
  the entry's allocations and the environment binding to `GrantBundle`.
  No user id is set.

  **After the insert.** The action is a never-updating upsert on
  `:unique_delegated_authorization`. A freshly inserted row passes. An
  existing row with the same digest, terms and allocations (status,
  revision, revocation and updater excluded, OQ9) is an identical replay:
  returned unchanged (a revoked grant stays revoked) and marked
  `:sdr_replayed`, so neither allocations nor an event are written. Any
  other existing row is `:grant_conflict`, never a repair.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Forbidden
  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Provisioning
  alias SdrAgent.AgentEnv.Registry
  alias SdrAgent.Agents.Errors.ProvisioningRefused
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Clock

  @private [:authorization_sha256, :claim_nonce, :decision_refs]
  @terms [
    :name,
    :purpose,
    :profile_ids,
    :total_attempts,
    :per_utc_day_attempts,
    :starts_at,
    :expires_at
  ]
  @allocation_terms [:key, :profile_id, :applies_to, :attempts, :available_from, :available_until]
  @bundle :grant_bundle_delegated

  @doc "The changeset context key under which `GrantBundle` finds the delegated bundle."
  def bundle_key, do: @bundle

  @impl true
  def change(changeset, _opts, _context) do
    if Enum.any?(@private, &supplied?(changeset, &1)) do
      Ash.Changeset.add_error(changeset, ProvisioningRefused.exception(reason: :inputs_refused))
    else
      changeset
      |> Ash.Changeset.before_action(&provision/1)
      |> Ash.Changeset.after_action(&replay/2)
    end
  end

  # By presence, never by value: a private argument stored through
  # `private_arguments:` (any value Ash casts, nil included), or its name
  # as a plain params key (which Ash drops from the arguments but keeps in
  # the params).
  defp supplied?(changeset, name) do
    Map.has_key?(changeset.arguments, name) or
      (is_map(changeset.params) and
         (Map.has_key?(changeset.params, name) or
            Map.has_key?(changeset.params, Atom.to_string(name))))
  end

  defp provision(changeset) do
    with {:ok, registration, entry} <- attested(changeset),
         :ok <- bound(changeset, registration),
         :ok <- valid(entry),
         :ok <- unexpired(entry),
         :ok <- sole_authorization(changeset, entry) do
      provisioned(changeset, registration, entry)
    else
      {:refused, reason} ->
        Ash.Changeset.add_error(changeset, ProvisioningRefused.exception(reason: reason))

      _unattested ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end
  end

  defp attested(changeset) do
    id = Ash.Changeset.get_argument(changeset, :authorization_id)

    with {:ok, registration} <- Provisioning.current(),
         {:ok, ^registration} <- Provisioning.verify(registration),
         true <- registration.level in [:provisioning, :spend_ready],
         true <- registration.authorization_id == id,
         {:ok, entry} <- Registry.fetch(id),
         true <- Registry.sha256(entry) == registration.authorization_sha256 do
      {:ok, registration, entry}
    end
  end

  defp bound(changeset, registration) do
    with {:ok, identity} <- AgentEnv.live_database_identity(),
         :ok <- AgentEnv.check_live_binding(registration, identity),
         true <- Ash.Changeset.get_attribute(changeset, :tenant_id) == registration.tenant_id do
      :ok
    else
      _mismatch -> {:refused, :binding_mismatch}
    end
  end

  defp valid(entry) do
    case Registry.validate(entry) do
      :ok -> :ok
      {:error, _rule} -> {:refused, :authorization_invalid}
    end
  end

  defp unexpired(entry) do
    if DateTime.compare(Clock.utc_now(), entry.expires_at) == :lt,
      do: :ok,
      else: {:refused, :authorization_expired}
  end

  defp sole_authorization(changeset, entry) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    id = entry.id

    ModelCallGrant
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and provisioning == :delegated and
        delegated_authorization_id != ^id
    )
    |> Ash.exists?(authorize?: false)
    |> if(do: {:refused, :another_authorization_provisioned}, else: :ok)
  end

  defp provisioned(changeset, registration, entry) do
    terms = %{
      name: entry.id,
      purpose: purpose(entry),
      profile_ids: entry.profile_ids,
      total_attempts: entry.total_attempts,
      per_utc_day_attempts: entry.per_utc_day_attempts,
      starts_at: entry.starts_at,
      expires_at: entry.expires_at,
      provisioning: :delegated,
      delegated_authorization_id: entry.id,
      delegated_authorization_sha256: registration.authorization_sha256
    }

    changeset
    |> Ash.Changeset.force_change_attributes(terms)
    |> Ash.Changeset.force_set_argument(:authorization_sha256, registration.authorization_sha256)
    |> Ash.Changeset.force_set_argument(:claim_nonce, registration.claim_nonce)
    |> Ash.Changeset.force_set_argument(:decision_refs, entry.decision_refs)
    |> Ash.Changeset.put_context(@bundle, %{
      allocations: entry.allocations,
      binding_sha256: registration.binding_sha256
    })
  end

  defp purpose(entry) do
    "Delegated agent-environment authorization #{entry.id} " <>
      "(#{entry.environment_id}; #{Enum.join(entry.decision_refs, ", ")})"
  end

  defp replay(changeset, grant) do
    cond do
      grant.id == Ash.Changeset.get_attribute(changeset, :id) ->
        {:ok, grant}

      identity(stored_terms(grant), stored_allocations(grant)) ==
          identity(requested_terms(changeset), changeset.context[@bundle].allocations) ->
        {:ok, Ash.Resource.put_metadata(grant, :sdr_replayed, true)}

      true ->
        {:error, ProvisioningRefused.exception(reason: :grant_conflict)}
    end
  end

  defp stored_terms(grant) do
    grant
    |> Map.take([:provisioning, :delegated_authorization_sha256 | @terms])
  end

  defp requested_terms(changeset) do
    Map.new(
      [:provisioning, :delegated_authorization_sha256 | @terms],
      &{&1, Ash.Changeset.get_attribute(changeset, &1)}
    )
  end

  defp stored_allocations(grant) do
    ModelCallAllocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.read!(authorize?: false)
  end

  # Canonical semantic identity (Codex OQ9): terms, digest and the
  # allocations as an unordered set; lifecycle fields are not compared.
  defp identity(terms, allocations) do
    Canonical.normalize(%{
      terms: terms,
      allocations:
        allocations
        |> Enum.map(fn allocation ->
          Map.new(@allocation_terms, &{&1, Map.get(allocation, &1)})
        end)
        |> Canonical.normalize()
        |> Enum.sort()
    })
  end
end
