defmodule SdrAgent.Agents.Admission.Gate do
  @moduledoc """
  Admission before spend (R0-07 slice B, REQ-07-2/3/7; packet section 7,
  rows B1–B5, B4', B5'; entity PASS at 3600fcf). A real (generation-2
  ClaudeCLI) call is admitted before reservation
  (`SdrAgent.Agents.Admission.admit/5`) and again at launch
  (`SdrAgent.Agents.admit_launch/3`) only when, in this order:

    1. **calibration** (a `:proof` run, or any call carrying calibration
       authority): the authority is valid — at reservation the test-seam
       marker (`SdrAgent.Agents.Checks.CalibrationAdmission`), at launch
       the `calibration_tuple` recorded on the invocation's one original
       `model.invocation.reserved` event — else `:calibration_not_authorized`;
       and every predecessor is latched (B4'), else
       `:calibration_evidence_pending`;
    2. **the gate is active** (`SdrAgent.Agents.ResultGate.active?/0`, and
       the test-seam refuse-only override is not set), else
       `:result_gate_inactive`;
    3. **the store root is trusted**: the configured root is the one
       observed trusted before any lock was taken (`observe_store/0`),
       else `:witness_store_untrusted`;
    4. **the tuple is promoted**: `SdrAgent.Agents.Witness.promoted?/2` for
       the call's runtime identity — against the shipped allowlist, or for
       an authorized calibration call against its own exact entry — else
       `:tuple_not_promoted`.

  Refusals are `{:error, reason, check}`; `check` is a metadata-only
  diagnostic (for example `:predecessor_authority_invalid`).

  **Store trust is observation-time trust (B5').** `observe_store/0` runs
  the full filesystem validation before the caller takes any row or head
  lock; under the locks only the pure comparison of the configured root
  with the observed one runs, with no I/O. That proves the configured root
  is the one trusted at the observation, not that the same path's
  permissions, ownership, inode or symlinks are unchanged at the admission
  instant. A same-path change after the observation is caught by the
  launch's fresh observation or, after spend, by the result gate's
  validated store read (`:store_unreadable`, output withheld).

  **Predecessors (B4').** The real calibration ledger of the tenant:
  ModelInvocations of generation 2, `claude_cli`, of a `:proof` run, of any
  status and profile (Fake and non-proof rows are never predecessors).
  Every one but the invocation itself needs a `ModelResultRelease
  :calibration` with an `evidence_sha256`. At reservation the new row does
  not exist yet; at launch exactly this invocation is excluded. A row
  reserved after an unlatched one cannot be admitted, so a later row that
  exists anyway is a defect and also blocks: no row is ever excluded by
  its order. An unlatched predecessor without exactly one original
  reservation event carrying a valid tuple is reported as
  `:predecessor_authority_invalid`, never skipped.

  Ordinary admission never reads a per-call witness override or the test
  override switch: there is no caller, job or runtime flag that admits an
  ordinary call.
  """

  require Ash.Query

  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel

  @reasons [
    :result_gate_inactive,
    :tuple_not_promoted,
    :witness_store_untrusted,
    :calibration_not_authorized,
    :calibration_evidence_pending
  ]
  @tuple_keys ~w(cli_version method model_id profile_id projection_version provider)
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @doc "The five admission refusal reasons (packet section 2, Admission row)."
  def reasons, do: @reasons

  ## Store observation (before any lock)

  @doc """
  Observes the configured witness store root — the full filesystem
  validation, `Store.validate_root/1` — before the caller takes any lock.
  Returns `%{root:, trusted?:}`. Emits `[:sdr_agent, :admission,
  :store_probe]` start/stop telemetry.
  """
  def observe_store do
    :telemetry.span([:sdr_agent, :admission, :store_probe], %{}, fn ->
      root = Witness.store_root()
      trusted? = is_binary(root) and match?({:ok, _root}, Store.validate_root(root))
      {%{root: root, trusted?: trusted?}, %{}}
    end)
  end

  ## Gate mode

  @doc """
  Whether the result gate admits real calls: the compiled mode is
  enforced (`ResultGate.active?/0`) and, in test-seam builds only, the
  refuse-only override (`config :sdr_agent, #{inspect(__MODULE__)},
  force_inactive: true`) is not set. Nothing can make an inactive gate
  active.
  """
  def active?, do: ResultGate.active?() and not forced_inactive?()

  if @test_seams do
    defp forced_inactive?,
      do: Keyword.get(Application.get_env(:sdr_agent, __MODULE__, []), :force_inactive) == true
  else
    defp forced_inactive?, do: false
  end

  ## Reservation

  @doc """
  The gate before reservation, under the reservation's locks and after the
  admission instant, for a call of the reviewed real `profile_id` in the
  locked `run`: the runtime identity checked is the profile's reviewed one
  (CLI version, resolved model; row B2). `observation` is
  `observe_store/0`'s result and `authority` the calibration marker's scope
  (or nil). Returns `{:ok, calibration_tuple}` (the recorded tuple of an
  authorized calibration call, else nil) or `{:error, reason, check}`.
  """
  def admit_reservation(run, profile_id, observation, authority) do
    {:ok, profile} = ModelProfiles.fetch_real(profile_id)

    identity = %{
      provider: :claude_cli,
      provider_version: profile.cli_version,
      profile_id: profile.id,
      model_id: profile.resolved_model,
      ledger_generation: 2
    }

    with {:ok, entries, tuple} <- calibration(run, identity, authority, nil),
         :ok <- gate(),
         :ok <- store(observation),
         :ok <- promoted(identity, entries) do
      {:ok, tuple}
    end
  end

  ## Launch

  @doc """
  The gate at launch, under the launch's locks and head, for the owned
  reserved `invocation` of the locked `run`: the same checks against the
  invocation's recorded identity, with the calibration authority
  re-derived from its one original reservation event. Returns `:ok` or
  `{:error, reason, check}`.
  """
  def admit_launch(run, invocation, observation) do
    identity =
      Map.take(invocation, [
        :provider,
        :provider_version,
        :profile_id,
        :model_id,
        :ledger_generation
      ])

    with {:ok, entries, _tuple} <-
           calibration(run, identity, recorded_authority(run, invocation), invocation.id),
         :ok <- gate(),
         :ok <- store(observation),
         do: promoted(identity, entries)
  end

  ## Checks

  # Calibration authority exists only in test-seam builds: anywhere else a
  # `:proof` call is refused whatever authority it names, a recorded one
  # included, and no predecessor ledger is read.
  if @test_seams do
    defp calibration(%{usage_origin: :proof} = run, identity, authority, self_id) do
      with {:ok, entry} <- authorized(authority, identity),
           :ok <- predecessors(run.tenant_id, self_id) do
        {:ok, [entry], tuple_record(entry)}
      end
    end
  else
    defp calibration(%{usage_origin: :proof}, _identity, nil, _self_id),
      do: {:error, :calibration_not_authorized, :authority_missing}

    defp calibration(%{usage_origin: :proof}, _identity, _authority, _self_id),
      do: {:error, :calibration_not_authorized, :authority_invalid}
  end

  defp calibration(_run, _identity, nil, _self_id), do: {:ok, :shipped, nil}

  defp calibration(_run, _identity, :invalid, _self_id),
    do: {:error, :calibration_not_authorized, :authority_invalid}

  defp calibration(_run, _identity, _authority, _self_id),
    do: {:error, :calibration_not_authorized, :not_a_proof_run}

  if @test_seams do
    defp authorized(nil, _identity),
      do: {:error, :calibration_not_authorized, :authority_missing}

    # The entry must also name the profile's current reviewed identity
    # (review MF1): a historical tuple that agrees with its own stored
    # invocation but not with today's reviewed CLI version or model is
    # refused before the call is sent.
    defp authorized({profile_id, entry}, identity) do
      with {:ok, [entry]} <- Witness.exact_overrides([entry]),
           true <- entry.profile_id == profile_id and profile_id == identity.profile_id,
           true <- Witness.promoted?(identity, [entry]) do
        if current_reviewed?(identity),
          do: {:ok, entry},
          else: {:error, :calibration_not_authorized, :profile_drift}
      else
        _invalid -> {:error, :calibration_not_authorized, :authority_invalid}
      end
    end

    defp authorized(_authority, _identity),
      do: {:error, :calibration_not_authorized, :authority_invalid}

    defp current_reviewed?(identity) do
      case ModelProfiles.fetch_real(identity.profile_id) do
        {:ok, profile} ->
          profile.cli_version == identity.provider_version and
            profile.resolved_model == identity.model_id

        _error ->
          false
      end
    end
  end

  defp gate, do: if(active?(), do: :ok, else: {:error, :result_gate_inactive, :inactive})

  # Pure: no filesystem I/O under the caller's locks.
  defp store(%{root: nil}), do: {:error, :witness_store_untrusted, :store_unset}
  defp store(%{trusted?: false}), do: {:error, :witness_store_untrusted, :store_untrusted}

  defp store(%{root: root, trusted?: true}) do
    if Witness.store_root() == root,
      do: :ok,
      else: {:error, :witness_store_untrusted, :store_changed}
  end

  defp store(_observation), do: {:error, :witness_store_untrusted, :store_unobserved}

  defp promoted(identity, :shipped), do: promoted(identity, Witness.reconciled_methods())

  defp promoted(identity, entries) do
    if Witness.promoted?(identity, entries),
      do: :ok,
      else: {:error, :tuple_not_promoted, :not_promoted}
  end

  ## Predecessors (B4')

  if @test_seams do
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ModelResultRelease

    defp predecessors(tenant_id, self_id) do
      ledger =
        ModelInvocation
        |> Ash.Query.filter(
          tenant_id == ^tenant_id and ledger_generation == 2 and provider == :claude_cli and
            agent_run.usage_origin == :proof
        )
        |> Ash.Query.select([
          :id,
          :agent_run_id,
          :tenant_id,
          :profile_id,
          :provider_version,
          :model_id
        ])
        |> Ash.Query.sort(id: :asc)
        |> Ash.read!(authorize?: false)
        |> Enum.reject(&(&1.id == self_id))

      latched =
        ModelResultRelease
        |> Ash.Query.filter(
          model_invocation_id in ^Enum.map(ledger, & &1.id) and disposition == :calibration and
            not is_nil(evidence_sha256)
        )
        |> Ash.Query.select([:model_invocation_id])
        |> Ash.read!(authorize?: false)
        |> MapSet.new(& &1.model_invocation_id)

      case Enum.reject(ledger, &MapSet.member?(latched, &1.id)) do
        [] ->
          :ok

        unlatched ->
          {:error, :calibration_evidence_pending, blocking(unlatched)}
      end
    end

    # The metadata-only diagnostic names the first blocking predecessor
    # (review, B4'): one whose recorded authority is missing, malformed or
    # not bound to its own stored identity is `predecessor_authority_invalid`
    # (owner recovery identifies the row by this id); otherwise the first
    # unlatched one is `predecessor_unlatched`. The barrier stays closed
    # either way.
    defp blocking(unlatched) do
      case Enum.find(unlatched, &(not bound_authority?(&1))) do
        nil -> {:predecessor_unlatched, hd(unlatched).id}
        invalid -> {:predecessor_authority_invalid, invalid.id}
      end
    end

    defp bound_authority?(predecessor) do
      case recorded_tuple(predecessor) do
        {:ok, entry} ->
          entry.profile_id == predecessor.profile_id and
            entry.cli_version == predecessor.provider_version and
            entry.model_id == predecessor.model_id

        _missing_or_malformed ->
          false
      end
    end
  end

  ## Recorded authority

  # The authority recorded by the one original reservation event of this
  # run's invocation: nil when it records none, `:invalid` when the event
  # is missing, duplicated or its tuple malformed.
  defp recorded_authority(run, invocation) do
    case recorded_tuple(%{invocation | agent_run_id: run.id, tenant_id: run.tenant_id}) do
      {:ok, entry} -> {entry.profile_id, entry}
      other -> other
    end
  end

  @doc """
  The calibration tuple recorded by the one original `model.invocation.reserved`
  event of `invocation` (its `id`, `agent_run_id` and `tenant_id`):
  `{:ok, entry}`, nil when it records none, or `:invalid` when the event is
  missing, duplicated or its tuple malformed. Also used by the calibration
  evidence file (R0-07 slice E, R11-3) to bind its candidate.
  """
  def recorded_tuple(invocation) do
    case original_reservation(invocation) do
      {:ok, event} -> decode(get_in(event.payload, ["arguments", "calibration_tuple"]))
      :error -> :invalid
    end
  end

  @doc """
  The console's launch-record claim recorded by the same one original
  `model.invocation.reserved` event (R0-07 E4c-2): `{:ok, %{instance_id:
  id}}`, `{:ok, nil}` when it records none, or `{:error, :claim_unrecorded}`
  when the event is missing or duplicated, the claim is malformed, or a
  claim is recorded without a valid admitted calibration tuple next to it
  (a claim alone is no authority).
  """
  def recorded_claim(invocation) do
    with {:ok, event} <- original_reservation(invocation),
         arguments = Map.get(event.payload, "arguments") || %{},
         {:ok, claim} <- decode_claim(arguments["calibration_claim"]),
         :ok <- with_tuple(claim, decode(arguments["calibration_tuple"])) do
      {:ok, claim}
    else
      _missing_duplicate_or_malformed -> {:error, :claim_unrecorded}
    end
  end

  defp with_tuple(nil, _tuple), do: :ok
  defp with_tuple(_claim, {:ok, _entry}), do: :ok
  defp with_tuple(_claim, _missing_or_invalid), do: :error

  # The one original `model.invocation.reserved` event of an invocation,
  # in its exact tenant, run and subject scope; `:error` when missing or
  # duplicated.
  defp original_reservation(%{id: id, agent_run_id: run_id, tenant_id: tenant_id})
       when is_binary(id) and is_binary(run_id) and is_binary(tenant_id) do
    case reservation_events(id, run_id, tenant_id) do
      [event] -> {:ok, event}
      _missing_or_duplicate -> :error
    end
  end

  defp original_reservation(_invocation), do: :error

  defp reservation_events(id, run_id, tenant_id) do
    AuditEvent
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and event_type == "model.invocation.reserved" and
        subject_resource == "SdrAgent.Agents.ModelInvocation" and subject_id == ^id and
        model_invocation_id == ^id and agent_run_id == ^run_id
    )
    |> Ash.read!(Kernel.opts(tenant_id))
  end

  @claim_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  defp decode_claim(nil), do: {:ok, nil}

  defp decode_claim(%{"instance_id" => id} = claim) when map_size(claim) == 1 and is_binary(id) do
    if id =~ @claim_uuid, do: {:ok, %{instance_id: id}}, else: :error
  end

  defp decode_claim(_malformed), do: :error

  defp decode(nil), do: nil

  defp decode(%{} = tuple) do
    with true <- Enum.sort(Map.keys(tuple)) == @tuple_keys,
         "claude_cli" <- tuple["provider"],
         "propagated_id" <- tuple["method"],
         {:ok, profile_id} <- real_profile(tuple["profile_id"]),
         true <-
           Enum.all?(["cli_version", "model_id", "projection_version"], &is_binary(tuple[&1])) do
      {:ok,
       %{
         provider: :claude_cli,
         cli_version: tuple["cli_version"],
         profile_id: profile_id,
         model_id: tuple["model_id"],
         projection_version: tuple["projection_version"],
         method: :propagated_id
       }}
    else
      _malformed -> :invalid
    end
  end

  defp decode(_malformed), do: :invalid

  defp real_profile(name) when is_binary(name) do
    case Enum.find(ModelProfiles.real_ids(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      id -> {:ok, id}
    end
  end

  defp real_profile(_name), do: :error

  @doc """
  The recorded form of an exact entry (string keys and values), written as
  the `calibration_tuple` argument of the invocation's
  `model.invocation.reserved` event.
  """
  def tuple_record(entry) do
    Map.new(entry, fn {key, value} -> {Atom.to_string(key), to_string(value)} end)
  end
end
