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

    1. the run `FOR UPDATE`, then its Operation `FOR SHARE`;
    2. the invocation `FOR SHARE`;
    3. its current links `FOR SHARE`;
    4. the selected cause's candidates `FOR UPDATE`;
    5. the chain head;
    6. then the release is re-read.

  **An existing release is authoritative.** A release committed by a
  competing finalizer is returned as it is: never overwritten, no second
  cause, no run stop.

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
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
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
  operation_id}`). Returns `{:released, release, output}` (a competing
  release only), `{:withheld, release, run}` or `{:error, reason}`.
  """
  @spec run(struct(), map(), keyword()) ::
          {:released, struct(), term()} | {:withheld, struct(), struct()} | {:error, term()}
  def run(invocation, gate, _opts \\ []) do
    actor = Actor.system(:agent_runtime, invocation.tenant_id)

    fn -> locked(invocation, gate, actor) end
    |> Audit.transaction()
    |> case do
      {:ok, result} -> result
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      {:error, error} -> {:error, error}
    end
  end

  defp locked(invocation, gate, actor) do
    tenant_id = invocation.tenant_id

    with {:ok, run} <- ResultGate.lock(AgentRun, gate.run_id, tenant_id, "FOR UPDATE"),
         :ok <- ResultGate.own_run(run, invocation, gate),
         :ok <- ResultGate.lock_operation(run, tenant_id),
         {:ok, invocation} <-
           ResultGate.lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE"),
         {:ok, links} <- lock_current_links(invocation),
         {:ok, plan, cause} <- select(links, invocation, run),
         {:ok, _head} <- Kernel.lock_head(tenant_id),
         {:ok, release} <- existing_release(invocation) do
      decide(release, plan, {invocation, run, primary(links), cause}, actor)
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp decide(nil, plan, {invocation, run, link, cause}, actor),
    do: ResultGate.under_head(plan, invocation, run, link, cause, actor)

  # A competing finalizer's committed release (G7): respected as it is.
  defp decide(%ModelResultRelease{disposition: :released} = release, _plan, held, actor) do
    {invocation, _run, _link, _cause} = held

    case ReleasedOutput.fetch(invocation.id, actor) do
      {:ok, output} -> {:released, release, output}
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp decide(%ModelResultRelease{disposition: :withheld} = release, _plan, held, _actor) do
    {_invocation, run, _link, _cause} = held
    {:withheld, release, run}
  end

  defp decide(_calibration, _plan, _held, _actor), do: Repo.rollback(:not_gated)

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

  # Row R7-2 (isolated here): a known mismatch is never downgraded.
  defp mismatch(invocation, run) do
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

  # Under the head every decider has committed or waits, so this plain read
  # is authoritative.
  defp existing_release(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
    )
    |> Ash.read_one()
  end
end
