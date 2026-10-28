# D-237: the prototype gate exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Admission do
    @moduledoc """
    The prototype branch of real-call admission (ADR-0005 D-237 amendment
    item 4 "Partitioned admission"; interfaces r6 IF-4; Codex A1 and P1). In
    prototype runtime `SdrAgent.Agents.Admission.Gate` dispatches here before
    any scope or eligibility check, and only this path exists: a refusal is
    final, never a fallback to the ordinary promoted-tuple or store checks.

    Refusals are `{:error, :prototype_not_authorized, check}`; an inactive
    result gate stays `{:error, :result_gate_inactive, :inactive}`.

      * **Reservation** (`reservation/4`, under the reservation's locks and
        head, before any grant is read, so a refusal is uncharged), in this
        order: a `:proof` run (`proof_run`); a calibration authority
        (`scope_mismatch`); the live binding against the boot snapshot and
        the compiled policy entry's digest, and the run in the bound tenant
        (`binding_mismatch`); the active result gate; the absent witness
        store (`witness_mode_mismatch`: the snapshot says absent, no root is
        configured and none was observed); the run's origin, the call's
        explicit purpose and its profile in the policy entry and the funded
        scope (`scope_mismatch`). Passing these does not by itself admit a
        charge: `SdrAgent.Agents.Changes.AdmissionCharge` refuses every
        prototype-runtime charge that does not carry the recorded authority.
      * **Launch** (`launch/3`, under `Admission.lock_charge/1` and the head,
        so a refusal keeps its charge): a `:proof` run, the live binding, the
        active gate and the absent store as above, then the
        `prototype_authority` recorded by the invocation's one original
        `model.invocation.reserved` event: a missing, duplicated or non-map
        record is `authority_unrecorded`. No reservation records an authority
        yet, so a recorded one was not recorded by this admission and is
        refused `authority_mismatch`; the comparison of its 14 keys and the
        charged grant's checks come with the recording.

    The release decision (`SdrAgent.Prototype.Release`) reuses `live/0` and
    `recorded/1`.
    """

    alias SdrAgent.Agents.Admission.Gate
    alias SdrAgent.Agents.Witness
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.Prototype

    @reason :prototype_not_authorized

    ## Reservation

    @doc """
    The reservation gate in prototype runtime for `call`
    (`%{profile_id:, purpose:}`) in the locked `run`; `observation` is the
    store observation (`Gate.observe_store/0`) and `calibration` the
    calibration marker's scope. `{:ok, nil}` (no calibration tuple) or
    `{:error, reason, check}`.
    """
    def reservation(run, %{profile_id: profile_id, purpose: purpose}, observation, calibration) do
      with :ok <- not_proof(run),
           :ok <- no_calibration(calibration),
           {:ok, live} <- live(),
           :ok <- same_tenant(run, live),
           :ok <- gate_active(),
           :ok <- witness_absent(live.binding, observation),
           :ok <- in_scope(run.usage_origin, purpose, profile_id, live) do
        {:ok, nil}
      end
    end

    ## Launch

    @doc """
    The launch gate in prototype runtime for the owned reserved `invocation`
    of the locked `run`, its charge share-locked: `{:error, reason, check}`
    (see the moduledoc; no launch is admitted until reservations record
    their authority).
    """
    def launch(run, invocation, observation) do
      with :ok <- not_proof(run),
           {:ok, live} <- live(),
           :ok <- same_tenant(run, live),
           :ok <- gate_active(),
           :ok <- witness_absent(live.binding, observation),
           {:ok, _recorded} <- recorded(invocation) do
        refuse(:authority_mismatch)
      end
    end

    ## Shared checks (also used by the release decision)

    @doc """
    The live prototype state: `{:ok, %{binding:, entry:, funding:}}` when the
    runtime is prototype, `check_live/0` passes and the snapshot records the
    compiled policy entry's digest; `{:error, reason, :binding_mismatch}`
    otherwise.
    """
    def live do
      with :prototype <- Prototype.runtime(),
           :ok <- Prototype.check_live(),
           {:ok, binding} <- Prototype.binding(),
           {:ok, entry} <- Prototype.policy_entry(),
           {:ok, funding} <- Prototype.funding_entry(),
           true <- binding.policy_entry_sha256 == sha256(entry) do
        {:ok, %{binding: binding, entry: entry, funding: funding}}
      else
        _not_live -> refuse(:binding_mismatch)
      end
    end

    @doc """
    The `prototype_authority` recorded by `invocation`'s one original
    `model.invocation.reserved` event: `{:ok, map}` or
    `{:error, reason, :authority_unrecorded}`.
    """
    def recorded(invocation) do
      case Gate.recorded_prototype_authority(invocation) do
        {:ok, %{} = authority} -> {:ok, authority}
        _missing_duplicated_or_malformed -> refuse(:authority_unrecorded)
      end
    end

    ## Internals

    defp refuse(check), do: {:error, @reason, check}

    defp not_proof(%{usage_origin: :proof}), do: refuse(:proof_run)
    defp not_proof(_run), do: :ok

    defp no_calibration(nil), do: :ok
    defp no_calibration(_authority), do: refuse(:scope_mismatch)

    defp same_tenant(%{tenant_id: tenant_id}, %{binding: %{tenant_id: tenant_id}}), do: :ok
    defp same_tenant(_run, _live), do: refuse(:binding_mismatch)

    defp gate_active,
      do: if(Gate.active?(), do: :ok, else: {:error, :result_gate_inactive, :inactive})

    # The store is absent: the snapshot says so, no root is configured, and
    # no root was observed. A pure comparison (no filesystem I/O).
    defp witness_absent(binding, observation) do
      observed_root? = match?(%{root: root} when not is_nil(root), observation)

      if binding.witness_mode == "absent" and is_nil(Witness.store_root()) and not observed_root?,
        do: :ok,
        else: refuse(:witness_mode_mismatch)
    end

    # The run's origin, the call's purpose and its profile are in the policy
    # entry and in the funding entry's funded scope.
    defp in_scope(origin, purpose, profile_id, %{entry: entry, funding: funding}) do
      funded? =
        Enum.any?(funding.funded_scope, fn {funded_origin, purposes} ->
          funded_origin == origin and purpose in purposes
        end)

      if origin in entry.usage_origins and purpose in entry.purposes and
           profile_id in entry.identity.profile_ids and profile_id in funding.profile_ids and
           funded?,
         do: :ok,
         else: refuse(:scope_mismatch)
    end

    defp sha256(term), do: Base.encode16(Canonical.sha256(term), case: :lower)
  end
end
