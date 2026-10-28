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
    guard = Keyword.get(opts, :guard, fn _run -> :ok end)
    actor = Actor.system(:agent_runtime, invocation.tenant_id)

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
         {:ok, plan, cause} <-
           hold(plan(outcome, evidence, invocation), receipt, evidence, {invocation, run}),
         :ok <- before_head(invocation),
         {:ok, _head} <- Kernel.lock_head(tenant_id) do
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

  ## Known evidence (plain reads, no lock)

  defp known_evidence(invocation) do
    links =
      WireWitnessLink
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
      )
      |> Ash.read!()

    failures =
      Failure
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and subject_resource == @subject and
          subject_id == ^invocation.id and class == :reconciliation_required
      )
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.read!()

    %{links: links, failures: failures}
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

  defp hold(%{reason: :witness_mismatch}, _receipt, _evidence, {invocation, run}),
    do: Recovery.mismatch(invocation, run)

  defp hold(plan, receipt, evidence, {invocation, run} = held) do
    preferred =
      case Map.get(plan, :prototype_refusal) do
        :known_integrity_signal -> live_cause(evidence, held, :critical)
        :witness_evidence_present -> live_cause(evidence, held, :warning)
        _other -> nil
      end

    result =
      case preferred do
        %Failure{id: id} -> ResultGate.lock(Failure, id, invocation.tenant_id, "FOR UPDATE")
        nil -> ResultGate.select_cause(plan, receipt, invocation, run)
      end

    with {:ok, cause} <- result, do: {:ok, plan, cause}
  end

  # A usable live cause of `severity` stays the bound cause.
  defp live_cause(evidence, {invocation, run}, severity) do
    Enum.find(evidence.failures, fn failure ->
      failure.severity == severity and failure.status in @live and
        ResultGate.gate_capable?(failure, invocation, run)
    end)
  end
end
