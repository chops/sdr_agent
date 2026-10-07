defmodule SdrAgent.AI.ModelProvider.Fake do
  @moduledoc "Deterministic structured-output provider for development, tests, and CI."

  @behaviour SdrAgent.AI.ModelProvider

  @default_output %{answer: "qualified", score: 42}

  @impl true
  def prepare(_request, _opts) do
    {:ok,
     %{
       provider: :fake,
       provider_version: "0.0.0",
       model_id: "fake-qualifier",
       model_catalog_entry: %{"id" => "fake-qualifier"},
       account_mode_ref: "fake:none",
       data_control_setting: "synthetic-only"
     }}
  end

  @impl true
  def complete(request, opts) do
    {:ok,
     %{
       output: Keyword.get(opts, :output, @default_output),
       provider: :fake,
       model: "fixture",
       request_id: request.id,
       raw_response: Jason.encode!(%{output: Keyword.get(opts, :output, @default_output)}),
       usage: %{input_tokens: 0, output_tokens: 0, plan_calls: 1}
     }}
  end
end
