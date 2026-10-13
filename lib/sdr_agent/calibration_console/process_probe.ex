defmodule SdrAgent.CalibrationConsole.ProcessProbe do
  @moduledoc """
  The macOS process probe of `SdrAgent.CalibrationConsole.LaunchRecord`
  (R0-07 slice E4b, row R11-1; staged process-group delta, Codex PASS
  2d6beb1d).

    * `self_pid/0` — `{:ok, pid}` of this VM.
    * `start_identity/1` — `{:ok, identity}`, the process start time
      (`lstart`, fixed C locale and UTC), or `:absent`.
    * `group_members/1` — `{:ok, pids}`, the runnable (non-zombie) members of
      a process group. macOS `ps` reports no session id, so the launch
      record observes the CLI's own process group. Group emptiness is not a
      whole-descendant proof: a descendant can change its process group.

  Both read one snapshot of `/bin/ps -A -o pid=,pgid=,stat=,lstart=`, run
  with `LC_ALL=C` and `TZ=UTC` through `SdrAgent.ChildEnv` (the inherited
  TZ changes `lstart`), with stderr captured into the output. The snapshot
  is used only when `ps` exits 0 and every line is a well-formed row. A
  failed, empty, diagnostic-bearing or malformed snapshot is `{:error,
  :ps_failed | :ps_malformed}`, never absence or an empty group. A pid is
  `:absent` only when a valid snapshot has no row for it. An unreaped
  zombie keeps its start identity, which conservatively keeps a root busy.
  Start times have one-second resolution, so a pid reused within the same
  second reads as the same process (conservative: busy, never free).

  Invalid pids are `{:error, :invalid_pid}`. Only test-seam builds honour
  the `ps:` override (`config :sdr_agent, #{inspect(__MODULE__)}, ps:
  path`); other builds always run `/bin/ps`.
  """

  @ps "/bin/ps"
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @env [{"LC_ALL", "C"}, {"TZ", "UTC"}]
  @row ~r/\A\s*(\d+)\s+(\d+)\s+([A-Z][A-Za-z+<>]*)\s+(\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4})\s*\z/

  @doc "This VM's OS pid: `{:ok, pid}`."
  def self_pid, do: {:ok, String.to_integer(System.pid())}

  @doc "`{:ok, start identity}`, `:absent`, or `{:error, reason}` (see the moduledoc)."
  def start_identity(pid) when is_integer(pid) and pid > 0 do
    with {:ok, rows} <- snapshot() do
      case Enum.find(rows, &(&1.pid == pid)) do
        nil -> :absent
        row -> {:ok, row.start}
      end
    end
  end

  def start_identity(_pid), do: {:error, :invalid_pid}

  @doc "`{:ok, runnable member pids}` of process group `pgid`, or `{:error, reason}`."
  def group_members(pgid) when is_integer(pgid) and pgid > 0 do
    with {:ok, rows} <- snapshot() do
      {:ok,
       rows
       |> Enum.filter(&(&1.pgid == pgid and not String.starts_with?(&1.stat, "Z")))
       |> Enum.map(& &1.pid)
       |> Enum.sort()}
    end
  end

  def group_members(_pgid), do: {:error, :invalid_pid}

  # One successful, fully well-formed process table.
  defp snapshot do
    case System.cmd(ps(), ["-A", "-o", "pid=,pgid=,stat=,lstart="],
           env: SdrAgent.ChildEnv.cmd([], @env),
           stderr_to_stdout: true
         ) do
      {output, 0} -> rows(output)
      {_output, _status} -> {:error, :ps_failed}
    end
  rescue
    _error -> {:error, :ps_failed}
  end

  defp rows(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case row(line) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        :error -> {:halt, {:error, :ps_malformed}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :ps_malformed}
      other -> other
    end
  end

  defp row(line) do
    case Regex.run(@row, line, capture: :all_but_first) do
      [pid, pgid, stat, start] -> numbers(pid, pgid, stat, start)
      nil -> :error
    end
  end

  defp numbers(pid, pgid, stat, start) do
    case {String.to_integer(pid), String.to_integer(pgid)} do
      {pid, pgid} when pid > 0 and pgid >= 0 ->
        {:ok, %{pid: pid, pgid: pgid, stat: stat, start: start}}

      _other ->
        :error
    end
  end

  if @test_seams do
    defp ps, do: :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:ps, @ps)
  else
    defp ps, do: @ps
  end
end
