# Approved Phase4a compile-safe deny declaration only; no policy references it.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.SeedScope do
    @moduledoc """
    The registered, transaction-bound authority for one D-268 seed run.

    Phase4a declaration: every entry is deny-only. No callback, registry,
    marker, query, lock, write or positive policy authority exists yet.
    """

    @doc "Deny-only declaration of the seed-run callback boundary."
    def run(_actor, _opts, _fun), do: {:error, :not_implemented}

    @doc "Deny-only declaration of ordered member binding."
    def bind(_ref, _kind, _record), do: {:error, :not_implemented}

    @doc "No scope is registered by the declaration."
    def fetch(_ref), do: nil

    @doc "No run id is created by the declaration."
    def fetch_run_id(_ref), do: nil

    @doc "No scope authorizes an activation in this declaration."
    def valid?(_scope, _changeset, _actor), do: false
  end
end
