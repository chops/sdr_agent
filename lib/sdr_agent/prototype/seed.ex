defmodule SdrAgent.Prototype.Seed do
  @moduledoc """
  Writes the D-237 GTM seed (interfaces r6 IF-7; supplement 1 r2 §3-§4,
  Codex R5-R7) as the acting prototype operator, in one transaction, from
  the validated `SdrAgent.Prototype.SeedDir.read/2` result; returns ids and
  digests only.

  RED stage (D-237 S3): the API is the contract; `run/2` returns
  `{:error, :not_implemented}`.
  """

  @doc "Writes or replays the seed."
  @spec run(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
  def run(_seed, _actor), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
