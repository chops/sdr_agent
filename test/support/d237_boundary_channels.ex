defmodule SdrAgent.D237BoundaryChannels do
  @moduledoc """
  The pure channel checker of the D-237 task boundary real-process proof
  (P2; S1b proposal r4 section 4). It compares one observed child run with
  one exact expectation (`SdrAgent.D237BoundaryCases.expected/2`) and
  returns the closed, sorted list of violations; `[]` means the run met
  the expectation exactly. There is no generic exemption, no trimming and
  no normalization: every byte, line, status and file is accounted for.

  Observed run: `%{status:, stdout:, stderr:, files:, orphans:, launcher:}`.
  `stdout` and `stderr` are the captured bytes, or a non-binary marker when
  a capture could not be read; an unreadable capture is never treated as
  empty.

  Expectation: `%{status:, stdout:, logger:, stderr:, files:}` plus the
  optional keys of the checker deltas d1-d3 (S1b plan r2 section 3, I2).
  An absent optional key keeps the original meaning:
  - `format` (d1): `:test` (absent) or `:dev`, chosen per case, never
    detected;
  - `tagged` (d1): the exact multiset of `{level, code}` dev console lines,
    `[]` when absent, with `level` in SafeLog's eight levels and `code` in
    `SdrAgent.Prototype.SafeLog.codes/0`;
  - `orphans` (d2): `0` (absent) or `:not_observed` ("no proof", never
    equal to `0`); the observed value must equal it exactly;
  - `logger` (required; d3): an exact non-negative integer, or a finite
    range `{min, max}` of integers with `0 <= min <= max <= 64`.
  Any other form of these four keys is `[:expectation_invalid]` only: the
  observation is not checked and the expectation never passes. Which cases
  may use `:not_observed` or a range is fixed by the case tables, not here.

  stdout framing: zero bytes, or only complete lines, each ending in one
  `\\n`. A final segment without its `\\n` is a partial line, a zero-length
  line is a blank line, and any byte outside printable ASCII (0x20..0x7E)
  in a line is an invalid byte; none of those lines is classified or
  counted. Each complete line is then classified under the expectation's
  format, and is otherwise unknown:
  - `:test`: a withheld console logger line (the `config/config.exs`
    format under `MIX_ENV=test`, with SafeLog's rebuilt message), counted,
    or a closed `prototype:` line;
  - `:dev` (`config/dev.exs`, `"[$level] $metadata$message\\n"`; SafeLog
    keeps no configured metadata key): exactly `[<level>] prototype: log
    content withheld` (counted), exactly `[<level>] prototype: <code>`
    (tagged), or a closed `prototype:` line. `<level>` and `<code>` are
    compared as exact strings of the closed sets, never by pattern. Tagged
    lines are recognised only under `:dev` and are never ranged.
  Closed lines and tagged lines are each compared as an exact multiset: an
  expected one not seen is `:missing_line`, a seen one not expected is
  `:extra_line`. A ranged count still classifies every line, and the
  sentinel check covers all of stdout.

  stderr, per class (`:empty`, `:sentinel` or `:banner`):
  - `:empty` (classes B and the raw completions) requires exactly zero
    bytes; nothing relaxes it.
  - `:sentinel` and `:banner` (raw controls only) check ONLY the relation
    between a `** (` banner and the sentinel: present together
    (`:sentinel`) or the banner without the sentinel (`:banner`). They do
    not check the stacktrace bytes, and they never justify relaxing the
    `:empty` contract.

  Violations: `:expectation_invalid` (alone), `:status`, `:capture_unknown`,
  `:sentinel_stdout`, `:sentinel_stderr`, `:partial_line`, `:blank_line`,
  `:invalid_byte`, `:unknown_line`, `:missing_line`, `:extra_line`,
  `:logger_count`, `:banner_stdout`, `:stderr_not_empty`,
  `:stderr_missing_leak`, `:stderr_shape`, `:files`, `:orphans`,
  `:launcher_output`.
  """

  alias SdrAgent.Prototype.SafeLog

  @logger ~r/\A\d{2}:\d{2}:\d{2}\.\d{3} \[(warning|error)\] prototype: log content withheld\z/
  @closed ~r/\Aprototype: [a-z_]+( [a-z_]+=[a-z0-9_-]+)*\z/
  @dev_console ~r/\A\[([a-z]+)\] prototype: (.+)\z/
  @withheld_message "log content withheld"
  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]
  @max_range 64
  @banner "** ("

  @doc "The sorted, unique violations of `observed` against `expected` for `sentinel`."
  @spec violations(map(), map(), String.t()) :: [atom()]
  def violations(expected, observed, sentinel) when is_binary(sentinel) and sentinel != "" do
    case form(expected) do
      {:ok, checked} ->
        [
          stdout_checks(expected, checked, observed.stdout, sentinel),
          stderr_checks(expected.stderr, observed.stderr, sentinel),
          run_checks(expected, checked, observed)
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      :invalid ->
        [:expectation_invalid]
    end
  end

  # The validated d1-d3 forms of the expectation; any other form is invalid.
  defp form(expected) do
    with {:ok, format} <- key(expected, :format, :test, &(&1 in [:test, :dev])),
         {:ok, tagged} <- key(expected, :tagged, [], &tagged?/1),
         {:ok, orphans} <- key(expected, :orphans, 0, &(&1 === 0 or &1 === :not_observed)),
         {:ok, logger} <- key(expected, :logger, nil, &logger?/1) do
      {:ok, %{format: format, tagged: tagged, orphans: orphans, logger: logger}}
    end
  end

  # A present key keeps its value, `nil` included; an absent key takes the default.
  defp key(expected, name, default, valid?) do
    value = Map.get(expected, name, default)
    if valid?.(value), do: {:ok, value}, else: :invalid
  end

  defp tagged?(tagged) do
    codes = SafeLog.codes()
    proper_list?(tagged) and Enum.all?(tagged, &tag?(&1, codes))
  end

  defp tag?({level, code}, codes), do: level in @levels and code in codes
  defp tag?(_entry, _codes), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp logger?(count) when is_integer(count), do: count >= 0

  defp logger?({min, max}) when is_integer(min) and is_integer(max),
    do: 0 <= min and min <= max and max <= @max_range

  defp logger?(_logger), do: false

  defp stdout_checks(expected, checked, stdout, sentinel) when is_binary(stdout) do
    %{lines: lines, partial: partial, blank: blank, invalid: invalid} = frame(stdout)
    seen = classify(lines, checked.format)

    [
      flag(String.contains?(stdout, sentinel), :sentinel_stdout),
      flag(partial, :partial_line),
      flag(blank > 0, :blank_line),
      flag(invalid > 0, :invalid_byte),
      flag(seen.unknown > 0, :unknown_line),
      flag(
        expected.stdout -- seen.closed != [] or checked.tagged -- seen.tagged != [],
        :missing_line
      ),
      flag(
        seen.closed -- expected.stdout != [] or seen.tagged -- checked.tagged != [],
        :extra_line
      ),
      flag(not count?(seen.logger, checked.logger), :logger_count),
      flag(String.contains?(stdout, @banner), :banner_stdout)
    ]
  end

  defp stdout_checks(_expected, _checked, _unreadable, _sentinel), do: :capture_unknown

  defp run_checks(expected, checked, observed) do
    [
      flag(observed.status != expected.status, :status),
      files(expected.files, observed.files),
      flag(observed.orphans != checked.orphans, :orphans),
      flag(observed.launcher != "", :launcher_output)
    ]
  end

  defp count?(count, {min, max}), do: count >= min and count <= max
  defp count?(count, exact), do: count == exact

  defp files(expected, observed) when is_list(observed),
    do: flag(Enum.sort(observed) != Enum.sort(expected), :files)

  defp files(_expected, _unreadable), do: [:files, :capture_unknown]

  defp flag(true, violation), do: violation
  defp flag(false, _violation), do: nil

  # Splits stdout into its complete lines without trimming anything. Every
  # complete line ends in "\n"; the segment after the last "\n" must be
  # empty (no bytes), otherwise it is a partial line and is not classified.
  defp frame(stdout) do
    segments = :binary.split(stdout, "\n", [:global])
    {complete, [tail]} = Enum.split(segments, -1)
    {blank, rest} = Enum.split_with(complete, &(&1 == ""))
    {invalid, lines} = Enum.split_with(rest, &(not printable_ascii?(&1)))

    %{
      lines: lines,
      partial: tail != "",
      blank: length(blank),
      invalid: length(invalid) + if(printable_ascii?(tail), do: 0, else: 1)
    }
  end

  defp printable_ascii?(bytes),
    do: for(<<b <- bytes>>, reduce: true, do: (acc -> acc and b in 0x20..0x7E))

  # Closed and tagged lines keep their multiplicity; logger lines are counted.
  defp classify(lines, format) do
    levels = Map.new(@levels, &{Atom.to_string(&1), &1})
    codes = Map.new(SafeLog.codes(), &{Atom.to_string(&1), &1})

    Enum.reduce(lines, %{closed: [], tagged: [], logger: 0, unknown: 0}, fn line, seen ->
      case line_class(line, format, levels, codes) do
        :logger -> %{seen | logger: seen.logger + 1}
        {:tagged, tag} -> %{seen | tagged: seen.tagged ++ [tag]}
        :closed -> %{seen | closed: seen.closed ++ [line]}
        :unknown -> %{seen | unknown: seen.unknown + 1}
      end
    end)
  end

  defp line_class(line, :test, _levels, _codes) do
    cond do
      Regex.match?(@logger, line) -> :logger
      Regex.match?(@closed, line) -> :closed
      true -> :unknown
    end
  end

  defp line_class(line, :dev, levels, codes) do
    case Regex.run(@dev_console, line, capture: :all_but_first) do
      [level, message] -> console_class(Map.fetch(levels, level), message, codes)
      nil -> if Regex.match?(@closed, line), do: :closed, else: :unknown
    end
  end

  # A dev console line: the exact level string, then exactly the withheld
  # message or exactly one code's name; anything else is unknown.
  defp console_class(:error, _message, _codes), do: :unknown

  defp console_class({:ok, _level}, message, _codes) when message == @withheld_message,
    do: :logger

  defp console_class({:ok, level}, message, codes) do
    case Map.fetch(codes, message) do
      {:ok, code} -> {:tagged, {level, code}}
      :error -> :unknown
    end
  end

  defp stderr_checks(_expected, unreadable, _sentinel) when not is_binary(unreadable),
    do: :capture_unknown

  defp stderr_checks(:empty, "", _sentinel), do: nil

  defp stderr_checks(:empty, err, sentinel),
    do: [:stderr_not_empty, flag(String.contains?(err, sentinel), :sentinel_stderr)]

  defp stderr_checks(:sentinel, err, sentinel) do
    if String.contains?(err, @banner) and String.contains?(err, sentinel),
      do: nil,
      else: :stderr_missing_leak
  end

  defp stderr_checks(:banner, err, sentinel) do
    cond do
      String.contains?(err, sentinel) -> [:stderr_shape, :sentinel_stderr]
      String.contains?(err, @banner) -> nil
      true -> :stderr_shape
    end
  end
end
