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

  RED stage (D-237 S1 item 5): DENY-ONLY. `match?/3` refuses every request;
  `context/1`, `fetch/1` and `purpose/0` are the contract.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_dossier_source_scope

  @impl true
  def describe(_opts),
    do: "the agent runtime reads a source hash of its run's lead entry in the live binding"

  @impl true
  def match?(_actor, _authorizer, _opts), do: red(false)

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
    if sha256s != [] and Enum.all?(sha256s, &(is_binary(&1) and byte_size(&1) == 32)) do
      %{@marker => %{scope | sha256s: Enum.uniq(sha256s)}}
    else
      raise ArgumentError, "a dossier source scope needs one or more 32-byte sha256s"
    end
  end

  def context(_other), do: raise(ArgumentError, "not a dossier source scope")

  @doc "The well-formed scope in `context`, if any."
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    case Map.get(context, @marker) do
      %{
        tenant_id: tenant_id,
        agent_run_id: agent_run_id,
        lead_id: lead_id,
        entry_id: entry_id,
        sha256s: sha256s
      } = scope
      when is_binary(tenant_id) and is_binary(agent_run_id) and is_binary(lead_id) and
             is_binary(entry_id) and is_list(sha256s) ->
        {:ok, scope}

      _other ->
        :error
    end
  end

  def fetch(_context), do: :error

  # RED stub result, typed dynamic(); nothing sets the key (ruling e).
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
