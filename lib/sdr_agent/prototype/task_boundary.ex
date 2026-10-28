defmodule SdrAgent.Prototype.TaskBoundary do
  @moduledoc """
  The terminal, value-free presentation boundary of the D-237 prototype
  tasks (S1b task presentation boundary proposal r2; Codex 70e186ec
  "must_fix before task presentation").

  Every `sdr.prototype.*` task's `run/1` is exactly two statements:

      attached = SafeLog.attach()
      TaskBoundary.run(:import, attached, fn -> ... end)

  The proposed contract of `run/3` (proposal r2 section 2; NOT
  implemented):

  - `task` is one atom of `t:task/0` and `body` a zero-arity function;
    anything else aborts at stage `:entry` without calling the body and
    without raising.
  - `attached` must be exactly `:ok`; anything else aborts at stage
    `:attach` without calling the body.
  - An outermost call refuses, at stage `:entry`, a calling process that
    holds process-local authority: an open `SdrAgent.Repo` transaction or
    an active `SdrAgent.AgentEnv.OperationSnapshot` registration. Nothing
    is copied into the body's process.
  - The body runs in a fresh monitored process whose `$callers` is the
    caller followed by the caller's own `$callers`. Inside that process a
    nested `run/3` runs its body inline (no new process, no catch).
  - Only a body result of `:ok` (completed) or `:refused` (the body printed
    its own closed code) is known. Every other result, raise, throw, exit
    or death of the body's process aborts at stage `:body`.
  - `:ok` returns `:ok`; `:refused` exits `{:shutdown, 2}`; an abort prints
    at most the one fixed line `prototype: task_aborted task=<task>
    stage=<stage>` through `SafeLog.say/2` (a withheld line when `task` is
    not valid; no line when stdout is broken) and exits `{:shutdown, 70}`.
  - It never reads, formats, logs or classifies a caught kind, reason,
    exception, stacktrace or exit reason, owns no transaction and changes
    no Logger configuration.

  Deny-only declaration (D-237 S1b, Codex 2be38ff6, correlation
  m_1793191947818835667_4f40bdc2): `run/3` is NOT implemented. It never
  calls the body, never starts a process, never exits, never prints and
  never changes the environment; it returns `{:error, :not_implemented}`.
  """

  @typedoc "The closed set of task atoms the boundary presents."
  @type task :: :setup | :provision | :import | :op | :serve | :export

  @doc "Runs a task body inside the boundary; see the moduledoc (deny-only)."
  @spec run(task(), term(), (-> :ok | :refused)) :: :ok | {:error, :not_implemented}
  def run(_task, _attached, _body), do: red({:error, :not_implemented})

  @typedoc "One observed entry-guard result: what the guard returned, or the kind it raised."
  @type observed :: {:returned, term()} | {:raised, :error | :exit | :throw}

  @doc """
  The pure entry decision of contract r6 steps 4a and 4b (deny-only).

  `repo` is the observed `SdrAgent.Prototype.RepoState.repo_state/0`
  result, called dynamically (an absent module is observed as
  `{:raised, :error}`); `snapshot` is the observed
  `SdrAgent.AgentEnv.OperationSnapshot.current/0` result. The answer is
  `:clear` only when `repo` is `{:returned, :not_started}` or
  `{:returned, {:started, false}}` AND `snapshot` is `{:returned, :inert}`
  or `{:returned, {:error, :snapshot_not_in_use}}`; every other pair,
  malformed observations included, is `:refuse`. The observations are
  bounded and non-linearizable (contract r6); the decision never reads,
  formats or retains a raised value.

  Deny-only declaration (D-237 S1b I2 RED): returns
  `{:error, :not_implemented}`.
  """
  @spec entry_decision(observed() | term(), observed() | term()) ::
          :clear | :refuse | {:error, :not_implemented}
  def entry_decision(_repo, _snapshot), do: red({:error, :not_implemented})

  # Deny-only stub result, typed dynamic() so callers' success clauses
  # compile against it (Elixir 1.20 infers literal returns); read-only,
  # nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
