defmodule SdrAgent.Repo.QueryLog do
  @moduledoc """
  The Repo's query log (ADR-0005 C4 amendment; C4 section 3.6), replacing
  Ecto's default logger (`config :sdr_agent, SdrAgent.Repo, log: false`) in
  every environment. Each `[:sdr_agent, :repo, :query]` event is logged at
  `:debug` with the allowlisted fields of `SdrAgent.Repo.SafeMetadata`
  only: never parameters, SQL text, error messages or connection details.
  """

  require Logger

  alias SdrAgent.Repo.SafeMetadata

  @event [:sdr_agent, :repo, :query]
  @handler {__MODULE__, :query}

  @doc "Attaches the handler (idempotent)."
  def setup do
    :telemetry.detach(@handler)
    :telemetry.attach(@handler, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(@event, measurements, metadata, _config) do
    Logger.debug(fn ->
      fields = SafeMetadata.fields(measurements, metadata)

      "db query " <>
        Enum.map_join(Enum.sort(fields), " ", fn {key, value} -> "#{key}=#{value}" end)
    end)
  end
end
