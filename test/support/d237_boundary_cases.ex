defmodule SdrAgent.D237BoundaryCases do
  @moduledoc """
  Test-only synthetic task bodies and their exact per-class expectations
  for the D-237 task boundary real-process proof (P2; S1b proposal r4
  section 4). Shared by `mix d237.boundary_probe` (class B, bounded) and
  `mix d237.boundary_raw` (class R, the unbounded control). In this C
  slice only the expectations are exercised (by the pure checker
  controls); the bodies run only under a separate process-execution grant.

  Each body first records that it ran (an empty `ran` file in
  `D237_CASE_DIR`), then does one thing with a synthetic sentinel. Nothing
  here reads private data, starts the application, a database, a model or
  the network.

  `expected/2` is the exact expectation of one case for the channel
  checker (`SdrAgent.D237BoundaryChannels`): the exit status, the exact
  non-logger stdout lines (a multiset), the exact count of withheld
  console logger lines, the stderr shape and the exact files of the case
  directory. These are predictions from source, to be confirmed by the
  first sealed run and re-reviewed if they change; an unexpected result
  is a STOP, never a widened expectation.

  stderr per class:
  - every bounded case (class B), and the raw completions, expect `:empty`:
    exactly zero bytes;
  - the raw leaking cases expect `:sentinel` (a `** (` banner holding the
    sentinel) and `self_kill` expects `:banner` (the banner without it).
    These raw shapes check only the banner and sentinel relation, not the
    stacktrace bytes; they show the harness can see a leak and never
    justify relaxing class B's zero-byte stderr.
  """

  require Logger

  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Prototype.SafeLog

  defmodule SentinelError do
    @moduledoc "A synthetic exception whose field and message carry a sentinel (test only)."
    defexception [:value]

    @impl true
    def message(%{value: value}), do: "synthetic failure holding " <> value
  end

  @refusal_id "00000000-0000-4000-8000-000000000237"
  @abort "prototype: task_aborted task=import stage=body"
  @files ["err", "out", "pid", "ran"]

  @cases ~w(ok refused raise exception_field ash_unknown throw exit_reason exit_normal
            exit_shutdown_0 exit_shutdown_term mix_raise bad_return_error bad_return_nil
            linked task_await self_kill logger)

  # Kernel.CLI prints the formatted value (bounded: nothing); status 1.
  @leaking ~w(raise exception_field ash_unknown throw exit_reason mix_raise linked task_await)
  # Kernel.CLI reports status 0 and prints nothing (a false success when raw).
  @silent_zero ~w(exit_normal exit_shutdown_0 exit_shutdown_term bad_return_error bad_return_nil)
  # Cases whose failure also logs exactly one crash report (withheld by SafeLog).
  @crash_report ~w(linked task_await)

  @doc "The case names, in order."
  @spec cases() :: [String.t()]
  def cases, do: @cases

  @doc "The fixed closed line the `refused` case prints."
  @spec refusal_line() :: String.t()
  def refusal_line,
    do: "prototype: op_result command=status id=#{@refusal_id} result=refused reason=forbidden"

  @doc "The exact expectation of case `name` under class `:bounded` or `:raw`."
  @spec expected(:bounded | :raw, String.t()) :: map()
  def expected(:bounded, "ok"), do: exp(0, [], 0, :empty)
  def expected(:bounded, "refused"), do: exp(2, [refusal_line()], 0, :empty)
  def expected(:bounded, "logger"), do: exp(0, [], 1, :empty)

  def expected(:bounded, name) when name in @crash_report, do: exp(70, [@abort], 1, :empty)
  def expected(:bounded, name) when name in @cases, do: exp(70, [@abort], 0, :empty)

  def expected(:raw, "ok"), do: exp(0, [], 0, :empty)
  def expected(:raw, "refused"), do: exp(0, [refusal_line()], 0, :empty)
  def expected(:raw, "logger"), do: exp(0, [], 1, :empty)
  def expected(:raw, "self_kill"), do: exp(1, [], 0, :banner)

  def expected(:raw, name) when name in @leaking,
    do: exp(1, [], if(name in @crash_report, do: 1, else: 0), :sentinel)

  def expected(:raw, name) when name in @silent_zero, do: exp(0, [], 0, :empty)

  defp exp(status, stdout, logger, stderr),
    do: %{status: status, stdout: stdout, logger: logger, stderr: stderr, files: @files}

  @doc """
  Runs case `name` with `sentinel` after recording that the body ran. Any
  other argument list returns `:invalid_argv` (an unknown result).
  """
  @spec run([String.t()]) :: term()
  def run([name, sentinel]) when name in @cases and is_binary(sentinel) do
    mark_ran()
    body(name, sentinel)
  end

  def run(_argv), do: :invalid_argv

  defp mark_ran do
    case System.get_env("D237_CASE_DIR") do
      dir when is_binary(dir) and dir != "" -> File.write!(Path.join(dir, "ran"), "")
      _unset -> raise "D237_CASE_DIR is unset"
    end
  end

  defp body("ok", _s), do: :ok

  defp body("refused", _s) do
    SafeLog.say(:op_result,
      command: :status,
      id: @refusal_id,
      result: :refused,
      reason: :forbidden
    )

    :refused
  end

  defp body("raise", s), do: raise("synthetic " <> s)
  defp body("exception_field", s), do: raise(SentinelError, value: s)

  defp body("ash_unknown", s),
    do: raise(Unknown.exception(errors: [UnknownError.exception(error: s)]))

  defp body("throw", s), do: throw({:thrown, s})
  defp body("exit_reason", s), do: exit({:custom, s})
  defp body("exit_normal", _s), do: exit(:normal)
  defp body("exit_shutdown_0", _s), do: exit({:shutdown, 0})
  defp body("exit_shutdown_term", s), do: exit({:shutdown, {:term, s}})
  defp body("mix_raise", s), do: Mix.raise("synthetic " <> s)
  defp body("bad_return_error", s), do: {:error, s}
  defp body("bad_return_nil", _s), do: nil

  defp body("linked", s) do
    :proc_lib.spawn_link(fn -> raise "synthetic linked " <> s end)

    receive do
    after
      5_000 -> :ok
    end
  end

  defp body("task_await", s) do
    Task.async(fn -> raise "synthetic task " <> s end) |> Task.await()
    :ok
  end

  defp body("self_kill", _s), do: Process.exit(self(), :kill)

  defp body("logger", s) do
    Logger.error("synthetic logged " <> s)
    :ok
  end
end
