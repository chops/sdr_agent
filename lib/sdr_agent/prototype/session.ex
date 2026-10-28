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

  RED stage (D-237 S1): `oban_insert_only_opts/0` is the contract; `enter/1`
  returns `{:error, :not_implemented}`.
  """

  @doc "The insert-only Oban options of an enqueuing task (ruling 1)."
  @spec oban_insert_only_opts() :: keyword()
  def oban_insert_only_opts do
    [queues: false, plugins: false, peer: false, stage_interval: :infinity]
  end

  @doc "Enters a task process; see the moduledoc."
  @spec enter(keyword()) :: {:ok, map()} | {:error, atom()}
  def enter(_opts), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
