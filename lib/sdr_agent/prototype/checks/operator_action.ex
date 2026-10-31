defmodule SdrAgent.Prototype.Checks.OperatorAction do
  @moduledoc """
  Policy check for the D-237 prototype operator (interfaces r6 IF-3):
  `authorize_if {SdrAgent.Prototype.Checks.OperatorAction, action: atom}`.

  It passes only when `action` is one of the closed operator atoms
  (`actions/0`), the runtime is prototype, and the authoritative resolver
  `SdrAgent.Prototype.operator_actor/1`, re-run on `actor.id`, returns
  exactly that actor (type, id and tenant). An `SdrAgent.Actor` struct, its
  type or its fields are never proof by themselves.

  It is compiled only with the prototype authority
  (`:prototype_authority_compiled`); the production build refuses every
  request and references no authority.
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

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    # The full live path on every call (`SdrAgent.Prototype.Authority.operator?/1`:
    # boot snapshot, kernel binding read, complete snapshot, real identity,
    # delegation read and resolution), then the exact actor; nothing cached.
    @impl true
    def match?(%SdrAgent.Actor{type: :prototype_operator, id: id} = actor, _authorizer, opts)
        when is_binary(id) do
      Keyword.get(opts, :action) in @actions and SdrAgent.Prototype.Authority.operator?(actor)
    end

    def match?(%SdrAgent.Accounts.User{} = actor, _authorizer, opts) do
      Keyword.get(opts, :action) in [:review_read, :assign, :mac_worker_control] and
        SdrAgent.Prototype.Authority.hosted_owner?(actor)
    end

    def match?(_actor, _authorizer, _opts), do: false
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end
end
