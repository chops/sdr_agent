defmodule SdrAgent.Agents.Admission do
  @moduledoc """
  Reservation-time admission of real-model calls against owner-created
  grants (C9-02/03; R0 readiness packet "Changed backend action contracts").

  It runs inside `SdrAgent.Agents.reserve_model_invocation/3`'s transaction
  for a ClaudeCLI call, in this lock order (the grant editors' order is
  grant `FOR UPDATE` → its allocations `FOR UPDATE` → chain head):

    1. the run row (`FOR UPDATE`);
    2. `lock_candidates/2`: the candidate grants — the run's tenant,
       `:active`, listing the call's profile — read under MVCC and then
       locked `FOR SHARE` by id, then all their allocations `FOR SHARE` by
       id. A reservation therefore never waits for a grant or allocation row
       while it holds the chain head, and no editor can commit a change to a
       candidate (or add an allocation to it) until the reservation ends;
       the invocation's FK checks (`FOR KEY SHARE`) find the rows already
       held;
    3. the chain head, explicitly; only now is the admission instant `now`
       read from `SdrAgent.Clock`, so time spent waiting for any lock counts;
    4. `admit/4`: eligibility, windows and room (the grant's UTC day is the
       day of `now`) from fresh reads of the locked candidates under the
       head (a grant committed after step 2 is not a candidate: the
       reservation is ordered before it). The same `now` is written as the
       invocation's `reserved_at`, so the recorded charge, its quota day and
       the eligibility windows share one instant.

  It selects the one allocation that may fund the call:

    * the run has a `usage_origin`, which with the call's purpose gives the
      trusted usage bucket (`SdrAgent.Agents.UsageBucket`);
    * its grant is of the run's tenant, `:active`, with
      `starts_at ≤ now < expires_at`, and lists the call's profile;
    * the allocation is of the same tenant and grant, its `profile_id` is
      unset or the call's, the bucket is in `applies_to`, and it is
      available at `now` (`available?/2`).

  Exactly one allocation must match. Its room is then checked: the grant's
  consumed attempts (ModelInvocations charged to it) below `total_attempts`,
  today's (UTC, by `reserved_at`) below `per_utc_day_attempts` when set, and
  the allocation's below its `attempts`. Attempts are never refunded.

  Refusals (`%Refusal{reason: reason}`), in order of the checks:
  `:no_usage_origin`; then the R0-07 slice B admission gate
  (`SdrAgent.Agents.Admission.Gate`: `:calibration_not_authorized`,
  `:calibration_evidence_pending`, `:result_gate_inactive`,
  `:witness_store_untrusted`, `:tuple_not_promoted`, each with a
  metadata-only `check`); then the model profile switch fence (C2-02b1,
  `SdrAgent.Agents.Admission.SwitchFence`: `:profile_switch_fenced` while
  the tenant has an open switch, read fresh under the head; at launch also
  the epoch rule); then `:no_eligible_grant` (no grant passes the
  grant checks), `:no_allocation` (an eligible grant, but no allocation for
  this profile, bucket and time), `:ambiguous_allocation`, and
  `{:budget_exhausted, :grant | :grant_day | :allocation}`. The gate's
  checks come before the grant checks: they mean this build or
  configuration may not spend, which no grant can fix.

  `record_refusal/1` then commits the refusal on its own, after the
  reservation rolled back: one deduplicated Failure of the run —
  `budget_exhausted` for a grant refusal, `provider_error` for an
  admission-gate refusal — and a `model.reservation.refused` audit event
  (metadata only).
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Admission.SwitchFence
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Redactor
  alias SdrAgent.Repo

  @run_resource "SdrAgent.Agents.AgentRun"

  defmodule Refusal do
    @moduledoc """
    A refused reservation: the `reason` returned to the caller and the
    metadata recorded with the refusal (never the request content).
    """
    @enforce_keys [:reason, :tenant_id, :agent_run_id]
    defstruct [
      :reason,
      :tenant_id,
      :agent_run_id,
      :operation_id,
      :correlation_id,
      :usage_origin,
      :purpose,
      :profile_id,
      :bucket,
      :grant_id,
      :allocation_id,
      :idempotency_key,
      :check
    ]
  end

  defmodule Refused do
    @moduledoc """
    The receipt of a committed refusal, returned to the caller as
    `{:error, %Refused{}}`: the refusal `reason` and its metadata-only
    `check`, the exact Failure recorded for it, the refusal event, the run,
    the refused request's idempotency key, and the `stage` —
    `:reservation` (`model.reservation.refused`, after the reservation
    rolled back) or `:launch` (`model.launch.refused`, committed with the
    failed row by `SdrAgent.Agents.admit_launch/3`; R0-07 slice B, row B1).
    A run stopped by the refusal links exactly this Failure
    (`SdrAgent.Agents.Changes.LinkRefusalAttention`).
    """
    @enforce_keys [:reason, :failure_id, :event_id, :agent_run_id]
    defstruct [:reason, :failure_id, :event_id, :agent_run_id, :request_id, :stage, :check]
  end

  @doc """
  Step 2 of the lock order (see the moduledoc): with the run row locked and
  before the chain head, locks the run tenant's candidate grants for
  `profile_id` and all their allocations `FOR SHARE`, grants then
  allocations, each by id. Returns `{:ok, grant_ids}` (possibly empty).
  """
  def lock_candidates(run, profile_id) do
    ids =
      ModelCallGrant
      |> Ash.Query.filter(tenant_id == ^run.tenant_id and status == :active)
      |> Ash.Query.select([:id, :profile_ids])
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(profile_id in &1.profile_ids))
      |> Enum.map(& &1.id)

    locked =
      ModelCallGrant
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    ModelCallAllocation
    |> Ash.Query.filter(grant_id in ^locked)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read!(authorize?: false)

    {:ok, locked}
  end

  # The G-R0 shape (packet 8.3): the calibration grant the console binds.
  @g_r0_profiles [:claude_cli_opus, :claude_cli_sonnet]
  @g_r0_total 4
  @g_r0_expires ~U[2026-10-19 05:59:00Z]
  @g_r0_attempts 2

  @doc """
  The G-R0 binding for `profile_id` in `tenant_id` at `now` (packet 8.3,
  read-only preflight): `{:ok, %{grant_id:, grant_revision:,
  allocation_id:, profile_id:}}` when exactly one grant of the tenant has
  the G-R0 shape and that profile's allocation is available at `now`
  (`available?/2`); `{:error, :calibration_grant_unavailable}` otherwise.
  """
  def calibration_grant(tenant_id, profile_id, now) do
    ModelCallGrant
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.Query.load(:allocations)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&g_r0?(&1, now))
    |> case do
      [grant] -> grant_binding(grant, profile_id, now)
      _none_or_several -> {:error, :calibration_grant_unavailable}
    end
  end

  # The requested profile's allocation must also be inside its existing
  # window at `now` (`available?/2`, packet 8.3 "existing ... window terms").
  defp grant_binding(grant, profile_id, now) do
    case Enum.filter(grant.allocations, &(&1.profile_id == profile_id)) do
      [allocation] ->
        if available?(allocation, now), do: binding(grant, allocation), else: unavailable()

      _ ->
        unavailable()
    end
  end

  defp unavailable, do: {:error, :calibration_grant_unavailable}

  defp binding(grant, allocation) do
    {:ok,
     %{
       grant_id: grant.id,
       grant_revision: grant.revision,
       allocation_id: allocation.id,
       profile_id: allocation.profile_id
     }}
  end

  @doc "Whether `grant` (allocations loaded) has the G-R0 shape at `now`."
  def g_r0?(grant, now) do
    grant.status == :active and Enum.sort(grant.profile_ids) == Enum.sort(@g_r0_profiles) and
      grant.total_attempts == @g_r0_total and
      DateTime.compare(grant.expires_at, @g_r0_expires) == :eq and
      DateTime.compare(grant.starts_at, now) != :gt and
      DateTime.compare(now, grant.expires_at) == :lt and g_r0_allocations?(grant.allocations)
  end

  defp g_r0_allocations?(allocations) when length(allocations) == 2 do
    Enum.all?(allocations, fn allocation ->
      allocation.key == :proof and allocation.applies_to == [:proof] and
        allocation.attempts == @g_r0_attempts and is_nil(allocation.released_at)
    end) and Enum.sort(Enum.map(allocations, & &1.profile_id)) == Enum.sort(@g_r0_profiles)
  end

  defp g_r0_allocations?(_allocations), do: false

  @doc """
  Step 4: admits a ClaudeCLI call of `profile_id` with `purpose` in the
  locked, freshly read `run`, among the share-locked `candidate_ids`.
  `gate` carries the admission gate's inputs taken before any lock
  (`%{store: Gate.observe_store(), calibration: authority, binding:}`; a G-R0
  `binding` restricts the candidates to the bound grant, packet 8.3). Returns
  `{:ok, %{grant_id:, allocation_id:, calibration_tuple:, calibration_claim:,
  calibration_binding:}}` or
  `{:error, %Refusal{}}`. Callers hold the run row, candidate and
  chain-head locks.
  """
  def admit(run, call, now, candidate_ids, gate) do
    purpose = Map.get(call, :purpose)
    profile_id = Map.get(call, :profile_id)

    refusal = %Refusal{
      reason: nil,
      tenant_id: run.tenant_id,
      agent_run_id: run.id,
      operation_id: run.operation_id,
      correlation_id: run.correlation_id,
      usage_origin: run.usage_origin,
      purpose: purpose,
      profile_id: profile_id,
      bucket: UsageBucket.bucket(run.usage_origin, purpose),
      idempotency_key: Map.get(call, :idempotency_key)
    }

    binding = gate_binding(gate)

    with :ok <- origin(refusal),
         {:ok, tuple} <- admission_gate(refusal, run, gate),
         :ok <- switch_fence(refusal),
         {:ok, candidate_ids} <- bound_candidates(refusal, candidate_ids, binding, now),
         {:ok, grants} <- eligible_grants(refusal, candidate_ids, now),
         {:ok, grant, allocation} <- one_allocation(refusal, grants, now),
         :ok <- bound_allocation(refusal, allocation, binding),
         :ok <- room(%{refusal | grant_id: grant.id, allocation_id: allocation.id}, grant, now) do
      {:ok,
       %{
         grant_id: grant.id,
         allocation_id: allocation.id,
         calibration_tuple: tuple,
         calibration_claim: claim_record(tuple, gate),
         calibration_binding: binding_record(tuple, binding)
       }}
    end
  end

  # C2-02b1: a fresh read of the tenant's open switch, after the head
  # (`admit/5` runs under it), before grant eligibility.
  defp switch_fence(refusal) do
    case SwitchFence.open_switch(refusal.tenant_id) do
      :ok -> :ok
      {:error, reason, check} -> {:error, %{refusal | reason: reason, check: check}}
      {:error, error} -> {:error, error}
    end
  end

  defp gate_binding(%{binding: %{} = binding}), do: binding
  defp gate_binding(_gate), do: nil

  # G-R0 binding (packet 8.3, round 11): under the candidate share locks the
  # bound grant is the only G-R0-shaped candidate, at its bound revision,
  # with its bound allocation unreleased; the candidate set is that grant.
  defp bound_candidates(_refusal, candidate_ids, nil, _now), do: {:ok, candidate_ids}

  # The uniqueness observation is fresh, under the head, over every grant of
  # the tenant (a read, never a lock): a G-R0 grant committed after the
  # candidates were discovered refuses (round 11, Codex 01a13625). The bound
  # grant itself must be one of the share-locked candidates.
  defp bound_candidates(refusal, candidate_ids, binding, now) do
    shaped =
      ModelCallGrant
      |> Ash.Query.filter(tenant_id == ^refusal.tenant_id)
      |> Ash.Query.load(:allocations)
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&g_r0?(&1, now))

    case shaped do
      [%{id: id, revision: revision} = grant]
      when id == binding.grant_id and revision == binding.grant_revision ->
        bound_allocation_present(refusal, grant, binding, id in candidate_ids)

      _ ->
        mismatch(refusal)
    end
  end

  defp bound_allocation_present(refusal, _grant, _binding, false = _locked?),
    do: mismatch(refusal)

  defp bound_allocation_present(refusal, grant, binding, true = _locked?) do
    if Enum.any?(grant.allocations, &(&1.id == binding.allocation_id)),
      do: {:ok, [grant.id]},
      else: mismatch(refusal)
  end

  defp bound_allocation(_refusal, _allocation, nil), do: :ok

  defp bound_allocation(refusal, allocation, binding),
    do: if(allocation.id == binding.allocation_id, do: :ok, else: mismatch(refusal))

  defp mismatch(refusal), do: {:error, %{refusal | reason: :calibration_grant_mismatch}}

  # Recorded only next to an admitted calibration tuple, from the marker.
  defp binding_record(nil, _binding), do: nil
  defp binding_record(_tuple, nil), do: nil

  defp binding_record(_tuple, binding) do
    %{
      "grant_id" => binding.grant_id,
      "grant_revision" => binding.grant_revision,
      "allocation_id" => binding.allocation_id,
      "profile_id" => Atom.to_string(binding.profile_id)
    }
  end

  # The console's claim is recorded only next to an admitted calibration
  # tuple (R0-07 E4c-2), never on its own.
  defp claim_record(nil, _gate), do: nil
  defp claim_record(_tuple, %{claim: claim}) when is_binary(claim), do: %{"instance_id" => claim}
  defp claim_record(_tuple, _gate), do: nil

  defp admission_gate(refusal, run, gate) do
    call = %{profile_id: refusal.profile_id, purpose: refusal.purpose}

    case Gate.admit_reservation(run, call, gate.store, gate.calibration) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, reason, check} -> {:error, %{refusal | reason: reason, check: check}}
    end
  end

  @doc "Whether `grant` admits calls of `profile_id` at `now` (status, window, profile)."
  def grant_eligible?(grant, profile_id, now) do
    grant.status == :active and DateTime.compare(grant.starts_at, now) != :gt and
      DateTime.compare(now, grant.expires_at) == :lt and profile_id in grant.profile_ids
  end

  @doc "Whether `allocation` may fund a call of `profile_id` in `bucket` at `now`."
  def allocation_eligible?(allocation, profile_id, bucket, now) do
    (is_nil(allocation.profile_id) or allocation.profile_id == profile_id) and
      bucket in allocation.applies_to and available?(allocation, now)
  end

  @doc """
  An allocation is available at `now` iff (`released_at` is set, or
  `available_from` is unset or ≤ `now`) and (`available_until` is unset or
  `now` < it).
  """
  def available?(allocation, now) do
    opened? =
      not is_nil(allocation.released_at) or is_nil(allocation.available_from) or
        DateTime.compare(allocation.available_from, now) != :gt

    open? =
      is_nil(allocation.available_until) or
        DateTime.compare(now, allocation.available_until) == :lt

    opened? and open?
  end

  ## Launch admission (C9-03)

  @doc """
  Launch admission's share locks (`SdrAgent.Agents.admit_launch/3`): with
  the run and invocation rows locked and before the chain head, locks the
  grant and then the allocation the invocation was charged to `FOR SHARE`
  (the reservation's order), so no grant editor commits a change to them
  until the launch commits, and the launch waits for an editor that holds
  them. A row without a charge (generation 1) locks nothing.
  """
  def lock_charge(invocation) do
    for {resource, id} <- [
          {ModelCallGrant, invocation.grant_id},
          {ModelCallAllocation, invocation.allocation_id}
        ],
        not is_nil(id) do
      resource
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read!(authorize?: false)
    end

    :ok
  end

  @doc """
  The complete non-room launch predicate for the owned, `:reserved`
  ClaudeCLI `invocation` of the locked `run` at `now` (read under the chain
  head), with the server's `effective_profile`. Room is not re-checked: the
  attempt was charged at reservation. Returns `:ok` or `{:error, reason,
  check}`:

    * `:run_not_running_at_launch` (the run's status) — the run was stopped
      (succeeded, failed, budget_exhausted or cancelled) while its call was
      queued: only a `:running` run reserves and settles model calls
      (`SdrAgent.Agents.Changes.BudgetCounter`), so no other status may
      launch one;
    * `:legacy_invocation_without_grant` (`:legacy_generation`) — a row
      written before R0 (generation 1);
    * `:profile_mismatch_at_launch` (`:profile_mismatch`) — reserved under
      another profile than the server runs;
    * only for an exempted calibration call (`expected`, see
      `calibration_launch/1`; packet 8.13 C8): `:calibration_not_authorized`
      with `:exemption_scope` (not a `:proof` run, or the run has an
      Operation), `:exemption_input` (the invocation's prompt or output
      schema reference is not the expected one) or `:exemption_request`
      (its stored request is not the expected one);
    * the R0-07 slice B admission gate (`Gate.admit_launch/3`, with the
      store observation `store` taken before the launch's locks):
      `:calibration_not_authorized`, `:calibration_evidence_pending`,
      `:result_gate_inactive`, `:witness_store_untrusted` or
      `:tuple_not_promoted`, with its check;
    * `:calibration_grant_mismatch` (`:binding_changed` or
      `:binding_unrecorded`) — a G-R0 binding recorded at reservation no
      longer matches the charge, the profile or the grant's revision, or
      the recorded binding is malformed (packet 8.3); with `expected`, a
      recorded binding is required (`:binding_unrecorded` when there is
      none);
    * `:grant_ineligible_at_launch` with the failed check: `:grant_missing`,
      `:grant_revoked`, `:grant_not_started`, `:grant_expired`,
      `:profile_not_in_grant`, `:allocation_not_in_grant`,
      `:allocation_profile_restricted`, `:bucket_not_applicable` or
      `:allocation_unavailable`.
  """
  def launch_check(run, invocation, effective_profile, now, store, expected \\ nil) do
    cond do
      run.status != :running ->
        {:error, :run_not_running_at_launch, run.status}

      invocation.ledger_generation != 2 ->
        {:error, :legacy_invocation_without_grant, :legacy_generation}

      invocation.profile_id != effective_profile ->
        {:error, :profile_mismatch_at_launch, :profile_mismatch}

      true ->
        with :ok <- ordinary_scope(run, expected),
             :ok <- exemption(run, invocation, expected),
             :ok <- Gate.admit_launch(run, invocation, store),
             :ok <- SwitchFence.launch(run.tenant_id, invocation.id),
             :ok <- launch_binding(invocation, run.tenant_id, is_map(expected)),
             do: launch_terms(run, invocation, now)
    end
  end

  @doc """
  The `calibration_launch:` option of `Agents.admit_launch/3` (packet 8.13):
  `nil` when it is absent (ordinary launch behaviour), the expectation when
  it is exactly `%{run_id:, tenant_id:, request_sha256:, prompt_ref:,
  schema_ref:}` (lowercase UUID strings, a 32-byte request SHA-256, and
  references of exactly `%{id:, version:, sha256:}` with a 32-byte
  SHA-256), and `:invalid` for any other present value, an explicit `nil`
  included. It can only add refusals.
  """
  def calibration_launch(opts) do
    case {Keyword.fetch(opts, :ordinary_launch), Keyword.fetch(opts, :calibration_launch)} do
      {:error, :error} -> nil
      {:error, {:ok, value}} -> if expectation?(value), do: value, else: :invalid
      {{:ok, true}, :error} -> :ordinary
      _invalid -> :invalid
    end
  end

  # L2 E3: the ordinary mode refuses a :proof run (the locked run decides;
  # recorded authority stays with the gate's own re-read).
  defp ordinary_scope(%{usage_origin: :proof}, :ordinary),
    do: {:error, :calibration_not_authorized, :ordinary_scope}

  defp ordinary_scope(_run, _expected), do: :ok

  @expectation_keys [:prompt_ref, :request_sha256, :run_id, :schema_ref, :tenant_id]
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  defp expectation?(%{} = expected) do
    Enum.sort(Map.keys(expected)) == @expectation_keys and uuid?(expected.run_id) and
      uuid?(expected.tenant_id) and sha256?(expected.request_sha256) and
      ref?(expected.prompt_ref) and ref?(expected.schema_ref)
  end

  defp expectation?(_value), do: false

  defp ref?(%{id: id, version: version, sha256: sha256} = ref),
    do: map_size(ref) == 3 and is_binary(id) and is_binary(version) and sha256?(sha256)

  defp ref?(_ref), do: false

  defp uuid?(value), do: is_binary(value) and value =~ @uuid
  defp sha256?(value), do: is_binary(value) and byte_size(value) == 32

  # Packet 8.13 C8: an exempted calibration call launches only a proof run's
  # own call (no Operation) with the code-owned input it was reserved with.
  defp exemption(_run, _invocation, nil), do: :ok
  defp exemption(_run, _invocation, :ordinary), do: :ok

  defp exemption(run, invocation, expected) do
    cond do
      run.usage_origin != :proof or not is_nil(run.operation_id) ->
        {:error, :calibration_not_authorized, :exemption_scope}

      not fixed_input?(invocation, expected) ->
        {:error, :calibration_not_authorized, :exemption_input}

      invocation.request_sha256 != expected.request_sha256 ->
        {:error, :calibration_not_authorized, :exemption_request}

      true ->
        :ok
    end
  end

  defp fixed_input?(invocation, %{prompt_ref: prompt, schema_ref: schema}) do
    {invocation.prompt_template_id, invocation.prompt_template_version,
     invocation.prompt_template_sha256} == {prompt.id, prompt.version, prompt.sha256} and
      {invocation.output_schema_id, invocation.output_schema_version,
       invocation.output_schema_sha256} == {schema.id, schema.version, schema.sha256}
  end

  # The G-R0 binding recorded at reservation (packet 8.3 "At launch"): the
  # charge and profile are still the bound ones, and the grant (read under
  # its share lock) is still at the bound revision. An amendment or
  # revocation refuses, a malformed recorded binding is never read as a
  # legacy absence, and there is no fallback to another budget.
  defp launch_binding(invocation, tenant_id, required?) do
    case Gate.recorded_binding(invocation) do
      {:ok, nil} ->
        if required?,
          do: {:error, :calibration_grant_mismatch, :binding_unrecorded},
          else: :ok

      {:ok, binding} ->
        if bound?(invocation, binding, charged(ModelCallGrant, invocation.grant_id, tenant_id)),
          do: :ok,
          else: {:error, :calibration_grant_mismatch, :binding_changed}

      {:error, :binding_unrecorded} ->
        {:error, :calibration_grant_mismatch, :binding_unrecorded}
    end
  end

  defp bound?(_invocation, _binding, nil), do: false

  defp bound?(invocation, binding, grant) do
    {invocation.grant_id, invocation.allocation_id, invocation.profile_id, grant.revision} ==
      {binding.grant_id, binding.allocation_id, binding.profile_id, binding.grant_revision}
  end

  defp launch_terms(run, invocation, now) do
    with {:ok, grant} <- launch_grant(invocation, run.tenant_id, now),
         :ok <- launch_allocation(invocation, grant, run, now) do
      :ok
    else
      {:error, check} -> {:error, :grant_ineligible_at_launch, check}
    end
  end

  defp launch_grant(invocation, tenant_id, now) do
    grant = charged(ModelCallGrant, invocation.grant_id, tenant_id)

    cond do
      is_nil(grant) -> {:error, :grant_missing}
      grant.status != :active -> {:error, :grant_revoked}
      DateTime.compare(grant.starts_at, now) == :gt -> {:error, :grant_not_started}
      DateTime.compare(now, grant.expires_at) != :lt -> {:error, :grant_expired}
      invocation.profile_id not in grant.profile_ids -> {:error, :profile_not_in_grant}
      true -> {:ok, grant}
    end
  end

  defp launch_allocation(invocation, grant, run, now) do
    allocation = charged(ModelCallAllocation, invocation.allocation_id, run.tenant_id)
    bucket = UsageBucket.bucket(run.usage_origin, invocation.purpose)

    cond do
      is_nil(allocation) or allocation.grant_id != grant.id ->
        {:error, :allocation_not_in_grant}

      allocation.profile_id not in [nil, invocation.profile_id] ->
        {:error, :allocation_profile_restricted}

      is_nil(bucket) or bucket not in allocation.applies_to ->
        {:error, :bucket_not_applicable}

      not available?(allocation, now) ->
        {:error, :allocation_unavailable}

      true ->
        :ok
    end
  end

  # A fresh read of the charged row in the run's tenant (nil otherwise).
  defp charged(_resource, nil, _tenant_id), do: nil

  defp charged(resource, id, tenant_id) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp origin(%Refusal{usage_origin: nil} = refusal),
    do: {:error, %{refusal | reason: :no_usage_origin}}

  defp origin(_refusal), do: :ok

  defp eligible_grants(refusal, candidate_ids, now) do
    ModelCallGrant
    |> Ash.Query.filter(
      id in ^candidate_ids and tenant_id == ^refusal.tenant_id and status == :active and
        starts_at <= ^now and expires_at > ^now
    )
    |> Ash.Query.load(:allocations)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(
      &(&1.tenant_id == refusal.tenant_id and grant_eligible?(&1, refusal.profile_id, now))
    )
    |> case do
      [] -> {:error, %{refusal | reason: :no_eligible_grant}}
      grants -> {:ok, grants}
    end
  end

  defp one_allocation(refusal, grants, now) do
    matches =
      for grant <- grants,
          allocation <- grant.allocations,
          allocation.tenant_id == refusal.tenant_id and allocation.grant_id == grant.id,
          allocation_eligible?(allocation, refusal.profile_id, refusal.bucket, now),
          do: {grant, allocation}

    case matches do
      [{grant, allocation}] ->
        {:ok, grant, allocation}

      [] ->
        {:error, %{refusal | reason: :no_allocation, grant_id: single_grant(grants)}}

      _ ->
        {:error,
         %{
           refusal
           | reason: :ambiguous_allocation,
             grant_id: single_grant(matches_grants(matches))
         }}
    end
  end

  defp matches_grants(matches), do: Enum.map(matches, &elem(&1, 0))

  defp single_grant(grants) do
    case Enum.uniq_by(grants, & &1.id) do
      [grant] -> grant.id
      _ -> nil
    end
  end

  defp room(refusal, grant, now) do
    cond do
      consumed(grant_id: grant.id) >= grant.total_attempts ->
        {:error, %{refusal | reason: {:budget_exhausted, :grant}}}

      grant.per_utc_day_attempts && consumed_today(grant.id, now) >= grant.per_utc_day_attempts ->
        {:error, %{refusal | reason: {:budget_exhausted, :grant_day}}}

      consumed(allocation_id: refusal.allocation_id) >= allocation_attempts(grant, refusal) ->
        {:error, %{refusal | reason: {:budget_exhausted, :allocation}}}

      true ->
        :ok
    end
  end

  defp allocation_attempts(grant, refusal),
    do: Enum.find(grant.allocations, &(&1.id == refusal.allocation_id)).attempts

  defp consumed(filter) do
    ModelInvocation
    |> Ash.Query.do_filter(filter)
    |> Ash.count!(authorize?: false)
  end

  defp consumed_today(grant_id, now) do
    from = DateTime.new!(DateTime.to_date(now), ~T[00:00:00.000000], "Etc/UTC")
    until = DateTime.add(from, 1, :day)

    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant_id and reserved_at >= ^from and reserved_at < ^until)
    |> Ash.count!(authorize?: false)
  end

  ## Refusal reporting

  @doc """
  Commits `refusal` in its own guarded transaction as `agent_runtime`: the
  run's Operation (if any) is locked `FOR SHARE` first, as Operation
  lifecycle writers lock it before the head, then the chain head, then an
  unresolved (open or acknowledged)
  `budget_exhausted` Failure of the same run with the same detail — the
  dedupe key `(reason, grant or none, run)`, stored as the Failure's
  redacted detail and matched by its `detail_sha256` — is reused, or a new
  critical one is opened; then `model.reservation.refused` is appended
  (reason, bucket, profile, grant/allocation, failure id and whether it
  was deduplicated). Concurrent and repeated refusals therefore open one
  Failure. Returns `{:ok, %Refused{}}` — the exact receipt of this refusal
  — or `{:error, error}`.
  """
  def record_refusal(%Refusal{} = refusal) do
    agent = Actor.system(:agent_runtime, refusal.tenant_id)
    detail = detail(refusal)

    Audit.transaction(fn ->
      with :ok <- lock_operation(refusal),
           {:ok, _head} <- Kernel.lock_head(refusal.tenant_id),
           {:ok, failure, deduplicated?} <- failure(refusal, detail, agent),
           {:ok, event} <- Audit.append(event(refusal, failure, deduplicated?), actor: agent) do
        %Refused{
          reason: refusal.reason,
          failure_id: failure.id,
          event_id: event.id,
          agent_run_id: refusal.agent_run_id,
          request_id: refusal.idempotency_key,
          stage: :reservation,
          check: refusal.check
        }
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # Operation lifecycle writers lock the Operation FOR UPDATE, then the chain
  # head; the Failure's operation FK (FOR KEY SHARE) would otherwise wait for
  # them while this transaction holds the head. Taken first, it orders the
  # refusal before or after the writer.
  defp lock_operation(%Refusal{operation_id: id}), do: lock_operation_share(id)

  @doc """
  Locks the Operation `id` `FOR SHARE` (nil locks nothing), as refusal
  recording and launch admission take it before the chain head: Operation
  lifecycle writers lock it `FOR UPDATE`, then the head.
  """
  def lock_operation_share(nil), do: :ok

  def lock_operation_share(id) do
    SdrAgent.Operations.Operation
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read!(authorize?: false)

    :ok
  end

  @doc "Whether `reason` is an R0-07 admission-gate refusal (a `provider_error` Failure)."
  def admission_reason?(reason), do: reason in Gate.reasons() or reason in fence_reasons()

  @doc """
  The model profile switch fence's refusal reasons (C2-02b1,
  `SdrAgent.Agents.Admission.SwitchFence`): admission reasons, recorded as a
  `provider_error` and stopping the run `:model_not_admitted`.
  """
  def fence_reasons, do: SwitchFence.reasons()

  defp failure_class(reason),
    do: if(admission_reason?(reason), do: :provider_error, else: :budget_exhausted)

  @doc "The detail reason recorded for a refusal reason (R0 packet, Operations.Failure)."
  def reason_name({:budget_exhausted, :grant}), do: "grant_exhausted"
  def reason_name({:budget_exhausted, :grant_day}), do: "grant_day_exhausted"
  def reason_name({:budget_exhausted, :allocation}), do: "allocation_exhausted"
  def reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure(refusal, detail, agent) do
    sha256 = :crypto.hash(:sha256, Redactor.redact(detail))

    Failure
    |> Ash.Query.for_read(:read, %{}, actor: agent)
    |> Ash.Query.filter(
      tenant_id == ^refusal.tenant_id and class == ^failure_class(refusal.reason) and
        subject_resource == ^@run_resource and subject_id == ^refusal.agent_run_id and
        detail_sha256 == ^sha256 and status in [:open, :acknowledged]
    )
    |> Ash.Query.sort(occurred_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> case do
      {:ok, %Failure{} = existing} -> {:ok, existing, true}
      {:ok, nil} -> open_failure(refusal, detail, agent)
      {:error, error} -> {:error, error}
    end
  end

  defp open_failure(refusal, detail, agent) do
    attrs = %{
      operation_id: refusal.operation_id,
      subject_resource: @run_resource,
      subject_id: refusal.agent_run_id,
      class: failure_class(refusal.reason),
      severity: :critical,
      retryable: false,
      message: message(refusal),
      detail: detail
    }

    with {:ok, failure} <- Operations.open_failure(attrs, actor: agent),
         do: {:ok, failure, false}
  end

  defp message(%{reason: reason} = refusal) when reason in [:profile_switch_fenced] do
    "model call not admitted: #{reason_name(reason)} (#{check_label(refusal.check)}) " <>
      "(profile #{refusal.profile_id}); a model profile switch is in progress"
  end

  defp message(refusal) do
    if admission_reason?(refusal.reason) do
      "model call not admitted: #{reason_name(refusal.reason)} (#{check_label(refusal.check)}) " <>
        "(profile #{refusal.profile_id}); no real call is made until the result gate, " <>
        "the witness store and the promoted tuple admit it"
    else
      "model call reservation refused: #{reason_name(refusal.reason)} " <>
        "(bucket #{refusal.bucket || "none"}, profile #{refusal.profile_id}); " <>
        "no real call is made until an admin grants an eligible allocation"
    end
  end

  # The dedupe key, stored as the Failure's detail (the check only when set).
  defp detail(refusal) do
    %{
      "kind" => "model_reservation_refused",
      "reason" => reason_name(refusal.reason),
      "grant_id" => refusal.grant_id || "none",
      "agent_run_id" => refusal.agent_run_id
    }
    |> then(&if(refusal.check, do: Map.put(&1, "check", name(refusal.check)), else: &1))
    |> Canonical.encode!()
  end

  defp event(refusal, failure, deduplicated?) do
    %{
      event_type: "model.reservation.refused",
      category: :model,
      subject_resource: @run_resource,
      subject_id: refusal.agent_run_id,
      action: "reserve",
      agent_run_id: refusal.agent_run_id,
      correlation_id: refusal.correlation_id,
      idempotency_key: refusal.idempotency_key,
      payload:
        %{
          "reason" => reason_name(refusal.reason),
          "usage_origin" => name(refusal.usage_origin),
          "purpose" => name(refusal.purpose),
          "bucket" => name(refusal.bucket),
          "profile_id" => name(refusal.profile_id),
          "grant_id" => refusal.grant_id,
          "allocation_id" => refusal.allocation_id,
          "failure_id" => failure.id,
          "deduplicated" => deduplicated?
        }
        |> then(&if(refusal.check, do: Map.put(&1, "check", name(refusal.check)), else: &1))
    }
  end

  defp name(nil), do: nil
  defp name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp name(check), do: check_name(check)

  @doc """
  The metadata-only name of a refusal `check`: the atom's name, or
  `"check:id"` for a check that names the blocking row (row B4').
  """
  def check_name(check) when is_atom(check), do: Atom.to_string(check)
  def check_name({check, id}) when is_atom(check) and is_binary(id), do: "#{check}:#{id}"

  @doc """
  The human label of a refusal `check` for a Failure message: its name
  without any row id (the id stays in the detail and event, where it is
  structured metadata rather than prose).
  """
  def check_label({check, _id}) when is_atom(check), do: Atom.to_string(check)
  def check_label(check), do: check_name(check)
end
