defmodule SdrAgent.Test.AgentEnvFixtures do
  @moduledoc """
  C2* S1 PR-A fixtures for the agent environment's operation snapshot
  (plan `claude-c2star-s1-environment-plan-r2.md` section 4.7; ADR-0005 C2*
  amendment item 2 and its addendum 1, D-227). They use only existing
  modules — `SdrAgent.Audit.Canonical`, `SdrAgent.Repo`, the Application
  environment and, for the setup of a real run, the agent framework's own
  pieces — so they compile while `SdrAgent.AgentEnv` and its modules do not
  exist yet. `SdrAgent.AgentEnv.OperationSnapshot` is only ever resolved at
  run time (`current_snapshot/0`).

    * `root!/1` — a fresh physical 0700 root under the gitignored
      `tmp/agent-env-roots` (fresh across VMs, as `SdrAgent.Test.WitnessRoot`
      builds its roots); removed on exit.
    * `configure!/2`, `unconfigure!/0` — the `config :sdr_agent,
      SdrAgent.AgentEnv` keyword (`root:`, `mode:`, `step:`, `nonce:`,
      `database:`), restored on exit (`async: false` tests only, as
      `SdrAgent.OutreachFixtures.put_env!/2`). `database:` defaults to the
      live test database, so a bound environment of that database is
      attested.
    * `bound!/2` — the `<root>/state/` files of a bound environment: the
      bootstrap history (pending, created, the four step receipts), an
      `environment.json` for the live test database and the sandbox tenant
      (or a given `database_oid:`), and a `:run` or `:provisioning` lease
      (`lease: :none` writes none). Returns `%{nonce, bootstrap_nonce,
      binding_sha256, environment, database, database_oid, tenant_id}`;
      `nonce` is the lease's.
    * `authorized!/2` — `authorization.claim.json` and `authorization.json`
      bound to the environment; `fields` override any key of the final file,
      so tests can write deliberately inconsistent files.
    * `tamper!/2`, `write_state!/3`, `write_lease!/3`, `path/2` — direct
      state-file writes (S4 T-U3 uses `tamper!/2`). Files are canonical
      `sdr-canonical-json/1` bytes with no trailing newline, mode 0600.
    * `trace_snapshots/2` — runs `fun` and returns `{result, events}`: every
      `[:sdr_agent, :agent_env, :snapshot, …]` event from any process, in
      emission order, as `%{kind, pid, seq, metadata, measurements,
      in_transaction?}` (`in_transaction?` is read in the emitting process).
      With `queries: predicate`, matching `[:sdr_agent, :repo, :query]`
      events are recorded too, as `%{kind: :query, pid, seq, query, source,
      in_transaction?, current}`, where `current` is
      `OperationSnapshot.current/0` evaluated in the querying process at that
      query (`:unavailable` while the module does not exist).
    * `trace_file_calls/1` — runs `fun` and returns `{result, calls}`, every
      `:file`/`:prim_file` call the calling process made (an OTP trace
      session; the tracer is a separate collector process).
    * `handoff_ready!/2`, `evidence_ready!/2` (F2; Codex OQ5 ruling) —
      `{params, sdr_ctx}` at the boundary of a real run's `"proposal"` step
      (B1's six `HandOffProposal` params) or `"bundle"` step. Setup only,
      through the framework's own pieces: the run is created by
      `SdrAgent.SDRCase.assign!/2` and started as `AgentWorker.run/2` starts
      it (no drain); its turns run through `Jido.Agent.cmd/3` with the
      Runner's context shape, recording emitted signals and syncing phase
      and budget as `SdrAgent.SDR.Runner` does, up to the signal of the
      target flow; that flow then runs through `Jido.Exec.run/4` as a
      runtime copy truncated before the target step, whose output is the
      step's own params expression. The params are therefore exactly the
      flow's mapping at this base. The proof that follows calls the step's
      `perform/2` (or `run/2`) itself; callers start their trace only then.

  Disclosure: the fixtures write only their own private roots and the
  test's sandboxed rows. Nothing here is production provisioning evidence.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Repo
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Flows.PrepareOutreachFlow
  alias SdrAgent.SDR.Flows.ResearchLeadFlow
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SDR.Signals
  alias SdrAgent.SDRCase
  alias SdrAgent.Telemetry.Agent, as: Spans

  @config SdrAgent.AgentEnv
  @snapshot SdrAgent.AgentEnv.OperationSnapshot
  @environment_id "agentenv-1"
  @run_port 4130
  @bootstrap_steps [:create, :migrate, :seed, :probe]
  @attempts 5
  @turn_timeout 900_000
  @max_turns 12
  @query_event [:sdr_agent, :repo, :query]
  @snapshot_events [
    [:sdr_agent, :agent_env, :snapshot, :observe, :start],
    [:sdr_agent, :agent_env, :snapshot, :observe, :stop],
    [:sdr_agent, :agent_env, :snapshot, :observe, :exception],
    [:sdr_agent, :agent_env, :snapshot, :inherit],
    [:sdr_agent, :agent_env, :snapshot, :refuse],
    [:sdr_agent, :agent_env, :snapshot, :invalidate]
  ]

  ## Roots and configuration

  @doc "A fresh physical 0700 root under `tmp/agent-env-roots`; removed on exit."
  def root!(prefix \\ "agentenv") do
    base = Path.expand("tmp/agent-env-roots")
    File.mkdir_p!(base)
    Enum.each([Path.dirname(base), base], &File.chmod!(&1, 0o755))
    root = allocate!(base, prefix, @attempts)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp allocate!(_base, _prefix, 0),
    do: raise("C2* S1 fixture: no fresh agent-env root: every candidate already exists")

  defp allocate!(base, prefix, attempts) do
    root = Path.join(base, "#{prefix}-#{hex(16)}")

    case File.mkdir(root) do
      :ok ->
        File.chmod!(root, 0o700)
        root

      {:error, :eexist} ->
        allocate!(base, prefix, attempts - 1)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory", path: root
    end
  end

  @doc """
  Configures `SdrAgent.AgentEnv` for the rest of the test: `mode:` (`:run`,
  `:provisioning`, `:bootstrap` or `:check`; required), `nonce:`, `step:`
  (default per mode) and `database:` (default: the live test database).
  Returns the keyword written.
  """
  def configure!(root, opts) do
    mode = Keyword.fetch!(opts, :mode)

    config = [
      root: root,
      mode: mode,
      step: Keyword.get_lazy(opts, :step, fn -> default_step(mode) end),
      nonce: Keyword.get(opts, :nonce),
      database: Keyword.get_lazy(opts, :database, &configured_database/0)
    ]

    put_config!(config)
    config
  end

  @doc "Removes any `SdrAgent.AgentEnv` configuration for the rest of the test (inert)."
  def unconfigure!, do: put_config!(nil)

  defp put_config!(config) do
    previous = Application.fetch_env(:sdr_agent, @config)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, @config, value)
        :error -> Application.delete_env(:sdr_agent, @config)
      end
    end)

    if config,
      do: Application.put_env(:sdr_agent, @config, config),
      else: Application.delete_env(:sdr_agent, @config)

    :ok
  end

  defp default_step(:run), do: :run
  defp default_step(:provisioning), do: :provision
  defp default_step(:bootstrap), do: :seed
  defp default_step(:check), do: :check

  defp configured_database, do: Keyword.fetch!(Repo.config(), :database)

  ## State files

  @doc """
  Writes a bound environment under `root` (see the moduledoc). Options:
  `lease:` (`:run`, default; `:provisioning`; `:none`), `database_oid:`
  (`:live`, default, or an integer), `tenant_id:` (default: the singleton
  tenant).
  """
  def bound!(root, opts \\ []) do
    {database, live_oid} = live_identity!()

    oid =
      case Keyword.get(opts, :database_oid, :live) do
        :live -> live_oid
        oid when is_integer(oid) -> oid
      end

    tenant_id = Keyword.get_lazy(opts, :tenant_id, &tenant_id!/0)
    bootstrap = nonce()

    write_state!(root, :pending, %{
      "environment_id" => @environment_id,
      "nonce" => bootstrap,
      "started_at" => DateTime.utc_now()
    })

    write_state!(root, :created, %{
      "database" => database,
      "database_oid" => oid,
      "nonce" => bootstrap
    })

    Enum.each(@bootstrap_steps, fn step ->
      write_state!(root, {:receipt, bootstrap, step}, receipt(bootstrap, step, tenant_id))
    end)

    environment = %{
      "environment_id" => @environment_id,
      "database" => database,
      "database_oid" => oid,
      "tenant_id" => tenant_id,
      "nonce" => bootstrap,
      "created_at" => DateTime.utc_now()
    }

    binding = write_state!(root, :environment, environment)

    %{
      nonce: write_lease!(root, Keyword.get(opts, :lease, :run), binding),
      bootstrap_nonce: bootstrap,
      binding_sha256: binding,
      environment: Canonical.normalize(environment),
      database: database,
      database_oid: oid,
      tenant_id: tenant_id
    }
  end

  # Per-step receipt keys (section 4.2): `probe` adds `tenant_id`.
  defp receipt(nonce, step, tenant_id) do
    base = %{
      "nonce" => nonce,
      "step" => Atom.to_string(step),
      "completed_at" => DateTime.utc_now()
    }

    if step == :probe, do: Map.put(base, "tenant_id", tenant_id), else: base
  end

  @doc """
  Writes `instance.lease` for `mode` (`:run` or `:provisioning`) targeting
  `binding_sha256`, with a fresh nonce; `:none` writes nothing. Returns the
  nonce (or nil).
  """
  def write_lease!(_root, :none, _binding_sha256), do: nil

  def write_lease!(root, mode, binding_sha256) when mode in [:run, :provisioning] do
    nonce = nonce()

    write_state!(root, :lease, %{
      "environment_id" => @environment_id,
      "mode" => Atom.to_string(mode),
      "nonce" => nonce,
      "target" => %{"binding_sha256" => binding_sha256},
      "port" => if(mode == :run, do: @run_port, else: nil),
      "started_at" => DateTime.utc_now()
    })

    nonce
  end

  @doc """
  Writes the claim and the final authorization files bound to the
  environment under `root`; `fields` (string or atom keys) override keys of
  `authorization.json`. Returns `%{sha256, claim_sha256, data, claim}` (the
  file digests and the decoded contents).
  """
  def authorized!(root, fields \\ %{}) do
    binding = file_sha256!(root, :environment)
    id = Ecto.UUID.generate()
    entry_digest = hex(32)
    claim_nonce = nonce()

    claim = %{
      "authorization_id" => id,
      "authorization_sha256" => entry_digest,
      "binding_sha256" => binding,
      "nonce" => claim_nonce,
      "claimed_at" => DateTime.utc_now()
    }

    overrides = Map.new(fields, fn {key, value} -> {to_string(key), value} end)

    final =
      Map.merge(
        %{
          "authorization_id" => id,
          "authorization_sha256" => entry_digest,
          "binding_sha256" => binding,
          "grant_id" => Ecto.UUID.generate(),
          "revision" => 1,
          "event_id" => Ecto.UUID.generate(),
          "nonce" => claim_nonce
        },
        overrides
      )

    claim_sha256 = write_state!(root, :claim, claim)
    sha256 = write_state!(root, :authorization, final)

    %{
      sha256: sha256,
      claim_sha256: claim_sha256,
      data: Canonical.normalize(final),
      claim: Canonical.normalize(claim)
    }
  end

  @doc """
  Rewrites the state file `name` with a fresh `nonce` (same closed keys, new
  digest). Returns the new digest.
  """
  def tamper!(root, name) do
    data = root |> path(name) |> File.read!() |> Jason.decode!()
    write_state!(root, name, Map.put(data, "nonce", nonce()))
  end

  @doc """
  Writes the state file `name`: `contents` is a term (written as canonical
  bytes) or raw bytes. Mode 0600 under a 0700 `state/`. Returns the
  lowercase hex SHA-256 of the bytes written.
  """
  def write_state!(root, name, contents) do
    dir = Path.join(root, "state")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    bytes = if is_binary(contents), do: contents, else: Canonical.encode!(contents)
    file = path(root, name)
    File.write!(file, bytes)
    File.chmod!(file, 0o600)
    sha256(bytes)
  end

  @doc "The path of state file `name` (section 4.2 names) under `root`."
  def path(root, name), do: Path.join([root, "state", file_name(name)])

  defp file_name(:pending), do: "environment.pending"
  defp file_name(:lease), do: "instance.lease"
  defp file_name(:created), do: "environment.created.json"
  defp file_name(:environment), do: "environment.json"
  defp file_name(:claim), do: "authorization.claim.json"
  defp file_name(:authorization), do: "authorization.json"
  defp file_name({:receipt, nonce, step}), do: "instance.#{nonce}.#{step}.exit"
  defp file_name({:run_receipt, nonce}), do: "instance.#{nonce}.exit"

  @doc "The lowercase hex SHA-256 of state file `name`'s current bytes."
  def file_sha256!(root, name), do: root |> path(name) |> File.read!() |> sha256()

  @doc "A fresh nonce: 32 lowercase hex characters."
  def nonce, do: hex(16)

  @doc "`bytes` random bytes as lowercase hex."
  def hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc "The live database's name and oid (a plain read): `{name, oid}`."
  def live_identity! do
    %{rows: [[name, oid]]} =
      Repo.query!(
        "SELECT current_database()::text, d.oid::bigint FROM pg_database d " <>
          "WHERE d.datname = current_database()"
      )

    {name, oid}
  end

  defp tenant_id! do
    {:ok, tenant_id} = Kernel.singleton_tenant_id()
    tenant_id
  end

  ## Traces

  @doc """
  Runs `fun` and returns `{result, events}` (see the moduledoc). Option
  `queries:` — a predicate on `[:sdr_agent, :repo, :query]` metadata whose
  matches are recorded with the querying process's `current/0`.
  """
  def trace_snapshots(fun, opts \\ []) when is_function(fun, 0) do
    ref = make_ref()
    id = "c2star-s1-snapshot-trace-#{System.unique_integer([:positive])}"
    queries = Keyword.get(opts, :queries)
    events = if queries, do: [@query_event | @snapshot_events], else: @snapshot_events
    config = %{to: self(), ref: ref, queries: queries}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_trace/4, config)

    try do
      result = fun.()
      {result, collect(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  # Telemetry handler of `trace_snapshots/2`; runs in the emitting process
  # and never raises.
  def handle_trace(@query_event, _measurements, metadata, %{queries: predicate} = config) do
    if matches?(predicate, metadata) do
      send(config.to, {
        config.ref,
        %{
          kind: :query,
          pid: self(),
          seq: seq(),
          query: Map.get(metadata, :query),
          source: Map.get(metadata, :source),
          in_transaction?: in_transaction?(),
          current: current_snapshot()
        }
      })
    end

    :ok
  end

  def handle_trace(event, measurements, metadata, config) do
    send(config.to, {
      config.ref,
      %{
        kind: kind(event),
        pid: self(),
        seq: seq(),
        metadata: metadata,
        measurements: measurements,
        in_transaction?: in_transaction?()
      }
    })

    :ok
  end

  defp kind([_, _, _, :observe, :start]), do: :observe_start
  defp kind([_, _, _, :observe, :stop]), do: :observe_stop
  defp kind([_, _, _, :observe, :exception]), do: :observe_exception
  defp kind([_, _, _, kind]), do: kind

  defp matches?(predicate, metadata) when is_function(predicate, 1) do
    predicate.(metadata) == true
  rescue
    _error -> false
  end

  defp matches?(_predicate, _metadata), do: false

  defp in_transaction? do
    Repo.in_transaction?()
  rescue
    _error -> :unknown
  end

  defp seq, do: System.unique_integer([:monotonic])

  defp collect(ref, acc) do
    receive do
      {^ref, event} -> collect(ref, [event | acc])
    after
      0 -> Enum.sort_by(acc, & &1.seq)
    end
  end

  @doc """
  `SdrAgent.AgentEnv.OperationSnapshot.current/0` in the calling process, or
  `:unavailable` while that module or function does not exist. Never raises.
  """
  def current_snapshot do
    module = snapshot_module()

    if Code.ensure_loaded?(module) and function_exported?(module, :current, 0),
      do: invoke(module, :current, []),
      else: :unavailable
  rescue
    exception -> {:probe_failed, exception.__struct__}
  end

  defp snapshot_module, do: @snapshot

  defp invoke(module, function, args), do: apply(module, function, args)

  @doc """
  Runs `fun` in the calling process and returns `{result, calls}`: each
  `{module, function, arity}` call the process made to `:file` or
  `:prim_file` while `fun` ran, in order.
  """
  def trace_file_calls(fun) when is_function(fun, 0) do
    collector = spawn(fn -> collect_calls([]) end)
    session = :trace.session_create(:c2star_s1_file_calls, collector, [])

    try do
      _ = :trace.function(session, {:file, :_, :_}, true, [])
      _ = :trace.function(session, {:prim_file, :_, :_}, true, [])
      _ = :trace.process(session, self(), true, [:call])
      result = fun.()
      _ = :trace.process(session, self(), false, [:call])
      {result, delivered_calls(session, collector)}
    after
      :trace.session_destroy(session)
      send(collector, :stop)
    end
  end

  defp delivered_calls(session, collector) do
    ref = :trace.delivered(session, self())

    receive do
      {:trace_delivered, _tracee, ^ref} -> :ok
    after
      5_000 -> raise "C2* S1 fixture: trace delivery was not confirmed"
    end

    send(collector, {:calls, self()})

    receive do
      {:file_calls, calls} -> calls
    after
      5_000 -> raise "C2* S1 fixture: the file-call collector did not answer"
    end
  end

  defp collect_calls(acc) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        collect_calls([{module, function, length(args)} | acc])

      {:calls, from} ->
        send(from, {:file_calls, Enum.reverse(acc)})

      :stop ->
        :ok
    end
  end

  ## A real run at a step boundary (setup only)

  @doc """
  `{params, sdr_ctx}` at the `"proposal"` step of `PrepareOutreachFlow` for a
  new assignment of fixture lead `key` (`SdrAgent.SDRCase` context): B1's
  six `HandOffProposal` params as the flow maps them, and the action's
  context (`agent_state` set, no ToolInvocation: a direct call).
  """
  def handoff_ready!(ctx, key),
    do: step_ready!(ctx, key, "sdr.draft.requested", PrepareOutreachFlow, "proposal")

  @doc """
  `{params, sdr_ctx}` at the `"bundle"` step of `ResearchLeadFlow` for a new
  assignment of fixture lead `key` (`SdrAgent.SDRCase` context): the
  `BuildEvidenceBundle` params as the flow maps them.
  """
  def evidence_ready!(ctx, key),
    do: step_ready!(ctx, key, "sdr.research.requested", ResearchLeadFlow, "bundle")

  defp step_ready!(ctx, key, target, flow_module, step) do
    %{job: job} = SDRCase.assign!(ctx, key)
    {sdr, agent, signal} = job |> started!() |> advance!(target)
    turn = turn_context(sdr, signal)
    context = %{sdr: turn, agent_id: agent.id, agent_state: agent.state, signal: signal}

    params =
      flow_module
      |> truncated!(step)
      |> execute!(Map.new(signal.data), context, step)

    {params, %{turn | agent_state: agent.state}}
  end

  # As `SdrAgent.SDR.AgentWorker.run/2` and `SdrAgent.SDR.Runner.run/3`
  # start a run (no drain, no Runner).
  defp started!(%Oban.Job{id: job_id, args: %{"tenant_id" => tenant_id, "signal" => dumped}}) do
    actor = Actor.system(:agent_runtime, tenant_id)
    {:ok, %{} = operation} = Operations.find_operation(job_id, actor: actor)
    {:ok, run} = Agents.find_run_by_operation(operation.id, actor: actor)
    {:ok, signal} = Signals.load(dumped)
    {:ok, _operation} = Operations.start_operation(operation, actor: actor)
    {:ok, run} = Agents.start_run(run, actor: actor)
    {:ok, model} = Runtime.resolve(default_model())

    sdr = %Context{
      actor: actor,
      tenant_id: run.tenant_id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      model: model
    }

    agent =
      SDRAgent.new!(
        id: run.id,
        state: %{
          tenant_id: run.tenant_id,
          run_id: run.id,
          lead_id: run.lead_id,
          campaign_id: run.campaign_id
        }
      )

    {sdr, agent, [signal]}
  end

  defp default_model,
    do: :sdr_agent |> Application.get_env(SdrAgent.SDR, []) |> Keyword.get(:model, [])

  defp advance!({sdr, agent, queue}, target), do: advance!(sdr, agent, queue, target, 0)

  defp advance!(sdr, agent, [%Jido.Signal{type: target} = signal | _rest], target, _turns),
    do: {sdr, agent, signal}

  defp advance!(_sdr, _agent, _queue, target, turns) when turns >= @max_turns,
    do: raise("C2* S1 fixture: the turn limit was reached before #{target}")

  defp advance!(_sdr, _agent, [], target, _turns),
    do: raise("C2* S1 fixture: the run's turns ended before #{target}")

  defp advance!(sdr, agent, [signal | rest], target, turns) do
    {agent, emitted} = turn!(sdr, agent, signal)
    advance!(sdr, agent, rest ++ emitted, target, turns + 1)
  end

  # One Runner turn (`SdrAgent.SDR.Runner`, evaluate/3 and its helpers).
  defp turn!(sdr, agent, signal) do
    opts = [
      context: %{sdr: turn_context(sdr, signal)},
      max_concurrency: 1,
      timeout: @turn_timeout
    ]

    case Jido.Agent.cmd(agent, signal, opts) do
      {:ok, agent, directives} ->
        {:ok, run} = Agents.get_run(sdr.run_id, actor: sdr.actor)
        emitted = for %Jido.Agent.Directive.Emit{signal: next} <- directives, do: next
        Enum.each(emitted, &record!(&1, signal, run, sdr))
        {sync!(agent, run, sdr), emitted}

      other ->
        raise "C2* S1 fixture: turn #{signal.type} failed: #{inspect(other, limit: 5)}"
    end
  end

  defp turn_context(sdr, signal),
    do: %{sdr | signal_id: signal.id, signal_type: signal.type, otel: Spans.current()}

  defp record!(next, parent, run, sdr) do
    {:ok, _event} = Signals.record(next, sdr.actor, run: run, parent: parent.id)
  end

  defp sync!(agent, run, sdr) do
    run = phase!(run, agent.state.phase, sdr)

    {:ok, agent} =
      Jido.Agent.set(agent,
        budget: %{
          model_calls: run.budget.model_calls_used,
          tool_calls: run.budget.tool_calls_used
        }
      )

    agent
  end

  defp phase!(%{phase: phase} = run, phase, _sdr), do: run

  defp phase!(%{status: :running} = run, phase, sdr) do
    {:ok, run} = Agents.set_run_phase(run, phase, actor: sdr.actor)
    run
  end

  defp phase!(run, _phase, _sdr), do: run

  # The flow's canonical value without `step`, whose params expression
  # becomes the output: the params the step would have received.
  defp truncated!(flow_module, step) do
    flow = flow_module.flow()

    case Enum.split_with(flow.components, &(Map.get(&1, :name) == step)) do
      {[%Jido.Flow.Step{params: params}], kept} ->
        Jido.Flow.new!(%{
          flow
          | name: "#{flow.name}_before_#{step}",
            components: kept,
            output: params
        })

      _other ->
        raise "C2* S1 fixture: #{inspect(flow_module)} has no single step #{inspect(step)}"
    end
  end

  defp execute!(flow, input, context, step) do
    case Jido.Exec.run(flow, input, context, max_concurrency: 1, timeout: @turn_timeout) do
      {:ok, params} when is_map(params) ->
        params

      {:ok, params, _effects} when is_map(params) ->
        params

      other ->
        raise "C2* S1 fixture: the flow before #{step} failed: #{inspect(other, limit: 5)}"
    end
  end
end
