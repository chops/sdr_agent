# D-237: the prototype gate exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Release do
    @moduledoc """
    The prototype gate's release decision (ADR-0005 D-237 amendment item 5;
    interfaces r6 IF-4; Codex A1, A2). It is reached only through
    `SdrAgent.Agents.ResultGate.finalize/4`, which dispatches here at its
    head in prototype runtime with its own four arguments; no other module
    references it (an xref test asserts this). No caller supplies the
    authority, the basis or a decision: options other than `guard:` are
    ignored.

    **One transaction, in the finalizer's lock order:** the run `FOR UPDATE`,
    its Operation `FOR SHARE`, the invocation `FOR SHARE`; then plain reads
    of every wire-witness link of the invocation (current or superseded;
    link writers lock the invocation `FOR UPDATE`, which this transaction
    holds `FOR SHARE`) and every `reconciliation_required` Failure of it
    (live or resolved): the known evidence; then the selected cause
    `FOR UPDATE`; then the chain head. No lock is taken after the head.
    In test-seam builds only, a `before_head` hook (see the source) runs
    just before the head.

    **Under the head, the Failures again** (Codex 0235e6fd ruling 2). Failure
    writers append under the chain head, so the invocation's Failures are
    read again there (a plain read; still no lock after the head). If they
    change the mismatch branch's cause, the known-evidence code or the
    preferred bound cause, nothing is written: the transaction rolls back
    and the gate decides once more, refusal-only, taking its locks before
    the head again. A second change returns `{:error, :recheck_failed}` with
    nothing written; the facade returns it unchanged and the sweeper leaves
    it to its next pass (D-237 TF-1). There is no third attempt and no
    fallback.

    **Outcomes** (the existing `finalize/4` shapes; this increment never
    releases):

      * a mismatch link (current or superseded), or a mismatch receipt:
        withheld `witness_mismatch` on the invocation's critical cause as run
        recovery selects it (`ResultGate.Recovery.mismatch/2`); the run stops
        `witness_mismatch`;
      * `{:interrupted, _}` and `{:timeout, _}` otherwise keep their existing
        outcomes (`gate_interrupted`; `witness_timeout` / `capture_pending`)
        and causes; neither ever releases;
      * otherwise withheld `prototype_authority_refused` with one code, known
        evidence first: `known_integrity_signal` (a critical Failure, live or
        resolved; a usable live critical stays the bound cause and no
        mismatch is claimed), `witness_evidence_present` (any other link, or
        a live warning, which stays the bound cause); then `binding_mismatch`
        (the live binding), `witness_mode_mismatch` (the observation is not
        the absent store's empty receipt; a reconciled receipt is recorded
        with its true classification `:reconciled`), and
        `authority_unrecorded` (no single original reservation event records
        a `prototype_authority`). No reservation records one yet, so a
        recorded one is refused `authority_mismatch`; the remaining
        eligibility checks, the release and its basis come with the
        recording. The run stops `witness_unreconciled`.
    """

    require Ash.Query

    alias SdrAgent.Actor
    alias SdrAgent.Agents.AgentRun
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ResultGate
    alias SdrAgent.Agents.ResultGate.Recovery
    alias SdrAgent.Agents.WireWitnessLink
    alias SdrAgent.Agents.Witness
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Operations.Failure
    alias SdrAgent.Prototype.Admission, as: PrototypeAdmission
    alias SdrAgent.Repo

    @subject "SdrAgent.Agents.ModelInvocation"
    @live [:open, :acknowledged]
    @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

    @doc false
    @spec finalize(struct(), map(), {:ok | :timeout | :interrupted, map()}, keyword()) ::
            {:withheld, struct(), struct()} | {:error, term()}
    def finalize(invocation, gate, {kind, receipt} = outcome, opts)
        when kind in [:ok, :timeout, :interrupted] and is_map(receipt) do
      seamed(invocation, fn -> bounded(invocation, gate, outcome, opts) end)
    end

    defp bounded(invocation, gate, outcome, opts) do
      guard = Keyword.get(opts, :guard, fn _run -> :ok end)
      actor = Actor.system(:agent_runtime, invocation.tenant_id)
      attempt = fn -> attempt(invocation, gate, outcome, {guard, actor}) end

      # A bounded repeat: one more refusal-only attempt after a failed recheck;
      # a second failure is returned, never a third attempt.
      case attempt.() do
        {:error, :recheck_failed} -> attempt.()
        result -> result
      end
    end

    defp attempt(invocation, gate, outcome, {guard, actor}) do
      fn -> locked(invocation, gate, outcome, guard, actor) end
      |> Audit.transaction()
      |> case do
        {:ok, result} -> result
        {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
        {:error, error} -> {:error, error}
      end
    end

    defp locked(invocation, gate, {_kind, receipt} = outcome, guard, actor) do
      tenant_id = invocation.tenant_id

      with {:ok, run} <- ResultGate.lock(AgentRun, gate.run_id, tenant_id, "FOR UPDATE"),
           :ok <- ResultGate.own_run(run, invocation, gate),
           :ok <- ResultGate.lock_operation(run, tenant_id),
           :ok <- guard.(run),
           {:ok, invocation} <-
             ResultGate.lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE"),
           evidence = known_evidence(invocation),
           plan = plan(outcome, evidence, invocation),
           :ok <- usable_after_live_refusal(plan),
           {:ok, plan, cause} <- hold(plan, receipt, evidence, {invocation, run}),
           :ok <- before_head(invocation),
           {:ok, _head} <- Kernel.lock_head(tenant_id),
           :ok <- recheck(plan, cause, evidence, {invocation, run}) do
        ResultGate.under_head(plan, invocation, run, nil, cause, actor)
      else
        {:error, error} -> Repo.rollback(error)
      end
    end

    # Test-seam builds only (`:claude_cli_test_seams`, config/test.exs; Codex
    # 2c9450b7 ruling 2): a `before_head: fun/1` in this module's Application
    # env runs on the locked invocation after the plain reads and the cause
    # lock, before the chain head. Its return value is ignored: it supplies no
    # authority, decision or cause and skips no check. Every other build has
    # no callback path.
    if @test_seams do
      defp before_head(invocation) do
        case Keyword.get(Application.get_env(:sdr_agent, __MODULE__, []), :before_head) do
          fun when is_function(fun, 1) ->
            _ignored = fun.(invocation)
            :ok

          _none ->
            :ok
        end
      end
    else
      defp before_head(_invocation), do: :ok
    end

    # D-237 TF-1 RED seam (Codex cc688175 RL; plan r2 section 3), test-seam
    # builds only: a `finalize_result: fun/1` in this module's Application env
    # injects a TECHNICAL outcome in place of the bounded attempts, so the
    # facade's and the sweeper's handling of a failed finalize can be tested.
    # A deny/no-positive declaration: the fun returns `{:error, _}` (injected
    # as the outcome) or `:passthrough` (the real attempts run, for another
    # invocation); any other value (a release, a withheld decision, a
    # success) raises a fixed, value-free ArgumentError, so it can never
    # manufacture a decision. Every other build has no seam path.
    if @test_seams do
      defp seamed(invocation, attempts) do
        case Keyword.get(Application.get_env(:sdr_agent, __MODULE__, []), :finalize_result) do
          fun when is_function(fun, 1) ->
            case fun.(invocation) do
              {:error, _error} = injected -> injected
              :passthrough -> attempts.()
              _other -> raise ArgumentError, "finalize_result injects {:error, _} only"
            end

          _none ->
            attempts.()
        end
      end
    else
      defp seamed(_invocation, attempts), do: attempts.()
    end

    ## Known evidence (plain reads, no lock)

    defp known_evidence(invocation) do
      links =
        WireWitnessLink
        |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
        |> Ash.Query.filter(
          tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
        )
        |> Ash.read!()

      %{links: links, failures: failures(invocation)}
    end

    defp failures(invocation) do
      Failure
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and subject_resource == @subject and
          subject_id == ^invocation.id and class == :reconciliation_required
      )
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.read!()
    end

    ## The plan

    defp plan({kind, receipt}, evidence, invocation) do
      cond do
        Enum.any?(evidence.links, &(&1.link_status == :mismatch)) or
            Map.get(receipt, :status) == :mismatch ->
          ResultGate.plan(:ok, %{status: :mismatch})

        kind in [:interrupted, :timeout] ->
          ResultGate.plan(kind, receipt)

        true ->
          %{
            release?: false,
            reason: :prototype_authority_refused,
            classification: classification(receipt),
            prototype_refusal: refusal_code(receipt, evidence, invocation)
          }
      end
    end

    # The true observation classification (amendment item 5; Codex 2c9450b7
    # ruling 3b): a reconciled receipt is recorded as :reconciled.
    defp classification(%{status: :skipped}), do: :store_unconfigured
    defp classification(%{status: :reconciled}), do: :reconciled

    defp classification(%{codes: codes} = receipt) when is_list(codes),
      do: ResultGate.plan(:ok, receipt).classification

    defp classification(_receipt), do: :unclassified

    # Known evidence first, then the live binding, the observation and the
    # recorded authority.
    defp refusal_code(receipt, evidence, invocation) do
      with :ok <- no_known_evidence(evidence),
           {:ok, live} <- step(PrototypeAdmission.live()),
           :ok <- absent_observation(receipt, live),
           {:ok, _recorded} <- step(PrototypeAdmission.recorded(invocation)) do
        :authority_mismatch
      else
        {:refuse, code} -> code
      end
    end

    defp step({:error, _reason, check}), do: {:refuse, check}
    defp step(other), do: other

    defp no_known_evidence(%{links: links, failures: failures}) do
      cond do
        Enum.any?(failures, &(&1.severity == :critical)) -> {:refuse, :known_integrity_signal}
        links != [] -> {:refuse, :witness_evidence_present}
        Enum.any?(failures, &(&1.status in @live)) -> {:refuse, :witness_evidence_present}
        true -> :ok
      end
    end

    defp absent_observation(%{status: :skipped, link_id: nil}, %{binding: binding}) do
      if binding.witness_mode == "absent" and is_nil(Witness.store_root()),
        do: :ok,
        else: {:refuse, :witness_mode_mismatch}
    end

    defp absent_observation(_receipt, _live), do: {:refuse, :witness_mode_mismatch}

    ## The cause, locked before the head

    # D-237 TF-2 (plan r2): only the refusal code `binding_mismatch` can
    # follow a live read (`refusal_code/3`); one state probe before the cause
    # read. An error leaves through `locked/5`'s owner rollback.
    defp usable_after_live_refusal(%{prototype_refusal: :binding_mismatch}),
      do: PrototypeAdmission.state_probe()

    defp usable_after_live_refusal(_plan), do: :ok

    defp hold(%{reason: :witness_mismatch}, _receipt, _evidence, {invocation, run}),
      do: Recovery.mismatch(invocation, run)

    defp hold(plan, receipt, evidence, {invocation, run} = held) do
      result =
        case preferred(Map.get(plan, :prototype_refusal), evidence, held) do
          %Failure{id: id} -> ResultGate.lock(Failure, id, invocation.tenant_id, "FOR UPDATE")
          nil -> ResultGate.select_cause(plan, receipt, invocation, run)
        end

      with {:ok, cause} <- result, do: {:ok, plan, cause}
    end

    # A usable live critical (known_integrity_signal) or warning
    # (witness_evidence_present) stays the bound cause.
    defp preferred(:known_integrity_signal, evidence, held),
      do: live_cause(evidence, held, :critical)

    defp preferred(:witness_evidence_present, evidence, held),
      do: live_cause(evidence, held, :warning)

    defp preferred(_code, _evidence, _held), do: nil

    defp live_cause(evidence, {invocation, run}, severity) do
      Enum.find(evidence.failures, fn failure ->
        failure.severity == severity and failure.status in @live and
          ResultGate.gate_capable?(failure, invocation, run)
      end)
    end

    ## Under the head: the Failures again

    # Failure writers append under the chain head, so the invocation's
    # Failures are read again here: a plain read, no lock (the links stay as
    # read: link writers lock the invocation FOR UPDATE). Evidence that changes
    # the branch's cause or the refusal code fails the recheck: the attempt
    # rolls back with nothing written, and `finalize/4` decides once more.
    defp recheck(plan, cause, evidence, {invocation, _run} = held) do
      reread = %{evidence | failures: failures(invocation)}

      if unchanged?(plan, cause, {evidence, reread}, held),
        do: :ok,
        else: {:error, :recheck_failed}
    end

    # A mismatch: the critical cause run recovery would select now.
    defp unchanged?(%{reason: :witness_mismatch}, cause, {_evidence, reread}, held),
      do: mismatch_cause_id(reread, held) == cause_id(cause)

    # A refusal: the same known-evidence code and the same preferred cause.
    defp unchanged?(%{prototype_refusal: code}, _cause, {evidence, reread}, held) do
      evidence_code(reread) == evidence_code(evidence) and
        cause_id(preferred(code, reread, held)) == cause_id(preferred(code, evidence, held))
    end

    # Interrupted and timed-out gates: neither branch nor cause depends on
    # the known Failures.
    defp unchanged?(_plan, _cause, _evidence, _held), do: true

    defp evidence_code(evidence) do
      case no_known_evidence(evidence) do
        {:refuse, code} -> code
        :ok -> nil
      end
    end

    # As `ResultGate.Recovery.mismatch/2` selects: the oldest gate-capable live
    # critical, nil when there is no live critical, :unbound otherwise.
    defp mismatch_cause_id(%{failures: failures}, {invocation, run}) do
      live = Enum.filter(failures, &(&1.severity == :critical and &1.status in @live))

      case {live, Enum.find(live, &ResultGate.gate_capable?(&1, invocation, run))} do
        {[], nil} -> nil
        {_live, %Failure{id: id}} -> id
        {_unusable, nil} -> :unbound
      end
    end

    defp cause_id(nil), do: nil
    defp cause_id(%Failure{id: id}), do: id
  end
end
