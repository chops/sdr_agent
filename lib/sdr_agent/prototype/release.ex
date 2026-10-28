# D-237: the prototype gate exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Release do
    @moduledoc """
    The prototype gate's release decision (ADR-0005 D-237 amendment items 5
    and 6; interfaces r6 IF-4; Codex A1, A2; b2c α, correction r2 and the
    boundary delta a7bbcac3). It is reached only through
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
    (live or resolved): the known evidence; then, by branch, the charged
    grant and its one charged allocation `FOR SHARE`
    (`SdrAgent.Agents.Admission.lock_charge/1`; release) or the selected
    cause `FOR UPDATE` (refusal, mismatch); then the chain head. No lock is
    taken after the head. In test-seam builds only, a `before_head` hook
    (see the source) runs just before the head.

    **The plan, before the head,** for a completed call with no mismatch,
    in this order (each refusal is withheld `prototype_authority_refused`
    with one code): known evidence first (`known_integrity_signal`: a
    critical Failure, live or resolved, a usable live critical staying the
    bound cause, no mismatch claimed; `witness_evidence_present`: any other
    link, or a live warning, which stays the bound cause); the live binding
    (`binding_mismatch`); the absent store's empty receipt
    (`witness_mode_mismatch`, a reconciled receipt recorded with its true
    classification `:reconciled`); the one original reservation event's
    authority (`authority_unrecorded`); the identity (`identity_mismatch`:
    ClaudeCLI, generation 2, a compiled profile); the recorded authority by
    the launch's comparator (`authority_mismatch`, `operator_mismatch`,
    `witness_mode_mismatch`); the scope (`scope_mismatch`: a running,
    non-proof run, a completed invocation, origin, purpose and profile in
    the policy and the funded scope); the output (`output_invalid`); the
    charged grant by the launch's checks (`grant_not_eligible`,
    `operator_mismatch`, `grant_changed`; a technical read error rolls the
    attempt back with its identity); the window (`outside_window`, the end
    exclusive). If all hold, the plan is the release.

    **Under the head** (Codex 0235e6fd ruling 2; 3122b0d4 Q2): the Failures
    are read again (plain), and

      * a release plan is recomputed in full at ONE instant read here
        (`SdrAgent.Clock.utc_now/0`): if it is still the release, the
        decision is `released_unverified` / `owner_prototype_unverified`
        with the `d237-basis/1` built from those facts
        (`SdrAgent.Prototype.Basis.build/1`), decided in this gate's own
        `Prelocked` context (`finalizer: :prototype_gate`, bound to that
        instant), and the output is read through
        `SdrAgent.Agents.ReleasedOutput.fetch/2`; the run stays running.
        Anything else writes nothing: the attempt rolls back carrying the
        under-head refusal code;
      * a refusal or mismatch plan keeps the b1 rule: if the known-evidence
        code or the preferred or mismatch cause changed, nothing is written
        and the attempt rolls back; otherwise it is withheld with the
        pre-head code and the run stops (`witness_unreconciled`, or
        `witness_mismatch`).

    **The bounded repeat:** after a failed recheck the gate decides once
    more in REFUSAL-ONLY mode. A release plan becomes a refusal with the
    carried code (or, with none, `{:error, :recheck_failed}` and nothing
    written); under the head a CURRENT refusal at that instant wins over
    the carried code (a `binding_mismatch` first passes the TF-2 state
    probe). A second failed recheck returns `{:error, :recheck_failed}` with
    nothing written; the facade returns it unchanged and the sweeper leaves
    it to its next pass (D-237 TF-1). There is no third attempt, no
    fallback and no release in the repeat.

    `{:interrupted, _}` and `{:timeout, _}` keep their existing outcomes
    (`gate_interrupted`; `witness_timeout` / `capture_pending`) and never
    release.

    **Existing-first (b2c β; packet r1 section 3.4):** right after the
    invocation's `FOR SHARE` lock, a plain read of its release. An existing
    `released_unverified` release is returned only through
    `SdrAgent.Agents.ReleasedOutput.fetch/2`, which verifies its ORIGINAL
    basis historically and the live binding for current use
    (`SdrAgent.Prototype.ReleasedScope`): `{:released, release, output}`,
    nothing written, no eligibility, no new decision and no head lock; a
    refusal or error rolls back and is returned. With no release, or a
    withheld or calibration one, the flow above applies unchanged. The
    output of a new release is read the same way.

    **β stage P (not landable):** the verified read is complete; the raw
    existing-release decision does not yet verify the original
    historically (B1; see `SdrAgent.Prototype.ReleasedScope`).
    """

    require Ash.Query

    alias SdrAgent.Actor
    alias SdrAgent.Agents
    alias SdrAgent.Agents.Admission, as: AgentAdmission
    alias SdrAgent.Agents.AgentRun
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ModelResultRelease
    alias SdrAgent.Agents.ReleaseDecision.Prelocked
    alias SdrAgent.Agents.ReleasedOutput
    alias SdrAgent.Agents.ResultGate
    alias SdrAgent.Agents.ResultGate.Recovery
    alias SdrAgent.Agents.WireWitnessLink
    alias SdrAgent.Agents.Witness
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Clock
    alias SdrAgent.Operations.Failure
    alias SdrAgent.Prototype.Admission, as: PrototypeAdmission
    alias SdrAgent.Prototype.Basis
    alias SdrAgent.Repo

    @subject "SdrAgent.Agents.ModelInvocation"
    @live [:open, :acknowledged]
    @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

    @doc false
    @spec finalize(struct(), map(), {:ok | :timeout | :interrupted, map()}, keyword()) ::
            {:released, struct(), term()} | {:withheld, struct(), struct()} | {:error, term()}
    def finalize(invocation, gate, {kind, receipt} = outcome, opts)
        when kind in [:ok, :timeout, :interrupted] and is_map(receipt) do
      seamed(invocation, fn -> bounded(invocation, gate, outcome, opts) end)
    end

    defp bounded(invocation, gate, outcome, opts) do
      guard = Keyword.get(opts, :guard, fn _run -> :ok end)
      actor = Actor.system(:agent_runtime, invocation.tenant_id)
      attempt = fn mode -> attempt(invocation, gate, outcome, {guard, actor, mode}) end

      # A bounded repeat: one more refusal-only attempt after a failed recheck,
      # carrying attempt 1's under-head code; a second failure is returned
      # plain, never a third attempt.
      case attempt.(:normal) do
        {:error, {:recheck_failed, code}} -> attempt.({:refusal_only, code}) |> plain()
        result -> result
      end
    end

    defp plain({:error, {:recheck_failed, _code}}), do: {:error, :recheck_failed}
    defp plain(result), do: result

    defp attempt(invocation, gate, outcome, ctx) do
      fn -> locked(invocation, gate, outcome, ctx) end
      |> Audit.transaction()
      |> case do
        {:ok, result} -> result
        {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
        {:error, error} -> {:error, error}
      end
    end

    defp locked(invocation, gate, {_kind, receipt} = outcome, {guard, actor, mode}) do
      tenant_id = invocation.tenant_id

      with {:ok, run} <- ResultGate.lock(AgentRun, gate.run_id, tenant_id, "FOR UPDATE"),
           :ok <- ResultGate.own_run(run, invocation, gate),
           :ok <- ResultGate.lock_operation(run, tenant_id),
           :ok <- guard.(run),
           {:ok, invocation} <-
             ResultGate.lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE"),
           :none <- existing_first(invocation, actor),
           held = {invocation, run},
           evidence = known_evidence(invocation),
           {:ok, plan} <- moded(plan(outcome, evidence, held, Clock.utc_now()), mode),
           :ok <- usable_after_live_refusal(plan),
           {:ok, plan, cause} <- hold(plan, receipt, evidence, held),
           :ok <- before_head(invocation),
           {:ok, _head} <- Kernel.lock_head(tenant_id) do
        under_head(plan, cause, %{
          outcome: outcome,
          evidence: evidence,
          held: held,
          mode: mode,
          actor: actor
        })
      else
        {:replayed, released} -> released
        {:error, error} -> Repo.rollback(error)
      end
    end

    # D-237 b2c β EXISTING-FIRST (packet r1 section 3.4): an existing
    # released_unverified release is returned only through the verified
    # released-output read (its ORIGINAL basis, never re-derived): nothing is
    # written, no eligibility or new decision, no head lock; a refusal or
    # error rolls back. No release, or a withheld or calibration one, keeps
    # the α/b1 flow below.
    defp existing_first(invocation, actor) do
      case existing_release(invocation) do
        {:ok, %ModelResultRelease{disposition: :released_unverified} = release} ->
          case ReleasedOutput.fetch(invocation.id, actor) do
            {:ok, output} -> {:replayed, {:released, release, output}}
            {:error, error} -> {:error, error}
          end

        {:ok, _none_or_other} ->
          :none

        {:error, error} ->
          {:error, error}
      end
    end

    # A plain read (no lock clause): the release row is immutable.
    defp existing_release(invocation) do
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
      )
      |> Ash.read_one()
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

    defp plan({kind, receipt}, evidence, held, now) do
      cond do
        Enum.any?(evidence.links, &(&1.link_status == :mismatch)) or
            Map.get(receipt, :status) == :mismatch ->
          ResultGate.plan(:ok, %{status: :mismatch})

        kind in [:interrupted, :timeout] ->
          ResultGate.plan(kind, receipt)

        true ->
          decision(receipt, evidence, held, now)
      end
    end

    defp decision(receipt, evidence, held, now) do
      classification = classification(receipt)

      case eligibility(receipt, evidence, held, now) do
        {:ok, facts} -> %{release?: :unverified, classification: classification, facts: facts}
        {:refuse, code} -> refusal(classification, code)
      end
    end

    defp refusal(classification, code) do
      %{
        release?: false,
        reason: :prototype_authority_refused,
        classification: classification,
        prototype_refusal: code
      }
    end

    # The repeat is refusal-only: a release plan becomes a refusal with the
    # carried code, or, with none, no decision at all.
    defp moded(plan, :normal), do: {:ok, plan}

    defp moded(%{release?: :unverified}, {:refusal_only, nil}),
      do: {:error, {:recheck_failed, nil}}

    defp moded(%{release?: :unverified} = plan, {:refusal_only, code}),
      do: {:ok, refusal(plan.classification, code)}

    defp moded(plan, {:refusal_only, _code}), do: {:ok, plan}

    # The true observation classification (amendment item 5; Codex 2c9450b7
    # ruling 3b): a reconciled receipt is recorded as :reconciled.
    defp classification(%{status: :skipped}), do: :store_unconfigured
    defp classification(%{status: :reconciled}), do: :reconciled

    defp classification(%{codes: codes} = receipt) when is_list(codes),
      do: ResultGate.plan(:ok, receipt).classification

    defp classification(_receipt), do: :unclassified

    # Known evidence first, then the live binding, the observation, the
    # recorded authority, the identity, the recorded values, the scope, the
    # output, the charged grant and the window (amendment item 5).
    defp eligibility(receipt, evidence, {invocation, run}, now) do
      with :ok <- no_known_evidence(evidence),
           {:ok, live} <- step(PrototypeAdmission.live()),
           :ok <- absent_observation(receipt, live),
           {:ok, recorded} <- step(PrototypeAdmission.recorded(invocation)),
           :ok <- identity(invocation, live),
           :ok <- step(PrototypeAdmission.check_recorded(recorded, live, invocation)),
           :ok <- in_scope(run, invocation, live),
           :ok <- valid_output(invocation),
           {:ok, grant} <- step(PrototypeAdmission.check_charge(invocation, live, recorded)),
           :ok <- in_window(now, live.funding) do
        {:ok,
         %{
           snapshot: live.binding,
           entry: live.entry,
           funding: live.funding,
           invocation: invocation,
           run: run,
           grant: grant,
           decided_at: now
         }}
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

    # Before the recorded authority (Codex 3122b0d4 Q4): ClaudeCLI,
    # generation 2, a profile of the compiled identity.
    defp identity(invocation, %{entry: entry}) do
      if invocation.provider == :claude_cli and invocation.ledger_generation == 2 and
           invocation.profile_id in entry.identity.profile_ids,
         do: :ok,
         else: {:refuse, :identity_mismatch}
    end

    defp in_scope(run, invocation, live) do
      if running?(run, invocation) and scoped?(run.usage_origin, invocation, live),
        do: :ok,
        else: {:refuse, :scope_mismatch}
    end

    defp running?(run, invocation),
      do:
        run.status == :running and run.usage_origin != :proof and invocation.status == :completed

    defp scoped?(origin, invocation, %{entry: entry, funding: funding}) do
      funded? =
        Enum.any?(funding.funded_scope, fn {funded_origin, purposes} ->
          funded_origin == origin and invocation.purpose in purposes
        end)

      funded? and origin in entry.usage_origins and invocation.purpose in entry.purposes and
        invocation.profile_id in funding.profile_ids
    end

    defp valid_output(%{validation_status: :valid}), do: :ok
    defp valid_output(_invocation), do: {:refuse, :output_invalid}

    # The funding entry's window: the start inclusive, the end exclusive.
    defp in_window(now, funding) do
      if DateTime.compare(now, funding.starts_at) != :lt and
           DateTime.compare(now, funding.expires_at) == :lt,
         do: :ok,
         else: {:refuse, :outside_window}
    end

    ## Before the head: the branch's locks

    # D-237 TF-2 (plan r2): only the refusal code `binding_mismatch` can
    # follow a live read; one state probe before the cause read. An error
    # leaves through `locked/4`'s owner rollback.
    defp usable_after_live_refusal(%{prototype_refusal: :binding_mismatch}),
      do: PrototypeAdmission.state_probe()

    defp usable_after_live_refusal(_plan), do: :ok

    # The release branch: the charged grant, then the one charged allocation,
    # FOR SHARE (the launch's order); no cause.
    defp hold(%{release?: :unverified} = plan, _receipt, _evidence, {invocation, _run}) do
      with :ok <- AgentAdmission.lock_charge(invocation), do: {:ok, plan, nil}
    end

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

    ## Under the head

    # The release branch: the plan again, in full, at ONE instant read here;
    # only the same release is decided, anything else writes nothing and
    # rolls back carrying the under-head refusal code.
    defp under_head(%{release?: :unverified}, nil, ctx) do
      %{outcome: outcome, evidence: evidence, held: {invocation, _run} = held} = ctx
      reread = %{evidence | failures: failures(invocation)}
      now = Clock.utc_now()

      case plan(outcome, reread, held, now) do
        %{release?: :unverified} = current -> release(current, held, ctx.actor, now)
        current -> Repo.rollback({:recheck_failed, Map.get(current, :prototype_refusal)})
      end
    end

    # Failure writers append under the chain head, so the invocation's
    # Failures are read again here: a plain read, no lock (the links stay as
    # read: link writers lock the invocation FOR UPDATE). Evidence that changes
    # the branch's cause or the known-evidence code fails the recheck: the
    # attempt rolls back with nothing written, and `finalize/4` decides once
    # more, refusal-only.
    defp under_head(plan, cause, ctx) do
      %{evidence: evidence, held: {invocation, _run} = held} = ctx
      reread = %{evidence | failures: failures(invocation)}

      if unchanged?(plan, cause, {evidence, reread}, held),
        do: withhold(plan, cause, reread, ctx),
        else: Repo.rollback({:recheck_failed, carried(plan, reread)})
    end

    defp carried(%{prototype_refusal: code}, reread), do: evidence_code(reread) || code
    defp carried(_plan, _reread), do: nil

    defp withhold(plan, cause, reread, %{held: {invocation, run}} = ctx) do
      case current_code(plan, reread, ctx) do
        {:ok, plan} -> ResultGate.under_head(plan, invocation, run, nil, cause, ctx.actor)
        {:error, error} -> Repo.rollback(error)
      end
    end

    # The refusal-only repeat (Codex 3122b0d4 Q2): a CURRENT refusal at the
    # decision instant wins over the carried or pre-head code; a current
    # binding_mismatch first passes the TF-2 state probe. A normal attempt
    # keeps its pre-head code.
    defp current_code(
           %{prototype_refusal: code} = plan,
           reread,
           %{mode: {:refusal_only, _}} = ctx
         ) do
      case plan(ctx.outcome, reread, ctx.held, Clock.utc_now()) do
        %{prototype_refusal: ^code} ->
          {:ok, plan}

        %{prototype_refusal: :binding_mismatch} ->
          with :ok <- PrototypeAdmission.state_probe(),
               do: {:ok, %{plan | prototype_refusal: :binding_mismatch}}

        %{prototype_refusal: current} ->
          {:ok, %{plan | prototype_refusal: current}}

        _release_or_other ->
          {:ok, plan}
      end
    end

    defp current_code(plan, _reread, _ctx), do: {:ok, plan}

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

    ## The release (the gate's own context)

    # The basis from the facts at the decision instant, decided in this
    # gate's own Prelocked context bound to that instant; the output only
    # through the released-output read. Any refusal or error rolls back.
    defp release(%{facts: facts}, {invocation, _run}, actor, now) do
      case Basis.build(facts) do
        {:ok, basis, sha256} ->
          %{
            tenant_id: invocation.tenant_id,
            model_invocation_id: invocation.id,
            finalizer: :prototype_gate,
            decided_at: now
          }
          |> Prelocked.run(&decide_release(&1, invocation, {basis, sha256}, actor))
          |> case do
            {:error, error} -> Repo.rollback(error)
            released -> released
          end

        {:error, :basis_invalid} ->
          Repo.rollback(:basis_invalid)
      end
    end

    defp decide_release(prelocked, invocation, {basis, sha256}, actor) do
      attrs = %{
        model_invocation_id: invocation.id,
        disposition: :released_unverified,
        reason: :owner_prototype_unverified,
        basis: basis,
        basis_sha256: sha256
      }

      with {:ok, release} <-
             Agents.decide_result_release(attrs, actor: actor, prelocked: prelocked),
           {:ok, output} <- ReleasedOutput.fetch(invocation.id, actor) do
        {:released, release, output}
      else
        {:error, error} -> Repo.rollback(error)
      end
    end
  end
end
