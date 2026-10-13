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
    * a distinct later mismatch, meaning a current mismatch link that was
      not current at the baseline, still opens its own critical.

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

  @note "agents.witness.gate_evidence_changed"
  @resource "SdrAgent.Agents.ModelResultRelease"
  @statuses ~w(unwitnessed inferred reconciled mismatch)

  @type t :: %{
          release: struct(),
          cause_id: Ecto.UUID.t(),
          baseline_status: atom(),
          baseline_link_ids: [Ecto.UUID.t()]
        }

  @doc """
  The protection of `invocation`: `{:ok, t()}` for a withheld release with
  a bound cause, `{:ok, nil}` otherwise, or `{:error, :binding_unavailable}`.
  """
  @spec protection(struct()) :: {:ok, t() | nil} | {:error, :binding_unavailable}
  def protection(invocation) do
    with {:ok, release} <- release(invocation),
         {:ok, cause_id} when is_binary(cause_id) <- Binding.bound_cause(release),
         {:ok, status, link_ids} <- baseline(release, invocation) do
      {:ok,
       %{
         release: release,
         cause_id: cause_id,
         baseline_status: status,
         baseline_link_ids: link_ids
       }}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, _} -> {:error, :binding_unavailable}
    end
  end

  @doc "Whether a current mismatch link was not current at the baseline."
  @spec distinct_mismatch?(t(), [struct()]) :: boolean()
  def distinct_mismatch?(protection, links),
    do:
      Enum.any?(
        links,
        &(&1.link_status == :mismatch and &1.id not in protection.baseline_link_ids)
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

  # The links current at the decision: recorded by then, with no successor
  # recorded by then.
  defp as_of(release, invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        recorded_at <= ^release.decided_at
    )
    |> Ash.read()
    |> case do
      {:ok, links} ->
        superseded = MapSet.new(links, & &1.supersedes_id)
        current = Enum.reject(links, &MapSet.member?(superseded, &1.id))
        {:ok, Witness.status(current), current |> Enum.map(& &1.id) |> Enum.sort()}

      error ->
        error
    end
  end
end
