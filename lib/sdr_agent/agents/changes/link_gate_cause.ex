defmodule SdrAgent.Agents.Changes.LinkGateCause do
  @moduledoc """
  AgentRun `:fail` change for a run stopped by the result gate (R0-07 slice
  C; packet section 2, AgentRun and Failure rows; rows G1 and G6): instead
  of opening a Failure, the run links the gate's exact cause
  (`witness_failure_id`) as its `attention_failure_id`, given the withheld
  release (`release_id`).

  In a `before_action`, with the run row already re-read
  (`SdrAgent.Agents.Changes.RunRow`), it requires:

    * the release `:withheld`, for an invocation of this run, with a reason
      of the stop's category — `:witness_mismatch` for `:witness_mismatch`;
      `:witness_missing`, `:witness_timeout`, `:store_unreadable` or
      `:gate_interrupted` for `:witness_unreconciled`;
    * the Failure of the run's tenant, class `reconciliation_required`,
      subject that invocation, `operation_id` equal to the run's Operation
      (nil for a run without one), and bound as `gate_cause_id` by the
      release's immutable withheld event
      (`SdrAgent.Agents.ReleaseDecision.Binding`). No other Failure — an
      arbitrary `reconciliation_required` one, or a null-Operation one the
      event does not bind — can be a run cause.

  Its status does not matter: a cause resolved before the stop stays the
  run's historical cause. The Failure is read `FOR UPDATE` (lock order run →
  Failure → chain head) — or, under the finalizer's verified Prelocked
  context for this run's invocation and this receipt (`prelocked/1`), with
  no lock clause: the finalizer already holds it before the head (G6).


  C2* (S3 plan r2 §6; OQ11): for a `:demo_exception` release of an
  invocation of this run, and only with the stop `:witness_unreconciled`,
  the cause is instead the Failure that meets the same identity checks
  (tenant, `reconciliation_required`, subject that invocation, the run's
  Operation) and is a warning with exactly the message "demo exception not
  in use" (Recovery's fixed cause). Every withheld release still needs its
  event's binding.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Binding
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @unreconciled [:witness_missing, :witness_timeout, :store_unreadable, :gate_interrupted]
  @linkable [:withheld, :demo_exception]
  @demo_message "demo exception not in use"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.valid?, do: link(changeset), else: changeset
    end)
  end

  @doc """
  `:ok` when `changeset` is a gate stop under the finalizer's verified
  Prelocked context: its registered invocation is the release's, that
  invocation belongs to this run, and its receipt is `witness_failure_id`.
  Otherwise `:error` (the ordinary locks apply).
  """
  def prelocked(changeset) do
    run = changeset.data
    arg = &Ash.Changeset.get_argument(changeset, &1)

    with %{sdr_prelocked: context} <- changeset.context,
         stop when stop in [:witness_mismatch, :witness_unreconciled] <- arg.(:status_reason),
         {:ok, registered} <- Prelocked.verify(context),
         true <-
           not is_nil(registered.receipt_id) and
             registered.receipt_id == arg.(:witness_failure_id),
         true <- registered.tenant_id == run.tenant_id,
         {:ok, release} <- read(ModelResultRelease, arg.(:release_id), run.tenant_id),
         true <- release.model_invocation_id == registered.model_invocation_id,
         {:ok, invocation} <- read(ModelInvocation, release.model_invocation_id, run.tenant_id),
         true <- invocation.agent_run_id == run.id do
      :ok
    else
      _ -> :error
    end
  end

  defp link(changeset) do
    %AgentRun{} = run = changeset.data
    arg = &Ash.Changeset.get_argument(changeset, &1)
    lock = if prelocked(changeset) == :ok, do: nil, else: :for_update

    with {:ok, %{disposition: disposition} = release} when disposition in @linkable <-
           read(ModelResultRelease, arg.(:release_id), run.tenant_id),
         true <- category?(release, arg.(:status_reason)),
         {:ok, invocation} <- read(ModelInvocation, release.model_invocation_id, run.tenant_id),
         true <- invocation.agent_run_id == run.id,
         {:ok, %Failure{} = failure} <-
           read(Failure, arg.(:witness_failure_id), run.tenant_id, lock),
         true <- cause_of?(failure, invocation, run),
         true <- bound?(release, failure) do
      Ash.Changeset.force_change_attribute(changeset, :attention_failure_id, failure.id)
    else
      _ -> invalid(changeset)
    end
  end

  defp read(resource, id, tenant_id, lock \\ nil)

  defp read(resource, id, tenant_id, lock) when is_binary(id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> then(&if(lock, do: Ash.Query.lock(&1, lock), else: &1))
    |> Ash.read_one()
    |> case do
      {:ok, %^resource{} = row} -> {:ok, row}
      _ -> :error
    end
  end

  defp read(_resource, _id, _tenant_id, _lock), do: :error

  defp category?(%{disposition: :demo_exception}, stop), do: stop == :witness_unreconciled
  defp category?(%{reason: :witness_mismatch}, :witness_mismatch), do: true
  defp category?(%{reason: reason}, :witness_unreconciled), do: reason in @unreconciled
  defp category?(_release, _stop), do: false

  # A withheld release binds its cause in its immutable event; a demo row's
  # only cause is the fixed warning (C2* OQ11), on top of `cause_of?/3`.
  defp bound?(%{disposition: :withheld} = release, failure),
    do: Binding.bound_cause(release) == {:ok, failure.id}

  defp bound?(%{disposition: :demo_exception}, failure),
    do: failure.severity == :warning and failure.message == @demo_message

  defp cause_of?(failure, invocation, run) do
    failure.tenant_id == run.tenant_id and failure.class == :reconciliation_required and
      failure.subject_resource == inspect(ModelInvocation) and
      failure.subject_id == invocation.id and failure.operation_id == run.operation_id
  end

  defp invalid(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :witness_failure_id,
      message:
        "must be the result gate's cause of this run's withheld release, of the stop's reason"
    )
  end
end
