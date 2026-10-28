defmodule SdrAgent.Prototype.CaptureBoundaryTest do
  @moduledoc """
  The D-237 capture boundary's contract (S4 proposal r3 sections 2-4 and 6,
  scoped PASS for RED preparation: Codex 6b79bfb3). It applies to prototype
  runtime and `kind: :captured` only.

  - T1: an accepted receipt recorded inside Delivery's own transaction is
    unchanged, and no transaction-hook warning is logged. Ordinary runtime is
    unchanged too. These are controls.
  - T2a: a public `record_receipt` inside a foreign `Repo.transaction` keeps
    the Audit Guard's `ArgumentError`, raised before any boundary or receipt
    query. Control.
  - T2b, T2c: a public call inside `Audit.transaction/1`, or a raw
    authorized Ash `:record` inside a `Repo.transaction`, reaches the action.
    It is refused as nested (`prototype_capture_nested`) before any boundary
    read or receipt write. The Ash transaction-hook warning is logged, not
    suppressed. The caller's transaction stays usable and commits, and no
    denial is audited for this Invalid refusal.
  - T11: a typed business refusal at the worker is a permanent delivery
    outcome. The job completes, the operation is failed_permanent with the
    closed reason, and the draft failed.
  - T12: the capture refusal codes are a closed set with a code-only
    message, and the two unchecked codes are retired.
  - T13: each boundary stage's call, made as the delivery worker, queries
    only its own source; the policy checks issue no query. Control.

  Errors are compared by struct name only, never by text or value. The
  proposed `SdrAgent.Outreach.Errors.CaptureRefused` is named as an atom, so
  this file compiles before it exists. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureLog
  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Repo

  @refused SdrAgent.Outreach.Errors.CaptureRefused
  @boundary_sources [
    "prototype_database_bindings",
    "delivery_operations",
    "approvals",
    "suppressions"
  ]
  @hook_warning "hooks on `SdrAgent.Outreach.DeliveryReceipt.record` are being executed"
  @codes [
    :prototype_binding_mismatch,
    :prototype_approval_not_delegated,
    :prototype_outside_window,
    :prototype_recipient_suppressed,
    :prototype_assurance_unavailable,
    :prototype_capture_nested
  ]

  @doc false
  # The repo query handler: for the attaching process only, it forwards each
  # statement's source and result command. No statement text, parameter or
  # error value is read.
  def observe_query(_event, _measurements, metadata, owner) do
    if self() == owner do
      command =
        case metadata[:result] do
          {:ok, %{command: command}} -> command
          _error -> :error
        end

      send(owner, {__MODULE__, :query, metadata[:source], command})
    end
  end

  # Runs `fun` and returns {its result, [{source, command}]} for this process.
  defp queries(fun) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:sdr_agent, :repo, :query], &__MODULE__.observe_query/4, self())

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, collected([])}
  end

  defp collected(acc) do
    receive do
      {__MODULE__, :query, source, command} -> collected([{source, command} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Boundary reads and receipt or audit writes among `queries`.
  defp touched(queries) do
    Enum.filter(queries, fn {source, command} ->
      source in @boundary_sources or
        (source in ["delivery_receipts", "audit_events"] and command == :insert)
    end)
  end

  defp held! do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    {ctx, delivery, hold_before_capture!(ctx, delivery)}
  end

  defp capture_attrs(operation) do
    %{
      delivery_operation_id: operation.id,
      idempotency_key: operation.idempotency_key,
      kind: :captured,
      provider: :capture,
      provider_message_id:
        SdrAgent.Outreach.Delivery.CaptureAdapter.provider_message_id(operation.idempotency_key),
      rendered_sha256: operation.rendered_sha256
    }
  end

  defp kinds(ctx, delivery), do: ctx |> receipts!(delivery) |> Enum.map(& &1.kind) |> Enum.sort()

  defp tenant_row(resource, id, tenant_id, actor) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one()
  end

  # ------------------------------------------------------------------ T1

  test "T1: a prototype delegated delivery is accepted inside Delivery's transaction, no hook warning (control)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    log = capture_log(fn -> deliver!() end)

    assert kinds(ctx, delivery) == [:accepted, :captured]
    assert outreach!(ctx, delivery).state == :accepted
    refute log =~ @hook_warning, "a transaction-hook warning was logged"
  end

  test "T1: ordinary runtime captured and accepted receipts are unchanged (control)" do
    ctx = demo!(nil)
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)

    log = capture_log(fn -> deliver!() end)

    assert kinds(ctx, delivery) == [:accepted, :captured]
    assert outreach!(ctx, delivery).state == :accepted
    refute log =~ @hook_warning, "a transaction-hook warning was logged"
  end

  # ------------------------------------------------------------------ T2

  test "T2a: a public record_receipt inside a foreign Repo transaction keeps the Guard's ArgumentError (control)" do
    {ctx, delivery, operation} = held!()

    {result, queries} =
      queries(fn ->
        Repo.transaction(fn -> outcome(fn -> record_operation(ctx, operation) end) end)
      end)

    assert result == {:ok, {:raised, ArgumentError}}
    assert touched(queries) == []
    no_capture!(ctx, delivery)
  end

  test "T2b: a public record_receipt inside Audit.transaction is refused as nested; the caller stays usable" do
    {ctx, delivery, operation} = held!()
    denials = length(events_of(ctx.tenant, "authz.denied"))
    marker = "d237-s4-nested-control@d237-s4.test"

    {transaction, log} =
      with_log(fn ->
        Audit.transaction(fn ->
          observed = queries(fn -> outcome(fn -> record_operation(ctx, operation) end) end)
          usable = Repo.query!("SELECT 1").rows
          written = Outreach.suppress(%{scope: :email, value: marker}, actor: ctx.admin)
          {observed, usable, match?({:ok, _}, written)}
        end)
      end)

    assert {:ok, {{refusal, queries}, [[1]], true}} = transaction
    assert refusal == {:refused, :prototype_capture_nested}
    assert touched(queries) == []
    assert log =~ @hook_warning, "the Ash transaction-hook warning was not logged"
    assert match?({:ok, [_]}, Outreach.matching_suppressions(marker, actor: ctx.admin))
    assert length(events_of(ctx.tenant, "authz.denied")) == denials
    no_capture!(ctx, delivery)
  end

  test "T2c: a raw authorized Ash :record inside a Repo transaction is refused as nested before any boundary read" do
    {ctx, delivery, operation} = held!()
    dlv = Actor.system(:delivery_worker, ctx.tenant.id)

    {transaction, log} =
      with_log(fn ->
        Repo.transaction(fn ->
          observed =
            queries(fn ->
              outcome(fn ->
                DeliveryReceipt
                |> Ash.Changeset.for_create(:record, capture_attrs(operation), actor: dlv)
                |> Ash.create()
              end)
            end)

          {observed, Repo.query!("SELECT 1").rows}
        end)
      end)

    assert {:ok, {{refusal, queries}, [[1]]}} = transaction
    assert refusal == {:refused, :prototype_capture_nested}
    assert touched(queries) == []
    assert log =~ @hook_warning, "the Ash transaction-hook warning was not logged"
    no_capture!(ctx, delivery)
  end

  # ------------------------------------------------------------------ T11

  test "T11: a typed business refusal at the worker is a permanent delivery outcome; the job completes" do
    fixture = bound!(enter_runtime: false)
    ctx = demo!(fixture)
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    enter_window!(fixture)

    counts = deliver!()
    op = outreach!(ctx, delivery)
    draft = outreach!(ctx, %Outreach.Draft{id: op.draft_id})

    assert {Map.get(counts, :success), Map.get(counts, :failure)} == {1, 0}

    assert {op.state, op.last_error, draft.status} ==
             {:failed_permanent, %{"reason" => "prototype_approval_not_delegated"}, :failed}

    no_capture!(ctx, delivery)
  end

  test "T11: capture at the exclusive window end is a permanent delivery outcome; the job completes" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    capture_hook!(:before_capture, fn _op -> Clock.freeze(window_end()) end)

    counts = deliver!()
    op = outreach!(ctx, delivery)
    draft = outreach!(ctx, %Outreach.Draft{id: op.draft_id})

    assert {Map.get(counts, :success), Map.get(counts, :failure)} == {1, 0}

    assert {op.state, op.last_error, draft.status} ==
             {:failed_permanent, %{"reason" => "prototype_outside_window"}, :failed}

    no_capture!(ctx, delivery)
  end

  # ------------------------------------------------------------------ T12

  test "T12: the capture refusal codes are a closed set with a code-only message" do
    assert Code.ensure_loaded?(@refused), "prerequisite: CaptureRefused is not defined"
    codes = Function.capture(@refused, :codes, 0).()
    assert codes == @codes

    for code <- codes do
      error = Function.capture(@refused, :exception, 1).(code: code)
      assert Exception.message(error) == "prototype capture refused (#{code})"
    end

    refute :prototype_suppression_unchecked in codes
    refute :prototype_capture_unchecked in codes
  end

  # ------------------------------------------------------------------ T13

  test "T13: each boundary stage's call, as the delivery worker, queries only its own source (control)" do
    {ctx, _delivery, operation} = held!()
    dlv = Actor.system(:delivery_worker, ctx.tenant.id)

    stages = [
      {"prototype_database_bindings", fn -> SdrAgent.Prototype.check_live() end},
      {"delivery_operations",
       fn -> tenant_row(DeliveryOperation, operation.id, ctx.tenant.id, dlv) end},
      {"approvals", fn -> tenant_row(Approval, operation.approval_id, ctx.tenant.id, dlv) end},
      {"suppressions",
       fn -> Outreach.matching_suppressions(to_string(operation.recipient_email), actor: dlv) end}
    ]

    for {source, call} <- stages do
      {result, queries} = queries(call)
      sources = queries |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      assert {source, sources} == {source, [source]}
      refute match?({:error, _}, result), "the #{source} stage call returned an error"
    end
  end
end
