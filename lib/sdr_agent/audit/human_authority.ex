defmodule SdrAgent.Audit.HumanAuthority do
  @moduledoc """
  Lower-owned interface for human role eligibility and the narrow hosted
  User write scope (ADR-0009 layering). It confers no role by itself:
  ActorRole still checks the requested role list, and scoped actions still
  enforce their own resource policies.

  The implementation is bound at compile time. Prototype builds explicitly
  select their authoritative implementation; a missing selection refuses
  every check. Ordinary production uses the lower constant implementation
  and never loads prototype authority to decide a role. Runtime config and
  request input cannot replace the implementation. Exceptions, unavailable
  callbacks and non-boolean results all refuse; no result is cached.
  """

  @callback role_allowed?(term()) :: boolean()
  @callback valid_write_scope?(term(), term()) :: boolean()

  @default_provider if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false),
                      do: __MODULE__.Unavailable,
                      else: __MODULE__.Ordinary
  @provider Application.compile_env(:sdr_agent, :human_authority_provider, @default_provider)

  @doc "Fresh eligibility for an already role-qualified actor, through the configured implementation."
  if @provider == __MODULE__.Unavailable do
    def role_allowed?(_actor), do: false
  else
    def role_allowed?(actor) do
      @provider.role_allowed?(actor) == true
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end

  @doc "Whether this exact actor and subject carry the registered hosted User write scope."
  if @provider in [__MODULE__.Ordinary, __MODULE__.Unavailable] do
    # Constant refusal in these builds avoids a provably false comparison
    # against a constant provider under Elixir's production type analysis.
    def valid_write_scope?(_actor, _subject), do: false
  else
    def valid_write_scope?(actor, subject) do
      @provider.valid_write_scope?(actor, subject) == true
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end
end
