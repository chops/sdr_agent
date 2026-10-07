defmodule SdrAgent.AI.ModelProvider.CodexAppServer do
  @moduledoc "Disabled legacy adapter retained to fail closed after the ClaudeCLI pivot."
  @behaviour SdrAgent.AI.ModelProvider

  @impl true
  def prepare(_request, _opts), do: {:error, :codex_app_server_disabled}

  @impl true
  def complete(_request, _opts), do: {:error, :codex_app_server_disabled}
end
