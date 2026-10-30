defmodule SdrAgent.Research.Changes.DossierSourceBinding do
  @moduledoc """
  `ResearchArtifact :record` in D-237 prototype runtime (supplement 1 r2 §6,
  R8): binds the artifact to exactly one dossier source and its bytes before
  `StoreContent` and before any event; ordinary runtime is untouched.

    1. The source: the `DossierSource` rows in the actor's tenant of the
       artifact's `lead_id` whose `final_url` equals `source_url` and whose
       entry is of the live binding. Exactly one, else
       `dossier_source_missing` / `dossier_source_ambiguous`.
    2. The bytes: `sha256(content)` must equal the source's
       `content_sha256`, else `content_not_source_bound`. The content is
       never replaced.
    3. Server-owned fields, whatever the caller sent: `provider:
       :public_dossier`, `trust_level: :unverified`, `retrieved_at` = the
       source's `checked_at` (the spot-check), `published_at: nil`,
       `freshness: :unknown`, and exactly the ten metadata keys.

  A refusal is a changeset error whose message is the code.
  """
  use Ash.Resource.Change

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  if @prototype_compiled do
    require Ash.Query

    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Research.DossierEntry
    alias SdrAgent.Research.DossierSource
    alias SdrAgent.Research.DossierSourceRead

    @impl true
    def change(changeset, _opts, _context) do
      if SdrAgent.Prototype.runtime() == :prototype, do: bind(changeset), else: changeset
    end

    defp bind(changeset) do
      tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
      lead_id = Ash.Changeset.get_attribute(changeset, :lead_id)
      url = Ash.Changeset.get_attribute(changeset, :source_url)
      content = Ash.Changeset.get_argument(changeset, :content)

      with {:ok, binding_id} <- live_binding(tenant_id),
           {:ok, source, entry} <- source(tenant_id, lead_id, url, binding_id),
           :ok <- bytes(source, content) do
        Ash.Changeset.force_change_attributes(changeset, %{
          provider: :public_dossier,
          trust_level: :unverified,
          retrieved_at: source.checked_at,
          published_at: nil,
          freshness: :unknown,
          metadata: metadata(source, entry)
        })
      else
        {:error, code} when is_atom(code) ->
          Ash.Changeset.add_error(changeset, field: :source_url, message: Atom.to_string(code))

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end

    defp live_binding(tenant_id) when is_binary(tenant_id) do
      case SdrAgent.Prototype.binding() do
        {:ok, %{id: binding_id, tenant_id: ^tenant_id}} -> {:ok, binding_id}
        {:ok, _other_tenant} -> {:error, :forbidden}
        {:error, error} -> {:error, error}
      end
    end

    defp live_binding(_tenant_id), do: {:error, :forbidden}

    defp source(tenant_id, lead_id, url, binding_id)
         when is_binary(lead_id) and is_binary(url) do
      DossierSource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and lead_id == ^lead_id and final_url == ^url)
      |> Ash.read()
      |> case do
        {:ok, sources} -> one(sources, tenant_id, lead_id, binding_id)
        {:error, error} -> {:error, error}
      end
    end

    defp source(_tenant_id, _lead_id, _url, _binding_id), do: {:error, :dossier_source_missing}

    defp one(sources, tenant_id, lead_id, binding_id) do
      bound =
        for source <- sources,
            {:ok, %DossierEntry{lead_id: ^lead_id} = entry} <- [entry(source, tenant_id)],
            DossierSourceRead.in_binding?(entry, tenant_id, binding_id),
            do: {source, entry}

      case bound do
        [{source, entry}] -> {:ok, source, entry}
        [] -> {:error, :dossier_source_missing}
        _many -> {:error, :dossier_source_ambiguous}
      end
    end

    defp entry(source, tenant_id) do
      DossierEntry
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^source.entry_id and tenant_id == ^tenant_id)
      |> Ash.read_one()
    end

    defp bytes(source, content) when is_binary(content) do
      if :crypto.hash(:sha256, content) == source.content_sha256,
        do: :ok,
        else: {:error, :content_not_source_bound}
    end

    defp bytes(_source, _content), do: {:error, :content_not_source_bound}

    defp metadata(source, entry) do
      %{
        "dossier_source_id" => source.id,
        "dossier_entry_id" => entry.id,
        "source_id" => source.source_id,
        "dossier_sha256" => entry.dossier_sha256,
        "spotcheck_sha256" => entry.spotcheck_sha256,
        "original_url" => source.original_url,
        "final_url" => source.final_url,
        "source_type" => Atom.to_string(source.source_type),
        "retrieved_on" => Date.to_iso8601(source.retrieved_on),
        "retrieved_at_meaning" => "spot_check"
      }
    end
  else
    # No prototype authority in this build (production): never a binding.
    @impl true
    def change(changeset, _opts, _context), do: changeset
  end
end
