# D-237: this check exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain it, and the
# `ModelInvocation` field-policy clause naming it is compiled out there.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Checks.VerifiedReleasedRead do
    @moduledoc """
    Field-policy filter check on `SdrAgent.Agents.ModelInvocation`'s
    output-bearing fields (`parsed_output`, `validation_errors`, `refusal`;
    mechanism note r3 section A, Codex 3122b0d4 and 3603b76f M1/N1): a
    verified `SdrAgent.Prototype.ReleasedScope` authorizes exactly its own
    row.

    In prototype runtime, when the query context's
    `:sdr_prototype_released_scope` passes `SdrAgent.Prototype.ReleasedScope.verify/1`
    (its own process and transaction, registered, unchanged), the filter
    is that scope's invocation id and tenant with an existing
    `released_unverified` release of that id. Anything else (no context, a
    Boolean marker, a plain map, a forged, stale, copied or another
    process's scope, ordinary runtime) is `false`. It is evaluated per row,
    so a list read under one scope shows only that row's output.
    """
    use Ash.Policy.FilterCheck

    require Ash.Expr

    alias SdrAgent.Prototype.ReleasedScope

    @impl true
    def describe(_opts), do: "a verified released_unverified read scope of this row"

    @impl true
    def filter(_actor, %{query: %{context: context}}, _opts) when is_map(context) do
      with :prototype <- SdrAgent.Prototype.runtime(),
           {:ok, %ReleasedScope{} = scope} <-
             ReleasedScope.verify(Map.get(context, :sdr_prototype_released_scope)) do
        invocation_id = scope.model_invocation_id
        tenant_id = scope.tenant_id
        release_id = scope.release_id

        Ash.Expr.expr(
          id == ^invocation_id and tenant_id == ^tenant_id and
            exists(result_release, id == ^release_id and disposition == :released_unverified)
        )
      else
        _refused -> Ash.Expr.expr(false)
      end
    end

    def filter(_actor, _context, _opts), do: Ash.Expr.expr(false)
  end
end
