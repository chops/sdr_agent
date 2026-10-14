defmodule SdrAgent.Agents.CalibrationRecovery do
  @moduledoc """
  The calibration recovery action (R0-07 slice E4c-5, packet 8.12; entity
  PASS at 25c1b18), behind `SdrAgent.Agents.recover_calibration/3`.

  Test-seam builds and the calibration console only. As AGT of the tenant,
  for its own generation-2 real-profile ClaudeCLI invocation of a `:proof`
  run with no Operation and one original calibration reservation event, in
  one transaction (run `FOR UPDATE` → invocation `FOR UPDATE` → chain head):

    * `reserved` with `:unlaunched` → `failed` (`abandoned_before_launch`);
    * `sent` with `{:quiescent, observation}` or `{:attested, attestation}`
      → `unknown` (never re-sent); `sent` with `:unlaunched` →
      `{:error, :calibration_not_quiescent}`, nothing written;
    * a terminal invocation needs no transition. One with sent history is
      never unlaunched (`:calibration_not_quiescent`); a pre-sent refusal
      keeps its own reason.

  `{:attested, attestation}` (the console's `SdrAgent.CalibrationConsole.
  LaunchRecord` attestation, closed schema) must bind this invocation and
  its recorded claim (`SdrAgent.Agents.Admission.Gate.recorded_claim/1`),
  else `:attestation_mismatch`. It appends `calibration.owner_attested`
  with the attestation as an immutable metadata payload, deduplicated by
  `attestation_id`: an identical replay reuses the event; a different
  payload under the same id, for this or any other invocation of the
  tenant, is `:attestation_conflict` (the id is unique in the tenant's
  audit chain).

  It owns database transitions and the attestation event only: no grant, no
  model call, the original charge kept. Any other decision or invocation is
  `:calibration_not_recoverable`; wrong principals are `Ash.Error.Forbidden`.
  The attestation's file (in the recovery ticket) is written by the console
  after this commits. Outside test-seam builds every recovery is refused.
  """

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  if @test_seams do
    require Ash.Query

    alias SdrAgent.Actor
    alias SdrAgent.Agents.Admission.Gate
    alias SdrAgent.Agents.AgentRun
    alias SdrAgent.Agents.ModelInvocation
    alias SdrAgent.Agents.ResultGate
    alias SdrAgent.AI.ModelProfiles
    alias SdrAgent.Audit
    alias SdrAgent.Audit.AuditEvent
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Repo

    @event "calibration.owner_attested"
    @schema "r0-calibration-attestation/1"
    @keys ~w(schema attestation_id instance_id invocation_id ticket_id observation confirmed_at)a
    @observation_keys ~w(state root_pid process_group_id)a
    @terminal [:completed, :failed, :unknown]
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

    @doc "See the moduledoc. `{:ok, %{invocation:, attestation_event:}}` or `{:error, reason}`."
    def run(%ModelInvocation{} = invocation, decision, actor) do
      with :ok <- authorize(actor, invocation),
           {:ok, decision} <- decision(decision) do
        fn -> locked(invocation.id, decision, actor) end
        |> Audit.transaction()
        |> case do
          # Ash notifications are sent only after the commit.
          {:ok, {result, notifications}} ->
            Ash.Notifier.notify(notifications)
            {:ok, result}

          {:error, error} ->
            {:error, error}
        end
      end
    end

    def run(_invocation, _decision, _actor), do: {:error, :calibration_not_recoverable}

    defp authorize(%Actor{type: :agent_runtime, tenant_id: tenant_id}, %{tenant_id: tenant_id})
         when is_binary(tenant_id),
         do: :ok

    defp authorize(_actor, _invocation), do: {:error, Ash.Error.Forbidden.exception([])}

    ## Decisions (checked before any lock)

    defp decision(:unlaunched), do: {:ok, :unlaunched}

    defp decision({:quiescent, %{} = observation}) do
      if quiescent?(observation),
        do: {:ok, {:quiescent, observation}},
        else: {:error, :calibration_not_recoverable}
    end

    defp decision({:attested, %{} = attestation}) do
      if attestation?(attestation),
        do: {:ok, {:attested, attestation}},
        else: {:error, :attestation_mismatch}
    end

    defp decision(_other), do: {:error, :calibration_not_recoverable}

    # Exactly the LaunchRecord attestation's closed schema.
    defp attestation?(%{observation: %{} = observation} = attestation) do
      Enum.sort(Map.keys(attestation)) == Enum.sort(@keys) and
        attestation.schema == @schema and
        Enum.all?(
          [:attestation_id, :instance_id, :invocation_id, :ticket_id],
          &uuid?(attestation[&1])
        ) and
        timestamp?(attestation.confirmed_at) and attested?(observation)
    end

    defp attestation?(_attestation), do: false

    # Automatic quiescence is observed only for a launched tree: both ids,
    # the root leading its own group (E4c-1; Codex, 5f90cf8). A pending launch needs the owner's attestation.
    defp quiescent?(observation),
      do: closed_observation?(observation) and launched_ids?(observation)

    # An attestation's observation is consistent with its state: a pending
    # launch has no ids; a launched tree has both.
    defp attested?(%{state: "launch_pending"} = observation),
      do:
        closed_observation?(observation) and is_nil(observation.root_pid) and
          is_nil(observation.process_group_id)

    defp attested?(observation),
      do: closed_observation?(observation) and launched_ids?(observation)

    defp closed_observation?(observation),
      do: Enum.sort(Map.keys(observation)) == Enum.sort(@observation_keys)

    defp launched_ids?(observation),
      do:
        observation.state == "launched" and pos?(observation.root_pid) and
          pos?(observation.process_group_id) and
          observation.process_group_id === observation.root_pid

    defp uuid?(value), do: is_binary(value) and value =~ @uuid
    defp pos?(value), do: is_integer(value) and value > 0

    defp timestamp?(value) when is_binary(value) do
      with true <- value =~ @timestamp,
           {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
        DateTime.to_iso8601(datetime) == value
      else
        _ -> false
      end
    end

    defp timestamp?(_value), do: false

    ## Under the locks

    defp locked(invocation_id, decision, actor) do
      tenant_id = actor.tenant_id

      with {:ok, run_id} <- run_of(invocation_id, tenant_id),
           {:ok, run} <- ResultGate.lock(AgentRun, run_id, tenant_id, "FOR UPDATE"),
           {:ok, invocation} <-
             ResultGate.lock(ModelInvocation, invocation_id, tenant_id, "FOR UPDATE"),
           :ok <- recoverable(run, invocation),
           {:ok, _head} <- Kernel.lock_head(tenant_id),
           {:ok, result, notifications} <- apply_decision(invocation, decision, actor) do
        {result, notifications}
      else
        {:error, error} -> Repo.rollback(error)
      end
    end

    # The run id of the invocation (immutable; read before any lock so the
    # run is locked first).
    defp run_of(invocation_id, tenant_id) when is_binary(invocation_id) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^invocation_id and tenant_id == ^tenant_id)
      |> Ash.Query.select([:id, :agent_run_id])
      |> Ash.read_one()
      |> case do
        {:ok, %ModelInvocation{agent_run_id: run_id}} -> {:ok, run_id}
        _ -> {:error, :calibration_not_recoverable}
      end
    end

    defp run_of(_invocation_id, _tenant_id), do: {:error, :calibration_not_recoverable}

    defp recoverable(run, invocation) do
      if recoverable?(run, invocation) and match?({:ok, _entry}, Gate.recorded_tuple(invocation)),
        do: :ok,
        else: {:error, :calibration_not_recoverable}
    end

    @doc """
    The stored-row eligibility predicate (test-seam builds only): this
    invocation of this `:proof` run with no Operation, generation 2,
    ClaudeCLI and a reviewed real profile. The recovery reads both rows
    under their locks before applying it.
    """
    def recoverable?(run, invocation) do
      invocation.agent_run_id == run.id and run.usage_origin == :proof and
        is_nil(run.operation_id) and invocation.ledger_generation == 2 and
        invocation.provider == :claude_cli and ModelProfiles.real?(invocation.profile_id)
    end

    defp apply_decision(%{status: :reserved} = invocation, :unlaunched, actor) do
      with {:ok, failed, notes} <- transition(invocation, :fail, %{error: abandoned()}, actor),
           do: {:ok, %{invocation: failed, attestation_event: nil}, notes}
    end

    defp apply_decision(%{status: :reserved}, _launched_decision, _actor),
      do: {:error, :calibration_not_recoverable}

    defp apply_decision(%{status: :sent}, :unlaunched, _actor),
      do: {:error, :calibration_not_quiescent}

    defp apply_decision(%{status: :sent} = invocation, {:quiescent, _observation}, actor) do
      with {:ok, unknown, notes} <- transition(invocation, :mark_unknown, %{}, actor),
           do: {:ok, %{invocation: unknown, attestation_event: nil}, notes}
    end

    defp apply_decision(%{status: :sent} = invocation, {:attested, attestation}, actor) do
      with {:ok, event} <- attest(invocation, attestation, actor),
           {:ok, unknown, notes} <- transition(invocation, :mark_unknown, %{}, actor),
           do: {:ok, %{invocation: unknown, attestation_event: event}, notes}
    end

    # Terminal: no transition. Sent history is never unlaunched.
    defp apply_decision(%{status: status} = invocation, :unlaunched, _actor)
         when status in @terminal do
      if is_nil(invocation.sent_at),
        do: {:ok, %{invocation: invocation, attestation_event: nil}, []},
        else: {:error, :calibration_not_quiescent}
    end

    defp apply_decision(%{status: status} = invocation, {:quiescent, _observation}, _actor)
         when status in @terminal,
         do: {:ok, %{invocation: invocation, attestation_event: nil}, []}

    defp apply_decision(%{status: status} = invocation, {:attested, attestation}, actor)
         when status in @terminal do
      with {:ok, event} <- attest(invocation, attestation, actor),
           do: {:ok, %{invocation: invocation, attestation_event: event}, []}
    end

    defp abandoned, do: %{"kind" => "abandoned_before_launch"}

    defp transition(invocation, action, params, actor) do
      invocation
      |> Ash.Changeset.for_update(action, params, actor: actor)
      |> Ash.update(return_notifications?: true)
    end

    ## The audited attestation

    defp attest(invocation, attestation, actor) do
      with :ok <- binds(invocation, attestation) do
        payload = stringify(attestation)

        case existing(invocation.tenant_id, attestation.attestation_id) do
          [] -> append(invocation, payload, actor)
          [%{payload: ^payload} = event] -> {:ok, event}
          _different -> {:error, :attestation_conflict}
        end
      end
    end

    defp binds(invocation, attestation) do
      if attestation.invocation_id == invocation.id and
           Gate.recorded_claim(invocation) == {:ok, %{instance_id: attestation.instance_id}},
         do: :ok,
         else: {:error, :attestation_mismatch}
    end

    # The attestation id identifies one attestation in the tenant's chain
    # (Codex 01a135d9): any earlier event with it, for any invocation.
    defp existing(tenant_id, attestation_id) do
      AuditEvent
      |> Ash.Query.filter(tenant_id == ^tenant_id and event_type == @event)
      |> Ash.read!(Kernel.opts(tenant_id))
      |> Enum.filter(&(&1.payload["attestation_id"] == attestation_id))
    end

    defp append(invocation, payload, actor) do
      Kernel.append(
        %{
          event_type: @event,
          category: :model,
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          action: "recover_calibration",
          model_invocation_id: invocation.id,
          agent_run_id: invocation.agent_run_id,
          payload: payload
        },
        actor: actor,
        tenant_id: invocation.tenant_id
      )
    end

    defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
    defp stringify(value), do: value
  else
    @doc "Outside test-seam builds no calibration recovery exists: always refused."
    def run(_invocation, _decision, _actor), do: {:error, :calibration_not_recoverable}
  end
end
