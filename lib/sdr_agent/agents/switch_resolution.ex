defmodule SdrAgent.Agents.SwitchResolution do
  @moduledoc """
  The phase-free pieces of the attended resolution of a blocked model
  profile switch (C2-02b2β, `docs/product/r0/c2-02b2b-interface.md`
  sections 1 and 2), shared by the caller's orchestration
  (`SdrAgent.Agents.ProfileSwitches`) and the coordinator that executes it
  (`SdrAgent.AI.ModelProvider.Coordinator`): the attestation's closed shape,
  the stored replay read by `attestation_id`, the exact semantic replay
  decision, and the mapping of a rolled-back write to its result. None of
  them writes, locks or opens a phase.
  """
  require Ash.Query

  alias Ash.Error.Query.NotFound
  alias SdrAgent.Agents.ModelProfileSwitch

  @lease_kinds [:none, :survivor, :dead_holder]
  @attestation_keys Enum.sort([
                      :attestation_id,
                      :switch_id,
                      :attested_start_id,
                      :attested_generation,
                      :attested_lease_kind,
                      :outcome,
                      :confirmation
                    ])
  # The typed refusals a rolled-back resolution reports as they are.
  @typed_refusals [
    :attestation_conflict,
    :switch_not_blocked,
    :stale_attestation,
    :observation_unknown,
    :switch_open
  ]

  @doc """
  The attestation's closed shape (section 2, step 2) for switch `switch_id`:
  `{:ok, attestation}` or `{:error, :attestation_invalid}`. Exactly the
  keys `attestation_id`, `switch_id` (= `switch_id`), `attested_start_id`,
  `attested_generation` (≥ 1), `attested_lease_kind` (`:none | :survivor
  | :dead_holder`), `outcome` (`:failed`) and `confirmation` (exactly
  `"STOPPED " <> switch_id`, with no trimming or case folding).
  """
  def checked_attestation(switch_id, %{} = attestation)
      when is_binary(switch_id) and not is_struct(attestation) do
    if closed?(attestation) and bound?(attestation, switch_id) and attested?(attestation),
      do: {:ok, attestation},
      else: {:error, :attestation_invalid}
  end

  def checked_attestation(_switch_id, _attestation), do: {:error, :attestation_invalid}

  @doc """
  The stored read by `attestation_id` in `tenant_id` (`read_opts`: the
  reader's actor options): `{:ok, switch | nil}`, or `{:error,
  :observation_unknown}` when unreadable (never "absent").
  """
  def replay_lookup(tenant_id, attestation_id, read_opts) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, read_opts)
    |> Ash.Query.filter(tenant_id == ^tenant_id and attestation_id == ^attestation_id)
    |> Ash.read_one()
    |> case do
      {:ok, found} -> {:ok, found}
      _error -> {:error, :observation_unknown}
    end
  end

  @doc """
  The replay decision on a stored row carrying the attestation's id: its
  semantic identity (the switch, the resolver `resolver_id`, the attested
  start, generation and lease kind, and the `:failed` outcome) must match
  exactly: `{:ok, %{switch: stored, replay: true}}`, else `{:error,
  :attestation_conflict}`.
  """
  def resolution_result(%ModelProfileSwitch{} = stored, attestation, resolver_id) do
    if stored.id == attestation.switch_id and stored.resolved_by_id == resolver_id and
         stored.attested_start_id == attestation.attested_start_id and
         stored.attested_generation == attestation.attested_generation and
         stored.attested_lease_kind == attestation.attested_lease_kind and
         stored.status == :failed and stored.resolution == :owner_attested,
       do: {:ok, %{switch: stored, replay: true}},
       else: {:error, :attestation_conflict}
  end

  @doc """
  The coordinator's mapping of a rolled-back resolution: a typed refusal or
  Forbidden as it is; anything else definitely did not commit
  (`:resolve_timeout`).
  """
  def rolled_back_result(reason) when reason in @typed_refusals, do: {:error, reason}
  def rolled_back_result(%Ash.Error.Forbidden{} = error), do: {:error, error}

  def rolled_back_result(%Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &match?(%NotFound{}, &1)),
      do: {:error, error},
      else: {:error, :resolve_timeout}
  end

  def rolled_back_result(_reason), do: {:error, :resolve_timeout}

  defp closed?(attestation), do: attestation |> Map.keys() |> Enum.sort() == @attestation_keys

  # The switch, named twice: by id, and in the typed confirmation.
  defp bound?(attestation, switch_id) do
    attestation.switch_id === switch_id and
      attestation.confirmation === "STOPPED " <> switch_id
  end

  defp attested?(attestation) do
    canonical_uuid?(attestation.attestation_id) and
      canonical_uuid?(attestation.attested_start_id) and
      positive?(attestation.attested_generation) and
      attestation.attested_lease_kind in @lease_kinds and
      attestation.outcome === :failed
  end

  defp positive?(value), do: is_integer(value) and value >= 1

  defp canonical_uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Ecto.UUID.cast(value) == {:ok, value}

  defp canonical_uuid?(_value), do: false
end
