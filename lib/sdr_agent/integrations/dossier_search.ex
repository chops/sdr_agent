defmodule SdrAgent.Integrations.DossierSearch do
  @moduledoc """
  The `SdrAgent.Integrations.SearchProvider` adapter selected in D-237
  prototype runtime (interfaces r6 IF-6; supplement 1 r2 §6a, Codex Q2). A
  refusing stub, for the reason given in `SdrAgent.Integrations.DossierWeb`:
  every call returns `{:error, :prototype_scoped_read_required}`, never
  content, never a network call.

  RED stage (D-237 S3): `search/2` returns `{:error, :not_implemented}`.
  """
  @behaviour SdrAgent.Integrations.SearchProvider

  @impl true
  def search(_query, _opts), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
