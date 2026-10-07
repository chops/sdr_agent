defmodule SdrAgentWeb.Trace do
  @moduledoc """
  Links from a row's `trace_id` to its trace in Grafana Tempo (ADR-0005:
  the app's OpenTelemetry trace; Postgres stays the system of record, Tempo
  is a 168h convenience view).

  Configuration (`config :sdr_agent, SdrAgentWeb.Trace, ...`):

    * `:grafana_url` — Grafana base URL, default `"http://localhost:3000"`
      (the local observability stack);
    * `:datasource_uid` — the Tempo datasource uid, default `"tempo"`.

  Only well-formed W3C trace ids (32 lower-case hex) produce a link.
  """
  use Phoenix.Component

  import SdrAgentWeb.CoreComponents, only: [icon: 1]

  @doc "The Grafana Explore URL of `trace_id`, or nil when it is not a trace id."
  @spec url(String.t() | nil) :: String.t() | nil
  def url(trace_id) when is_binary(trace_id) do
    if Regex.match?(~r/\A[0-9a-f]{32}\z/, trace_id) do
      config = Application.get_env(:sdr_agent, __MODULE__, [])

      base =
        config |> Keyword.get(:grafana_url, "http://localhost:3000") |> String.trim_trailing("/")

      uid = Keyword.get(config, :datasource_uid, "tempo")

      panes = %{
        "t" => %{
          "datasource" => uid,
          "queries" => [
            %{
              "refId" => "A",
              "datasource" => %{"type" => "tempo", "uid" => uid},
              "queryType" => "traceql",
              "query" => trace_id
            }
          ],
          "range" => %{"from" => "now-7d", "to" => "now"}
        }
      }

      query =
        URI.encode_query(%{
          "schemaVersion" => "1",
          "orgId" => "1",
          "panes" => Jason.encode!(panes)
        })

      base <> "/explore?" <> query
    end
  end

  def url(_trace_id), do: nil

  @doc "An external link to a trace in Tempo (nothing when there is no valid trace id)."
  attr :trace_id, :string, default: nil
  attr :label, :string, default: "Trace"

  def trace_link(assigns) do
    assigns = assign(assigns, :href, url(assigns.trace_id))

    ~H"""
    <a
      :if={@href}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      data-trace-id={@trace_id}
      title={"Open trace #{@trace_id} in Grafana Tempo"}
      class="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 font-mono text-[0.7rem] text-sky-700 ring-1 ring-inset ring-sky-600/20 transition hover:bg-sky-50 focus-visible:outline-2 focus-visible:outline-teal-600"
    >
      <.icon name="hero-arrow-top-right-on-square" class="size-3" />
      {@label}
    </a>
    """
  end
end
