defmodule SdrAgent.Audit.Checks.DossierSourceScope do
  @moduledoc """
  Policy check for `SdrAgent.Audit.Payload` `:read_dossier_source_content`
  (supplement 1 r2 §6a, Q2; the precedent is
  `SdrAgent.Audit.Checks.ReconciliationScope`).

  Contract: it passes only when ALL hold:

    * the runtime is prototype and `SdrAgent.Prototype.check_live/0` is `:ok`;
    * the actor is an `%SdrAgent.Actor{type: :agent_runtime}` whose tenant is
      the binding's;
    * the action carries the private scope built by `context/1`, which only
      `SdrAgent.Research.read_dossier_sources/4` (S3) builds, from the
      authoritative run, lead, entry and sources it re-read;
    * the scope's tenant is the actor's;
    * the requested `sha256` is one of the scope's `sha256s` (those sources'
      `content_sha256`).

  `purpose/0` is the fixed AuditAccess purpose of a scoped read.

  `fetch/1` validates every member at consumption and never raises. The
  positive branch exists only with the prototype authority
  (`:prototype_authority_compiled`); the production build refuses every
  request.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_dossier_source_scope

  @impl true
  def describe(_opts),
    do: "the agent runtime reads a source hash of its run's lead entry in the live binding"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def match?(
          %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant_id},
          %{subject: %Ash.ActionInput{context: context, arguments: arguments}},
          _opts
        )
        when is_binary(tenant_id) and is_map(context) do
      with :prototype <- SdrAgent.Prototype.Authority.runtime(),
           {:ok, %{tenant_id: ^tenant_id}} <- SdrAgent.Prototype.Authority.binding(),
           :ok <- SdrAgent.Prototype.Authority.check_live(),
           {:ok, %{tenant_id: ^tenant_id, sha256s: sha256s}} <- fetch(context) do
        Map.get(arguments, :sha256) in sha256s
      else
        _refused -> false
      end
    end

    def match?(_actor, _authorizer, _opts), do: false
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end

  @doc "The fixed AuditAccess purpose of a scoped dossier source read."
  @spec purpose() :: String.t()
  def purpose, do: "d237_dossier_source"

  @doc """
  The private context for one read: `tenant_id`, `agent_run_id`, `lead_id`,
  `entry_id` and the 32-byte `sha256s` of that entry's sources. Any other
  input raises `ArgumentError`.
  """
  @spec context(map()) :: map()
  def context(
        %{
          tenant_id: tenant_id,
          agent_run_id: agent_run_id,
          lead_id: lead_id,
          entry_id: entry_id,
          sha256s: sha256s
        } = scope
      )
      when is_binary(tenant_id) and is_binary(agent_run_id) and is_binary(lead_id) and
             is_binary(entry_id) and is_list(sha256s) do
    if hashes?(sha256s) do
      %{@marker => %{scope | sha256s: Enum.uniq(sha256s)}}
    else
      raise ArgumentError, "a dossier source scope needs one or more 32-byte sha256s"
    end
  end

  def context(_other), do: raise(ArgumentError, "not a dossier source scope")

  @doc """
  The well-formed scope in `context`, if any: binary tenant, run, lead and
  entry ids and a non-empty list of 32-byte hashes only. A forged or
  malformed scope (any other shape or member) is `:error`; it never raises.
  """
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    with %{sha256s: sha256s} = scope <- Map.get(context, @marker),
         true <-
           Enum.all?(
             [:tenant_id, :agent_run_id, :lead_id, :entry_id],
             &is_binary(Map.get(scope, &1))
           ),
         true <- hashes?(sha256s) do
      {:ok, scope}
    else
      _malformed -> :error
    end
  end

  def fetch(_context), do: :error

  # A non-empty PROPER list of 32-byte binaries. Anything else, an improper
  # tail included, is false; it never raises (Codex 6ccaa32f R1).
  defp hashes?([_ | _] = sha256s), do: all_hashes?(sha256s)
  defp hashes?(_other), do: false

  defp all_hashes?([]), do: true

  defp all_hashes?([sha256 | rest]) when is_binary(sha256) and byte_size(sha256) == 32,
    do: all_hashes?(rest)

  defp all_hashes?(_improper_or_invalid), do: false
end
