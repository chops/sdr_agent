# D-237: the prototype basis exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Basis do
    @moduledoc """
    The `d237-basis/1` of a `released_unverified` decision (ADR-0005 D-237
    amendment item 6; interfaces r6 IF-4; release scope proposal r1 section
    3; Codex 3122b0d4 Q5).

    **RED-b2c deny-only declaration** (Codex 79819840 R3): only `encode/1`
    is declared, and it refuses every input with the value-free
    `{:error, :basis_invalid}`. No basis is built, encoded or verified here
    yet, and nothing calls this module. The b2c increment replaces it with
    the size guard over the canonical (`sdr-canonical-json/1`) UTF-8 bytes
    (at most 8192: `{:ok, bytes, sha256_hex}`), plus `build/1`,
    `verify_new/2` and `verify_historical/2`.
    """

    @doc "Deny-only (RED-b2c): every input is `{:error, :basis_invalid}`."
    @spec encode(term()) :: {:ok, binary(), String.t()} | {:error, :basis_invalid}
    def encode(_basis), do: {:error, :basis_invalid}
  end
end
