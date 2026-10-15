defmodule SdrAgent.Agents.CalibrationFinish do
  @moduledoc """
  The guarded calibration finish (R0-07 slice E, row R11-2; harness round
  13, entity PASS at 094caa86; staged E1 contract in the packet), behind
  `SdrAgent.Agents.finish_calibration/3`.

  For a terminal (`completed`, `failed` or `unknown`) generation-2 ClaudeCLI
  invocation of a `:proof` run with no Operation, as AGT of its tenant, in
  one transaction: run `FOR UPDATE` → invocation `FOR SHARE` → chain head,
  then, under a `SdrAgent.Agents.ReleaseDecision.Prelocked` context binding
  the tenant and invocation with **nil** link and **nil** receipt, the
  `:calibration` latch with the artifact's hash as `evidence_sha256`
  (`SdrAgent.Agents.Checks.CalibrationContext`) and:

    * a still-running run → `:succeeded` with `:calibration_latched`
      (`AgentRun :finish_calibration`), whatever the call's outcome;
    * an already-terminal run → unchanged; the latch only.

  No row lock is requested after the head and no file is read: the hash is
  trusted in-process metadata that the calibration console validates first
  (row R11-3). An identical replay returns the latch; a different hash is
  `{:error, :calibration_evidence_conflict}`; any other shape or state is
  `{:error, :calibration_not_finishable}`; wrong principals are
  `Ash.Error.Forbidden`. Outside test-seam builds (where no calibration
  latch can exist) every finish is refused.
  """

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  if @test_seams do
    require Ash.Query

    alias SdrAgent.Actor
    alias SdrAgent.Agents
    alias SdrAgent.Agents.AgentRun
    alias SdrAgent.Agents.Errors.ReleaseConflict
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ReleaseDecision.Prelocked
    alias SdrAgent.Agents.ResultGate
    alias SdrAgent.AI.ModelProfiles
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Repo

    @terminal [:completed, :failed, :unknown]
    @sha256 ~r/\A[0-9a-f]{64}\z/

    @doc "See the moduledoc. Returns `{:ok, %{release:, run:}}` or `{:error, reason}`."
    def run(%ModelInvocation{} = invocation, evidence, actor) do
      with :ok <- authorize(actor, invocation),
           {:ok, sha} <- evidence_sha(evidence) do
        fn -> locked(invocation.id, sha, actor) end
        |> Audit.transaction()
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, error} -> {:error, reason(error)}
        end
      end
    end

    def run(_invocation, _evidence, _actor), do: {:error, :calibration_not_finishable}

    defp authorize(%Actor{type: :agent_runtime, tenant_id: tenant_id}, %{tenant_id: tenant_id})
         when is_binary(tenant_id),
         do: :ok

    defp authorize(_actor, _invocation), do: {:error, Ash.Error.Forbidden.exception([])}

    defp evidence_sha(%{sha256: sha}) when is_binary(sha) do
      if Regex.match?(@sha256, sha), do: {:ok, sha}, else: {:error, :calibration_not_finishable}
    end

    defp evidence_sha(_evidence), do: {:error, :calibration_not_finishable}

    defp locked(invocation_id, sha, actor) do
      tenant_id = actor.tenant_id

      with {:ok, run_id} <- run_of(invocation_id, tenant_id),
           {:ok, run} <- ResultGate.lock(AgentRun, run_id, tenant_id, "FOR UPDATE"),
           {:ok, invocation} <-
             ResultGate.lock(ModelInvocation, invocation_id, tenant_id, "FOR SHARE"),
           :ok <- finishable(run, invocation),
           {:ok, _head} <- Kernel.lock_head(tenant_id) do
        Prelocked.run(
          %{tenant_id: tenant_id, model_invocation_id: invocation.id},
          &under_head(&1, run, invocation, sha, actor)
        )
      else
        {:error, error} -> Repo.rollback(error)
      end
    end

    # Under the head, every dependent row held: the latch, then the run.
    defp under_head(prelocked, run, invocation, sha, actor) do
      with {:ok, release} <- latch(invocation, sha, actor, prelocked),
           {:ok, run} <- stop(run, release, actor, prelocked) do
        %{release: release, run: run}
      else
        {:error, error} -> Repo.rollback(error)
      end
    end

    # The run id of the invocation (immutable; read before any lock so the run
    # is locked first).
    defp run_of(invocation_id, tenant_id) when is_binary(invocation_id) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^invocation_id and tenant_id == ^tenant_id)
      |> Ash.Query.select([:id, :agent_run_id])
      |> Ash.read_one()
      |> case do
        {:ok, %ModelInvocation{agent_run_id: run_id}} -> {:ok, run_id}
        _ -> {:error, :calibration_not_finishable}
      end
    end

    defp run_of(_invocation_id, _tenant_id), do: {:error, :calibration_not_finishable}

    defp finishable(run, invocation) do
      if invocation.agent_run_id == run.id and run.usage_origin == :proof and
           is_nil(run.operation_id) and invocation.ledger_generation == 2 and
           invocation.provider == :claude_cli and invocation.status in @terminal and
           ModelProfiles.real?(invocation.profile_id),
         do: :ok,
         else: {:error, :calibration_not_finishable}
    end

    defp latch(invocation, sha, actor, prelocked) do
      attrs = %{
        model_invocation_id: invocation.id,
        disposition: :calibration,
        reason: :calibration,
        evidence_sha256: sha
      }

      Agents.decide_result_release(attrs,
        actor: actor,
        prelocked: prelocked,
        context:
          SdrAgent.Agents.Checks.CalibrationContext.context(invocation.profile_id, invocation.id)
      )
    end

    defp stop(%AgentRun{status: :running} = run, release, actor, prelocked) do
      run
      |> Ash.Changeset.for_update(:finish_calibration, %{release_id: release.id},
        actor: actor,
        context: %{sdr_prelocked: prelocked}
      )
      |> Ash.update()
    end

    defp stop(run, _release, _actor, _prelocked), do: {:ok, run}

    defp reason(reason) when is_atom(reason), do: reason
    defp reason(%Ash.Error.Forbidden{} = error), do: error

    defp reason(error) do
      if conflict?(error), do: :calibration_evidence_conflict, else: error
    end

    defp conflict?(%ReleaseConflict{}), do: true
    defp conflict?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &conflict?/1)
    defp conflict?(_error), do: false
  else
    @doc "Outside test-seam builds no calibration latch can exist: always refused."
    def run(_invocation, _evidence, _actor), do: {:error, :calibration_not_finishable}
  end
end
