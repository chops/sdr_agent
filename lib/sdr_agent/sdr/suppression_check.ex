defmodule SdrAgent.SDR.SuppressionCheck do
  @moduledoc """
  The deterministic suppression lookup the agent runs before working or
  enrolling a lead (S2: "enrollment checks of suppression are done by the
  orchestrating Jido action, which records a Decision"; spec §8: the model
  never decides legal suppression).

  The Suppression store is S8's. Until it exists the default implementation
  is `SdrAgent.SDR.SuppressionCheck.NoStore`, which reports
  `:not_suppressed` and says so in the recorded Decision inputs
  (`store: "none"`); S8 configures its implementation with
  `config :sdr_agent, :suppression_check, Module`. The S8 send gate checks
  suppression again before every send regardless.
  """

  @callback check(email :: String.t(), context :: map()) ::
              {:ok, :suppressed | :not_suppressed, map()} | {:error, term()}

  @doc "The configured implementation."
  def impl, do: Application.get_env(:sdr_agent, :suppression_check, __MODULE__.NoStore)
end
