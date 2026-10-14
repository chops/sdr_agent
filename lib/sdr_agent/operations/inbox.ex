defmodule SdrAgent.Operations.Inbox do
  @moduledoc "Source-owned, policy-authorized and SQL-bounded Failure metadata for Home."

  import Ash.Expr, only: [expr: 1]

  require Ash.Query

  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Operations.Failure
  alias SdrAgent.ReadDeadline

  @fields [
    :id,
    :tenant_id,
    :status,
    :class,
    :severity,
    :subject_resource,
    :subject_id,
    :operation_id,
    :retryable,
    :message,
    :occurred_at,
    :acknowledged_at,
    :resolved_at
  ]

  @doc "At most 51 authorized candidates, after the global continuation predicate."
  def list(actor, cursor) do
    with :ok <- ReadDeadline.operator(actor) do
      Failure
      |> GuardedCall.read_query(actor: actor, action: :attention)
      |> Ash.Query.unset(:sort)
      |> Ash.Query.select(@fields)
      |> Ash.Query.calculate(
        :inbox_priority,
        :integer,
        expr(if(severity == :critical, do: 0, else: 1))
      )
      |> after_cursor(cursor)
      |> then(fn query ->
        Ash.Query.sort(query, [
          {Map.fetch!(query.calculations, :inbox_priority), :asc},
          {:occurred_at, :asc},
          {:id, :asc}
        ])
      end)
      |> Ash.Query.limit(51)
      |> Ash.read()
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {priority, instant, producer, id}) do
    time = DateTime.from_unix!(instant, :microsecond)
    equal_producer = producer == "operations_failures"
    later_producer = "operations_failures" > producer
    critical_cursor = priority == 0

    same_priority =
      if critical_cursor, do: expr(severity == :critical), else: expr(severity != :critical)

    after_key =
      expr(
        occurred_at > ^time or
          (occurred_at == ^time and (^later_producer or (^equal_producer and id > ^id)))
      )

    Ash.Query.filter(
      query,
      (severity != :critical and ^critical_cursor) or
        (^same_priority and ^after_key)
    )
  end
end
