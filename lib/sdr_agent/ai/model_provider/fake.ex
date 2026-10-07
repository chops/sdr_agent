defmodule SdrAgent.AI.ModelProvider.Fake do
  @moduledoc "Deterministic structured-output provider for development, tests, and CI."

  @behaviour SdrAgent.AI.ModelProvider

  @default_output %{answer: "qualified", score: 42}

  @impl true
  def complete(request, opts) do
    {:ok,
     %{
       output: Keyword.get(opts, :output, @default_output),
       provider: :fake,
       model: "fixture",
       request_id: request.id
     }}
  end
end
