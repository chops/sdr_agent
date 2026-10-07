defmodule SdrAgent.AI.ModelProvider.Fake do
  @moduledoc """
  Deterministic structured-output provider for development, tests, and CI.

  Output, in order of precedence: the `:output` provider option (a fixed
  map); otherwise, for a request carrying structured `:input`, the
  responder's answer for the request's `operation` — the `:responder`
  provider option or `config :sdr_agent, :fake_model_responder` (default
  `SdrAgent.SDR.FakeBrain`, the agent's fixture brain); otherwise a fixed
  default. Every answer is still parsed by the request's Zoi schema in
  `SdrAgent.AI.ModelProvider`.
  """

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
    output = output(request, opts)

    {:ok,
     %{
       output: output,
       provider: :fake,
       model: "fixture",
       request_id: request.id,
       raw_response: Jason.encode!(%{output: output}),
       usage: %{input_tokens: 0, output_tokens: 0, plan_calls: 1}
     }}
  end

  defp output(request, opts) do
    case Keyword.fetch(opts, :output) do
      {:ok, output} ->
        output

      :error ->
        responder =
          Keyword.get_lazy(opts, :responder, fn ->
            Application.get_env(:sdr_agent, :fake_model_responder, SdrAgent.SDR.FakeBrain)
          end)

        case request do
          %{input: input, operation: operation} -> responder.respond(operation, input)
          _ -> @default_output
        end
    end
  end
end
