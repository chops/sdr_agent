defmodule SdrAgent.Audit.AnchorSink do
  @moduledoc "Publication boundary for immutable, signed audit anchor evidence."

  @callback publish(binary(), keyword()) :: {:ok, map()} | {:error, term()}
end
