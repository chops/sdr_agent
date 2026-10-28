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
    * the receipt's operation and its approval, each read through the
      recording actor's policy-authorized path by id AND the binding tenant,
      exist, and the approval's approver is the binding's anchor
      (`prototype_approval_not_delegated`; a read that returns an error is
      `prototype_capture_unchecked`);
    * the decision instant is inside the funding entry's
      `[starts_at, expires_at)` (`prototype_outside_window`);
    * the operation's immutable recipient is not suppressed by email or
      domain under Outreach's own normalised matching
      (`SdrAgent.Outreach.matching_suppressions/2`;
      `prototype_recipient_suppressed`); the lookup runs in its own
      savepoint, and a failed lookup is rolled back to it and refuses closed
      (`prototype_suppression_unchecked`) at once, never read as "not
      suppressed" and never surfacing the database error;
    * the server-derived block is present (`prototype_assurance_unavailable`).

  The raised message carries the code only: no recipient, SQL or inner
  error. Ordinary runtime, and every other receipt kind, are unchanged. The
  prototype part compiles only with `:prototype_authority_compiled`.

  Test-build seams. These compile only with `:prototype_test_seams`, which
  only config/test.exs sets (S4 proposal r3 section 5.1, the r3a schemas;
  Codex 1fabb2d3, bounded prerequisite construction). They are site-local
  process keys, read only at this boundary's call sites, so Ash's create
  authorize pre-flight never consumes them. Each acts only when its scope's
  `op_id` is the receipt's operation, and each message echoes the scope's
  `ref`, `op_id` and `attempt`:

    * `{__MODULE__, :observer}` = `%{ref, op_id, attempt}`: each refusal
      decided here sends `{__MODULE__, ref, :refused, op_id, attempt, code}`;
    * `{__MODULE__, :inject}` = `%{ref, op_id, attempt, stage, result}`
      (stage `:binding | :operation | :approval | :suppression`): that
      stage's call returns `result` instead of reading, after sending
      `{__MODULE__, ref, :injected, op_id, attempt, stage}`;
    * `{__MODULE__, :fault}` = `%{ref, op_id, attempt, point: :decision}`:
      decision code sends `{__MODULE__, ref, :fault_raised, op_id, attempt,
      :decision}` and then raises a synthetic `KeyError`.

  With no scope set, and in every other build, the seams do nothing.
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
          nil ->
            {:ok, record}

          code ->
            observe(record.delivery_operation_id, code)
            refuse!(code)
        end
      end
    end

    defp refusal(changeset, record, actor) do
      with {:ok, binding} <- live_binding(record),
           {:ok, operation} <- delegated(record, binding, actor),
           :ok <- inside_window(),
           :ok <- unsuppressed(operation, actor) do
        decision_fault(record.delivery_operation_id)

        if is_map(Ash.Changeset.get_argument(changeset, :prototype)),
          do: nil,
          else: :prototype_assurance_unavailable
      else
        {:refuse, code} -> code
      end
    end

    defp live_binding(record) do
      with :ok <- stage(:binding, record.delivery_operation_id, &SdrAgent.Prototype.check_live/0),
           {:ok, %{tenant_id: tenant_id} = binding} <- SdrAgent.Prototype.binding(),
           true <- tenant_id == record.tenant_id do
        {:ok, binding}
      else
        _ -> {:refuse, :prototype_binding_mismatch}
      end
    end

    # Codex f9a45a0c R2: the receipt's operation and its approval are read
    # through the policy-authorized path of the recording actor (DLV), by id
    # AND the binding tenant; a missing or foreign row is not delegated, and a
    # read that returns an error refuses as unchecked, never as a decision.
    defp delegated(record, binding, actor) do
      op_id = record.delivery_operation_id

      with {:ok, %{} = operation} <-
             stage(:operation, op_id, fn ->
               tenant_row(SdrAgent.Outreach.DeliveryOperation, op_id, binding, actor)
             end),
           {:ok, %{} = approval} <-
             stage(:approval, op_id, fn ->
               tenant_row(SdrAgent.Outreach.Approval, operation.approval_id, binding, actor)
             end),
           true <- approval.approver_id == binding.operator_user_id do
        {:ok, operation}
      else
        {:error, _unchecked} -> {:refuse, :prototype_capture_unchecked}
        _not_delegated -> {:refuse, :prototype_approval_not_delegated}
      end
    end

    defp tenant_row(_resource, nil, _binding, _actor), do: {:ok, nil}

    defp tenant_row(resource, id, binding, actor) do
      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(id == ^id and tenant_id == ^binding.tenant_id)
      |> Ash.read_one()
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
      case lookup(operation, actor) do
        {:ok, []} -> :ok
        {:ok, [_ | _]} -> {:refuse, :prototype_recipient_suppressed}
        _failed -> {:refuse, :prototype_suppression_unchecked}
      end
    end

    # The lookup runs in its own savepoint: a failed query (which may abort
    # the transaction, and which the data layer answers by rolling back the
    # innermost transaction) is rolled back to that savepoint, so the
    # receipt's transaction stays usable only long enough to raise the fixed
    # refusal; no other query follows and nothing of the error is kept.
    defp lookup(operation, actor) do
      case SdrAgent.Repo.transaction(fn -> matching(operation, actor) end) do
        {:ok, rows} -> {:ok, rows}
        {:error, _rolled_back} -> :unchecked
      end
    rescue
      _error -> :unchecked
    end

    defp matching(operation, actor) do
      read = fn ->
        SdrAgent.Outreach.matching_suppressions(operation.recipient_email, actor: actor)
      end

      case stage(:suppression, operation.id, read) do
        {:ok, rows} when is_list(rows) -> rows
        _failed -> SdrAgent.Repo.rollback(:unchecked)
      end
    end

    defp refuse!(code) do
      raise Ash.Error.Changes.InvalidChanges,
        fields: [:kind],
        message: "#{code}: the prototype capture boundary refused this receipt"
    end

    # Test-build seams (see the moduledoc): site-local, bound to the
    # receipt's operation, and inert without a scope.
    if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do
      defp stage(stage, op_id, read) do
        case Process.get({__MODULE__, :inject}) do
          %{ref: ref, op_id: ^op_id, attempt: attempt, stage: ^stage, result: result} ->
            send(self(), {__MODULE__, ref, :injected, op_id, attempt, stage})
            result

          _none ->
            read.()
        end
      end

      defp decision_fault(op_id) do
        case Process.get({__MODULE__, :fault}) do
          %{ref: ref, op_id: ^op_id, attempt: attempt, point: :decision} ->
            send(self(), {__MODULE__, ref, :fault_raised, op_id, attempt, :decision})
            raise KeyError, key: :d237_s4_synthetic_fault, term: %{}

          _none ->
            :ok
        end
      end

      defp observe(op_id, code) do
        case Process.get({__MODULE__, :observer}) do
          %{ref: ref, op_id: ^op_id, attempt: attempt} ->
            send(self(), {__MODULE__, ref, :refused, op_id, attempt, code})

          _none ->
            :ok
        end
      end
    else
      defp stage(_stage, _op_id, read), do: read.()
      defp decision_fault(_op_id), do: :ok
      defp observe(_op_id, _code), do: :ok
    end
  else
    defp prototype(changeset, _context), do: changeset
  end
end
