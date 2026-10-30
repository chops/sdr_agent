if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule Mix.Tasks.Sdr.Prototype.Setup do
    @moduledoc """
    Fresh prototype setup entry. Parser RED scaffold: refuses all input
    until the strict four-option parser is implemented.
    """
    use Mix.Task

    @doc "Pure argv parser; no environment, filesystem or setup effects."
    def parse(_args),
      do: :persistent_term.get({__MODULE__, :red_stub}, {:error, :not_implemented})

    @impl Mix.Task
    def run(_args), do: {:error, :not_implemented}
  end
end
