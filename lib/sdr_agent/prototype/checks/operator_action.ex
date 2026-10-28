defmodule SdrAgent.Prototype.Checks.OperatorAction do
  @moduledoc """
  Policy check for the D-237 prototype operator (interfaces r6 IF-3):
  `authorize_if {SdrAgent.Prototype.Checks.OperatorAction, action: atom}`.

  It passes only when `action` is one of the closed operator atoms
  (`actions/0`), the runtime is prototype, and the authoritative resolver
  `SdrAgent.Prototype.operator_actor/1` re-run on `actor.id` returns an
  actor of the same tenant as `actor.tenant_id`. An `SdrAgent.Actor`
  struct, its type or its fields are never proof by themselves.

  RED stage (D-237 S1): `actions/0` is the contract; `match?/3` refuses
  every request.
  """
  use Ash.Policy.SimpleCheck

  @actions [
    :provision,
    :revoke_grant,
    :import_dossier,
    :seed_settings,
    :assign,
    :review_read,
    :approve,
    :reject,
    :revoke_approval
  ]

  @doc "The closed list of operator action atoms."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @impl true
  def describe(opts), do: "the resolved prototype operator performs #{inspect(opts[:action])}"

  @impl true
  def match?(_actor, _context, _opts), do: red(false)

  # RED stub result, typed dynamic() so callers compile against the stub
  # (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
