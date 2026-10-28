# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ImportOutcome do
    @moduledoc """
    The closed refusal reason of `mix sdr.prototype.import` (I4 r2):
    `reason/2` maps a stage and its error term to one atom of the agreed
    `import_refused` family (S3 + S1b, 24 reasons). Pure: no I/O; it reads
    only closed atoms and the shape of a refusal, never a value; any other
    term is `:import_failed`, and it never raises.

    Deny-only declaration (RED): every input is `:import_failed`.
    """

    @doc "The closed reason for `error` at `stage` (deny-only: always `:import_failed`)."
    @spec reason(term(), term()) :: atom()
    def reason(_stage, _error), do: :import_failed
  end
end
