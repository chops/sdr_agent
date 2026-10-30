defmodule SdrAgent.Prototype.Session do
  @moduledoc """
  The common entry of the D-237 operator task processes (interfaces r6 IF-2
  "Process kinds", IF-3 "How a session delegation is created"). Operator
  callers enter through `enter/1`, not directly through `enter_session/2`.

  The terminal import caller loads `app.config` through its Mix requirement
  before attaching SafeLog and calling `TaskBoundary.launch/3`. Its body
  starts OpenTelemetry and parses argv before entering Session; the import
  guard and protected readers follow successful entry. In a prototype build,
  `enter/1` observes the real RepoState first: it starts the real Repo only
  when absent, reuses an existing non-transactional Repo without owning or
  stopping it, and refuses every other state. It never starts the product
  application tree. It then runs `SdrAgent.Prototype.BootCheck.verify!/0`
  before any session or domain read, followed by
  `SdrAgent.Prototype.enter_session/2` with the `agent:` option (the task's
  `--agent`) and `SDR_PROTOTYPE_SESSION`. Only with `enqueue?: true`
  (`op assign`, `op approve`) does it then start the insert-only Oban of
  `oban_insert_only_opts/0` under a task-local supervisor: no queues,
  plugins, peer or stager, so jobs are only inserted inside the action's
  transaction and execute only in serve.

  A call made inside an already-open transaction
  (`SdrAgent.Repo.in_transaction?/0`) is refused first, in both builds,
  with `:binding_mismatch` (the code of `enter_session/2`'s own nesting
  refusal). This happens before the agent and correlation checks, before
  the boot check and before any query, so the caller's transaction, the
  fixed runtime and the delegations are untouched (Codex f3036a14 G-R6).
  Nothing here catches a rollback throw. The public
  `SdrAgent.Prototype.BootCheck.check/1` and `verify!/0` remain unsupported
  inside a foreign transaction, and every task must enter through
  `enter/1`.

  It returns `{:ok, %{actor: SdrAgent.Actor.t(), delegation_id: uuid,
  binding: SdrAgent.Prototype.Binding.t()}}` or `{:error, code}`.
  - With the prototype authority, `code` is one of: `:binding_mismatch`, a
    boot refusal code (`SdrAgent.Prototype.BootCheck.reasons/0`),
    `:invalid_agent`, `:session_unset`, `:invalid_correlation`,
    `:not_prototype_runtime` or `:delegation_not_found`.
  - In a production build it is `:binding_mismatch`, a boot refusal code or
    `:not_prototype_runtime`.

  A failed prototype Repo start raises the fixed, value-free
  `SdrAgent.Prototype.SessionRepoStart.RepoStartError`; the calling
  TaskBoundary owns presentation. A concurrent winner is never adopted or
  stopped. The real Repo's OTP parent is the starting body process; no
  survival or termination time after that body exits is promised here.

  These codes are not all in every task's `SdrAgent.Prototype.SafeLog`
  reason set. Printing them is the calling task's job; no such mapping
  exists here.

  With `enqueue?: true` the insert-only Oban starts last, after the
  binding read, from the configured Oban options merged with
  `oban_insert_only_opts/0` (`insert_only_config/1`), under a supervisor
  linked to the calling body; any start failure raises the fixed,
  value-free `ObanStartError`. Production builds
  retain the existing transaction guard and never reference the prototype
  RepoState or startup adapter at runtime.
  """

  defmodule ObanStartError do
    @moduledoc """
    Fixed insert-only Oban start failure of an enqueuing task entry. It
    carries no cause, options or process identifier; TaskBoundary presents
    the existing fixed abort outcome.
    """
    defexception message: "prototype: oban_start_failed"
  end

  @doc "The insert-only Oban options of an enqueuing task (ruling 1)."
  @spec oban_insert_only_opts() :: keyword()
  def oban_insert_only_opts do
    [queues: false, plugins: false, peer: false, stage_interval: :infinity]
  end

  @doc """
  Pure: the configured Oban options `base` with `oban_insert_only_opts/0`
  over them, so no queue, plugin, peer or stager runs in a task process.
  """
  @spec insert_only_config(keyword()) :: keyword()
  def insert_only_config(base) when is_list(base),
    do: Keyword.merge(base, oban_insert_only_opts())

  @doc """
  The pure Repo decision of a task entry (S1 I4b r2 §7), over a
  `SdrAgent.Prototype.RepoState.repo_state/0` result: `:not_started` is
  `:start` (the entry starts the Repo), `{:started, false}` is `:reuse`
  (a Repo this entry does not own and never stops), and `{:started, true}`
  or any other value is `{:error, :binding_mismatch}` (the nesting
  refusal). It starts, stops and reads nothing.
  """
  @spec repo_decision(term()) :: :start | :reuse | {:error, :binding_mismatch}
  def repo_decision(:not_started), do: :start
  def repo_decision({:started, false}), do: :reuse
  def repo_decision(_state), do: {:error, :binding_mismatch}

  @doc "Enters a task process; see the moduledoc."
  @spec enter(keyword()) :: {:ok, map()} | {:error, atom()}
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    def enter(opts) when is_list(opts) do
      case repo_decision(SdrAgent.Prototype.RepoState.repo_state()) do
        :start ->
          :ok = SdrAgent.Prototype.SessionRepoStart.start!()
          entered(opts)

        :reuse ->
          entered(opts)

        {:error, :binding_mismatch} = refusal ->
          refusal
      end
    end

    defp entered(opts) do
      with :ok <- boot(),
           {:ok, agent} <- agent(Keyword.get(opts, :agent)),
           {:ok, correlation} <- correlation(Keyword.get(opts, :session_correlation)),
           {:ok, delegation_id} <- SdrAgent.Prototype.enter_session(agent, correlation),
           {:ok, actor} <- SdrAgent.Prototype.operator_actor(delegation_id),
           {:ok, binding} <- SdrAgent.Prototype.binding(),
           :ok <- insert_only_oban(Keyword.get(opts, :enqueue?, false)) do
        {:ok, %{actor: actor, delegation_id: delegation_id, binding: binding}}
      end
    end

    # IF-2 task kind: only an enqueuing command starts Oban, insert-only,
    # under a supervisor linked to (and ending with) the calling body.
    defp insert_only_oban(false), do: :ok
    defp insert_only_oban(true), do: start_insert_only_oban()

    @doc false
    # Public only for the cold-VM proof (test/support/session_oban_thin_child.exs);
    # callers enter through `enter/1` with `enqueue?: true`.
    @spec start_insert_only_oban() :: :ok
    def start_insert_only_oban do
      # A cold terminal has loaded configuration only: Oban.Registry belongs
      # to the :oban application, which no other entry step starts.
      {:ok, _started} = Application.ensure_all_started(:oban)
      config = insert_only_config(Application.fetch_env!(:sdr_agent, Oban))

      case Supervisor.start_link([{Oban, config}], strategy: :one_for_one) do
        {:ok, _supervisor} -> :ok
        _not_started -> raise ObanStartError
      end
    catch
      _kind, _reason -> raise ObanStartError
    end

    defp agent("claude_code"), do: {:ok, :claude_code}
    defp agent("codex_cli"), do: {:ok, :codex_cli}
    defp agent(_other), do: {:error, :invalid_agent}

    defp correlation(value) when is_binary(value) and value != "", do: {:ok, value}
    defp correlation(_unset), do: {:error, :session_unset}
  else
    def enter(opts) when is_list(opts) do
      with :ok <- not_nested(), do: entered(opts)
    end

    # Production keeps the original query-free transaction guard.
    defp not_nested,
      do: if(SdrAgent.Repo.in_transaction?(), do: {:error, :binding_mismatch}, else: :ok)

    # No prototype authority in this build: the boot check runs, and the
    # entry then refuses.
    defp entered(_opts) do
      with :ok <- boot(), do: {:error, :not_prototype_runtime}
    end
  end

  # The boot check first, before any other read (IF-2 task kind); its refusal
  # is the fixed boot code.
  defp boot do
    SdrAgent.Prototype.BootCheck.verify!()
  rescue
    error in SdrAgent.Prototype.BootCheck.RefusalError -> {:error, error.code}
  end
end
