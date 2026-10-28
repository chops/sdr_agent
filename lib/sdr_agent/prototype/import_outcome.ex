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

    | Stage | Error | Reason |
    |---|---|---|
    | `:arguments` | `:invalid` | `:invalid_arguments` |
    | `:session` | an entry refusal code of `SdrAgent.Prototype.Session` | that code |
    | `:session` | a `SdrAgent.Prototype.BootCheck.reasons/0` code | `:boot_refused` |
    | `:dossier` or `:spotcheck` | `{path, :digest_mismatch}` | `:digest_mismatch` |
    | `:dossier` | any other `{path, rule}` | `:dossier_invalid` |
    | `:spotcheck` | `{"artifact", :artifact_invalid}` | `:artifact_invalid` |
    | `:spotcheck` | any other `{path, rule}` | `:spotcheck_invalid` |
    | `:prepare` | `{path, rule}` with a dossier skip reason | that skip reason |
    | `:prepare` | `{path, :count}`, `:unknown_row` or `:duplicate` | `:invalid_arguments` |
    | `:prepare` | `{path, :artifact_invalid}` | `:artifact_invalid` |
    | `:prepare` | any other `{path, rule}` | `:dossier_invalid` |
    | `:import` | a `SdrAgent.Prototype.DossierImport` precheck code | that code |
    | `:cap_used` | a `DossierImport.cap_used/1` refusal code | that code |
    | anything else | anything | `:import_failed` |

    A `path` is a binary and a `rule` an atom; any other shape is
    `:import_failed`.
    """

    alias SdrAgent.Prototype.BootCheck

    @session_codes [
      :binding_mismatch,
      :not_prototype_runtime,
      :invalid_agent,
      :session_unset,
      :invalid_correlation,
      :delegation_not_found
    ]
    @skips [
      :no_named_person,
      :role_mailbox,
      :email_unavailable,
      :link_unconfirmed,
      :role_unconfirmed,
      :source_conflict,
      :insufficient_source,
      :not_selected
    ]
    @selection [:count, :unknown_row, :duplicate]
    @import_codes [
      :contact_cap_exceeded,
      :dossier_conflict,
      :binding_mismatch,
      :not_prototype_runtime,
      :forbidden,
      :import_failed
    ]
    @cap_codes [:forbidden, :binding_mismatch, :not_prototype_runtime, :import_failed]

    @doc "The closed reason for `error` at `stage`; see the moduledoc table."
    @spec reason(term(), term()) :: atom()
    def reason(:arguments, :invalid), do: :invalid_arguments
    def reason(:session, code) when code in @session_codes, do: code

    def reason(:session, code) when is_atom(code) do
      if code in BootCheck.reasons(), do: :boot_refused, else: :import_failed
    end

    def reason(stage, {path, :digest_mismatch})
        when stage in [:dossier, :spotcheck] and is_binary(path),
        do: :digest_mismatch

    def reason(:dossier, {path, rule}) when is_binary(path) and is_atom(rule),
      do: :dossier_invalid

    def reason(:spotcheck, {"artifact", :artifact_invalid}), do: :artifact_invalid

    def reason(:spotcheck, {path, rule}) when is_binary(path) and is_atom(rule),
      do: :spotcheck_invalid

    def reason(:prepare, {path, rule}) when is_binary(path) and rule in @skips, do: rule

    def reason(:prepare, {path, rule}) when is_binary(path) and rule in @selection,
      do: :invalid_arguments

    def reason(:prepare, {path, :artifact_invalid}) when is_binary(path), do: :artifact_invalid

    def reason(:prepare, {path, rule}) when is_binary(path) and is_atom(rule),
      do: :dossier_invalid

    def reason(:import, code) when code in @import_codes, do: code
    def reason(:cap_used, code) when code in @cap_codes, do: code
    def reason(_stage, _other), do: :import_failed
  end
end
