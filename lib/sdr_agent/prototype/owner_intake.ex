defmodule SdrAgent.Prototype.OwnerIntake do
  @moduledoc """
  Above-domain owner intake (ADR-0026). Preview reads only. Commit revalidates
  input, owner and Account outcome under binding/head locks, composing scoped
  Ash actions atomically. Reuse never changes Account fields, exact replay
  writes nothing, and save never assigns, runs a model or sends outreach.

  The API is present in every build. Without compiled prototype authority,
  preview and commit return `{:error, :forbidden}` and write-scope checks
  return false without consulting persistence or prototype authority.
  """
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    require Ash.Query

    alias SdrAgent.Audit
    alias SdrAgent.Audit.Guard
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Audit.Payload
    alias SdrAgent.Operations.HostedOwner
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.OwnerIntakeInput
    alias SdrAgent.Repo
    alias SdrAgent.Research
    alias SdrAgent.Research.OwnerProspectIntake
    alias SdrAgent.Sales

    @scope_key {__MODULE__, :write_scope}
    @marker :sdr_owner_intake_write_scope
    @codes [
      :forbidden,
      :invalid_input,
      :intake_conflict,
      :preview_stale,
      :account_inactive,
      :suppressed,
      :website_source_missing,
      :website_source_ambiguous,
      :intake_failed
    ]

    @doc "Read-only preview; keep the result server-side, never as browser authority."
    def preview(params, actor) do
      with :ok <- owner(actor),
           {:ok, input, hash} <- OwnerIntakeInput.normalize(params) do
        inspect_input(input, hash, actor)
      end
    rescue
      _ -> {:error, :intake_failed}
    end

    @doc "Commit freshly normalized input against a server-held preview."
    def commit(params, preview, actor) do
      with false <- Repo.in_transaction?(),
           :ok <- owner(actor),
           {:ok, input, hash} <- OwnerIntakeInput.normalize(params),
           true <- is_map(preview) and Map.get(preview, :submission_sha256) == hash do
        Audit.transaction(fn -> commit_locked(input, hash, preview, actor) end) |> unwrap()
      else
        true -> {:error, :intake_failed}
        false -> {:error, :preview_stale}
        {:error, :forbidden} -> deny(actor)
        {:error, code} -> {:error, code}
      end
    rescue
      _ -> {:error, :intake_failed}
    end

    defp owner(actor) do
      if SdrAgent.Audit.HumanAuthority.hosted_owner?(actor), do: :ok, else: {:error, :forbidden}
    end

    defp deny(actor) do
      Guard.refuse(
        %{resource: OwnerProspectIntake, action: :record, guarded?: true, subject_id: nil},
        actor
      )

      {:error, :forbidden}
    end

    defp inspect_input(input, hash, actor) do
      with {:ok, []} <- suppressions(input["email"], actor),
           {:ok, entry} <- lookup(OwnerProspectIntake, [submission_sha256: hash], actor),
           {:ok, account} <- lookup(Sales.Account, [domain: input["domain"]], actor),
           :ok <- account_active(account) do
        preview_for(input, hash, entry, account, actor)
      else
        {:ok, [_ | _]} -> {:error, :suppressed}
        {:error, code} when code in @codes -> {:error, code}
        _ -> {:error, :intake_failed}
      end
    end

    defp preview_for(input, hash, entry, _account, _actor) when not is_nil(entry) do
      {:ok,
       %{
         mode: :replay,
         submission_sha256: hash,
         account_id: entry.account_id,
         input: input,
         entry: entry
       }}
    end

    defp preview_for(input, hash, nil, account, actor) do
      with {:ok, nil} <- lookup(Sales.Contact, [email: input["email"]], actor),
           :ok <- website_source(input, account) do
        {:ok,
         %{
           mode: if(account, do: :reuse, else: :create),
           submission_sha256: hash,
           account_id: account && account.id,
           input: input,
           account: account
         }}
      else
        {:ok, _contact} -> {:error, :intake_conflict}
        error -> error
      end
    end

    defp account_active(nil), do: :ok
    defp account_active(%{status: :active}), do: :ok
    defp account_active(_), do: {:error, :account_inactive}

    defp website_source(input, account) do
      url = if account, do: account.website_url, else: input["website_url"]

      case Enum.count(
             input["sources"],
             &(&1["source_type"] == "company_site" and &1["url"] == url)
           ) do
        1 -> :ok
        0 -> {:error, :website_source_missing}
        _ -> {:error, :website_source_ambiguous}
      end
    end

    defp lookup(resource, filters, actor) do
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
      |> Ash.Query.filter(tenant_id == ^actor.tenant_id)
      |> Ash.Query.do_filter(filters)
      |> Ash.read_one()
    end

    # HostedOwner intentionally has no generic role grant on Suppression. This
    # internal authoritative read uses the resource's existing matching action
    # and kernel read policy, explicitly tenant-scoped after fresh owner auth.
    # No suppression row leaves the coordinator, only a closed refusal code.
    defp suppressions(email, actor) do
      SdrAgent.Outreach.Suppression
      |> Ash.Query.for_read(:matching, %{email: email}, Kernel.opts(actor.tenant_id))
      |> Ash.Query.filter(tenant_id == ^actor.tenant_id)
      |> Ash.read()
    end

    defp commit_locked(input, hash, previous, actor) do
      with {:ok, %{id: binding_id}} <- Prototype.binding(),
           {:ok, [_]} <-
             PrototypeDatabaseBinding
             |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
             |> Ash.Query.filter(id == ^binding_id and tenant_id == ^actor.tenant_id)
             |> Ash.Query.lock(:for_update)
             |> Ash.read(),
           {:ok, _head} <- Kernel.lock_head(actor.tenant_id),
           :ok <- owner(actor),
           {:ok, current} <- inspect_input(input, hash, actor) do
        commit_current(input, hash, previous, current, binding_id, actor)
      else
        {:error, code} when code in @codes -> Repo.rollback(code)
        _ -> Repo.rollback(:intake_failed)
      end
    end

    defp commit_current(
           _input,
           _hash,
           _previous,
           %{mode: :replay, entry: entry},
           _binding,
           _actor
         ),
         do: {:replay, ids(entry)}

    defp commit_current(input, hash, previous, current, binding_id, actor) do
      if current.account_id != Map.get(previous, :account_id),
        do: Repo.rollback(:preview_stale)

      create(input, hash, current.account, binding_id, actor)
    end

    defp create(input, hash, existing, binding_id, actor) do
      with {:ok, owner} <- lookup(HostedOwner, [user_id: actor.id, status: :active], actor),
           true <- not is_nil(owner) and owner.binding_id == binding_id,
           {:ok, account} <- account(input, existing, actor),
           {:ok, contact} <-
             scoped_domain(
               Sales,
               :intake_contact,
               Sales.Contact,
               %{
                 account_id: account.id,
                 first_name: input["first_name"],
                 last_name: input["last_name"],
                 title: input["title"],
                 email: input["email"]
               },
               actor
             ),
           {:ok, lead} <-
             scoped_domain(
               Sales,
               :intake_lead,
               Sales.Lead,
               %{account_id: account.id, contact_id: contact.id},
               actor
             ),
           {:ok, entry} <-
             scoped_domain(
               Research,
               :record_owner_intake,
               OwnerProspectIntake,
               %{
                 account_id: account.id,
                 contact_id: contact.id,
                 lead_id: lead.id,
                 binding_id: binding_id,
                 relocation_id: owner.relocation_id,
                 submission_sha256: hash
               },
               actor
             ),
           :ok <- store_sources(input["sources"], entry, actor) do
        {:created, ids(entry)}
      else
        {:error, %Ash.Error.Forbidden{}} -> Repo.rollback(:forbidden)
        _ -> Repo.rollback(:intake_failed)
      end
    end

    defp account(_input, existing, _actor) when not is_nil(existing), do: {:ok, existing}

    defp account(input, nil, actor) do
      scoped_domain(
        Sales,
        :intake_account,
        Sales.Account,
        %{
          name: input["company_name"],
          domain: input["domain"],
          website_url: input["website_url"]
        },
        actor
      )
    end

    defp store_sources(sources, entry, actor) do
      sources
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {source, index}, :ok ->
        case store_source(source, index, entry, actor) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp store_source(source, index, entry, actor) do
      content = source["excerpt"]
      hash = :crypto.hash(:sha256, content)
      attrs = %{content: content, content_type: "text/plain"}

      with {:ok, _} <-
             with_scope(Payload, :store_owner_intake_input, attrs, actor, fn context ->
               Payload
               |> Ash.Changeset.for_create(:store_owner_intake_input, attrs,
                 actor: actor,
                 context: context
               )
               |> Ash.create()
             end),
           {:ok, _} <-
             scoped_domain(
               Research,
               :record_owner_intake_source,
               Research.OwnerProspectSource,
               %{
                 intake_id: entry.id,
                 lead_id: entry.lead_id,
                 source_key: "s#{index}",
                 url: source["url"],
                 source_type: String.to_existing_atom(source["source_type"]),
                 retrieved_on: source["retrieved_on"],
                 content_sha256: hash
               },
               actor
             ) do
        :ok
      end
    end

    defp scoped_domain(domain, function, resource, attrs, actor) do
      action = if domain == Research, do: :record, else: :record_owner_intake

      with_scope(resource, action, attrs, actor, fn context ->
        apply(domain, function, [attrs, [actor: actor, context: context]])
      end)
    end

    defp with_scope(resource, action, attrs, actor, fun) do
      previous = Process.get(@scope_key)
      reference = make_ref()

      Process.put(@scope_key, %{
        reference: reference,
        resource: resource,
        action: action,
        attrs: attrs,
        actor: actor
      })

      try do
        fun.(%{@marker => reference})
      after
        if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
      end
    end

    @doc false
    def valid_write_scope?(actor, %Ash.Changeset{} = changeset) do
      with true <- Repo.in_transaction?(),
           reference when is_reference(reference) <- Map.get(changeset.context, @marker),
           %{
             reference: ^reference,
             actor: ^actor,
             resource: resource,
             action: action,
             attrs: attrs
           } <-
             Process.get(@scope_key),
           true <- resource == changeset.resource and action == changeset.action.name,
           true <- changeset.attributes[:tenant_id] == actor.tenant_id,
           true <- exact_attributes?(changeset, attrs),
           :ok <- owner(actor) do
        true
      else
        _ -> false
      end
    end

    def valid_write_scope?(_, _), do: false

    defp exact_attributes?(changeset, attrs) do
      Enum.all?(attrs, fn {key, value} ->
        type = Ash.Resource.Info.attribute(changeset.resource, key).type
        {:ok, expected} = Ash.Type.cast_input(type, value)
        Ash.Type.equal?(type, Ash.Changeset.get_attribute(changeset, key), expected)
      end)
    end

    defp ids(entry),
      do: Map.take(entry, [:account_id, :contact_id, :lead_id]) |> Map.put(:entry_id, entry.id)

    defp unwrap({:ok, {kind, ids}}), do: {:ok, kind, ids}
    defp unwrap({:error, code}) when code in @codes, do: {:error, code}
    defp unwrap(_), do: {:error, :intake_failed}
  else
    @doc "Refused: owner intake is unavailable without compiled prototype authority."
    def preview(_params, _actor), do: {:error, :forbidden}

    @doc "Refused: owner intake is unavailable without compiled prototype authority."
    def commit(_params, _preview, _actor), do: {:error, :forbidden}

    @doc false
    def valid_write_scope?(_actor, _changeset), do: false
  end
end
