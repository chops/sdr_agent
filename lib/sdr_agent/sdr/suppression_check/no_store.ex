defmodule SdrAgent.SDR.SuppressionCheck.NoStore do
  @moduledoc """
  S7 placeholder: no Suppression store exists before S8, so nothing is
  suppressed here; the recorded Decision states that no store was consulted.
  """
  @behaviour SdrAgent.SDR.SuppressionCheck

  @impl true
  def check(_email, _context), do: {:ok, :not_suppressed, %{"store" => "none", "until" => "S8"}}
end
