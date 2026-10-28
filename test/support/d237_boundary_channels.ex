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

  stdout framing: zero bytes, or only complete lines, each ending in one
  `\\n`. A final segment without its `\\n` is a partial line, a zero-length
  line is a blank line, and any byte outside printable ASCII (0x20..0x7E)
  in a line is an invalid byte; none of those lines is classified or
  counted. Each complete line is then a withheld console logger line (the
  `config/config.exs` format under `MIX_ENV=test`, with SafeLog's rebuilt
  message), a closed `prototype:` line, or unknown.

  stderr, per class (`:empty`, `:sentinel` or `:banner`):
  - `:empty` (classes B and the raw completions) requires exactly zero
    bytes; nothing relaxes it.
  - `:sentinel` and `:banner` (raw controls only) check ONLY the relation
    between a `** (` banner and the sentinel: present together
    (`:sentinel`) or the banner without the sentinel (`:banner`). They do
    not check the stacktrace bytes, and they never justify relaxing the
    `:empty` contract.

  Violations: `:status`, `:capture_unknown`, `:sentinel_stdout`,
  `:sentinel_stderr`, `:partial_line`, `:blank_line`, `:invalid_byte`,
  `:unknown_line`, `:missing_line`, `:extra_line`, `:logger_count`,
  `:banner_stdout`, `:stderr_not_empty`, `:stderr_missing_leak`,
  `:stderr_shape`, `:files`, `:orphans`, `:launcher_output`.
  """

  @logger ~r/\A\d{2}:\d{2}:\d{2}\.\d{3} \[(warning|error)\] prototype: log content withheld\z/
  @closed ~r/\Aprototype: [a-z_]+( [a-z_]+=[a-z0-9_-]+)*\z/
  @banner "** ("

  @doc "The sorted, unique violations of `observed` against `expected` for `sentinel`."
  @spec violations(map(), map(), String.t()) :: [atom()]
  def violations(expected, observed, sentinel) when is_binary(sentinel) and sentinel != "" do
    [
      stdout_checks(expected, observed.stdout, sentinel),
      stderr_checks(expected.stderr, observed.stderr, sentinel),
      run_checks(expected, observed)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stdout_checks(expected, stdout, sentinel) when is_binary(stdout) do
    %{lines: lines, partial: partial, blank: blank, invalid: invalid} = frame(stdout)
    {closed, logger, unknown} = classify(lines)

    [
      flag(String.contains?(stdout, sentinel), :sentinel_stdout),
      flag(partial, :partial_line),
      flag(blank > 0, :blank_line),
      flag(invalid > 0, :invalid_byte),
      flag(unknown > 0, :unknown_line),
      flag(expected.stdout -- closed != [], :missing_line),
      flag(closed -- expected.stdout != [], :extra_line),
      flag(logger != expected.logger, :logger_count),
      flag(String.contains?(stdout, @banner), :banner_stdout)
    ]
  end

  defp stdout_checks(_expected, _unreadable, _sentinel), do: :capture_unknown

  defp run_checks(expected, observed) do
    [
      flag(observed.status != expected.status, :status),
      files(expected.files, observed.files),
      flag(observed.orphans != 0, :orphans),
      flag(observed.launcher != "", :launcher_output)
    ]
  end

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

  defp classify(lines) do
    Enum.reduce(lines, {[], 0, 0}, fn line, {closed, logger, unknown} ->
      cond do
        Regex.match?(@logger, line) -> {closed, logger + 1, unknown}
        Regex.match?(@closed, line) -> {closed ++ [line], logger, unknown}
        true -> {closed, logger, unknown + 1}
      end
    end)
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
