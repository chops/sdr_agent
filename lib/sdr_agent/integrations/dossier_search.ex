defmodule SdrAgent.Integrations.DossierSearch do
  @moduledoc """
  The `SdrAgent.Integrations.SearchProvider` adapter selected in D-237
  prototype runtime (interfaces r6 IF-6; supplement 1 r2 §6a, Codex Q2). A
  refusing stub, for the reason given in `SdrAgent.Integrations.DossierWeb`:
  every call returns `{:error, :prototype_scoped_read_required}`, never
  content, never a network call.
  """
  @behaviour SdrAgent.Integrations.SearchProvider

  @impl true
  def search(_query, _opts), do: {:error, :prototype_scoped_read_required}
end
