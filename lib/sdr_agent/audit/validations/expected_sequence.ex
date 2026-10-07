defmodule SdrAgent.Audit.Validations.ExpectedSequence do
  @moduledoc """
  Guards a chain-head advance: the stored `last_sequence` must equal the
  `expected_sequence` argument (checked inside the SQL `UPDATE`). The kernel
  already holds the head row lock; this is defence in depth.
  """
  use Ash.Resource.Validation

  require Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    expected = Ash.Changeset.get_argument(changeset, :expected_sequence)

    if changeset.data.last_sequence == expected,
      do: :ok,
      else: {:error, field: :last_sequence, message: "chain head moved"}
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    expected = Ash.Changeset.get_argument(changeset, :expected_sequence)

    {:atomic, [:last_sequence], Ash.Expr.expr(last_sequence != ^expected),
     Ash.Expr.expr(
       error(^InvalidAttribute, %{
         field: :last_sequence,
         value: last_sequence,
         message: "chain head moved",
         vars: %{}
       })
     )}
  end
end
