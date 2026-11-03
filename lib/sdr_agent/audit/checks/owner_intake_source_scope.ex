defmodule SdrAgent.Audit.Checks.OwnerIntakeSourceScope do
  @moduledoc """
  Policy check for `SdrAgent.Audit.Payload` `:read_owner_intake_source_content`
  (ADR-0026). The owner-intake twin of
  `SdrAgent.Audit.Checks.DossierSourceScope`.

  It passes only when ALL hold:

    * the runtime is prototype and `SdrAgent.Prototype.check_live/0` is `:ok`;
    * the actor is an `%SdrAgent.Actor{type: :agent_runtime}` whose tenant is
      the binding's;
    * the action carries the private scope built by `context/1`, which only
      `SdrAgent.Research.OwnerIntakeSourceRead` builds;
    * the scope's tenant is the actor's and the requested `sha256` is one of
      the scope's `sha256s`;
    * re-read at consumption in the actor's tenant: the scope's run is
      running for the scope's lead, the scope's intake is that lead's
      `OwnerProspectIntake` of the live binding, and the requested hash is
      one of that intake's `OwnerProspectSource` content hashes.

  The scope never grants a read of a dossier source, and the dossier scope
  never grants a read of an owner excerpt: the two checks use different
  markers and re-read different rows.

  `purpose/0` is the fixed AuditAccess purpose of a scoped read. The
  positive branch exists only with the prototype authority
  (`:prototype_authority_compiled`); the production build refuses every
  request.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_owner_intake_source_scope
  @ids [:tenant_id, :agent_run_id, :lead_id, :intake_id]

  @impl true
  def describe(_opts),
    do:
      "the agent runtime reads an owner source hash of its run's lead intake in the live binding"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    require Ash.Query

    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Research.OwnerProspectIntake
    alias SdrAgent.Research.OwnerProspectSource

    @impl true
    def match?(
          %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant_id} = actor,
          %{subject: %Ash.ActionInput{context: context, arguments: arguments}},
          _opts
        )
        when is_binary(tenant_id) and is_map(context) do
      with :prototype <- SdrAgent.Prototype.Authority.runtime(),
           {:ok, %{id: binding_id, tenant_id: ^tenant_id}} <-
             SdrAgent.Prototype.Authority.binding(),
           :ok <- SdrAgent.Prototype.Authority.check_live(),
           {:ok, %{tenant_id: ^tenant_id, sha256s: sha256s} = scope} <- fetch(context),
           sha256 = Map.get(arguments, :sha256),
           true <- sha256 in sha256s do
        authoritative?(scope, sha256, binding_id, actor)
      else
        _refused -> false
      end
    end

    def match?(_actor, _authorizer, _opts), do: false

    # The scope's run, intake and hash, re-read now; any mismatch or read
    # error refuses.
    defp authoritative?(scope, sha256, binding_id, actor) do
      %{tenant_id: tenant_id, agent_run_id: run_id, lead_id: lead_id, intake_id: intake_id} =
        scope

      with {:ok, %{status: :running, lead_id: ^lead_id, tenant_id: ^tenant_id}} <-
             SdrAgent.Agents.get_run(run_id, actor: actor),
           {:ok,
            %OwnerProspectIntake{
              lead_id: ^lead_id,
              tenant_id: ^tenant_id,
              binding_id: ^binding_id
            }} <-
             Ash.get(OwnerProspectIntake, intake_id, Kernel.opts(tenant_id)),
           {:ok, [_ | _]} <-
             OwnerProspectSource
             |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
             |> Ash.Query.filter(
               tenant_id == ^tenant_id and intake_id == ^intake_id and lead_id == ^lead_id and
                 content_sha256 == ^sha256
             )
             |> Ash.read() do
        true
      else
        _refused -> false
      end
    end
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end

  @doc "The fixed AuditAccess purpose of a scoped owner source read."
  @spec purpose() :: String.t()
  def purpose, do: "owner_intake_source"

  @doc """
  The private context for one read: `tenant_id`, `agent_run_id`, `lead_id`,
  `intake_id` and the 32-byte `sha256s` of that intake's sources. Any other
  input raises `ArgumentError`.
  """
  @spec context(map()) :: map()
  def context(
        %{
          tenant_id: tenant_id,
          agent_run_id: agent_run_id,
          lead_id: lead_id,
          intake_id: intake_id,
          sha256s: sha256s
        } = scope
      )
      when is_binary(tenant_id) and is_binary(agent_run_id) and is_binary(lead_id) and
             is_binary(intake_id) and is_list(sha256s) do
    if hashes?(sha256s) do
      %{@marker => %{scope | sha256s: Enum.uniq(sha256s)}}
    else
      raise ArgumentError, "an owner source scope needs one or more 32-byte sha256s"
    end
  end

  def context(_other), do: raise(ArgumentError, "not an owner source scope")

  @doc """
  The well-formed scope in `context`, if any: binary tenant, run, lead and
  intake ids and a non-empty proper list of 32-byte hashes. Anything else is
  `:error`; it never raises.
  """
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    with %{sha256s: sha256s} = scope <- Map.get(context, @marker),
         true <- Enum.all?(@ids, &is_binary(Map.get(scope, &1))),
         true <- hashes?(sha256s) do
      {:ok, scope}
    else
      _malformed -> :error
    end
  end

  def fetch(_context), do: :error

  defp hashes?([_ | _] = sha256s), do: all_hashes?(sha256s)
  defp hashes?(_other), do: false

  defp all_hashes?([]), do: true

  defp all_hashes?([sha256 | rest]) when is_binary(sha256) and byte_size(sha256) == 32,
    do: all_hashes?(rest)

  defp all_hashes?(_improper_or_invalid), do: false
end
