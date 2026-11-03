defmodule SdrAgent.Research.OwnerIntakeSourceRead do
  @moduledoc """
  The owner-intake branch of `SdrAgent.Research.read_lead_sources/4`
  (ADR-0026): the only path from owner-supplied excerpts to the SDR actions.

  In prototype runtime, for an `:agent_runtime` actor of the binding's
  tenant, it re-reads in that tenant the running `AgentRun` whose lead is
  `lead_id`, that lead's one `OwnerProspectIntake` of the live binding and
  the intake's `OwnerProspectSource` rows (all, or the one whose `url` is
  the selector's). It builds `SdrAgent.Audit.Checks.OwnerIntakeSourceScope`
  from those sources' hashes only and reads each exact excerpt through
  `Payload :read_owner_intake_source_content` (one `payload_view` access per
  source, under AGT). No caller-built scope or hash is accepted.

  Returns `{:ok, [item]}` in `source_key` order, each item
  `%{origin: :owner_intake, source_id: "s1".."s3", owner_source_id,
  final_url, source_type, retrieved_on, checked_at: nil, content}`, or
  `{:error, code}`: `:not_prototype_runtime`, `:forbidden`,
  `:owner_intake_missing`, `:owner_source_missing`,
  `:owner_source_ambiguous`, `:content_not_source_bound`, or a read error as
  returned. The production build refuses every call.
  """
  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @type selector :: :all | {:final_url, String.t()}

  if @prototype_compiled do
    require Ash.Query

    alias SdrAgent.Audit.Checks.OwnerIntakeSourceScope
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Audit.Payload
    alias SdrAgent.Research.LeadSourceRead
    alias SdrAgent.Research.OwnerProspectIntake
    alias SdrAgent.Research.OwnerProspectSource

    @doc "See the moduledoc."
    @spec read(term(), term(), selector(), term()) :: {:ok, [map()]} | {:error, term()}
    def read(run_id, lead_id, selector, actor) when is_binary(run_id) and is_binary(lead_id) do
      with {:ok, run, binding_id} <- LeadSourceRead.authorize(run_id, lead_id, actor),
           {:ok, intake} <- intake(lead_id, run.tenant_id, binding_id),
           {:ok, sources} <- selected(intake, run.tenant_id, selector) do
        contents(sources, run, intake, actor)
      end
    end

    def read(_run_id, _lead_id, _selector, _actor), do: {:error, :forbidden}

    defp intake(lead_id, tenant_id, binding_id) do
      OwnerProspectIntake
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and lead_id == ^lead_id)
      |> Ash.read()
      |> case do
        {:ok, [%{binding_id: ^binding_id} = intake]} -> {:ok, intake}
        {:ok, _none_or_other_binding} -> {:error, :owner_intake_missing}
        {:error, error} -> {:error, error}
      end
    end

    defp selected(intake, tenant_id, selector) do
      OwnerProspectSource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^tenant_id and intake_id == ^intake.id and lead_id == ^intake.lead_id
      )
      |> Ash.Query.sort(source_key: :asc)
      |> Ash.read()
      |> case do
        {:ok, sources} -> pick(sources, selector)
        {:error, error} -> {:error, error}
      end
    end

    defp pick([_ | _] = sources, :all), do: {:ok, sources}
    defp pick([], :all), do: {:error, :owner_source_missing}

    defp pick(sources, {:final_url, url}) when is_binary(url) do
      case Enum.filter(sources, &(&1.url == url)) do
        [source] -> {:ok, [source]}
        [] -> {:error, :owner_source_missing}
        _many -> {:error, :owner_source_ambiguous}
      end
    end

    defp pick(_sources, _selector), do: {:error, :owner_source_missing}

    defp contents(sources, run, intake, actor) do
      scope =
        OwnerIntakeSourceScope.context(%{
          tenant_id: run.tenant_id,
          agent_run_id: run.id,
          lead_id: run.lead_id,
          intake_id: intake.id,
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
        :read_owner_intake_source_content,
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
        origin: :owner_intake,
        source_id: source.source_key,
        owner_source_id: source.id,
        final_url: source.url,
        source_type: source.source_type,
        retrieved_on: source.retrieved_on,
        checked_at: nil,
        content: bytes
      }
    end
  else
    @doc "Refused: no prototype authority in this build."
    @spec read(term(), term(), selector(), term()) :: {:error, :not_prototype_runtime}
    def read(_run_id, _lead_id, _selector, _actor), do: {:error, :not_prototype_runtime}
  end
end
