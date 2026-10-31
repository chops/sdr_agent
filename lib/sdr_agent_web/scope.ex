defmodule SdrAgentWeb.Scope do
  @moduledoc """
  The signed-in operator of a console request (Phoenix 1.8 scope): the
  `SdrAgent.Accounts.User` that every domain call passes as `actor:` and its
  role (`:admin`, `:reviewer` or `:auditor`).

  Presentation rechecks the lower human/owner authority: a hosted owner
  has separate assignment and control affordances, never inherited reviewer
  or admin buttons. The role only shapes the UI (which controls are shown). It is
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
  def reviewer?(%__MODULE__{role: role, user: user}),
    do: role in [:admin, :reviewer] and SdrAgent.Audit.HumanAuthority.role_allowed?(user)

  @doc "Whether the UI offers admin-only actions."
  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{role: role, user: user}),
    do: role == :admin and SdrAgent.Audit.HumanAuthority.role_allowed?(user)

  @doc "Fresh hosted-owner presentation, separate from ordinary human roles."
  @spec hosted_owner?(t()) :: boolean()
  def hosted_owner?(%__MODULE__{user: user}),
    do: SdrAgent.Audit.HumanAuthority.hosted_owner?(user)

  @doc "Assignment is offered to an ordinary reviewer or the current hosted owner."
  @spec assigner?(t()) :: boolean()
  def assigner?(%__MODULE__{} = scope), do: reviewer?(scope) or hosted_owner?(scope)

  @doc "Whether the operator is the read-only auditor, whose every view is recorded."
  @spec auditor?(t()) :: boolean()
  def auditor?(%__MODULE__{role: role}), do: role == :auditor
end
