# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.TaskBoundary do
    @moduledoc """
    The terminal, value-free presentation boundary of the D-237 prototype
    tasks (S1b task presentation boundary proposal r2; Codex 70e186ec
    "must_fix before task presentation"). Compiled only under
    `:prototype_authority_compiled`; the production build does not contain
    it.

    Every `sdr.prototype.*` task's `run/1` is exactly two statements:

        attached = SafeLog.attach()
        TaskBoundary.run(:import, attached, fn -> ... end)

    The contract of `run/3` (proposal r2 section 2, consolidated in r5
    section 1, with contract r6 steps 4a and 4b), in order:

    1. A call from a body process (it carries the boundary's nesting key)
       is nested: it re-checks steps 2 and 3 and runs `body` inline, in the
       same process, with no catch; a failed re-check raises. The outer
       boundary alone presents the outcome, with the outer task.
    2. `task` is one atom of `t:task/0` and `body` a zero-arity function;
       anything else aborts at stage `:entry` without calling the body and
       without raising.
    3. `attached` must be exactly `:ok`; anything else aborts at stage
       `:attach` without calling the body.
    4. An outermost call refuses, at stage `:entry`, a calling process that
       holds process-local authority: `entry_decision/2` over the observed
       `SdrAgent.Prototype.RepoState.repo_state/0` (S1's adapter, called
       dynamically: in a build without it the call raises, is observed as
       `{:raised, :error}` and refuses) and the observed
       `SdrAgent.AgentEnv.OperationSnapshot.current/0`.
    5. `ERL_CRASH_DUMP_BYTES` is set to `"0"`, a VM-wide effect.
    6. The body runs in a fresh monitored process whose `$callers` is the
       caller followed by the caller's own `$callers`, plus the nesting
       key. Nothing else is copied into it. A raise in steps 5 or 6 aborts
       at stage `:entry`.
    7. Only a body result of `:ok` (completed) or `:refused` (the body
       printed its own closed code) is known. Every other result, raise,
       throw, exit or death of the body's process aborts at stage `:body`.
    8. `:ok` returns `:ok`; `:refused` exits `{:shutdown, 2}`; an abort
       prints at most the one fixed line `prototype: task_aborted
       task=<task> stage=<stage>` through `SafeLog.say/2` (a withheld line
       when `task` is not valid; no line when stdout is broken) and exits
       `{:shutdown, 70}`. A caller continues after an exit only if it
       catches it (contract r6).

    It never reads, formats, logs or classifies a caught kind, reason,
    exception, stacktrace or exit reason, owns no transaction and changes
    no Logger configuration. The entry observations are bounded and
    non-linearizable (contract r6), not transaction or capability erasure.
    A body process outlives a caller that dies after the spawn (disclosed,
    non-deciding). The K0 entry token is not part of this module yet.
    """

    alias SdrAgent.AgentEnv.OperationSnapshot
    alias SdrAgent.Prototype.SafeLog

    # S1's RepoState (a3cd9b78) is reached only through a dynamic call, so
    # a build without it compiles and step 4a fails closed.
    @repo_state SdrAgent.Prototype.RepoState
    @tasks [:setup, :provision, :import, :op, :serve, :export]
    # Set only in a body process (step 6); it marks a nested call (step 1).
    @nested {__MODULE__, :body_process}
    @dump_var "ERL_CRASH_DUMP_BYTES"

    defmodule NestedRefusalError do
      @moduledoc false
      defexception message: "task boundary: nested call refused"
    end

    @typedoc "The closed set of task atoms the boundary presents."
    @type task :: :setup | :provision | :import | :op | :serve | :export

    @typedoc """
    A body's result. Only `:ok` and `:refused` are known; any other term is
    an abort at stage `:body` (moduledoc item 7), never a refusal.
    """
    @type body_result :: :ok | :refused | term()

    @doc """
    Runs a task body inside the boundary; see the moduledoc. An outermost
    call returns `:ok` or exits; a nested call returns the body's result.
    """
    @spec run(task(), term(), (-> body_result())) :: body_result()
    def run(task, attached, body) do
      if Process.get(@nested) == true,
        do: nested(task, attached, body),
        else: outermost(task, attached, body)
    end

    @typedoc "One observed entry-guard result: what the guard returned, or the kind it raised."
    @type observed :: {:returned, term()} | {:raised, :error | :exit | :throw}

    @doc """
    The pure entry decision of contract r6 steps 4a and 4b.

    `repo` is the observed `SdrAgent.Prototype.RepoState.repo_state/0`
    result, called dynamically (an absent module is observed as
    `{:raised, :error}`); `snapshot` is the observed
    `SdrAgent.AgentEnv.OperationSnapshot.current/0` result. The answer is
    `:clear` only when `repo` is `{:returned, :not_started}` or
    `{:returned, {:started, false}}` AND `snapshot` is `{:returned, :inert}`
    or `{:returned, {:error, :snapshot_not_in_use}}`; every other pair,
    malformed observations included, is `:refuse`. The observations are
    bounded and non-linearizable (contract r6); the decision never reads,
    formats or retains a raised value. It reads nothing else and changes
    nothing.
    """
    @spec entry_decision(observed() | term(), observed() | term()) :: :clear | :refuse
    def entry_decision(repo, snapshot) do
      if clear_repo?(repo) and clear_snapshot?(snapshot), do: :clear, else: :refuse
    end

    # Step 4a: no Repo started, or started with no open transaction.
    defp clear_repo?({:returned, :not_started}), do: true
    defp clear_repo?({:returned, {:started, false}}), do: true
    defp clear_repo?(_observed), do: false

    # Step 4b: no OperationSnapshot registration in this process.
    defp clear_snapshot?({:returned, :inert}), do: true
    defp clear_snapshot?({:returned, {:error, :snapshot_not_in_use}}), do: true
    defp clear_snapshot?(_observed), do: false

    # Step 1: steps 2 and 3 again, then the body inline with no catch.
    defp nested(task, attached, body) do
      case admission(task, attached, body) do
        :ok -> body.()
        _stage -> raise NestedRefusalError
      end
    end

    # Steps 2 to 8 of an outermost call; the first failure names its stage.
    defp outermost(task, attached, body) do
      with :ok <- admission(task, attached, body),
           :clear <- entry_guard(),
           {:started, monitored} <- start(body) do
        conclude(task, await(monitored))
      else
        :attach -> abort(task, :attach)
        :entry -> abort(task, :entry)
        :refuse -> abort(task, :entry)
        :not_started -> abort(task, :entry)
      end
    end

    # Steps 2 and 3, in order: the inputs, then the attach result.
    defp admission(task, _attached, body) when task not in @tasks or not is_function(body, 0),
      do: :entry

    defp admission(_task, :ok, _body), do: :ok
    defp admission(_task, _attached, _body), do: :attach

    # Steps 4a and 4b: both observations, then the pure decision.
    defp entry_guard do
      entry_decision(observe(&repo_state/0), observe(&OperationSnapshot.current/0))
    end

    defp repo_state, do: Function.capture(@repo_state, :repo_state, 0).()

    # What a guard returned, or only the kind it raised; the raised value
    # is never read.
    defp observe(guard) do
      {:returned, guard.()}
    catch
      kind, _reason -> {:raised, kind}
    end

    # Steps 5 and 6. A raise here is aborted entry.
    defp start(body) do
      System.put_env(@dump_var, "0")
      caller = self()
      tag = make_ref()
      inherited = Process.get(:"$callers") || []
      callers = [caller | inherited]
      {pid, ref} = spawn_monitor(fn -> body_process(caller, tag, callers, body) end)
      {:started, {pid, ref, tag}}
    catch
      _kind, _reason -> :not_started
    end

    # Step 7, in the body process: only :ok and :refused are known.
    defp body_process(caller, tag, callers, body) do
      Process.put(:"$callers", callers)
      Process.put(@nested, true)
      send(caller, {tag, outcome(body)})
    end

    defp outcome(body) do
      classify(body.())
    catch
      _kind, _reason -> :aborted
    end

    defp classify(:ok), do: :ok
    defp classify(:refused), do: :refused
    defp classify(_result), do: :aborted

    # The outcome message, or the body process's :DOWN with any reason
    # (never read), which is aborted.
    defp await({pid, ref, tag}) do
      receive do
        {^tag, outcome} ->
          Process.demonitor(ref, [:flush])
          outcome

        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :aborted
      end
    end

    # Step 8.
    defp conclude(_task, :ok), do: :ok
    defp conclude(_task, :refused), do: exit({:shutdown, 2})
    defp conclude(task, :aborted), do: abort(task, :body)

    defp abort(task, stage) do
      present(task, stage)
      exit({:shutdown, 70})
    end

    # The one fixed line, in its own try: a refusing or raising device
    # gives no line and the exit still happens. SafeLog.say/2 prints the
    # withheld line for a task it cannot render.
    defp present(task, stage) do
      SafeLog.say(:task_aborted, task: task, stage: stage)
    catch
      _kind, _reason -> :ok
    end
  end
end
