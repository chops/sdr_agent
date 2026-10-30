# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Seed do
    @moduledoc """
    Writes the D-237 GTM seed (interfaces r6 IF-7; supplement 1 r2 §3-§4,
    Codex R5-R7) as the acting prototype operator, in one transaction, from
    the validated `SdrAgent.Prototype.SeedDir.read/2` result; returns ids and
    digests only.

    `run/2` owns its one transaction (seed design D3), so a call inside an
    already-open transaction (a Repo or `SdrAgent.Audit.transaction/1`
    caller) is refused with `{:error, :seed_failed}` first, before any query:
    before the runtime, actor and live checks below, and before any read or
    write. That caller's transaction stays usable. The sole callers (setup
    phase 3 after the phase-2 commit, and the seed task) call it at top
    level.

    Then `run/2` re-checks the caller, before any write: prototype runtime
    (`:not_prototype_runtime`), the live binding (`SdrAgent.Prototype.check_live/0`,
    `:binding_mismatch`) and the live operator
    (`SdrAgent.Prototype.operator_actor/1`, called fresh, must resolve the
    actor's own delegation to exactly the same actor; anything else is
    `:forbidden`). Codes only.

    Content and pin checks precede writes. A locked binding serializes
    seed attempts. Empty history creates the provenance Payload, two
    revisions and the four Sales rows, then activates the exact registered
    seed triple. Every returned refusal rolls the whole transaction back.
    Exact history replays without writes or activation; partial, ambiguous
    or different history is never repaired or adopted. Exceptions propagate
    to the existing task boundary without inspecting their contents here.
    """

    require Ash.Query

    alias SdrAgent.Agents.RunSettings.ContentRules
    alias SdrAgent.Agents.SettingsRevision
    alias SdrAgent.Audit
    alias SdrAgent.Audit.AuditEvent
    alias SdrAgent.Audit.Checks.PrototypeInputScope
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Audit.Payload
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.SeedScope
    alias SdrAgent.Repo
    alias SdrAgent.Sales.Campaign
    alias SdrAgent.Sales.IcpDefinition
    alias SdrAgent.Sales.Sequence
    alias SdrAgent.Sales.SequenceStep

    @note "d237 seed provenance sha256:"
    @settings [:offering_profile, :writing_guide]
    @sales [
      {IcpDefinition, "sales.icp_definition.created"},
      {Sequence, "sales.sequence.created"},
      {SequenceStep, "sales.sequence_step.created"},
      {Campaign, "sales.campaign.created"}
    ]
    @creation_types Enum.map(@sales, &elem(&1, 1)) ++ ["settings.revision.created"]

    @doc """
    Writes or replays the seed; see the moduledoc. Inside an already-open
    transaction it is `{:error, :seed_failed}` before any query.
    """
    @spec run(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
    def run(seed, actor) do
      with :ok <- not_nested(),
           :ok <- live(actor),
           do: write(seed, actor)
    end

    # Seed design D3: the seed owns its one transaction, so an open caller
    # transaction (a nested Repo or Audit transaction is not a savepoint) is
    # refused before any query, and that transaction stays usable.
    defp not_nested, do: if(Repo.in_transaction?(), do: {:error, :seed_failed}, else: :ok)

    # The fresh real resolver must return exactly this actor (type, delegation
    # id and tenant), after the live binding check; nothing is taken from the
    # map or its type alone.
    defp live(%SdrAgent.Actor{type: :prototype_operator, id: id, tenant_id: tenant_id} = actor)
         when is_binary(id) and is_binary(tenant_id) do
      with :prototype <- Prototype.runtime(),
           :ok <- Prototype.check_live(),
           {:ok, ^actor} <- Prototype.operator_actor(id) do
        :ok
      else
        :ordinary -> {:error, :not_prototype_runtime}
        {:error, :binding_mismatch} -> {:error, :binding_mismatch}
        {:error, :not_prototype_runtime} -> {:error, :not_prototype_runtime}
        _ -> {:error, :forbidden}
      end
    end

    defp live(_actor) do
      if Prototype.runtime() == :prototype,
        do: {:error, :forbidden},
        else: {:error, :not_prototype_runtime}
    end

    defp write(seed, actor) do
      with :ok <- precheck(seed) do
        fn -> write_transaction(seed, actor) end
        |> Audit.transaction()
        |> closed_result()
      end
    end

    defp write_transaction(seed, actor) do
      lock_binding!(actor)

      case history(seed, actor) do
        :empty -> create(seed, actor)
        {:replay, rows} -> summary(:replay, seed, rows)
      end
    end

    # Ash may roll its enclosing transaction back with a changeset before
    # returning to the caller (e.g. a database uniqueness failure). Close
    # that result here as well; never let its content reach the task output.
    defp closed_result({:ok, summary}), do: {:ok, summary}
    defp closed_result({:error, %Ash.Changeset{}}), do: {:error, :seed_invalid}
    defp closed_result({:error, %Ash.Error.Invalid{}}), do: {:error, :seed_invalid}

    defp closed_result({:error, code})
         when code in [:seed_invalid, :seed_differs, :seed_failed, :binding_mismatch, :forbidden],
         do: {:error, code}

    defp closed_result({:error, _error}), do: {:error, :seed_failed}

    # SeedDir owns file shape and raw-file verification. Do not reserialize
    # decoded documents to "verify" their raw pins: whitespace is meaningful.
    defp precheck(%{
           offering_profile: profile,
           writing_guide: guide,
           campaign: campaign,
           provenance: %{"files" => files},
           provenance_bytes: bytes,
           sha256: pins
         })
         when is_map(campaign) and is_map(files) and is_binary(bytes) and is_map(pins) do
      with true <- valid_pins?(pins),
           true <- hex_digest(bytes) == pins.provenance,
           true <-
             Enum.all?(
               [:offering_profile, :writing_guide, :campaign],
               &(files[Atom.to_string(&1)] == pins[&1])
             ),
           {:ok, profile} <- ContentRules.canonical(:offering_profile, profile),
           :ok <- ContentRules.validate(:offering_profile, profile),
           {:ok, guide} <- ContentRules.canonical(:writing_guide, guide),
           :ok <- ContentRules.validate(:writing_guide, guide),
           true <- campaign["sender_name"] == "the GTMscape team",
           :ok <- campaign_text(campaign) do
        :ok
      else
        _invalid -> {:error, :seed_invalid}
      end
    end

    defp precheck(_seed), do: {:error, :seed_invalid}

    defp valid_pins?(pins) do
      Enum.all?([:offering_profile, :writing_guide, :campaign, :provenance], fn key ->
        is_binary(pins[key]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, pins[key])
      end)
    end

    defp campaign_text(text) when is_binary(text), do: ContentRules.text(text)
    defp campaign_text(map) when is_map(map), do: campaign_text(Map.values(map))

    defp campaign_text(list) when is_list(list) do
      Enum.reduce_while(list, :ok, fn value, :ok ->
        case campaign_text(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp campaign_text(_nontext), do: :ok
    defp hex_digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    defp lock_binding!(actor) do
      with {:ok, %{id: id}} <- Prototype.binding(),
           [_binding] <-
             PrototypeDatabaseBinding
             |> query(actor)
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.lock(:for_update)
             |> read!(),
           :ok <- live(actor) do
        :ok
      else
        _refused -> Repo.rollback(:binding_mismatch)
      end
    end

    defp query(resource, actor) do
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
      |> Ash.Query.filter(tenant_id == ^actor.tenant_id)
    end

    # Never issue another query after a returned read failure / SQL abort.
    defp read!(query) do
      case Ash.read(query) do
        {:ok, rows} -> rows
        {:error, _error} -> Repo.rollback(:seed_failed)
      end
    end

    defp history(seed, actor) do
      revisions =
        SettingsRevision
        |> query(actor)
        |> Ash.Query.filter(kind in ^@settings)
        |> read!()

      events =
        AuditEvent
        |> query(actor)
        |> Ash.Query.filter(
          action == "seed_prototype" and actor_type == :prototype_operator and
            event_type in ^@creation_types
        )
        |> read!()

      if revisions == [] and events == [] do
        :empty
      else
        replay(seed, actor, revisions, events)
      end
    end

    defp replay(seed, actor, revisions, events) do
      unless matching_revisions?(revisions, seed.sha256.provenance) and
               matching_events?(revisions, events, seed.sha256.provenance),
             do: Repo.rollback(:seed_differs)

      rows =
        Map.new(@sales, fn {resource, type} ->
          [event] = Enum.filter(events, &(&1.event_type == type))

          case resource |> query(actor) |> Ash.Query.filter(id == ^event.subject_id) |> read!() do
            [row] -> {resource, row}
            _missing -> Repo.rollback(:seed_differs)
          end
        end)

      icp = rows[IcpDefinition]
      sequence = rows[Sequence]
      step = rows[SequenceStep]
      campaign = rows[Campaign]

      unless step.sequence_id == sequence.id and campaign.sequence_id == sequence.id and
               campaign.icp_definition_id == icp.id,
             do: Repo.rollback(:seed_differs)

      unless Enum.all?([icp, sequence, campaign], &(&1.status == :active)),
        do: Repo.rollback(:seed_failed)

      {:replay, rows}
    end

    defp matching_revisions?(revisions, digest) do
      length(revisions) == 2 and
        Enum.sort(Enum.map(revisions, & &1.kind)) == Enum.sort(@settings) and
        Enum.all?(revisions, &(&1.number == 1 and &1.note == @note <> digest))
    end

    defp matching_events?(revisions, events, digest) do
      sales_match? =
        Enum.all?(@sales, fn {resource, type} ->
          case Enum.filter(events, &(&1.event_type == type)) do
            [event] ->
              event.subject_resource == inspect(resource) and
                get_in(event.payload, ["arguments", "seed_provenance_sha256"]) == digest

            _other ->
              false
          end
        end)

      revision_ids = Enum.sort(Enum.map(revisions, & &1.id))
      settings_events = Enum.filter(events, &(&1.event_type == "settings.revision.created"))

      settings_match? =
        Enum.all?(settings_events, &(&1.subject_resource == inspect(SettingsRevision))) and
          Enum.sort(Enum.map(settings_events, & &1.subject_id)) == revision_ids

      length(events) == 6 and sales_match? and settings_match? and
        length(Enum.uniq(Enum.map(events, & &1.correlation_id))) == 1 and
        Enum.all?(events, &(not is_nil(&1.correlation_id)))
    end

    defp create(seed, actor) do
      result =
        SeedScope.run(actor, %{digest: seed.sha256.provenance}, fn ref ->
          scoped_create(seed, actor, ref)
        end)

      case result do
        {:error, _refused} -> Repo.rollback(:seed_failed)
        summary -> summary
      end
    end

    defp scoped_create(seed, actor, ref) do
      context = %{sdr_seed_run_id: SeedScope.fetch_run_id(ref)}
      store_provenance!(seed, actor)
      create_settings!(seed, actor, context, ref)
      rows = create_sales!(seed, actor, context, ref)
      scope = %{sdr_prototype_seed_scope: SeedScope.fetch(ref)}

      for resource <- [IcpDefinition, Sequence, Campaign] do
        rows[resource]
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, context: scope)
        |> Ash.update()
        |> unwrap!(:seed_failed)
      end

      summary(:created, seed, rows)
    end

    defp create_settings!(seed, actor, context, ref) do
      for kind <- @settings do
        revision =
          create!(
            SettingsRevision,
            %{kind: kind, content: seed[kind], note: @note <> seed.sha256.provenance},
            actor,
            context
          )

        if kind == :offering_profile, do: bind!(ref, kind, revision)
      end
    end

    defp store_provenance!(seed, actor) do
      scope =
        PrototypeInputScope.context(%{
          tenant_id: actor.tenant_id,
          delegation_id: actor.id,
          purpose: :seed_provenance,
          sha256s: [:crypto.hash(:sha256, seed.provenance_bytes)]
        })

      Payload
      |> Ash.Changeset.for_create(
        :store_prototype_input,
        %{content: seed.provenance_bytes, content_type: "application/json"},
        actor: actor,
        context: scope
      )
      |> Ash.create()
      |> unwrap!(:seed_failed)
    end

    defp create_sales!(seed, actor, context, ref) do
      icp = seed.campaign["icp"]
      sequence = seed.campaign["sequence"]
      digest = seed.sha256.provenance

      icp_row =
        create!(
          IcpDefinition,
          %{
            name: icp["name"],
            description: icp["description"],
            criteria: icp["criteria"],
            seed_provenance_sha256: digest
          },
          actor,
          context
        )

      bind!(ref, :icp_definition, icp_row)

      sequence_row =
        create!(
          Sequence,
          %{name: sequence["name"], seed_provenance_sha256: digest},
          actor,
          context
        )

      bind!(ref, :sequence, sequence_row)

      step_row =
        create!(
          SequenceStep,
          %{
            sequence_id: sequence_row.id,
            instructions: sequence["step"]["instructions"],
            seed_provenance_sha256: digest
          },
          actor,
          context
        )

      bind!(ref, :sequence_step, step_row)

      campaign_row =
        create!(
          Campaign,
          %{
            name: "GTMscape prototype",
            icp_definition_id: icp_row.id,
            sequence_id: sequence_row.id,
            sender_name: "the GTMscape team",
            sender_email: "team@gtmscape.example",
            footer_template_version: "footer/1",
            seed_provenance_sha256: digest
          },
          actor,
          context
        )

      bind!(ref, :campaign, campaign_row)

      %{
        IcpDefinition => icp_row,
        Sequence => sequence_row,
        SequenceStep => step_row,
        Campaign => campaign_row
      }
    end

    defp create!(resource, attrs, actor, context) do
      resource
      |> Ash.Changeset.for_create(:seed_prototype, attrs, actor: actor, context: context)
      |> Ash.create()
      |> unwrap!(:seed_invalid)
    end

    defp unwrap!({:ok, record}, _code), do: record
    defp unwrap!({:error, %Ash.Error.Invalid{}}, code), do: Repo.rollback(code)
    defp unwrap!({:error, _error}, _code), do: Repo.rollback(:seed_failed)

    defp bind!(ref, kind, row) do
      case SeedScope.bind(ref, kind, row) do
        %SeedScope{} -> :ok
        _refused -> Repo.rollback(:seed_failed)
      end
    end

    defp summary(result, seed, rows) do
      %{
        result: result,
        revisions: 2,
        icp_id: rows[IcpDefinition].id,
        sequence_id: rows[Sequence].id,
        campaign_id: rows[Campaign].id,
        provenance_sha256: seed.sha256.provenance
      }
    end
  end
end
