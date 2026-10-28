defmodule SdrAgent.Outreach.Changes.PrototypeCapture do
  @moduledoc """
  The D-237 capture boundary on `DeliveryReceipt :record` (interfaces r6
  IF-1 capture boundary, IF-3 delegated approval, IF-5 block carriers;
  Codex 845d0959 and e9688dca). It must come after
  `SdrAgent.Research.Changes.MarkExisting` and before `AppendEvent`.

  Before the insert, every caller value of the `prototype` argument is
  scrubbed; in prototype runtime a `:captured` receipt gets the
  server-derived assurance block (`SdrAgent.Prototype.assurance/0`) as that
  argument, which `AppendEvent` records. Nothing is refused there, so a
  genuine replay is never refused.

  After the insert, in the same transaction and only for a NEW `:captured`
  receipt in prototype runtime (a replay, marked `:sdr_replayed` by
  `MarkExisting` from the stored row, is returned unchanged, with no event),
  every check below must hold, in this order, or the capture refuses by
  raising a fixed, content-free message naming the code, which rolls the
  inserted row back:

    * the live binding (`SdrAgent.Prototype.check_live/0`) and the receipt
      in the binding's tenant (`prototype_binding_mismatch`);
    * the receipt's operation and its approval, each read by id AND the
      binding tenant, exist, and the approval's approver is the binding's
      anchor (`prototype_approval_not_delegated`);
    * the decision instant is inside the funding entry's
      `[starts_at, expires_at)` (`prototype_outside_window`);
    * the operation's immutable recipient is not suppressed by email or
      domain under Outreach's own normalised matching
      (`SdrAgent.Outreach.matching_suppressions/2`;
      `prototype_recipient_suppressed`); a failed lookup refuses closed
      (`prototype_suppression_unchecked`) at once, issuing no further query
      on the possibly aborted transaction and never reading it as "not
      suppressed";
    * the server-derived block is present (`prototype_assurance_unavailable`).

  The raised message carries the code only: no recipient, SQL or inner
  error. Ordinary runtime, and every other receipt kind, are unchanged. The
  prototype part compiles only with `:prototype_authority_compiled`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.force_delete_argument(:prototype)
    |> prototype(context)
  end

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    require Ash.Query

    defp prototype(changeset, context) do
      if Ash.Changeset.get_attribute(changeset, :kind) == :captured and
           SdrAgent.Prototype.runtime() == :prototype do
        changeset
        |> with_block()
        |> Ash.Changeset.after_action(&checked(&1, &2, context.actor))
      else
        changeset
      end
    end

    defp with_block(changeset) do
      case SdrAgent.Prototype.assurance() do
        {:ok, %{} = block} -> Ash.Changeset.force_set_argument(changeset, :prototype, block)
        _unavailable -> changeset
      end
    end

    defp checked(changeset, record, actor) do
      if Ash.Resource.get_metadata(record, :sdr_replayed) do
        {:ok, record}
      else
        case refusal(changeset, record, actor) do
          nil -> {:ok, record}
          code -> refuse!(code)
        end
      end
    end

    defp refusal(changeset, record, actor) do
      with {:ok, binding} <- live_binding(record),
           {:ok, operation} <- delegated(record, binding),
           :ok <- inside_window(),
           :ok <- unsuppressed(operation, actor) do
        if is_map(Ash.Changeset.get_argument(changeset, :prototype)),
          do: nil,
          else: :prototype_assurance_unavailable
      else
        {:refuse, code} -> code
      end
    end

    defp live_binding(record) do
      with :ok <- SdrAgent.Prototype.check_live(),
           {:ok, %{tenant_id: tenant_id} = binding} <- SdrAgent.Prototype.binding(),
           true <- tenant_id == record.tenant_id do
        {:ok, binding}
      else
        _ -> {:refuse, :prototype_binding_mismatch}
      end
    end

    defp delegated(record, binding) do
      operation =
        tenant_row(SdrAgent.Outreach.DeliveryOperation, record.delivery_operation_id, binding)

      approval =
        operation && tenant_row(SdrAgent.Outreach.Approval, operation.approval_id, binding)

      if approval && approval.approver_id == binding.operator_user_id,
        do: {:ok, operation},
        else: {:refuse, :prototype_approval_not_delegated}
    end

    defp tenant_row(_resource, nil, _binding), do: nil

    defp tenant_row(resource, id, binding) do
      resource
      |> Ash.Query.filter(id == ^id and tenant_id == ^binding.tenant_id)
      |> Ash.read_one!(authorize?: false)
    end

    defp inside_window do
      with {:ok, %{starts_at: %DateTime{} = starts_at, expires_at: %DateTime{} = expires_at}} <-
             SdrAgent.Prototype.funding_entry(),
           now = SdrAgent.Clock.utc_now(),
           true <- DateTime.compare(now, starts_at) != :lt,
           true <- DateTime.compare(now, expires_at) == :lt do
        :ok
      else
        _ -> {:refuse, :prototype_outside_window}
      end
    end

    # A failed lookup may have aborted the transaction: refuse at once, with
    # no further query and nothing of the error kept.
    defp unsuppressed(operation, actor) do
      case lookup(operation.recipient_email, actor) do
        {:ok, []} -> :ok
        {:ok, [_ | _]} -> {:refuse, :prototype_recipient_suppressed}
        _failed -> {:refuse, :prototype_suppression_unchecked}
      end
    end

    defp lookup(email, actor) do
      SdrAgent.Outreach.matching_suppressions(email, actor: actor)
    rescue
      _error -> :unchecked
    end

    defp refuse!(code) do
      raise Ash.Error.Changes.InvalidChanges,
        fields: [:kind],
        message: "#{code}: the prototype capture boundary refused this receipt"
    end
  else
    defp prototype(changeset, _context), do: changeset
  end
end
