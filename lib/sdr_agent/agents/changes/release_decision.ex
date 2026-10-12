defmodule SdrAgent.Agents.Changes.ReleaseDecision do
  @moduledoc """
  `SdrAgent.Agents.ModelResultRelease` `:decide` rules (R0-07 entity PASS at
  1da747a), checked inside the action transaction:

    1. Statically: an allowed disposition/reason pair
       (`ModelResultRelease.allowed_pair?/2`); `evidence_sha256` present for
       `:calibration` and absent otherwise; a link for `:released`.
    2. Before the insert, with no row lock requested after the chain head
       (the event is appended in an after-action hook): the invocation is
       re-read **in the release's tenant** and locked `FOR SHARE`, then the
       link, when given, `FOR SHARE`. Link writes lock the invocation
       `FOR UPDATE`, so no successor can appear while the decision holds it.
       When the invocation already has a release, nothing else is checked:
       the upsert returns that row and step 4 compares it.
    3. Per disposition:
       * `:released` / `:withheld`: a completed generation-2 ClaudeCLI
         invocation of a non-`:proof` run; `:released` also needs a `:valid`
         output and a link that is this invocation's current, reconciled
         primary link, leaving the invocation `reconciled`, whose evidence
         names the invocation's CLI version, model, profile (round 5 item 7)
         and application digests, and
         whose exact tuple is on the shipped allowlist. Its projection and
         method are copied onto the release;
       * `:calibration`: `SdrAgent.Agents.Checks.CalibrationContext` bound
         to this invocation and its profile, a generation-2 ClaudeCLI
         invocation of a `:proof` run in any terminal status;
       * any given link must be this invocation's current link.
    4. After the upsert: a fresh row passes; an existing row with the same
       disposition, reason, link and evidence is an identical replay
       (marked so no second event is appended); anything else fails with
       `SdrAgent.Agents.Errors.ReleaseConflict`.

  The run id is put in the changeset context
  (`:model_result_release_agent_run_id`) for the event's run correlation.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.CalibrationContext
  alias SdrAgent.Agents.Errors.ReleaseConflict
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.Audit.Kernel

  @terminal [:completed, :failed, :unknown]
  @fingerprint [:disposition, :reason, :wire_witness_link_id, :evidence_sha256]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> static_rules()
    |> Ash.Changeset.before_action(&decide/1)
    |> Ash.Changeset.after_action(&check_replay/2)
  end

  defp static_rules(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    disposition = get.(:disposition)

    [
      pair_error(disposition, get.(:reason)),
      evidence_error(disposition, get.(:evidence_sha256)),
      link_error(disposition, get.(:wire_witness_link_id))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(changeset, fn {field, message}, acc -> invalid(acc, field, message) end)
  end

  # Missing or out-of-range values are reported by the attribute itself.
  defp pair_error(disposition, reason) when is_nil(disposition) or is_nil(reason), do: nil

  defp pair_error(disposition, reason) do
    unless ModelResultRelease.allowed_pair?(disposition, reason),
      do: {:reason, "#{inspect(reason)} is not a reason for #{inspect(disposition)}"}
  end

  defp evidence_error(:calibration, nil),
    do: {:evidence_sha256, "is required for a calibration latch"}

  defp evidence_error(disposition, evidence)
       when disposition in [:released, :withheld] and not is_nil(evidence),
       do: {:evidence_sha256, "is recorded only for a calibration latch"}

  defp evidence_error(_disposition, _evidence), do: nil

  defp link_error(:released, nil),
    do: {:wire_witness_link_id, "is required to release an output"}

  defp link_error(_disposition, _link), do: nil

  defp decide(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    tenant_id = get.(:tenant_id)

    with {:ok, invocation} <- lock(ModelInvocation, get.(:model_invocation_id), tenant_id),
         {:ok, link} <- lock_link(get.(:wire_witness_link_id), tenant_id) do
      changeset =
        Ash.Changeset.set_context(changeset, %{
          model_result_release_agent_run_id: invocation.agent_run_id
        })

      case existing(invocation) do
        # The upsert returns the existing row; `check_replay/2` compares it.
        :exists ->
          provenance(changeset, link)

        :none ->
          changeset
          |> check_disposition(get.(:disposition), invocation, link)
          |> check_link(invocation, link)
      end
    else
      {:error, field, message} -> invalid(changeset, field, message)
    end
  end

  # The link's evaluated projection and method, copied onto the release.
  defp provenance(changeset, %WireWitnessLink{} = link) do
    changeset
    |> Ash.Changeset.force_change_attribute(
      :projection_version,
      link.evidence["projection_version"]
    )
    |> Ash.Changeset.force_change_attribute(:method, link.method)
  end

  defp provenance(changeset, nil), do: changeset

  defp lock(resource, id, tenant_id) when is_binary(id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %^resource{} = row} -> {:ok, row}
      _ -> {:error, :model_invocation_id, "is not a model invocation of this tenant"}
    end
  end

  defp lock(_resource, _id, _tenant_id),
    do: {:error, :model_invocation_id, "is not a model invocation of this tenant"}

  defp lock_link(nil, _tenant_id), do: {:ok, nil}

  defp lock_link(id, tenant_id) do
    case lock(WireWitnessLink, id, tenant_id) do
      {:ok, link} ->
        {:ok, link}

      {:error, _field, _message} ->
        {:error, :wire_witness_link_id, "is not a link of this tenant"}
    end
  end

  defp existing(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.exists?()
    |> if(do: :exists, else: :none)
  end

  defp check_disposition(changeset, disposition, invocation, link)
       when disposition in [:released, :withheld] do
    cond do
      not gated?(invocation) ->
        invalid(
          changeset,
          :model_invocation_id,
          "must be a generation-2 ClaudeCLI invocation"
        )

      invocation.status != :completed ->
        invalid(changeset, :model_invocation_id, "must be completed")

      proof?(invocation) ->
        invalid(changeset, :model_invocation_id, "is a calibration call; it is never released")

      disposition == :released ->
        check_release(changeset, invocation, link)

      true ->
        changeset
    end
  end

  defp check_disposition(changeset, :calibration, invocation, _link) do
    cond do
      CalibrationContext.scope(changeset.context) != {invocation.profile_id, invocation.id} ->
        invalid(
          changeset,
          :disposition,
          "a calibration latch needs the calibration context of this invocation"
        )

      not gated?(invocation) or invocation.status not in @terminal ->
        invalid(
          changeset,
          :model_invocation_id,
          "must be a terminal generation-2 ClaudeCLI invocation"
        )

      not proof?(invocation) ->
        invalid(changeset, :model_invocation_id, "must be an invocation of a proof run")

      true ->
        changeset
    end
  end

  defp check_disposition(changeset, _disposition, _invocation, _link), do: changeset

  defp check_release(
         changeset,
         %{validation_status: :valid} = invocation,
         %WireWitnessLink{} = link
       ) do
    evidence = link.evidence
    projection = evidence["projection_version"]

    cond do
      link.link_status != :reconciled or evidence["classification"] != "primary" ->
        invalid(changeset, :wire_witness_link_id, "must be a reconciled primary link")

      not same_identity?(invocation, evidence) ->
        invalid(changeset, :wire_witness_link_id, "evidence must name this invocation")

      not Witness.allowlisted?(invocation, projection, link.method) ->
        invalid(changeset, :wire_witness_link_id, "its exact tuple is not on the allowlist")

      Witness.status(current_links(invocation)) != :reconciled ->
        invalid(changeset, :wire_witness_link_id, "the invocation is not reconciled")

      true ->
        provenance(changeset, link)
    end
  end

  defp check_release(changeset, %{validation_status: :valid}, _link),
    do: invalid(changeset, :wire_witness_link_id, "is required to release an output")

  defp check_release(changeset, _invocation, _link),
    do: invalid(changeset, :model_invocation_id, "must have a valid output to be released")

  # Any given link must be this invocation's current link (no successor).
  defp check_link(changeset, _invocation, nil), do: changeset

  defp check_link(changeset, invocation, link) do
    cond do
      link.model_invocation_id != invocation.id ->
        invalid(changeset, :wire_witness_link_id, "must be a link of this invocation")

      not Enum.any?(current_links(invocation), &(&1.id == link.id)) ->
        invalid(changeset, :wire_witness_link_id, "has been superseded")

      true ->
        changeset
    end
  end

  defp current_links(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        not exists(successors, true)
    )
    |> Ash.read!()
  end

  defp same_identity?(invocation, evidence) do
    WitnessEvidence.check_identity(invocation, evidence) == :ok and
      map_size(WitnessEvidence.identity(invocation)) == 2 and
      evidence["cli_version"] == invocation.provider_version and
      evidence["app_request_sha256"] == hex(invocation.request_sha256) and
      evidence["app_response_sha256"] == hex(invocation.response_sha256)
  end

  defp gated?(invocation),
    do: invocation.ledger_generation == 2 and invocation.provider == :claude_cli

  defp proof?(invocation) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(id == ^invocation.agent_run_id and tenant_id == ^invocation.tenant_id)
    |> Ash.read_one!()
    |> case do
      %AgentRun{usage_origin: :proof} -> true
      _ -> false
    end
  end

  defp check_replay(changeset, record) do
    cond do
      record.id == Ash.Changeset.get_attribute(changeset, :id) ->
        {:ok, record}

      Map.take(record, @fingerprint) == fingerprint(changeset) ->
        {:ok, Ash.Resource.put_metadata(record, :sdr_replayed, true)}

      true ->
        {:error,
         ReleaseConflict.exception(
           model_invocation_id: record.model_invocation_id,
           existing_id: record.id
         )}
    end
  end

  defp fingerprint(changeset),
    do: Map.new(@fingerprint, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp invalid(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
