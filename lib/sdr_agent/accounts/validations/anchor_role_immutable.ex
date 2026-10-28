defmodule SdrAgent.Accounts.Validations.AnchorRoleImmutable do
  @moduledoc """
  D-237 role immutability (interfaces r6 IF-3; Codex 20d0d5fb): the
  `:agent_operator` role belongs only to the credential-less anchor that
  setup creates (`:create_prototype_anchor`), and it never moves.

  Attached, with `before_action?: true` so that authorization comes first,
  to exactly `:create_user`, `:seed`, `:change_role` and `:set_password` on
  `SdrAgent.Accounts.User`. It refuses when the record's current role or
  the role being set is `:agent_operator`. That covers a create whose
  effective role is `:agent_operator`, a role change from or to it, and a
  password set on the anchor. The refusal is one
  `Ash.Error.Changes.InvalidAttribute` on `:role` with a fixed message, and
  it comes before any write.

  The SQL CHECK `users_agent_operator_password` stays as defence in depth.
  `:change_status` and `:change_password` are outside this validation.
  """
  use Ash.Resource.Validation

  @role :agent_operator
  @message "agent_operator is reserved for the D-237 anchor and immutable"

  @doc "The fixed refusal message."
  @spec message() :: String.t()
  def message, do: @message

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_data(changeset, :role) == @role or
         Ash.Changeset.get_attribute(changeset, :role) == @role,
       do: {:error, field: :role, message: @message},
       else: :ok
  end
end
