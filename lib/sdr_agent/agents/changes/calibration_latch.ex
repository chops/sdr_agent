defmodule SdrAgent.Agents.Changes.CalibrationLatch do
  @moduledoc """
  AgentRun `:finish_calibration` change (R0-07 slice E, row R11-2; harness
  round 13, entity PASS at 094caa86): the run is finished only by the
  guarded calibration finish, `SdrAgent.Agents.finish_calibration/3`.

  In a `before_action` it requires the finish's verified
  `SdrAgent.Agents.ReleaseDecision.Prelocked` context — tenant and
  invocation bound, **nil** link and **nil** receipt — and that `release_id`
  is the `:calibration` latch of that invocation, an invocation of this
  run. The finish already holds the run `FOR UPDATE` and the invocation
  `FOR SHARE` before the chain head, so the run row, the release and the
  invocation are re-read with no lock clause. It also enforces the finish's
  own invariants: a `:proof` run with no Operation, and its own terminal
  generation-2 ClaudeCLI invocation. Anything else is refused: the action
  is never reachable without its latch, and never weaker than the finish.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Audit.Kernel

  @terminal [:completed, :failed, :unknown]

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # The stored row, never the caller's struct, is what is checked.
      with true <- changeset.valid?,
           {:ok, run} <- reread(changeset, context),
           changeset = %{changeset | data: run},
           :ok <- latched(changeset) do
        changeset
      else
        false -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the calibration latch is verified before the change"}

  defp latched(changeset) do
    run = changeset.data

    with %{sdr_prelocked: context} <- changeset.context,
         {:ok, registered} <- Prelocked.verify(context),
         true <- registered.wire_witness_link_id == nil and registered.receipt_id == nil,
         true <- registered.tenant_id == run.tenant_id,
         {:ok, release} <-
           read(ModelResultRelease, Ash.Changeset.get_argument(changeset, :release_id), run),
         true <-
           release.disposition == :calibration and
             release.model_invocation_id == registered.model_invocation_id,
         {:ok, invocation} <- read(ModelInvocation, release.model_invocation_id, run),
         true <- finishable?(run, invocation) do
      :ok
    else
      _ ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :release_id,
           message: "must be the calibration latch of this run's invocation"
         )}
    end
  end

  # The finish's own invariants, enforced here too so the action is never
  # weaker than `SdrAgent.Agents.finish_calibration/3` (code review of
  # 930ef2a): a `:proof` run with no Operation, and its own terminal
  # generation-2 ClaudeCLI invocation.
  defp finishable?(run, invocation) do
    invocation.agent_run_id == run.id and run.usage_origin == :proof and
      is_nil(run.operation_id) and invocation.ledger_generation == 2 and
      invocation.provider == :claude_cli and invocation.status in @terminal
  end

  defp read(resource, id, run) when is_binary(id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(run.tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^run.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %^resource{} = row} -> {:ok, row}
      _ -> :error
    end
  end

  defp read(_resource, _id, _run), do: :error

  defp reread(changeset, context) do
    primary_key = Ash.Resource.Info.primary_key(changeset.resource)

    Ash.get(
      changeset.resource,
      changeset.data |> Map.take(primary_key) |> Map.to_list(),
      domain: changeset.domain,
      tracer: context.tracer,
      actor: nil,
      authorize?: false
    )
  end
end
