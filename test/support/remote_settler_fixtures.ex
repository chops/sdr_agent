defmodule SdrAgent.RemoteSettlerFixtures do
  @moduledoc """
  S-B3 RED fixtures (entity/plan r1 670c22e4 + r2 9f3168cc, Codex PASS):
  the settler entry `SdrAgent.Agents.RemoteCalls.settle_due/1`, the Oban
  worker `SdrAgent.Agents.RemoteSettler`, the `:remote_settler` kernel
  marker and `RemoteModelCall :expire_unclaimed`.

  Builds on `SdrAgent.RemoteCallFixtures` (the world, worker, reservation,
  claim and complete). Absent modules, functions, markers and actions are
  reached only through guarded calls (`Function.capture/3` after a loaded
  and exported assertion, or a structural action check), so a missing
  contract is an assertion failure, never a compile warning.

  Transcripts are synthetic stream-json fixtures in the ClaudeCLI shape
  (init attestation of the real `:claude_cli_opus` profile, then a result
  event); no model, no CLI, no network.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.Repo
  alias SdrAgent.SDR.Schemas

  @settler SdrAgent.Agents.RemoteSettler
  @remote_calls SdrAgent.Agents.RemoteCalls
  @marker "SB3TRANSCRIPTMARKER5d1e"

  ## Modules and markers (absent before GREEN)

  @doc "The settler Oban worker module."
  def settler, do: @settler

  @doc "The synthetic transcript marker (never in a log line or an AuditEvent payload)."
  def marker, do: @marker

  @doc "The kernel marker context of the settler (flunks while the marker is absent)."
  def settler_context do
    Function.capture(KernelMarker, :context, 1).(:remote_settler)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :remote_settler marker")
    UndefinedFunctionError -> flunk("KernelMarker has no context/1")
  end

  @doc "The settler's options: the tenant's kernel actor with the `:remote_settler` marker."
  def settler_opts(fx),
    do: [actor: Actor.system(:kernel, fx.tenant.id), context: settler_context()]

  @doc "`RemoteCalls.settle_due(opts)` (asserted exported)."
  def settle_due(opts), do: F.safely(fn -> F.invoke(@remote_calls, :settle_due, [opts]) end)

  @doc "Asserts the settler entry exists (before any concurrent participant starts)."
  def settler_entry! do
    F.loaded!(@remote_calls)

    assert function_exported?(@remote_calls, :settle_due, 1),
           "#{inspect(@remote_calls)}.settle_due/1 is not exported"

    :ok
  end

  @doc "One settler pass that succeeds (`:ok` or `{:ok, _}`)."
  def settle!(fx) do
    :ok = settler_entry!()
    result = settle_due(settler_opts(fx))
    assert ok?(result), "settle_due: #{inspect(result)}"
    result
  end

  @doc "Whether a settler result is a success."
  def ok?(:ok), do: true
  def ok?({:ok, _}), do: true
  def ok?(_other), do: false

  @doc "Whether `result` is an authorization refusal."
  def forbidden?({:error, %Ash.Error.Forbidden{}}), do: true
  def forbidden?({:error, :forbidden}), do: true
  def forbidden?(_other), do: false

  @doc "Asserts that RemoteModelCall declares `:expire_unclaimed` pending → expired_unclaimed."
  def expire_unclaimed!(resource \\ F.call_resource()) do
    F.loaded!(resource)

    assert Ash.Resource.Info.action(resource, :expire_unclaimed),
           "RemoteModelCall has no :expire_unclaimed action"

    assert {:expire_unclaimed, [:pending], :expired_unclaimed} in resource.transitions(),
           "RemoteModelCall.transitions/0 lacks pending → expired_unclaimed: " <>
             inspect(resource.transitions())

    resource
  end

  ## Reservation bound to the real schema ref

  @doc "Reservation overrides freezing `purpose`'s current schema ref (as admission compares)."
  def schema_bound(purpose \\ :qualification, overrides \\ %{}) do
    ref = Schemas.ref(purpose)

    Map.merge(
      %{
        purpose: purpose,
        output_schema_id: ref.id,
        output_schema_version: ref.version,
        output_schema_sha256: ref.sha256
      },
      Map.new(overrides)
    )
  end

  ## Transcripts

  @doc "A QualificationResult the bound Zoi schema accepts."
  def valid_output do
    %{
      "qualified" => true,
      "score" => 82,
      "criteria" => %{
        "company_size" => "pass",
        "industry" => "pass",
        "geography" => "unknown",
        "persona" => "pass",
        "trigger" => "fail"
      },
      "confidence" => 0.5,
      "evidence_ids" => [],
      "reason" => "synthetic qualification"
    }
  end

  @doc "The init attestation of the real profile (`overrides` replace fields)."
  def init_event(overrides \\ %{}) do
    {:ok, profile} = ModelProfiles.fetch_real(:claude_cli_opus)

    Map.merge(
      %{
        "type" => "system",
        "subtype" => "init",
        "model" => profile.resolved_model,
        "claude_code_version" => profile.cli_version,
        "tools" => [],
        "mcp_servers" => [],
        "slash_commands" => []
      },
      overrides
    )
  end

  @doc "An assistant event carrying `marker/0` (part of the transcript, never of the output)."
  def assistant_event,
    do: %{"type" => "assistant", "message" => %{"content" => "thinking " <> @marker}}

  @doc "A result event whose result text is `output` JSON-encoded (or a string as given)."
  def result_event(output \\ valid_output()) do
    text = if is_binary(output), do: output, else: Jason.encode!(output)

    %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "result" => text,
      "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
    }
  end

  @doc "Stream-json lines of `events` (each a map or a raw line)."
  def stream(events) do
    Enum.map_join(events, fn
      line when is_binary(line) -> line <> "\n"
      event -> Jason.encode!(event) <> "\n"
    end)
  end

  @doc "A valid transcript: init, an assistant event carrying the marker, the result."
  def valid_transcript(output \\ valid_output()),
    do: stream([init_event(), assistant_event(), result_event(output)])

  ## A run the StaleRunSweeper can recover

  @doc """
  `fx` with `run:` replaced by a started run whose Operation is bound to a
  discarded Oban job (what Oban's lifeline leaves after a crash), so the
  StaleRunSweeper treats it as abandoned once past its stale window.
  """
  def swept!(fx) do
    {:ok, job} =
      Oban.insert(
        Oban.Job.new(%{"sb3" => "synthetic"}, worker: SdrAgent.SDR.AgentWorker, queue: :research)
      )

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

    {:ok, operation} =
      SdrAgent.Operations.create_operation(
        %{
          kind: :research_lead,
          queue: :research,
          oban_job_id: job.id,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: Ecto.UUID.generate(),
          idempotency_key: "sb3-swept:#{System.unique_integer([:positive])}",
          correlation_id: Ecto.UUID.generate(),
          max_attempts: 1
        },
        actor: fx.agent
      )

    {:ok, operation} = SdrAgent.Operations.start_operation(operation, actor: fx.agent)

    attrs =
      fx.definition
      |> SdrAgent.AgentsFixtures.run_attrs()
      |> Map.put(:operation_id, operation.id)

    {:ok, run} = SdrAgent.Agents.create_run(attrs, actor: fx.agent)
    {:ok, run} = SdrAgent.Agents.start_run(run, actor: fx.agent)
    %{fx | run: run}
  end

  @doc "The AgentRun row `id` (plain SQL, string keys)."
  def run_row(id) do
    assert [row] = F.rows(SdrAgent.Agents.AgentRun, "id = $1", [F.dump(id)]), "no run #{id}"
    row
  end

  ## Claimed and completed calls

  @doc """
  The test process's one enrolled MacWorker of `fx`'s binding (one active
  worker per binding): enrolled on first use, then reused. `%{worker:, token:}`.
  """
  def worker!(fx) do
    key = {__MODULE__, :worker, fx.binding.id}

    case Process.get(key) do
      nil ->
        enrolled = F.enrol!(fx)
        Process.put(key, enrolled)
        enrolled

      enrolled ->
        enrolled
    end
  end

  @doc """
  Reserves (with `overrides`) at a frozen instant and claims it with
  `worker!/1`: `%{worker, token, invocation, nonce, launch, call_id, t1}`.
  The claim takes the earliest pending call, so reserve other pending calls
  after this one.
  """
  def claimed!(fx, overrides \\ %{}) do
    %{worker: worker, token: token} = worker!(fx)
    t0 = F.instant()
    SdrAgent.Clock.freeze(t0)
    invocation = F.reserve!(fx, overrides)
    t1 = DateTime.add(t0, 3, :second)
    SdrAgent.Clock.freeze(t1)
    nonce = F.nonce()
    launch = F.claim!(token, nonce)

    %{
      worker: worker,
      token: token,
      invocation: invocation,
      nonce: nonce,
      launch: launch,
      call_id: launch.call_id,
      t1: t1
    }
  end

  @doc "A claimed call completed (`:accepted`) with `transcript`; the invocation stays sent."
  def completed!(fx, transcript, overrides \\ schema_bound()) do
    c = claimed!(fx, overrides)

    kind =
      F.kind(F.complete(c.token, c.nonce, c.call_id, c.launch.request_sha256, transcript))

    assert kind == :accepted, "prerequisite: complete: #{inspect(kind)}"
    assert F.call_row(c.call_id)["state"] == "completed"
    assert invocation_row(c.invocation.id)["status"] == "sent"
    c
  end

  ## Rows

  @doc "The ModelInvocation row `id` (plain SQL, string keys)."
  def invocation_row(id) do
    assert [row] = F.rows(ModelInvocation, "id = $1", [F.dump(id)]), "no invocation #{id}"
    row
  end

  @doc "Whether the invocation row's `error` map carries `code` as a value (at any depth)."
  def error_code?(row, code), do: carries?(row["error"], code)

  defp carries?(value, code) when is_binary(value), do: value == code

  defp carries?(map, code) when is_map(map),
    do: Enum.any?(map, fn {_k, v} -> carries?(v, code) end)

  defp carries?(list, code) when is_list(list), do: Enum.any?(list, &carries?(&1, code))
  defp carries?(_value, _code), do: false

  @doc "Count of ModelResultRelease rows of invocation `id`."
  def release_count(id) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s[SELECT count(*) FROM "model_result_releases" WHERE model_invocation_id = $1],
        [F.dump(id)]
      )

    n
  end

  @doc "Count of ModelInvocations of run `run_id`."
  def invocations_of_run(run_id) do
    %{rows: [[n]]} =
      Repo.query!(~s[SELECT count(*) FROM "model_invocations" WHERE agent_run_id = $1], [
        F.dump(run_id)
      ])

    n
  end

  @doc "Count of AuditEvents (any tenant) of `type` whose subject is `subject_id`."
  def any_tenant_subject_count(type, subject_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE event_type = $1 AND subject_id = $2",
        [type, to_string(subject_id)]
      )

    n
  end

  @doc """
  Sets `column` of row `id` of `table` to `value` with triggers disabled (a
  planted row, as an administrator would), in its own transaction.
  """
  def plant!(table, id, column, value) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        %{num_rows: 1} =
          Repo.query!(~s[UPDATE "#{table}" SET "#{column}" = $1 WHERE id = $2], [
            value,
            F.dump(id)
          ])

        Repo.query!("SET LOCAL session_replication_role = origin")
      end)

    :ok
  end
end
