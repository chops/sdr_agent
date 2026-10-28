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

  Stage (D-237 S1b, Codex 17f9de95, Q22 RED first): a deny-only
  declaration. `violations/3` reads nothing and returns
  `[:not_implemented]`, so no observation ever passes.
  """

  @doc "The sorted, unique violations of `observed` against `expected` for `sentinel` (deny-only)."
  @spec violations(map(), map(), String.t()) :: [atom()]
  def violations(_expected, _observed, _sentinel), do: red([:not_implemented])

  # Deny-only stub result, typed dynamic() so callers' comparisons compile
  # against it (Elixir 1.20 infers literal returns); read-only, nothing sets
  # the key; replaced by the checker at GREEN.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
