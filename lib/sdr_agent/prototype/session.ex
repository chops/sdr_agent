defmodule SdrAgent.Prototype.Session do
  @moduledoc """
  The common entry of the D-237 operator task processes (interfaces r6 IF-2
  "Process kinds", IF-3 "How a session delegation is created"): every
  `sdr.prototype.*` task except setup calls `enter/1` right after
  `SdrAgent.Prototype.SafeLog.attach/0`.

  `enter/1` starts `app.config` and the Repo (never the application tree),
  runs `SdrAgent.Prototype.BootCheck.verify!/0` before any read, then
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

  These codes are not all in every task's `SdrAgent.Prototype.SafeLog`
  reason set. Printing them is the calling task's job; no such mapping
  exists here.

  Stage (D-237 S1 G): `enter/1` runs the boot check, then the session
  entry, in that order; the insert-only Oban of `enqueue?: true` is not yet
  started here (the enqueuing commands come with their own increment).
  """

  @doc "The insert-only Oban options of an enqueuing task (ruling 1)."
  @spec oban_insert_only_opts() :: keyword()
  def oban_insert_only_opts do
    [queues: false, plugins: false, peer: false, stage_interval: :infinity]
  end

  @doc """
  The pure Repo decision of a task entry (S1 I4b r2 §7), over a
  `SdrAgent.Prototype.RepoState.repo_state/0` result: `:not_started` is
  `:start` (the entry starts the Repo), `{:started, false}` is `:reuse`
  (a Repo this entry does not own and never stops), and `{:started, true}`
  or any other value is `{:error, :binding_mismatch}` (the nesting
  refusal). It starts, stops and reads nothing. RED: not implemented.
  """
  @spec repo_decision(term()) ::
          :start | :reuse | {:error, :binding_mismatch} | {:error, :not_implemented}
  def repo_decision(_state), do: red({:error, :not_implemented})

  @doc "Enters a task process; see the moduledoc."
  @spec enter(keyword()) :: {:ok, map()} | {:error, atom()}
  def enter(opts) when is_list(opts) do
    with :ok <- not_nested(), do: entered(opts)
  end

  # Codex f3036a14 G-R6: an open caller transaction is refused before the
  # build branch, the boot check or any query, with enter_session/2's own
  # nesting code. Repo.in_transaction?/0 issues no query.
  defp not_nested,
    do: if(SdrAgent.Repo.in_transaction?(), do: {:error, :binding_mismatch}, else: :ok)

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defp entered(opts) do
      with :ok <- boot(),
           {:ok, agent} <- agent(Keyword.get(opts, :agent)),
           {:ok, correlation} <- correlation(Keyword.get(opts, :session_correlation)),
           {:ok, delegation_id} <- SdrAgent.Prototype.enter_session(agent, correlation),
           {:ok, actor} <- SdrAgent.Prototype.operator_actor(delegation_id),
           {:ok, binding} <- SdrAgent.Prototype.binding() do
        {:ok, %{actor: actor, delegation_id: delegation_id, binding: binding}}
      end
    end

    defp agent("claude_code"), do: {:ok, :claude_code}
    defp agent("codex_cli"), do: {:ok, :codex_cli}
    defp agent(_other), do: {:error, :invalid_agent}

    defp correlation(value) when is_binary(value) and value != "", do: {:ok, value}
    defp correlation(_unset), do: {:error, :session_unset}
  else
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

  # RED stub result, typed dynamic() so callers compile against the stub
  # (Elixir 1.20 infers literal returns). Read-only: nothing writes the key;
  # removed in GREEN.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
