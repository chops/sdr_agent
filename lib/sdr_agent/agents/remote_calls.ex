defmodule SdrAgent.Agents.RemoteCalls do
  @moduledoc """
  The domain contracts of remote ClaudeCLI calls (S-B2; entity/plan r2
  "Contracts"; r4 R1, r4a C2/C3, plan P1). S-B4 adapts them to the worker
  wire; S-B3 settles completed calls and expires unclaimed ones.

  ## The RemoteCalls scope

  Every action of `SdrAgent.Agents.RemoteModelCall`, `ClaimNonce`,
  `RemoteCallResult`, `RemoteCallReceipt` and
  `SdrAgent.Operations.MacWorker` `:touch_last_seen` authorizes only with
  the domain-private scope (`SdrAgent.Agents.Checks.RemoteCallsScope`).
  This module alone opens it: inside a transaction it opens (or joins), it
  binds a fresh reference to the current process and passes the context
  (key `:sdr_agent_remote_calls_scope`) to its own requests;
  the binding is removed when the transaction function returns. There is no
  public grant (the test-seam build adds `__with_scope_for_test__/1`).

  ## Contracts

    * `claim(token, nonce, pins)` — one transaction under the R1 lock order
      (MacWorker `FOR UPDATE` by token digest → run → Operation (share) →
      invocation → call → charge → chain head; the clock is read once every
      lock is held). Refuses, writing nothing, unless the worker is active,
      its intake open and `pins` equal its enrolled pins exactly. A nonce
      already bound to a claimed call before its result deadline returns the
      same launch; bound to any other call, `{:ok, :none, state}`; spent with
      no call, `{:ok, :none}`. Otherwise, while the worker has no claimed
      call, the earliest pending call of the worker's tenant, profile and
      model before its claim deadline is re-checked under the locks,
      admitted by `SdrAgent.Agents.Admission.launch_check/6` and marked sent
      (reserved → sent, only here for a remote invocation), claimed (result
      deadline `claimed_at + 600 s`) and bound to the nonce:
      `{:ok, launch}` with `call_id`, `profile_id`, `model_id`,
      `request_sha256`, `prompt`, `schema` and `result_deadline`. A refused
      launch check rolls the whole claim back (`{:error, {:launch_refused,
      reason}}`); a candidate lost to a concurrent claim returns
      `{:ok, :none}` with no write; no candidate at all spends the nonce
      with a null call.
    * `complete(token, nonce, call_id, request_digest, transcript)` — the
      size cap (2097152 bytes) first; then the worker (any status) `FOR
      SHARE`, the nonce of this worker (unknown or spent with no call:
      refused, no receipt), and the NONCE's call under run → Operation →
      invocation → call. A posted `call_id` or `request_digest` that is not
      that call's is `:refused_mismatch` on that call only (a foreign call
      is never read, locked or written). Otherwise, as C3: completed — the
      server digest equal to the stored result's is `:duplicate_same`,
      different `:conflict`; expired — `:late`; claimed — at or after the
      result deadline claimed → expired_unknown and `:late`, a disabled
      worker `:refused_disabled` (state unchanged), else the immutable
      RemoteCallResult, claimed → completed and `:accepted`. Each outcome
      appends one receipt; `{:ok, kind}` for accepted, duplicate_same,
      conflict and late, `{:error, kind}` for refused_*.
    * `heartbeat(token, pins)` — an active worker with equal pins: writes
      `last_seen_at` and returns `{:ok, intake}`.

  Internal entries used by `SdrAgent.Agents`: `remote_invocation?/1` (the
  local launch's `:remote_transport` refusal), `remote?/0` and `check_request/1` (the
  trusted transport and the reservation's prompt and schema caps).
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ClaimNonce
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.RemoteCallReceipt
  alias SdrAgent.Agents.RemoteCallResult
  alias SdrAgent.Agents.RemoteModelCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.MacWorker
  alias SdrAgent.Repo

  @scope_key :sdr_agent_remote_calls_scope
  @result_window 600
  @field_cap 262_144
  @launch_purpose "remote_call_launch"
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  ## Scope

  @doc """
  Whether `context` carries the RemoteCalls scope bound to the current
  process while it is inside the transaction that opened it.
  """
  @spec scoped?(term()) :: boolean()
  def scoped?(context) when is_map(context) do
    ref = Map.get(context, @scope_key)
    is_reference(ref) and Process.get(@scope_key) == ref and Repo.in_transaction?()
  end

  def scoped?(_context), do: false

  @doc "Only the scope entry of a request context (for a nested read in the same scope)."
  @spec scope_of(term()) :: map()
  def scope_of(context) when is_map(context), do: Map.take(context, [@scope_key])
  def scope_of(_context), do: %{}

  # Runs `fun.(scope)` in a transaction (a new one, or the caller's) with a
  # fresh reference bound to this process. `fun` returns `{:ok, value}` to
  # commit or `{:error, error}` to roll back.
  defp with_scope(fun) do
    Repo.transaction(fn ->
      ref = make_ref()
      previous = Process.get(@scope_key)
      Process.put(@scope_key, ref)

      try do
        case fun.(%{@scope_key => ref}) do
          {:ok, value} -> value
          {:error, error} -> Repo.rollback(error)
        end
      after
        restore(previous)
      end
    end)
  end

  defp restore(nil), do: Process.delete(@scope_key)
  defp restore(previous), do: Process.put(@scope_key, previous)

  if @test_seams do
    @doc """
    Test-seam build only: runs `fun.(context)` inside a transaction with the
    process-bound RemoteCalls scope set; returns `{:ok, fun's value}`.
    """
    def __with_scope_for_test__(fun) when is_function(fun, 1),
      do: with_scope(fn scope -> {:ok, fun.(scope)} end)
  end

  ## Transport and reservation

  @doc "Whether the trusted transport (`config :sdr_agent, :model_transport`) is `:remote`."
  @spec remote?() :: boolean()
  def remote?, do: Application.get_env(:sdr_agent, :model_transport, :local) == :remote

  @doc """
  The remote launch input caps of a stored request body: a string `prompt`
  of at most 262144 bytes and a map `schema` whose JSON encoding is at most
  262144 bytes. `:ok` or `{:error, message}`.
  """
  @spec check_request(term()) :: :ok | {:error, String.t()}
  def check_request(request) when is_binary(request) do
    case Jason.decode(request) do
      {:ok, %{"prompt" => prompt, "schema" => schema}}
      when is_binary(prompt) and is_map(schema) ->
        cond do
          byte_size(prompt) > @field_cap ->
            {:error, "prompt is over #{@field_cap} bytes"}

          byte_size(Jason.encode!(schema)) > @field_cap ->
            {:error, "schema is over #{@field_cap} bytes"}

          true ->
            :ok
        end

      _other ->
        {:error, "has no remote prompt and schema"}
    end
  end

  def check_request(_request), do: {:error, "has no remote prompt and schema"}

  @doc "Whether `invocation` has a RemoteModelCall: `{:ok, boolean}`."
  @spec remote_invocation?(ModelInvocation.t()) :: {:ok, boolean()} | {:error, term()}
  def remote_invocation?(%ModelInvocation{id: id, tenant_id: tenant_id}) do
    with_scope(fn scope ->
      RemoteModelCall
      |> Ash.Query.for_read(:read, %{}, context: scope)
      |> Ash.Query.filter(model_invocation_id == ^id and tenant_id == ^tenant_id)
      |> Ash.exists()
    end)
  end

  ## Claim

  @doc "Claims work for the worker of `token`. See the moduledoc."
  def claim(token, nonce, pins) do
    with :ok <- token_input(token),
         :ok <- nonce_input(nonce),
         :ok <- pins_input(pins),
         {:ok, _worker} <- preflight(token) do
      # The witness store root is observed (the only filesystem I/O) before
      # any lock, for an authenticated worker only (as admit_launch).
      store = Gate.observe_store()
      unwrap(with_scope(&claim_locked(token, nonce, pins, store, &1)))
    end
  end

  defp preflight(token) do
    with_scope(fn scope ->
      case worker(token, nil, scope) do
        {:ok, nil} -> {:error, :unauthorized}
        other -> other
      end
    end)
  end

  defp claim_locked(token, nonce, pins, store, scope) do
    with {:ok, worker} <- authenticated(token, :for_update, scope),
         :ok <- claimable(worker, pins),
         {:ok, bound} <- nonce_row(worker, nonce, scope) do
      case bound do
        %ClaimNonce{call_id: nil} -> {:ok, {:ok, :none}}
        %ClaimNonce{call_id: call_id} -> replay(worker, call_id, scope)
        nil -> fresh(worker, nonce, pins, store, scope)
      end
    end
  end

  defp claimable(%MacWorker{status: :active, intake: :open, profile_pins: pins}, pins), do: :ok
  defp claimable(%MacWorker{status: :active, intake: :open}, _pins), do: {:error, :pins_mismatch}
  defp claimable(%MacWorker{status: :active}, _pins), do: {:error, :intake_paused}
  defp claimable(_worker, _pins), do: {:error, :worker_disabled}

  defp replay(worker, call_id, scope) do
    with {:ok, call} <- call(call_id, worker.tenant_id, nil, scope),
         do: replay_call(worker, call)
  end

  defp replay_call(worker, call) do
    if call.state == :claimed and
         DateTime.compare(SdrAgent.Clock.utc_now(), call.result_deadline) == :lt do
      with {:ok, launch} <- launch(call, agent(worker)), do: {:ok, {:ok, launch}}
    else
      {:ok, {:ok, :none, call.state}}
    end
  end

  defp fresh(worker, nonce, pins, store, scope) do
    with {:ok, busy?} <- claimed_call?(worker, scope),
         {:ok, candidate} <- candidate(worker, pins, busy?, scope),
         do: fresh_take(worker, nonce, candidate, store, scope)
  end

  defp fresh_take(worker, nonce, nil, _store, scope) do
    with {:ok, _spent} <- spend(worker, nonce, nil, scope), do: {:ok, {:ok, :none}}
  end

  defp fresh_take(worker, nonce, call, store, scope), do: take(worker, nonce, call, store, scope)

  defp claimed_call?(worker, scope) do
    RemoteModelCall
    |> Ash.Query.for_read(:read, %{}, context: scope)
    |> Ash.Query.filter(
      tenant_id == ^worker.tenant_id and worker_id == ^worker.id and state == :claimed
    )
    |> Ash.exists()
  end

  defp candidate(_worker, _pins, true, _scope), do: {:ok, nil}

  # Picked without a lock; re-checked under the locks in take/5.
  defp candidate(worker, pins, false, scope) do
    profile = String.to_existing_atom(pins["profile_id"])
    model = pins["model_id"]
    now = SdrAgent.Clock.utc_now()

    RemoteModelCall
    |> Ash.Query.for_read(:read, %{}, context: scope)
    |> Ash.Query.filter(
      tenant_id == ^worker.tenant_id and state == :pending and profile_id == ^profile and
        model_id == ^model and claim_deadline > ^now
    )
    |> Ash.Query.sort(claim_deadline: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  defp take(worker, nonce, candidate, store, scope) do
    agent = agent(worker)

    with {:ok, target} <- invocation(candidate.model_invocation_id, worker.tenant_id, nil, agent),
         {:ok, run} <- run(target.agent_run_id, worker.tenant_id, agent),
         :ok <- Admission.lock_operation_share(run.operation_id),
         {:ok, invocation} <- invocation(target.id, worker.tenant_id, :for_update, agent),
         {:ok, call} <- call(candidate.id, worker.tenant_id, :for_update, scope),
         :ok <- Admission.lock_charge(invocation),
         {:ok, _head} <- Kernel.lock_head(worker.tenant_id),
         :ok <- SdrAgent.Prototype.check_fence() do
      # The claim instant is read only once every lock is held.
      now = SdrAgent.Clock.utc_now()

      if call.state == :pending and invocation.status == :reserved and
           DateTime.compare(now, call.claim_deadline) == :lt do
        admit(worker, nonce, {run, invocation, call}, now, store, scope)
      else
        # Lost to a concurrent claim: no sent transition, claim or binding.
        {:ok, {:ok, :none}}
      end
    end
  end

  defp admit(worker, nonce, {run, invocation, call}, now, store, scope) do
    case Admission.launch_check(run, invocation, call.profile_id, now, store) do
      :ok ->
        with {:ok, _sent} <- mark_sent(invocation, agent(worker)),
             {:ok, claimed} <-
               transition(call, :claim, mac(worker), scope, %{
                 worker_id: worker.id,
                 claimed_at: now,
                 result_deadline: DateTime.add(now, @result_window, :second)
               }),
             {:ok, _bound} <- spend(worker, nonce, claimed.id, scope),
             {:ok, launch} <- launch(claimed, agent(worker)) do
          {:ok, {:ok, launch}}
        end

      {:error, reason, _check} ->
        {:error, {:launch_refused, reason}}
    end
  end

  defp mark_sent(invocation, agent) do
    invocation
    |> Ash.Changeset.for_update(:mark_sent, %{}, actor: agent)
    |> Ash.update()
  end

  defp spend(worker, nonce, call_id, scope) do
    ClaimNonce
    |> Ash.Changeset.for_create(
      :insert,
      %{worker_id: worker.id, claim_nonce: nonce, call_id: call_id},
      actor: mac(worker),
      context: scope
    )
    |> Ash.create()
  end

  # The domain launch: the frozen input of the call, its unrendered prompt
  # and schema read back from the stored request (an audited kernel read).
  defp launch(call, agent) do
    with {:ok, body} <- Kernel.read_content(call.request_sha256, @launch_purpose, agent),
         {:ok, %{"prompt" => prompt, "schema" => schema}} <- Jason.decode(body) do
      {:ok,
       %{
         call_id: call.id,
         profile_id: call.profile_id,
         model_id: call.model_id,
         request_sha256: call.request_sha256,
         prompt: prompt,
         schema: schema,
         result_deadline: call.result_deadline
       }}
    else
      {:error, error} -> {:error, error}
      _malformed -> {:error, :request_unreadable}
    end
  end

  ## Complete

  @doc "Completes the nonce's call with `transcript`. See the moduledoc."
  def complete(token, nonce, call_id, request_digest, transcript) do
    cond do
      not is_binary(transcript) ->
        {:error, :invalid_transcript}

      byte_size(transcript) > RemoteCallResult.max_bytes() ->
        {:error, :payload_too_large}

      token_input(token) != :ok ->
        {:error, :unauthorized}

      nonce_input(nonce) != :ok ->
        {:error, :unknown_nonce}

      true ->
        unwrap(
          with_scope(&complete_locked(token, nonce, {call_id, request_digest}, transcript, &1))
        )
    end
  end

  defp complete_locked(token, nonce, posted, transcript, scope) do
    with {:ok, worker} <- authenticated(token, :for_share, scope),
         {:ok, %ClaimNonce{call_id: call_id}} when is_binary(call_id) <-
           nonce_row(worker, nonce, scope),
         {:ok, call} <- lock_owned_call(worker, call_id, scope) do
      digest = :crypto.hash(:sha256, transcript)

      if mismatch?(call, posted),
        do: receipt(worker, call, :refused_mismatch, digest, scope),
        else: settle(worker, call, transcript, digest, scope)
    else
      {:ok, _no_call} -> {:error, :unknown_nonce}
      {:error, error} -> {:error, error}
    end
  end

  # The nonce's own call under run → Operation → invocation → call.
  defp lock_owned_call(worker, call_id, scope) do
    agent = agent(worker)

    with {:ok, target} <- call(call_id, worker.tenant_id, nil, scope),
         {:ok, invocation} <- invocation(target.model_invocation_id, worker.tenant_id, nil, agent),
         {:ok, run} <- run(invocation.agent_run_id, worker.tenant_id, agent),
         :ok <- Admission.lock_operation_share(run.operation_id),
         {:ok, _invocation} <- invocation(invocation.id, worker.tenant_id, :for_update, agent) do
      call(target.id, worker.tenant_id, :for_update, scope)
    end
  end

  defp mismatch?(call, {call_id, request_digest}),
    do: not (same_id?(call.id, call_id) and raw_digest(request_digest) == call.request_sha256)

  defp same_id?(id, posted) when is_binary(posted) do
    case Ecto.UUID.cast(posted) do
      {:ok, cast} -> cast == id
      :error -> false
    end
  end

  defp same_id?(_id, _posted), do: false

  defp raw_digest(<<_::binary-size(32)>> = raw), do: raw

  defp raw_digest(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :lower) do
      {:ok, raw} -> raw
      :error -> nil
    end
  end

  defp raw_digest(_other), do: nil

  # r4a C3 step 4, with the clock read once after every lock is held.
  defp settle(worker, %{state: :completed} = call, _transcript, digest, scope) do
    with {:ok, stored} <- stored_digest(call, scope) do
      kind = if stored == digest, do: :duplicate_same, else: :conflict
      receipt(worker, call, kind, digest, scope)
    end
  end

  defp settle(worker, %{state: state} = call, _transcript, digest, scope)
       when state in [:expired_unknown, :expired_unclaimed],
       do: receipt(worker, call, :late, digest, scope)

  defp settle(worker, %{state: :claimed} = call, transcript, digest, scope) do
    now = SdrAgent.Clock.utc_now()

    cond do
      DateTime.compare(now, call.result_deadline) != :lt ->
        with {:ok, expired} <- transition(call, :expire_unknown, mac(worker), scope),
             do: receipt(worker, expired, :late, digest, scope)

      worker.status == :disabled ->
        receipt(worker, call, :refused_disabled, digest, scope)

      true ->
        with {:ok, _result} <- store_result(worker, call, transcript, scope),
             {:ok, completed} <- transition(call, :complete, mac(worker), scope),
             do: receipt(worker, completed, :accepted, digest, scope)
    end
  end

  defp settle(_worker, _call, _transcript, _digest, _scope), do: {:error, :call_not_claimed}

  defp stored_digest(call, scope) do
    RemoteCallResult
    |> Ash.Query.for_read(:read, %{}, context: scope)
    |> Ash.Query.filter(call_id == ^call.id and tenant_id == ^call.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %RemoteCallResult{transcript_sha256: digest}} -> {:ok, digest}
      {:ok, nil} -> {:error, :result_missing}
      {:error, error} -> {:error, error}
    end
  end

  defp store_result(worker, call, transcript, scope) do
    RemoteCallResult
    |> Ash.Changeset.for_create(:store, %{call_id: call.id, transcript: transcript},
      actor: mac(worker),
      context: scope
    )
    |> Ash.create()
  end

  @refusals [:refused_disabled, :refused_mismatch]

  defp receipt(worker, call, kind, digest, scope) do
    RemoteCallReceipt
    |> Ash.Changeset.for_create(
      :append,
      %{call_id: call.id, kind: kind, transcript_sha256: digest},
      actor: mac(worker),
      context: scope
    )
    |> Ash.create()
    |> case do
      {:ok, _receipt} when kind in @refusals -> {:ok, {:error, kind}}
      {:ok, _receipt} -> {:ok, {:ok, kind}}
      {:error, error} -> {:error, error}
    end
  end

  ## Heartbeat

  @doc "Records an active worker's heartbeat; returns `{:ok, intake}`. See the moduledoc."
  def heartbeat(token, pins) do
    with :ok <- token_input(token),
         :ok <- pins_input(pins) do
      unwrap(with_scope(&heartbeat_locked(token, pins, &1)))
    end
  end

  defp heartbeat_locked(token, pins, scope) do
    with {:ok, worker} <- authenticated(token, :for_update, scope),
         :ok <- live(worker, pins),
         {:ok, touched} <- touch(worker, scope),
         do: {:ok, {:ok, touched.intake}}
  end

  defp live(%MacWorker{status: :active, profile_pins: pins}, pins), do: :ok
  defp live(%MacWorker{status: :active}, _pins), do: {:error, :pins_mismatch}
  defp live(_worker, _pins), do: {:error, :worker_disabled}

  defp touch(worker, scope) do
    worker
    |> Ash.Changeset.for_update(:touch_last_seen, %{}, actor: mac(worker), context: scope)
    |> Ash.update()
  end

  ## Reads and locks

  defp authenticated(token, lock, scope) do
    case worker(token, lock, scope) do
      {:ok, nil} -> {:error, :unauthorized}
      other -> other
    end
  end

  defp worker(token, lock, scope) do
    digest = :crypto.hash(:sha256, token)

    MacWorker
    |> Ash.Query.for_read(:read, %{}, context: scope)
    |> Ash.Query.filter(token_sha256 == ^digest)
    |> lock(lock)
    |> Ash.read_one()
  end

  defp nonce_row(worker, nonce, scope) do
    ClaimNonce
    |> Ash.Query.for_read(:read, %{}, context: scope)
    |> Ash.Query.filter(
      tenant_id == ^worker.tenant_id and worker_id == ^worker.id and claim_nonce == ^nonce
    )
    |> Ash.read_one()
  end

  defp call(id, tenant_id, lock, scope) do
    RemoteModelCall
    |> Ash.Query.for_read(:read, %{}, context: scope)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> lock(lock)
    |> Ash.read_one()
    |> found(:call_not_found)
  end

  defp invocation(id, tenant_id, lock, agent) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: agent)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> lock(lock)
    |> Ash.read_one()
    |> found(:invocation_not_found)
  end

  defp run(id, tenant_id, agent) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: agent)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> lock(:for_update)
    |> Ash.read_one()
    |> found(:run_not_found)
  end

  defp lock(query, nil), do: query
  defp lock(query, :for_update), do: Ash.Query.lock(query, :for_update)
  defp lock(query, :for_share), do: Ash.Query.lock(query, "FOR SHARE")

  defp found({:ok, nil}, reason), do: {:error, reason}
  defp found(other, _reason), do: other

  defp transition(call, action, actor, scope, input \\ %{}) do
    call
    |> Ash.Changeset.for_update(action, input, actor: actor, context: scope)
    |> Ash.update()
  end

  ## Actors and inputs

  # The worker's actor: built only here, after a token digest match.
  defp mac(worker), do: %Actor{type: :mac_worker, id: worker.id, tenant_id: worker.tenant_id}

  # The tenant's runtime identity for the reused launch-admission internals.
  defp agent(worker), do: Actor.system(:agent_runtime, worker.tenant_id)

  defp token_input(token) when is_binary(token) and byte_size(token) == 32, do: :ok
  defp token_input(_token), do: {:error, :unauthorized}

  defp nonce_input(nonce),
    do: if(ClaimNonce.valid?(nonce), do: :ok, else: {:error, :invalid_nonce})

  defp pins_input(pins) when is_map(pins) do
    if Enum.sort(Map.keys(pins)) == Enum.sort(MacWorker.pin_keys()),
      do: :ok,
      else: {:error, :pins_mismatch}
  end

  defp pins_input(_pins), do: {:error, :pins_mismatch}

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, error}), do: {:error, error}
end
