defmodule SdrAgent.Agents.Witness.GateEvidence do
  @moduledoc """
  The result gate's evidence after a withheld release (R0-07 slice C, row
  G4 with its section 6.4 bounds), used by the scan's attention step in
  `SdrAgent.Agents.Witness`.

  **Protected cause.** Exactly the Failure named as `gate_cause_id` by the
  invocation's release's original `model.result.withheld` event
  (`SdrAgent.Agents.ReleaseDecision.Binding`). That includes runs without
  an Operation; an `operation_id` alone protects nothing. While it is
  protected:

    * the scan never resolves it;
    * it counts, at its actual severity, as the invocation's live
      attention, so no duplicate is opened;
    * once it is resolved it stays resolved, and an unchanged observation
      (a C1 status equal to the baseline) never opens a new warning under
      a new id;
    * a distinct later mismatch, meaning a current mismatch link that has
      not yet received attention, still opens its own critical. A link
      has received attention when it was current at the baseline, or
      current when a later critical for the invocation was opened (rebuilt
      from the append-only link and Failure histories; review MF4). So a
      resolved distinct critical is not reopened while the C1 status stays
      the same.

  **Baseline.** The `current_status` and `current_link_ids` of the
  release's last `agents.witness.gate_evidence_changed` note. With no note,
  the C1 status and the current links as of the release's `decided_at`,
  rebuilt from the append-only link history.

  **Note.** `agents.witness.gate_evidence_changed` is appended by the
  kernel inside the scan's persist transaction, and only when the C1
  status differs from the baseline status, so repeated scans do not repeat
  it. Links: `model_invocation_id`, `agent_run_id`. Payload: `release_id`,
  `cause_failure_id`, `previous_status`, `current_status` (C1 codes) and
  the current link ids. It carries no content.

  A release with no bound cause (released, or withheld without a cause)
  protects nothing and gets no note. An unreadable binding or note fails
  closed (`{:error, :binding_unavailable}`): the scan writes nothing.
  """

  require Ash.Query

  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Binding
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @note "agents.witness.gate_evidence_changed"
  @resource "SdrAgent.Agents.ModelResultRelease"
  @subject "SdrAgent.Agents.ModelInvocation"
  @statuses ~w(unwitnessed inferred reconciled mismatch)

  @type t :: %{
          release: struct(),
          cause_id: Ecto.UUID.t(),
          baseline_status: atom(),
          baseline_link_ids: [Ecto.UUID.t()],
          attended_link_ids: [Ecto.UUID.t()]
        }

  @doc """
  The protection of `invocation`: `{:ok, t()}` for a withheld release with
  a bound cause, `{:ok, nil}` otherwise, or `{:error, :binding_unavailable}`.
  """
  @spec protection(struct()) :: {:ok, t() | nil} | {:error, :binding_unavailable}
  def protection(invocation) do
    with {:ok, release} <- release(invocation),
         {:ok, cause_id} when is_binary(cause_id) <- Binding.bound_cause(release),
         {:ok, status, link_ids} <- baseline(release, invocation),
         {:ok, attended} <- attended(release, invocation) do
      {:ok,
       %{
         release: release,
         cause_id: cause_id,
         baseline_status: status,
         baseline_link_ids: link_ids,
         attended_link_ids: Enum.uniq(link_ids ++ attended)
       }}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, _} -> {:error, :binding_unavailable}
    end
  end

  @doc """
  Whether a current mismatch link has not yet received attention: it was
  neither current at the baseline nor current when a critical for this
  invocation was opened after the release (review MF4).
  """
  @spec distinct_mismatch?(t(), [struct()]) :: boolean()
  def distinct_mismatch?(protection, links),
    do:
      Enum.any?(
        links,
        &(&1.link_status == :mismatch and &1.id not in protection.attended_link_ids)
      )

  @doc "Whether the C1 status over `links` differs from the baseline."
  @spec changed?(t(), [struct()]) :: boolean()
  def changed?(protection, links), do: Witness.status(links) != protection.baseline_status

  @doc "Appends the note when the C1 status changed (see the moduledoc)."
  @spec note(t() | nil, struct(), [struct()], term()) :: :ok | {:error, term()}
  def note(nil, _invocation, _links, _actor), do: :ok

  def note(protection, invocation, links, actor) do
    if changed?(protection, links) do
      attrs = %{
        event_type: @note,
        category: :model,
        subject_resource: @resource,
        subject_id: protection.release.id,
        action: "reconcile",
        model_invocation_id: invocation.id,
        agent_run_id: invocation.agent_run_id,
        payload: %{
          "release_id" => protection.release.id,
          "cause_failure_id" => protection.cause_id,
          "previous_status" => Atom.to_string(protection.baseline_status),
          "current_status" => Atom.to_string(Witness.status(links)),
          "current_link_ids" => links |> Enum.map(& &1.id) |> Enum.sort()
        }
      }

      case Kernel.append(attrs, actor: actor, tenant_id: invocation.tenant_id) do
        {:ok, _event} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp release(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
    )
    |> Ash.read_one()
  end

  defp baseline(release, invocation) do
    case last_note(release) do
      {:ok, nil} -> as_of(release, invocation)
      {:ok, %AuditEvent{payload: payload}} -> from_note(payload)
      error -> error
    end
  end

  defp last_note(release) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(release.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^release.tenant_id and event_type == @note and
        subject_resource == @resource and subject_id == ^release.id
    )
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  defp from_note(%{"current_status" => status, "current_link_ids" => ids})
       when status in @statuses and is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, String.to_existing_atom(status), ids},
      else: {:error, :binding_unavailable}
  end

  defp from_note(_malformed), do: {:error, :binding_unavailable}

  defp as_of(release, invocation) do
    with {:ok, current} <- current_at(invocation, release.decided_at) do
      {:ok, Witness.status(current), current |> Enum.map(& &1.id) |> Enum.sort()}
    end
  end

  # The mismatch links that already received attention after the release:
  # those current when each later critical for this invocation was opened
  # (a critical is opened in the same transaction as the links it answers),
  # rebuilt from the append-only histories.
  defp attended(release, invocation) do
    with {:ok, criticals} <- later_criticals(release, invocation) do
      Enum.reduce_while(criticals, {:ok, []}, &attend(invocation, &1, &2))
    end
  end

  defp attend(invocation, critical, {:ok, acc}) do
    case current_at(invocation, critical.inserted_at) do
      {:ok, links} -> {:cont, {:ok, acc ++ mismatch_ids(links)}}
      error -> {:halt, error}
    end
  end

  defp later_criticals(release, invocation) do
    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and subject_resource == @subject and
        subject_id == ^invocation.id and class == :reconciliation_required and
        severity == :critical and inserted_at >= ^release.decided_at
    )
    |> Ash.read()
  end

  defp mismatch_ids(links), do: for(%{link_status: :mismatch, id: id} <- links, do: id)

  # The links current at `time`: recorded by then, with no successor
  # recorded by then.
  defp current_at(invocation, time) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        recorded_at <= ^time
    )
    |> Ash.read()
    |> case do
      {:ok, links} ->
        superseded = MapSet.new(links, & &1.supersedes_id)
        {:ok, Enum.reject(links, &MapSet.member?(superseded, &1.id))}

      error ->
        error
    end
  end
end
