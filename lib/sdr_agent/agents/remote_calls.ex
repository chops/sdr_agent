defmodule SdrAgent.Agents.RemoteCalls do
  @moduledoc """
  The domain contracts of remote ClaudeCLI calls (S-B2; entity/plan r2
  "Contracts"; r4 R1, r4a C2/C3, plan P1). S-B4 adapts them to the worker
  wire; S-B3 settles completed calls and expires unclaimed ones.

  ## The RemoteCalls scope

  Every action of `SdrAgent.Agents.RemoteModelCall` (except `:create`),
  `ClaimNonce`, `RemoteCallResult`, `RemoteCallReceipt` and
  `SdrAgent.Operations.MacWorker` `:touch_last_seen` authorizes only with
  the domain-private scope (`SdrAgent.Agents.Checks.RemoteCallsScope`).
  `RemoteModelCall` `:create` instead requires the reservation scope
  (`SdrAgent.Agents.Checks.RemoteReservationScope`), bound only inside the
  `:reserve` transaction by `SdrAgent.Agents.Changes.CreateRemoteCall`.
  Only this module opens the RemoteCalls scope: inside a transaction it
  opens (or joins), it binds a fresh reference to the current process and
  passes the context (key `:sdr_agent_remote_calls_scope`) to its own
  requests; the binding is removed when the transaction function returns.
  There is no public grant (the test-seam build adds
  `__with_scope_for_test__/1`).

  The settlement read (S-B3 plan r3 D1): only `settle_due/1`, after the
  locked rebinding checks of one completed call, registers an internal
  settlement marker (this process, keyed to the current scope reference,
  inside the same transaction) around its read of the stored transcript;
  the `RemoteCallResult` `:transcript` field policy's `{RemoteCallsScope,
  read: :settlement}` branch passes only then (`settlement?/1`). The marker
  is restored on every exit; no context key, other process or plain scope
  passes it.

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
    * `settle_due(opts)` (S-B3; the cron worker
      `SdrAgent.Agents.RemoteSettler`) — only the kernel actor of a tenant
      with the `:remote_settler` KernelMarker context
      (`SdrAgent.Prototype.Checks.KernelMarker`); anything else is
      Forbidden with no write. Under the trusted `:remote` transport it
      selects, unlocked and in bounded batches, the tenant's pending calls
      at or after their claim deadline, claimed calls at or after their
      result deadline, and completed or expired_unknown calls whose
      invocation is still `sent`. Each one is then settled in its own
      RemoteCalls scope under run → Operation (share) → invocation → call
      (the authoritative reread) → charge → chain head, never a MacWorker
      lock, with the clock read once every lock is held. The locked rows
      are rebound first (the call's tenant; the invocation its own, of the
      same tenant, `:claude_cli`; the transport still `:remote`); a
      mismatch or a state that no longer applies is skipped with no write.
      Then: pending → expired_unclaimed (`:expire_unclaimed`) and a
      `reserved` invocation → failed `remote_unclaimed` (the charge kept);
      claimed → expired_unknown and a `sent` invocation → unknown; an
      expired_unknown call's `sent` invocation → unknown; a completed
      call's `sent` invocation is settled from the stored transcript:
      request binding (`request_sha256` equal to the call's), the schema
      recovered from the purpose and equal to the frozen id, version and
      sha256, the ClaudeCLI stream fold (`ClaudeCLI.stream_line/4`, init
      attestation, the first result; any non-blank byte after it, or an
      init without a result, is unprocessable), the reply envelope and
      the Zoi validation (`ModelProvider.validate_result/3`). A drift
      (missing init included) fails with its reason and the critical
      `provider_error` Failure of the local path
      (`ModelProvider.attention/3`); any other unprocessable transcript
      fails `remote_result_unprocessable`; a schema-invalid object fails
      validation as locally. All writes are the existing invocation and
      run actions as the tenant's agent runtime. The release stays the
      result gate's (`SdrAgent.SDR.StaleRunSweeper`); the transcript is
      never logged nor put in an event. `{:ok, counts}`.

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
  @settlement_key {__MODULE__, :settlement}
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

  @doc """
  Whether `context` carries the open RemoteCalls scope of this process
  (`scoped?/1`) AND this module registered its internal settlement marker
  against that same scope reference (only inside `settle_due/1`'s read of
  one completed call's transcript, plan r3 D1).
  """
  @spec settlement?(term()) :: boolean()
  def settlement?(context) when is_map(context),
    do: scoped?(context) and Process.get(@settlement_key) == Map.get(context, @scope_key)

  def settlement?(_context), do: false

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

  ## Settlement (S-B3)

  # Compiled only with the prototype authority: the production build has no
  # :remote_settler marker, so its settle_due/1 refuses every caller.
  @prototype_authority Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  if @prototype_authority do
    alias Ash.Error.Forbidden
    alias SdrAgent.Agents
    alias SdrAgent.AI.ModelProfiles
    alias SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.ClaudeCLI
    alias SdrAgent.Audit
    alias SdrAgent.Prototype.Checks.KernelMarker
    alias SdrAgent.SDR.Schemas

    @batch 100
    @unprocessable :remote_result_unprocessable

    @doc false
    # The settler's entry (`SdrAgent.Agents.RemoteSettler`). See the moduledoc.
    @spec settle_due(keyword()) :: {:ok, map()} | {:error, term()}
    def settle_due(opts) when is_list(opts) do
      actor = Keyword.get(opts, :actor)

      cond do
        not settler?(actor, Keyword.get(opts, :context)) -> {:error, Forbidden.exception([])}
        remote?() -> settle_tenant(actor.tenant_id)
        true -> {:ok, %{}}
      end
    end

    def settle_due(_opts), do: {:error, Forbidden.exception([])}

    defp settler?(%Actor{type: :kernel, tenant_id: tenant_id} = actor, context)
         when is_binary(tenant_id) and is_map(context),
         do: KernelMarker.match?(actor, %{subject: %{context: context}}, marker: :remote_settler)

    defp settler?(_actor, _context), do: false

    defp settle_tenant(tenant_id) do
      with {:ok, candidates} <- with_scope(&due(tenant_id, SdrAgent.Clock.utc_now(), &1)) do
        candidates
        |> Enum.map(&settle_one/1)
        |> Enum.reduce({:ok, %{}}, &tally/2)
      end
    end

    # One candidate in its own audited transaction (the invocation actions
    # are guarded) holding a fresh RemoteCalls scope.
    defp settle_one(candidate) do
      Audit.transaction(fn ->
        case with_scope(&settle_locked(candidate, &1)) do
          {:ok, outcome} -> outcome
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end

    defp tally({:ok, outcome}, {:ok, counts}),
      do: {:ok, Map.update(counts, outcome, 1, &(&1 + 1))}

    defp tally({:error, error}, {:ok, _counts}), do: {:error, error}
    defp tally(_result, {:error, error}), do: {:error, error}

    # The unlocked selection (bounded per case); each candidate is decided
    # again under its locks.
    defp due(tenant_id, now, scope) do
      with {:ok, unclaimed} <-
             RemoteModelCall
             |> Ash.Query.for_read(:read, %{}, context: scope)
             |> Ash.Query.filter(
               tenant_id == ^tenant_id and state == :pending and claim_deadline <= ^now
             )
             |> batch()
             |> Ash.read(),
           {:ok, unknown} <-
             RemoteModelCall
             |> Ash.Query.for_read(:read, %{}, context: scope)
             |> Ash.Query.filter(
               tenant_id == ^tenant_id and state == :claimed and result_deadline <= ^now
             )
             |> batch()
             |> Ash.read(),
           {:ok, sent} <- sent_invocations(tenant_id),
           {:ok, settled} <-
             RemoteModelCall
             |> Ash.Query.for_read(:read, %{}, context: scope)
             |> Ash.Query.filter(
               tenant_id == ^tenant_id and state in [:completed, :expired_unknown] and
                 model_invocation_id in ^sent
             )
             |> batch()
             |> Ash.read() do
        {:ok, Enum.uniq_by(unclaimed ++ unknown ++ settled, & &1.id)}
      end
    end

    defp batch(query), do: query |> Ash.Query.sort(id: :asc) |> Ash.Query.limit(@batch)

    defp sent_invocations(tenant_id) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, actor: Actor.system(:agent_runtime, tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and status == :sent and provider == :claude_cli)
      |> Ash.Query.select([:id])
      |> Ash.read()
      |> case do
        {:ok, rows} -> {:ok, Enum.map(rows, & &1.id)}
        {:error, error} -> {:error, error}
      end
    end

    # Run → Operation (share) → invocation → call → charge → chain head, the
    # call re-read under its lock; never a MacWorker lock.
    defp settle_locked(candidate, scope) do
      tenant_id = candidate.tenant_id
      agent = Actor.system(:agent_runtime, tenant_id)

      with {:ok, target} <- invocation(candidate.model_invocation_id, tenant_id, nil, agent),
           {:ok, run} <- run(target.agent_run_id, tenant_id, agent),
           :ok <- Admission.lock_operation_share(run.operation_id),
           {:ok, invocation} <- invocation(target.id, tenant_id, :for_update, agent),
           {:ok, call} <- call(candidate.id, tenant_id, :for_update, scope),
           :ok <- Admission.lock_charge(invocation),
           {:ok, _head} <- Kernel.lock_head(call.tenant_id) do
        # The settlement instant is read only once every lock is held.
        if bound?(call, invocation),
          do: settle_call(call, invocation, SdrAgent.Clock.utc_now(), scope),
          else: {:ok, :skipped}
      else
        {:error, reason}
        when reason in [:invocation_not_found, :run_not_found, :call_not_found] ->
          {:ok, :skipped}

        {:error, error} ->
          {:error, error}
      end
    end

    # The rebinding of the locked rows (plan r2 E1).
    defp bound?(call, invocation) do
      invocation.id == call.model_invocation_id and invocation.tenant_id == call.tenant_id and
        invocation.provider == :claude_cli and remote?()
    end

    defp settle_call(%{state: :pending} = call, invocation, now, scope) do
      if reached?(now, call.claim_deadline) do
        agent = Actor.system(:agent_runtime, call.tenant_id)

        with {:ok, _expired} <- transition(call, :expire_unclaimed, agent, scope),
             {:ok, _failed} <- fail_unclaimed(invocation, agent),
             do: {:ok, :expired_unclaimed}
      else
        {:ok, :skipped}
      end
    end

    defp settle_call(%{state: :claimed} = call, invocation, now, scope) do
      if reached?(now, call.result_deadline) do
        agent = Actor.system(:agent_runtime, call.tenant_id)

        with {:ok, _expired} <- transition(call, :expire_unknown, agent, scope),
             {:ok, _unknown} <- unknown_sent(invocation, agent),
             do: {:ok, :expired_unknown}
      else
        {:ok, :skipped}
      end
    end

    defp settle_call(
           %{state: :expired_unknown} = call,
           %{status: :sent} = invocation,
           _now,
           _scope
         ) do
      agent = Actor.system(:agent_runtime, call.tenant_id)
      with {:ok, _unknown} <- unknown_sent(invocation, agent), do: {:ok, :unknown}
    end

    defp settle_call(%{state: :completed} = call, %{status: :sent} = invocation, _now, scope) do
      agent = Actor.system(:agent_runtime, call.tenant_id)

      with {:ok, decision} <- decide(call, invocation, scope),
           do: apply_decision(decision, invocation, agent)
    end

    defp settle_call(_call, _invocation, _now, _scope), do: {:ok, :skipped}

    defp reached?(now, deadline), do: DateTime.compare(now, deadline) != :lt

    defp fail_unclaimed(%{status: :reserved} = invocation, agent) do
      Agents.fail_model_invocation(
        invocation,
        ModelProvider.failure_attrs(:remote_unclaimed, nil),
        actor: agent
      )
    end

    defp fail_unclaimed(_invocation, _agent), do: {:ok, :none}

    defp unknown_sent(%{status: :sent} = invocation, agent),
      do: Agents.mark_model_invocation_unknown(invocation, actor: agent)

    defp unknown_sent(_invocation, _agent), do: {:ok, :none}

    # The decision for a completed call: `{:complete, attrs}`, `{:invalid,
    # attrs}` (validation failed) or `{:failure, reason, latency}`.
    defp decide(call, invocation, scope) do
      with {:ok, schema} <- bound_schema(call, invocation),
           {:ok, profile} <- call_profile(call),
           {:ok, result} <- settlement_read(call, scope) do
        latency = latency(call, result)

        {:ok,
         result.transcript
         |> fold_transcript(profile)
         |> reply(schema, latency)}
      else
        :unprocessable -> {:ok, {:failure, @unprocessable, nil}}
        {:error, error} -> {:error, error}
      end
    end

    # The persisted request binding and the schema recovered from the
    # purpose, equal to the frozen ref (as admission compares it).
    defp bound_schema(call, invocation) do
      with true <- invocation.request_sha256 == call.request_sha256,
           true <- invocation.profile_id == call.profile_id,
           {:ok, schema, ref} <- recovered_schema(invocation.purpose),
           true <-
             {invocation.output_schema_id, invocation.output_schema_version,
              invocation.output_schema_sha256} == {ref.id, ref.version, ref.sha256} do
        {:ok, schema}
      else
        _unbound -> :unprocessable
      end
    end

    defp recovered_schema(purpose) do
      {:ok, Schemas.for_purpose(purpose), Schemas.ref(purpose)}
    rescue
      FunctionClauseError -> :unknown_purpose
    end

    defp call_profile(call) do
      case ModelProfiles.fetch_real(call.profile_id) do
        {:ok, %ModelProfiles.Profile{adapter: ClaudeCLI} = profile} -> {:ok, profile}
        _other -> :unprocessable
      end
    end

    # The domain-private settlement read of the stored bytes (plan r3 D1).
    defp settlement_read(call, scope) do
      with_settlement(scope, fn ->
        RemoteCallResult
        |> Ash.Query.for_read(:read, %{}, context: scope)
        |> Ash.Query.filter(call_id == ^call.id and tenant_id == ^call.tenant_id)
        |> Ash.read_one()
      end)
      |> case do
        {:ok, %RemoteCallResult{transcript: transcript} = result} when is_binary(transcript) ->
          {:ok, result}

        {:ok, _missing} ->
          {:error, :result_unreadable}

        {:error, error} ->
          {:error, error}
      end
    end

    defp latency(%{claimed_at: %DateTime{} = claimed_at}, %{received_at: %DateTime{} = received}),
      do: max(DateTime.diff(received, claimed_at, :millisecond), 0)

    defp latency(_call, _result), do: nil

    # The stored stream through the unchanged ClaudeCLI line fold. Unlike the
    # local collector, which stops reading at the first result, the whole
    # transcript is known: any non-blank byte after the first result, or an
    # unterminated non-blank tail, is unprocessable; an init with no result
    # is unprocessable; no init at all is the local missing attestation.
    defp fold_transcript(transcript, profile) do
      {lines, [tail]} = transcript |> String.split("\n") |> Enum.split(-1)
      blank_tail? = blank?([tail])

      case walk(lines, nil, [], profile) do
        {:drift, reason} ->
          {:failure, reason}

        {:result, outcome, rest} ->
          if blank_tail? and blank?(rest), do: outcome, else: {:failure, @unprocessable}

        {:end, nil} when blank_tail? ->
          {:failure, :missing_init_attestation}

        _invalid_or_no_result ->
          {:failure, @unprocessable}
      end
    end

    defp walk([], init, _messages, _profile), do: {:end, init}

    defp walk([line | rest], init, messages, profile) do
      case ClaudeCLI.stream_line(line, init, messages, profile) do
        {:attested, event, messages} -> walk(rest, event, messages, profile)
        {:cont, messages} -> walk(rest, init, messages, profile)
        {:drift, reason} -> {:drift, reason}
        {:result, outcome} -> {:result, outcome, rest}
        :invalid -> :invalid
      end
    end

    defp blank?(lines), do: Enum.all?(lines, &(String.trim(&1) == ""))

    defp reply({:failure, reason}, _schema, latency), do: {:failure, reason, latency}
    defp reply({:error, reason}, _schema, latency), do: {:failure, reason, latency}

    defp reply({:ok, _reply} = success, schema, latency) do
      case ModelProvider.envelope(success) do
        {:ok, result} -> ModelProvider.validate_result(schema, result, latency) |> validated()
        _malformed -> {:failure, @unprocessable, latency}
      end
    end

    defp validated({:complete, attrs, _output}), do: {:complete, attrs}
    defp validated({:fail, attrs, _errors}), do: {:invalid, attrs}

    defp apply_decision({:complete, attrs}, invocation, agent) do
      with {:ok, _completed} <- Agents.complete_model_invocation(invocation, attrs, actor: agent),
           do: {:ok, :completed}
    end

    defp apply_decision({:invalid, attrs}, invocation, agent) do
      with {:ok, _failed} <- Agents.fail_model_invocation(invocation, attrs, actor: agent),
           do: {:ok, :failed}
    end

    # As the local path's known failure: the redacted reason, and for a
    # drift the critical attention Failure in this transaction.
    defp apply_decision({:failure, reason, latency}, invocation, agent) do
      with {:ok, failed} <-
             Agents.fail_model_invocation(
               invocation,
               ModelProvider.failure_attrs(reason, latency),
               actor: agent
             ),
           {:ok, _attention} <- ModelProvider.attention(failed, reason, agent),
           do: {:ok, :failed}
    end

    # Registers the settlement marker against `scope`'s reference for `fun`
    # only, restoring the previous value on every exit.
    defp with_settlement(%{@scope_key => ref}, fun) when is_reference(ref) do
      previous = Process.get(@settlement_key)
      Process.put(@settlement_key, ref)

      try do
        fun.()
      after
        if is_nil(previous),
          do: Process.delete(@settlement_key),
          else: Process.put(@settlement_key, previous)
      end
    end
  else
    @doc false
    # The production build: no settler marker exists, so no caller settles.
    def settle_due(_opts), do: {:error, Ash.Error.Forbidden.exception([])}
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
