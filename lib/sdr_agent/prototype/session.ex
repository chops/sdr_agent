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

  It returns `{:ok, %{actor: SdrAgent.Actor.t(), delegation_id: uuid,
  binding: SdrAgent.Prototype.Binding.t()}}` or `{:error, code}` with a
  code of `SdrAgent.Prototype.SafeLog.reasons(:setup)`; `refuse/1` prints
  that code through `SafeLog.say/2` and exits with status 2.

  Stage (D-237 S1 G): `enter/1` runs the boot check, then the session
  entry, in that order; the insert-only Oban of `enqueue?: true` is not yet
  started here (the enqueuing commands come with their own increment).
  """

  @doc "The insert-only Oban options of an enqueuing task (ruling 1)."
  @spec oban_insert_only_opts() :: keyword()
  def oban_insert_only_opts do
    [queues: false, plugins: false, peer: false, stage_interval: :infinity]
  end

  @doc "Enters a task process; see the moduledoc."
  @spec enter(keyword()) :: {:ok, map()} | {:error, atom()}
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    def enter(opts) when is_list(opts) do
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
    def enter(opts) when is_list(opts) do
      with :ok <- boot(), do: {:error, :not_prototype_runtime}
    end
  end

  # The boot check first, before any other read (IF-2 task kind); its refusal
  # is the fixed boot code.
  defp boot do
    SdrAgent.Prototype.BootCheck.verify!()
  rescue
    error in SdrAgent.Prototype.BootCheck.Refusal -> {:error, error.code}
  end
end
