defmodule Mix.Tasks.Sdr.Prototype.Op do
  @shortdoc "D-237 prototype operator commands (assign, review, approve, reject, revoke, seed, status)"

  @moduledoc """
  `mix sdr.prototype.op <command> --agent claude_code|codex_cli ...`: the
  D-237 operator's commands (interfaces r6 IF-2 task kind, IF-3, IF-5; plan
  r7 section 3 "Operator gates, UI and acceptance").

    * `assign --lead ID --campaign ID`
    * `review --draft ID` writes the private bundle with the pending-revision
      view (and the run view) and prints its UUID only;
    * `approve --revision ID --revision-sha256 HEX --recipient-email ADDR`:
      all three exactly as reviewed, each required; the address is never
      refilled from the current contact;
    * `reject --revision ID --revision-sha256 HEX --reason CODE`
    * `revoke --approval ID`
    * `seed --seed-dir D --seed-sha256 P,G,C,V` (the separate seed retry)
    * `status`

  `parse/1` validates the arguments before any action; `execute/2` runs one
  parsed command as a resolved operator actor; `run/1` is the task entry.

  RED stage (D-237 S4): the contract surface only.
  """
  use Mix.Task

  @doc "Validates `argv`; `{:ok, parsed}` or `{:error, :invalid_arguments}`."
  @spec parse([String.t()]) :: {:ok, map()} | {:error, atom()}
  def parse(_argv), do: red({:error, :not_implemented})

  @doc "Runs one parsed command as the resolved operator `actor`."
  @spec execute(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
  def execute(_parsed, _actor), do: red({:error, :not_implemented})

  @impl Mix.Task
  def run(_argv), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so callers compile against the stub
  # (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
