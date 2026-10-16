defmodule SdrAgent.Telemetry.RepoSpans do
  @moduledoc """
  Client spans for Repo queries (ADR-0005 C4 amendment; C4 section 3.6),
  replacing the `opentelemetry_ecto` handler, which stays pinned but is no
  longer attached. One span per `[:sdr_agent, :repo, :query]` event, named
  `sdr_agent.repo.query:<source>` and parented like the dependency's (the
  process context, else its `$callers`), with `db.system`, `db.name` (the
  configured database name) and the allowlisted fields of
  `SdrAgent.Repo.SafeMetadata`. On error the status is `:error` with a
  description built only from `error_module`, `pg_code` and `constraint`.
  It never sets `db.url` or `db.statement`.
  """

  require OpenTelemetry.Tracer

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
    fields = SafeMetadata.fields(measurements, metadata)
    end_time = :opentelemetry.timestamp()
    start_time = end_time - Map.get(measurements, :total_time, 0)

    attributes =
      fields
      |> Map.new(fn {key, value} -> {"db.sdr.#{key}", value} end)
      |> Map.merge(%{"db.system" => "postgresql", "db.name" => database(metadata)})

    parent = parent_context()
    token = if parent != :undefined, do: OpenTelemetry.Ctx.attach(parent), else: :undefined

    span =
      OpenTelemetry.Tracer.start_span("sdr_agent.repo.query:#{fields.source}", %{
        start_time: start_time,
        attributes: attributes,
        kind: :client
      })

    if fields.outcome == "error" do
      description = SafeMetadata.error_description(fields)
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, description))
    end

    OpenTelemetry.Span.end_span(span)
    if token != :undefined, do: OpenTelemetry.Ctx.detach(token)
    :ok
  end

  defp parent_context do
    case OpentelemetryProcessPropagator.fetch_ctx(self()) do
      :undefined -> OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers")
      ctx -> ctx
    end
  end

  defp database(%{repo: repo}) when is_atom(repo) and not is_nil(repo) do
    case repo.config()[:database] do
      name when is_binary(name) -> name
      _other -> "other"
    end
  end

  defp database(_metadata), do: "other"
end
