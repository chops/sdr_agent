defmodule SdrAgent.Outreach.Changes.PrototypeCapture do
  @moduledoc """
  The D-237 capture boundary on `DeliveryReceipt :record` (interfaces r6
  IF-1, IF-3 and IF-5; the S4 capture-boundary contract, proposal r3
  sections 2 and 3, Codex 6b79bfb3 and 6a092753). It must come after
  `SdrAgent.Research.Changes.MarkExisting` and before `AppendEvent`.

  Every caller value of the `prototype` argument is scrubbed. Everything
  below applies only in prototype runtime and only to a `:captured`
  receipt; ordinary runtime and every other receipt kind get no hook.

  - **Block.** Before the insert, the receipt gets the server-derived
    assurance block (`SdrAgent.Prototype.assurance/0`) as that argument,
    which `AppendEvent` records.
  - **Nested guard** (`before_transaction`, no query). A call made inside
    an open transaction is refused before any transaction or read, with
    `SdrAgent.Outreach.Errors.CaptureRefused` `:prototype_capture_nested`.
    So the receipt's own transaction is always the outermost, and a failed
    read rolls back exactly that transaction. A public `record_receipt`
    inside a foreign `Repo` transaction never gets here: the Audit Guard
    raises its `ArgumentError` first, unchanged.
  - **Checks** (`after_action`, in the receipt's transaction, a NEW receipt
    only). A replay marked `:sdr_replayed` by `MarkExisting` is returned
    unchanged. Each check below decides only on a successful read; on a
    refusal it returns `{:error, CaptureRefused}` with that business code,
    so Ash halts the chain and rolls the insert back:
    - the live binding (`SdrAgent.Prototype.check_live/0`, S1's closed
      conservative denial) and the receipt in the binding's tenant:
      `prototype_binding_mismatch`;
    - the receipt's operation and its approval, each read through the
      recording actor's policy-authorized path by id AND the binding
      tenant. A missing or foreign row, or an approver other than the
      anchor, is `prototype_approval_not_delegated`;
    - the decision instant inside the funding entry's
      `[starts_at, expires_at)`: `prototype_outside_window`;
    - the operation's recipient not suppressed by email or domain, under
      Outreach's own matching (`SdrAgent.Outreach.matching_suppressions/2`):
      `prototype_recipient_suppressed`;
    - the server-derived block present: `prototype_assurance_unavailable`.
  - **Propagation.** A read is a plain call: no rescue, no catch, no nested
    transaction.
    - A returned `{:error, e}`, Forbidden included, is returned unchanged,
      and Ash rolls back with no further query.
    - A raise propagates, and Ash raises its error class.
    - A failed read's rollback throw ends the receipt's own transaction,
      and Ash returns the original, lossy error.

    Such a failure is never classified, never read as "not suppressed",
    and never retried or reported as success here. The former
    `*_unchecked` codes have no producer.

  The prototype part compiles only with `:prototype_authority_compiled`.

  Test-build seams. These compile only with `:prototype_test_seams`, which
  only config/test.exs sets (proposal r3 section 5.1, the r3a schemas).
  They are site-local process keys, read only at this boundary's call
  sites, so Ash's create authorize pre-flight never consumes them. Each
  acts only when its scope's `op_id` is the receipt's operation, and each
  message echoes the scope's `ref`, `op_id` and `attempt`:

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

    alias SdrAgent.Outreach.Errors.CaptureRefused

    defp prototype(changeset, context) do
      if Ash.Changeset.get_attribute(changeset, :kind) == :captured and
           SdrAgent.Prototype.runtime() == :prototype do
        changeset
        |> with_block()
        |> Ash.Changeset.before_transaction(&guard/1)
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

    # No query: the call shape alone decides.
    defp guard(changeset) do
      if SdrAgent.Repo.in_transaction?() do
        op_id = Ash.Changeset.get_attribute(changeset, :delivery_operation_id)
        Ash.Changeset.add_error(changeset, refused(op_id, :prototype_capture_nested))
      else
        changeset
      end
    end

    defp checked(changeset, record, actor) do
      if Ash.Resource.get_metadata(record, :sdr_replayed) do
        {:ok, record}
      else
        case decide(changeset, record, actor) do
          :ok -> {:ok, record}
          {:refuse, code} -> {:error, refused(record.delivery_operation_id, code)}
          {:error, _propagated} = error -> error
        end
      end
    end

    defp refused(op_id, code) do
      observe(op_id, code)
      CaptureRefused.exception(code: code)
    end

    defp decide(changeset, record, actor) do
      with {:ok, binding} <- live_binding(record),
           {:ok, operation} <- delegated(record, binding, actor),
           :ok <- inside_window(),
           :ok <- unsuppressed(operation, actor) do
        decision_fault(record.delivery_operation_id)

        if is_map(Ash.Changeset.get_argument(changeset, :prototype)),
          do: :ok,
          else: {:refuse, :prototype_assurance_unavailable}
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

    # The receipt's operation and its approval, read through the recording
    # actor's policy-authorized path (DLV) by id AND the binding tenant. A
    # missing or foreign row, or another approver, is not delegated; a
    # returned read error is propagated unchanged (Codex 99c249b0 C2).
    defp delegated(record, binding, actor) do
      op_id = record.delivery_operation_id

      with {:ok, operation} <-
             stage(:operation, op_id, fn ->
               tenant_row(SdrAgent.Outreach.DeliveryOperation, op_id, binding, actor)
             end),
           {:ok, %{} = operation} <- present(operation),
           {:ok, approval} <-
             stage(:approval, op_id, fn ->
               tenant_row(SdrAgent.Outreach.Approval, operation.approval_id, binding, actor)
             end),
           {:ok, %{} = approval} <- present(approval) do
        if approval.approver_id == binding.operator_user_id,
          do: {:ok, operation},
          else: {:refuse, :prototype_approval_not_delegated}
      end
    end

    defp present(nil), do: {:refuse, :prototype_approval_not_delegated}
    defp present(row), do: {:ok, row}

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

    # A plain read (proposal r3 section 2.3). A returned error propagates
    # unchanged. A failed read's rollback throw is never caught here: it ends
    # the receipt's own transaction, and nothing is read as "not suppressed".
    defp unsuppressed(operation, actor) do
      read = fn ->
        SdrAgent.Outreach.matching_suppressions(operation.recipient_email, actor: actor)
      end

      case stage(:suppression, operation.id, read) do
        {:ok, []} -> :ok
        {:ok, [_ | _]} -> {:refuse, :prototype_recipient_suppressed}
        {:error, _propagated} = error -> error
      end
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
