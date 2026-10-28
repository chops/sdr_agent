defmodule SdrAgent.Integrations.DossierWeb do
  @moduledoc """
  The `SdrAgent.Integrations.WebFetch` adapter selected in D-237 prototype
  runtime (interfaces r6 IF-6; supplement 1 r2 §6a, Codex Q2). It is a
  refusing stub: `fetch/1` receives only a URL, with no actor, run or lead,
  so it can never prove which verified-excerpt bytes a caller may read.
  Dossier source content reaches the SDR actions only through
  `SdrAgent.Research.read_dossier_sources/4`. Every call returns
  `{:error, :prototype_scoped_read_required}`; it never returns content and
  never touches the network.

  RED stage (D-237 S3): `fetch/1` returns `{:error, :not_implemented}`.
  """
  @behaviour SdrAgent.Integrations.WebFetch

  @impl true
  def fetch(_url), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
