defmodule SdrAgent.Research.DossierSourceRead do
  @moduledoc """
  The body of `SdrAgent.Research.read_dossier_sources/4` (D-237 supplement 1
  r2 §6a, Q2): the only path from imported dossier sources to the SDR
  actions.

  In prototype runtime, for an `:agent_runtime` actor of the binding's
  tenant, it re-reads the authoritative rows in that tenant: the running
  `AgentRun` whose lead is `lead_id`, that lead's one `DossierEntry` of the
  live binding, and the entry's `DossierSource` rows (all, or the one whose
  `final_url` is the selector's). It builds the
  `SdrAgent.Audit.Checks.DossierSourceScope` from those sources' hashes
  only and reads each verified excerpt through
  `Payload :read_dossier_source_content` (one `payload_view` AuditAccess per
  source, under AGT). No caller-built scope or hash is accepted.

  Returns `{:ok, [%{dossier_source_id, final_url, source_type,
  retrieved_on, checked_at, content}]}` in `source_id` order, or
  `{:error, code}`: `:not_prototype_runtime`, `:forbidden` (not AGT of the
  binding's tenant, or the run is not this lead's running run),
  `:binding_mismatch`, `:dossier_entry_missing`, `:dossier_entry_ambiguous`,
  `:dossier_source_missing`, `:dossier_source_ambiguous`,
  `:content_not_source_bound`, or a read error as returned. The production
  build refuses every call.
  """
  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @type selector :: :all | {:final_url, String.t()}

  if @prototype_compiled do
    require Ash.Query

    alias SdrAgent.Agents
    alias SdrAgent.Audit.Checks.DossierSourceScope
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Audit.Payload
    alias SdrAgent.Operations.PrototypeDelegation
    alias SdrAgent.Research.DossierEntry
    alias SdrAgent.Research.DossierSource

    @doc "See the moduledoc."
    @spec read(term(), term(), selector(), term()) :: {:ok, [map()]} | {:error, term()}
    def read(run_id, lead_id, selector, actor)
        when is_binary(run_id) and is_binary(lead_id) do
      with :ok <- prototype(),
           {:ok, tenant_id, binding_id} <- agent_of_binding(actor),
           :ok <- SdrAgent.Prototype.check_live(),
           {:ok, run} <- running_run(run_id, lead_id, tenant_id, actor),
           {:ok, entry} <- entry(lead_id, tenant_id, binding_id),
           {:ok, sources} <- selected(entry, tenant_id, selector) do
        contents(sources, run, entry, actor)
      end
    end

    def read(_run_id, _lead_id, _selector, _actor), do: {:error, :forbidden}

    @doc """
    True when `entry`'s delegation belongs to binding `binding_id` (shared
    with `SdrAgent.Research.Changes.DossierSourceBinding`).
    """
    @spec in_binding?(struct(), Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
    def in_binding?(%DossierEntry{delegation_id: delegation_id}, tenant_id, binding_id) do
      PrototypeDelegation
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^delegation_id)
      |> Ash.read_one()
      |> case do
        {:ok, %PrototypeDelegation{binding_id: ^binding_id}} -> true
        _other -> false
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

    defp entry(lead_id, tenant_id, binding_id) do
      DossierEntry
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and lead_id == ^lead_id)
      |> Ash.read()
      |> case do
        {:ok, entries} ->
          case Enum.filter(entries, &in_binding?(&1, tenant_id, binding_id)) do
            [entry] -> {:ok, entry}
            [] -> {:error, :dossier_entry_missing}
            _many -> {:error, :dossier_entry_ambiguous}
          end

        {:error, error} ->
          {:error, error}
      end
    end

    defp selected(entry, tenant_id, selector) do
      DossierSource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and entry_id == ^entry.id)
      |> Ash.Query.sort(source_id: :asc)
      |> Ash.read()
      |> case do
        {:ok, sources} -> pick(sources, selector)
        {:error, error} -> {:error, error}
      end
    end

    defp pick([_ | _] = sources, :all), do: {:ok, sources}
    defp pick([], :all), do: {:error, :dossier_source_missing}

    defp pick(sources, {:final_url, url}) when is_binary(url) do
      case Enum.filter(sources, &(&1.final_url == url)) do
        [source] -> {:ok, [source]}
        [] -> {:error, :dossier_source_missing}
        _many -> {:error, :dossier_source_ambiguous}
      end
    end

    defp pick(_sources, _selector), do: {:error, :dossier_source_missing}

    defp contents(sources, run, entry, actor) do
      scope =
        DossierSourceScope.context(%{
          tenant_id: run.tenant_id,
          agent_run_id: run.id,
          lead_id: run.lead_id,
          entry_id: entry.id,
          sha256s: Enum.map(sources, & &1.content_sha256)
        })

      Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
        case content(source, scope, actor) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end

    defp content(source, scope, actor) do
      Payload
      |> Ash.ActionInput.for_action(
        :read_dossier_source_content,
        %{sha256: source.content_sha256},
        actor: actor,
        context: scope
      )
      |> Ash.run_action()
      |> case do
        {:ok, bytes} when is_binary(bytes) ->
          if :crypto.hash(:sha256, bytes) == source.content_sha256,
            do: {:ok, item(source, bytes)},
            else: {:error, :content_not_source_bound}

        {:error, error} ->
          {:error, error}
      end
    end

    defp item(source, bytes) do
      %{
        dossier_source_id: source.id,
        final_url: source.final_url,
        source_type: source.source_type,
        retrieved_on: source.retrieved_on,
        checked_at: source.checked_at,
        content: bytes
      }
    end
  else
    @doc "Refused: no prototype authority in this build."
    @spec read(term(), term(), selector(), term()) :: {:error, :not_prototype_runtime}
    def read(_run_id, _lead_id, _selector, _actor), do: {:error, :not_prototype_runtime}
  end
end
