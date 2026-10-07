defmodule SdrAgentWeb.Scope do
  @moduledoc """
  The signed-in operator of a console request (Phoenix 1.8 scope): the
  `SdrAgent.Accounts.User` that every domain call passes as `actor:` and its
  role (`:admin`, `:reviewer` or `:auditor`).

  The role only shapes the UI (which links and controls are shown). It is
  never the authorization decision: every action goes through the public
  domain API with `actor: scope.user`, where Ash policies and
  `SdrAgent.Audit.Guard` decide and audit refusals.
  """

  @enforce_keys [:user, :role]
  defstruct [:user, :role]

  @type t :: %__MODULE__{user: SdrAgent.Accounts.User.t(), role: :admin | :reviewer | :auditor}

  @doc "The scope of a signed-in user."
  @spec for_user(SdrAgent.Accounts.User.t()) :: t()
  def for_user(%{role: role} = user), do: %__MODULE__{user: user, role: role}

  @doc "Whether the UI offers review actions (edit, approve, reject, revoke, cancel retry)."
  @spec reviewer?(t()) :: boolean()
  def reviewer?(%__MODULE__{role: role}), do: role in [:admin, :reviewer]

  @doc "Whether the UI offers admin-only actions."
  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{role: role}), do: role == :admin

  @doc "Whether the operator is the read-only auditor, whose every view is recorded."
  @spec auditor?(t()) :: boolean()
  def auditor?(%__MODULE__{role: role}), do: role == :auditor
end
