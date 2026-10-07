defmodule SdrAgent.Audit.Changes.Transition do
  @moduledoc """
  Lifecycle transition change (ADR-0010).

  Sets the state attribute to `:to` only when its current value is one of
  `:from`. In atomic updates the guard is part of the SQL `UPDATE` (a
  `CASE` that raises when the stored state is not allowed), so a stale
  struct or a concurrent writer cannot double-transition; the failure is an
  `Ash.Error.Invalid`.

  Options: `:from` (list of states), `:to` (state), `:attribute` (default
  `:status`). Each resource declares its transition table as data and a test
  compares it with the actions that use this change.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    if is_list(opts[:from]) and is_atom(opts[:to]) do
      {:ok, Keyword.put_new(opts, :attribute, :status)}
    else
      {:error, "Transition requires :from (list) and :to (atom)"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    attribute = opts[:attribute]
    current = Map.get(changeset.data, attribute)

    if current in opts[:from] do
      Ash.Changeset.force_change_attribute(changeset, attribute, opts[:to])
    else
      Ash.Changeset.add_error(changeset, error(opts, current))
    end
  end

  @impl true
  def atomic(_changeset, opts, _context) do
    attribute = opts[:attribute]
    from = opts[:from]
    to = opts[:to]

    {:atomic,
     %{
       attribute =>
         Ash.Expr.expr(
           if ^Ash.Expr.atomic_ref(attribute) in ^from do
             ^to
           else
             error(^InvalidAttribute, %{
               field: ^attribute,
               value: ^Ash.Expr.atomic_ref(attribute),
               message: ^"invalid transition to #{to}",
               vars: %{}
             })
           end
         )
     }}
  end

  defp error(opts, current) do
    InvalidAttribute.exception(
      field: opts[:attribute],
      value: current,
      message: "invalid transition from #{current} to #{opts[:to]}"
    )
  end
end
