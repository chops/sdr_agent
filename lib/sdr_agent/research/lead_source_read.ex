defmodule SdrAgent.Research.LeadSourceRead do
  @moduledoc """
  The body of `SdrAgent.Research.read_lead_sources/4` (ADR-0026): the
  sources of a lead's ONE input origin, resolved by lead id after the run is
  authorized.

  In prototype runtime, for an `:agent_runtime` actor of the binding's tenant
  whose run `run_id` is running for `lead_id`:

    * a lead with a `DossierEntry` (and no owner intake) is read through the
      unchanged `SdrAgent.Research.DossierSourceRead`; each item gains
      `origin: :dossier`, `source_id` (the dossier source id) and
      `owner_source_id: nil`;
    * a lead with an `OwnerProspectIntake` (and no dossier entry) is read
      through `SdrAgent.Research.OwnerIntakeSourceRead`;
    * both is `{:error, :lead_origin_ambiguous}`, neither is
      `{:error, :lead_origin_missing}`.

  Authorization comes first, so a refused caller learns nothing about the
  lead's origin. Other codes are those of the two readers. The production
  build refuses every call.
  """
  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @type selector :: :all | {:final_url, String.t()}

  if @prototype_compiled do
    require Ash.Query

    alias SdrAgent.Agents
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Research.DossierEntry
    alias SdrAgent.Research.DossierSourceRead
    alias SdrAgent.Research.OwnerIntakeSourceRead
    alias SdrAgent.Research.OwnerProspectIntake

    @doc "See the moduledoc."
    @spec read(term(), term(), selector(), term()) :: {:ok, [map()]} | {:error, term()}
    def read(run_id, lead_id, selector, actor) when is_binary(run_id) and is_binary(lead_id) do
      with {:ok, run, _binding_id} <- authorize(run_id, lead_id, actor),
           {:ok, origin} <- origin(lead_id, run.tenant_id) do
        read_origin(origin, run_id, lead_id, selector, actor)
      end
    end

    def read(_run_id, _lead_id, _selector, _actor), do: {:error, :forbidden}

    @doc """
    The shared caller check: prototype runtime, an `:agent_runtime` actor of
    the binding's tenant, a live binding, and run `run_id` running for
    `lead_id` in that tenant. Returns `{:ok, run, binding_id}`.
    """
    @spec authorize(term(), term(), term()) ::
            {:ok, struct(), Ecto.UUID.t()} | {:error, term()}
    def authorize(run_id, lead_id, actor) do
      with :ok <- prototype(),
           {:ok, tenant_id, binding_id} <- agent_of_binding(actor),
           :ok <- SdrAgent.Prototype.check_live(),
           {:ok, run} <- running_run(run_id, lead_id, tenant_id, actor) do
        {:ok, run, binding_id}
      end
    end

    defp prototype do
      case SdrAgent.Prototype.runtime() do
        :prototype -> :ok
        _ordinary -> {:error, :not_prototype_runtime}
      end
    end

    defp agent_of_binding(%SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant_id})
         when is_binary(tenant_id) do
      case SdrAgent.Prototype.binding() do
        {:ok, %{id: binding_id, tenant_id: ^tenant_id}} -> {:ok, tenant_id, binding_id}
        {:ok, _other_tenant} -> {:error, :forbidden}
        {:error, error} -> {:error, error}
      end
    end

    defp agent_of_binding(_actor), do: {:error, :forbidden}

    defp running_run(run_id, lead_id, tenant_id, actor) do
      case Agents.get_run(run_id, actor: actor) do
        {:ok, %{status: :running, lead_id: ^lead_id, tenant_id: ^tenant_id} = run} -> {:ok, run}
        {:ok, _other} -> {:error, :forbidden}
        {:error, error} -> {:error, error}
      end
    end

    defp origin(lead_id, tenant_id) do
      with {:ok, dossier?} <- exists?(DossierEntry, lead_id, tenant_id),
           {:ok, owner?} <- exists?(OwnerProspectIntake, lead_id, tenant_id) do
        case {dossier?, owner?} do
          {true, false} -> {:ok, :dossier}
          {false, true} -> {:ok, :owner_intake}
          {true, true} -> {:error, :lead_origin_ambiguous}
          {false, false} -> {:error, :lead_origin_missing}
        end
      end
    end

    defp exists?(resource, lead_id, tenant_id) do
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and lead_id == ^lead_id)
      |> Ash.exists()
    end

    defp read_origin(:owner_intake, run_id, lead_id, selector, actor),
      do: OwnerIntakeSourceRead.read(run_id, lead_id, selector, actor)

    defp read_origin(:dossier, run_id, lead_id, selector, actor) do
      case DossierSourceRead.read(run_id, lead_id, selector, actor) do
        {:ok, items} -> {:ok, Enum.map(items, &dossier_item/1)}
        error -> error
      end
    end

    defp dossier_item(item) do
      Map.merge(item, %{
        origin: :dossier,
        source_id: item.dossier_source_id,
        owner_source_id: nil
      })
    end
  else
    @doc "Refused: no prototype authority in this build."
    @spec read(term(), term(), selector(), term()) :: {:error, :not_prototype_runtime}
    def read(_run_id, _lead_id, _selector, _actor), do: {:error, :not_prototype_runtime}
  end
end
