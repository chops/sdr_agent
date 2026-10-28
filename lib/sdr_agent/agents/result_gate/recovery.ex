defmodule SdrAgent.Agents.ResultGate.Recovery do
  @moduledoc """
  The result gate's recovery finalization (R0-07 slice C; packet section
  6, rows G5 R2/R3, G7 and R7-2): a gated invocation decided from its
  durable witness state, without a reconcile receipt and without a new
  reconcile.

  Used once, in a fresh transaction, when `SdrAgent.Agents.ResultGate.finalize/4`
  was refused (G7), and by run recovery for an invocation whose links or
  cause already exist (G5 R2, R3).

  One transaction in the finalization lock order:

    1. the run `FOR UPDATE`, then its Operation `FOR SHARE` (then the
       caller's `guard:`);
    2. the invocation `FOR SHARE`, and the immutable release is read
       **before any replacement selection**;
    3. with no release: a savepoint, its current links `FOR SHARE`, the
       selected cause's candidates `FOR UPDATE`, the chain head, and the
       release read again. A release committed meanwhile by a concurrent
       decider rolls back to the savepoint (nothing written; the locks
       taken after it released) and is then decided as in step 2 or 4;
    4. with a withheld release and a still-running run: its link `FOR
       SHARE` and its original bound cause `FOR UPDATE`, then the head.

  **An existing release is authoritative.** It is never overwritten and no
  new receipt or cause is made. A `:released` one returns its output. A
  withheld one of a run no longer running is returned as it is (R3 stays
  untouched). A withheld one whose run is still running stops the run on
  the release's original bound cause (review MF5). If that binding is
  unavailable (no bound cause, or an unreadable event), recovery fails
  closed with `{:error, :binding_unavailable}`: nothing is written, no
  output is returned, and the run is left as it is.

  **Otherwise (row G5's selection):**

    * a current mismatch link gives `:witness_mismatch` with the
      invocation's usable live critical cause. That is one whose
      `operation_id` is the run's Operation (`nil` for a run without one,
      which the withheld event then binds, row G1). With no live critical,
      a bound critical is opened under the head. A live critical that is
      not usable gives `{:error, :mismatch_cause_unbound}`, with nothing
      written (row R7-2);
    * anything else gives `:gate_interrupted`, with the invocation's
      existing gate-capable live warning, or a new deduplicated one opened
      under the head.

  The decision is never `:released`. A running run is stopped with its
  exact receipt; a terminal run gets the release only (R3). One attempt:
  no recursion. A refusal or a database error returns `{:error, reason}`
  with no output, and the state stays sweepable.
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Binding
  alias SdrAgent.Agents.ReleasedOutput
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Repo

  @subject "SdrAgent.Agents.ModelInvocation"

  @doc """
  Recovers the gate of `invocation` under `gate` (`%{run_id,
  operation_id}`). Option `guard:` as for `ResultGate.finalize/4`. Returns `{:released, release, output}` (a competing
  release only), `{:withheld, release, run}` or `{:error, reason}`.

  C2* operation snapshot entry `:result_gate_recovery` (ADR-0005 C2* item
  2): under the gate or the sweeper's per-run owner it inherits.
  """
  @spec run(struct(), map(), keyword()) ::
          {:released, struct(), term()} | {:withheld, struct(), struct()} | {:error, term()}
  def run(invocation, gate, opts \\ []) do
    OperationSnapshot.enter(:result_gate_recovery, fn ->
      actor = Actor.system(:agent_runtime, invocation.tenant_id)
      guard = Keyword.get(opts, :guard, fn _run -> :ok end)

      fn -> locked(invocation, gate, guard, actor) end
      |> Audit.transaction()
      |> case do
        {:ok, result} -> result
        {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
        {:error, error} -> {:error, error}
      end
    end)
  end

  # The immutable decision is read first, before any replacement selection
  # (review, G7): the run, its Operation and the invocation are held, so a
  # release found here is authoritative.
  defp locked(invocation, gate, guard, actor) do
    tenant_id = invocation.tenant_id

    with {:ok, run} <- ResultGate.lock(AgentRun, gate.run_id, tenant_id, "FOR UPDATE"),
         :ok <- ResultGate.own_run(run, invocation, gate),
         :ok <- ResultGate.lock_operation(run, tenant_id),
         :ok <- guard.(run),
         {:ok, invocation} <-
           ResultGate.lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE"),
         {:ok, release} <- existing_release(invocation) do
      decide(release, {invocation, run}, actor)
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  # No release: G5's selection, then the head. A release a concurrent
  # decider committed meanwhile (found under the head; review round 2) is
  # honoured like one found first: the selection is rolled back to a
  # savepoint, which writes nothing and releases its link, cause and head
  # locks, and the immutable winner is decided in the normal order. Once
  # only: a found release never returns here.
  @savepoint "result_gate_recovery_selection"

  defp decide(nil, {invocation, run} = held, actor) do
    Repo.query!("SAVEPOINT #{@savepoint}")

    with {:ok, links} <- lock_current_links(invocation),
         {:ok, plan, cause} <- select(links, invocation, run),
         {:ok, _head} <- Kernel.lock_head(invocation.tenant_id),
         {:ok, nil} <- existing_release(invocation) do
      ResultGate.under_head(plan, invocation, run, primary(links), cause, actor)
    else
      {:ok, %ModelResultRelease{} = winner} ->
        Repo.query!("ROLLBACK TO SAVEPOINT #{@savepoint}")
        decide(winner, held, actor)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  # A competing finalizer's committed release (G7): respected as it is.
  defp decide(%ModelResultRelease{disposition: :released} = release, {invocation, _run}, actor) do
    case ReleasedOutput.fetch(invocation.id, actor) do
      {:ok, output} -> {:released, release, output}
      {:error, error} -> Repo.rollback(error)
    end
  end

  # Review MF5: a withheld release of a run no longer running is final; a
  # still-running run is stopped on the release's original bound cause
  # (and link), both locked before the head. No new receipt or release.
  defp decide(%ModelResultRelease{disposition: :withheld} = release, {_invocation, run}, _actor)
       when run.status != :running,
       do: {:withheld, release, run}

  defp decide(%ModelResultRelease{disposition: :withheld} = release, {invocation, run}, actor) do
    tenant_id = invocation.tenant_id

    with {:ok, cause_id} when is_binary(cause_id) <- Binding.bound_cause(release),
         {:ok, link} <- lock_release_link(release, tenant_id),
         {:ok, cause} <- ResultGate.lock(Failure, cause_id, tenant_id, "FOR UPDATE"),
         {:ok, _head} <- Kernel.lock_head(tenant_id) do
      ResultGate.stop_on_release(run, release, invocation, link, cause, actor)
    else
      {:ok, nil} -> Repo.rollback(:binding_unavailable)
      {:error, :binding_unavailable} -> Repo.rollback(:binding_unavailable)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp decide(_calibration, _held, _actor), do: Repo.rollback(:not_gated)

  defp lock_release_link(%{wire_witness_link_id: nil}, _tenant_id), do: {:ok, nil}

  defp lock_release_link(%{wire_witness_link_id: id}, tenant_id),
    do: ResultGate.lock(WireWitnessLink, id, tenant_id, "FOR SHARE")

  defp lock_current_links(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        not exists(successors, true)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read()
  end

  # The single current primary link, if any (the release's evaluated link).
  defp primary(links) do
    case Enum.filter(links, &(&1.evidence["classification"] == "primary")) do
      [link] -> link
      _ -> nil
    end
  end

  # Row G5's selection; the candidates are locked FOR UPDATE before the head.
  defp select(links, invocation, run) do
    if Enum.any?(links, &(&1.link_status == :mismatch)),
      do: mismatch(invocation, run),
      else: interrupted(invocation, run)
  end

  @doc false
  # Row R7-2 (isolated here): a known mismatch is never downgraded. Also the
  # prototype gate's mismatch selection (D-237 IF-4, A2): `{:ok, plan, cause}`
  # (cause nil: a bound critical is opened under the head) or
  # `{:error, :mismatch_cause_unbound}`.
  def mismatch(invocation, run) do
    plan = ResultGate.plan(:ok, %{status: :mismatch})

    with {:ok, live} <- lock_live(invocation, :critical) do
      case {live, Enum.find(live, &ResultGate.gate_capable?(&1, invocation, run))} do
        {[], nil} -> {:ok, plan, nil}
        {_live, %Failure{} = cause} -> {:ok, plan, cause}
        {_unusable, nil} -> {:error, :mismatch_cause_unbound}
      end
    end
  end

  defp interrupted(invocation, run) do
    plan = ResultGate.plan(:interrupted, %{status: :inferred})

    with {:ok, live} <- lock_live(invocation, :warning) do
      {:ok, plan, Enum.find(live, &ResultGate.gate_capable?(&1, invocation, run))}
    end
  end

  # The invocation's live witness causes of `severity`, oldest first.
  defp lock_live(invocation, severity) do
    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and subject_resource == @subject and
        subject_id == ^invocation.id and class == :reconciliation_required and
        severity == ^severity and status in [:open, :acknowledged]
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read()
  end

  # Plain read (immutable rows): first with the run and invocation held, and
  # again under the head, where every decider has committed or waits.
  defp existing_release(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
    )
    |> Ash.read_one()
  end
end
