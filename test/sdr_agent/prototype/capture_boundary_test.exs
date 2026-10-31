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
  - T4: through the test-build result-injection seam (proposal r3 section
    5.1), a returned Forbidden at the operation or approval read stays
    Forbidden, a returned Unknown stays Unknown, and an injected `{:ok, nil}`
    is the closed not-delegated refusal. Nothing is kept. The injection's own
    attempt-tagged message is a prerequisite: until the seam exists, this is
    a prerequisite RED, not a semantic one.
  - T5: through the test-build decision-fault seam, a programming fault in
    decision code is raised by Ash as `Ash.Error.Unknown` (create.ex:124-134).
    It is not a refusal, and nothing is kept. The cause is identified by the
    seam's own `fault_raised` message, never by error text.
  - T10: negative oracle controls (Codex 4c72c150 H2). The typed-refusal
    oracle rejects an Ash-wrapped storage failure, and a programming fault,
    at exactly `"S4-ORACLE refused: no typed refusal"` after reach for this
    operation and attempt. The propagated-failure oracle rejects a typed
    business refusal at exactly `"S4-ORACLE propagated: typed refusal
    observed"`.

  - T11, propagated (Codex 1fabb2d3 R1/R2): the non-business worker paths
    are each reached for this operation and attempt and asserted at the
    oracle's own step:
    - a storage failure after the seam. Today it escapes the drain as the
      C1 protocol defect, so it is RED at "S4-ORACLE propagated: protocol";
    - a returned Forbidden and a returned Unknown, injected at the approval
      read;
    - a raised Unknown (the decision fault).
  - The fixtures' seam scopes restore any prior value on exit and on
    unwind, including scopes armed inside the hook. Control.
  - T19: each distinct exit stops the boundary at the real call site, with
    no later stage read and no audit event insert, for a returned error
    (injected), a raise (the decision fault) and a rollback throw (a renamed
    source). Controls.

  The seams are site-local keys that only PrototypeCapture's boundary call
  sites read (Codex 7b7f4b1c). The create authorize pre-flight
  (create.ex:200) never consumes them, and no data-layer read rule is
  involved.

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

  @capture SdrAgent.Outreach.Changes.PrototypeCapture
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

  test "T13: each boundary stage's call, as the delivery worker, queries exactly its own sources (control)" do
    {ctx, _delivery, operation} = held!()
    dlv = Actor.system(:delivery_worker, ctx.tenant.id)

    # check_live reads its binding, then the (empty) relocation chain; every
    # other stage reads exactly its own table.
    stages = [
      {"prototype_database_bindings", ["prototype_database_bindings", "prototype_relocations"],
       fn -> SdrAgent.Prototype.check_live() end},
      {"delivery_operations", ["delivery_operations"],
       fn -> tenant_row(DeliveryOperation, operation.id, ctx.tenant.id, dlv) end},
      {"approvals", ["approvals"],
       fn -> tenant_row(Approval, operation.approval_id, ctx.tenant.id, dlv) end},
      {"suppressions", ["suppressions"],
       fn -> Outreach.matching_suppressions(to_string(operation.recipient_email), actor: dlv) end}
    ]

    for {source, expected, call} <- stages do
      {result, queries} = queries(call)
      sources = queries |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      assert {source, MapSet.new(sources)} == {source, MapSet.new(expected)}
      refute match?({:error, _}, result), "the #{source} stage call returned an error"
    end
  end

  # ------------------------------------------------------------------ T4, T5

  # A direct record of `operation` with the result-injection seam armed for
  # this operation, its current attempt and `stage`. Returns
  # {the messages for the seam's ref, the value-free outcome}.
  defp injected(ctx, operation, stage, result) do
    ref = make_ref()

    scope = %{
      ref: ref,
      op_id: operation.id,
      attempt: operation.attempt_count,
      stage: stage,
      result: result
    }

    outcome = with_seam(:inject, scope, fn -> direct_refusal(ctx, operation) end)
    {messages(ref), outcome}
  end

  defp injected_at(operation, stage),
    do: [{:injected, operation.id, operation.attempt_count, stage}]

  test "T4: an injected returned Forbidden at the operation or approval read stays Forbidden; nothing kept" do
    {ctx, delivery, operation} = held!()

    for stage <- [:operation, :approval] do
      forbidden = {:error, Ash.Error.Forbidden.exception([])}
      {seen, outcome} = injected(ctx, operation, stage, forbidden)

      assert seen == injected_at(operation, stage),
             "prerequisite: the #{stage} injection was not reached"

      assert outcome == {:returned, :error, Ash.Error.Forbidden}
    end

    no_capture!(ctx, delivery)
  end

  test "T4: an injected returned Unknown stays Unknown; an injected missing approval is not delegated" do
    {ctx, delivery, operation} = held!()

    {seen, outcome} =
      injected(ctx, operation, :approval, {:error, Ash.Error.Unknown.exception([])})

    assert seen == injected_at(operation, :approval),
           "prerequisite: the injection was not reached"

    assert outcome == {:returned, :error, Ash.Error.Unknown}

    {seen, outcome} = injected(ctx, operation, :approval, {:ok, nil})

    assert seen == injected_at(operation, :approval),
           "prerequisite: the injection was not reached"

    assert outcome == {:refused, :prototype_approval_not_delegated}
    no_capture!(ctx, delivery)
  end

  test "T5: a programming fault in the boundary's decision code is raised by Ash as Unknown, not a refusal" do
    {ctx, delivery, operation} = held!()
    ref = make_ref()
    scope = %{ref: ref, op_id: operation.id, attempt: operation.attempt_count, point: :decision}

    outcome = with_seam(:fault, scope, fn -> direct_refusal(ctx, operation) end)

    assert messages(ref) == [{:fault_raised, operation.id, operation.attempt_count, :decision}],
           "prerequisite: the decision fault was not reached"

    assert outcome == {:raised, Ash.Error.Unknown}
    no_capture!(ctx, delivery)
  end

  # ------------------------------------------------------------------ T10

  test "T10: the typed-refusal oracle rejects an Ash-wrapped storage failure after reach, at its typed step (control)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    rejected_at!("S4-ORACLE refused: no typed refusal", fn ->
      refused_attempt!(ctx, delivery, :prototype_recipient_suppressed, fn _op ->
        tamper!("ALTER TABLE delivery_receipts RENAME TO delivery_receipts_unavailable")
      end)
    end)

    tamper!("ALTER TABLE delivery_receipts_unavailable RENAME TO delivery_receipts")
    no_capture!(ctx, delivery)
  end

  test "T10: the typed-refusal oracle rejects a programming fault after reach, at its typed step" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    attempt = outreach!(ctx, delivery).attempt_count + 1
    ref = make_ref()

    # The decision fault is armed inside the hook by with_capture!/2, so it
    # binds exactly this operation and attempt, and its prior scope is
    # restored in the calling process on every exit (Codex 1fabb2d3).
    rejected_at!("S4-ORACLE refused: no typed refusal", fn ->
      refused_attempt!(ctx, delivery, :prototype_recipient_suppressed, fn _op -> :ok end,
        arm: [fault: %{ref: ref, point: :decision}]
      )
    end)

    assert messages(ref) == [{:fault_raised, delivery.id, attempt, :decision}],
           "prerequisite: the decision fault was not reached for this attempt"

    no_capture!(ctx, delivery)
  end

  test "the fixtures restore a prior seam scope on exit and on unwind (control)" do
    key = {@capture, :fault}
    Process.put(key, :prior_scope)

    try do
      scope = %{ref: make_ref(), op_id: Ecto.UUID.generate(), attempt: 1, point: :decision}
      with_seam(:fault, scope, fn -> :ok end)
      assert Process.get(key) == :prior_scope

      assert_raise RuntimeError, fn ->
        with_seam(:fault, scope, fn -> raise "synthetic unwind" end)
      end

      assert Process.get(key) == :prior_scope

      ctx = prototype_drafted!()
      assert {:ok, approval} = operator_approve(ctx, ctx.draft)
      _delivery = delivery_of!(ctx, approval)

      {_ref, drained} =
        with_capture!(fn _op -> raise "synthetic hook unwind" end,
          arm: [fault: %{ref: make_ref(), point: :decision}]
        )

      assert drained == {:raised, RuntimeError}
      assert Process.get(key) == :prior_scope
      assert Process.get({@capture, :observer}) == nil
    after
      Process.delete(key)
    end
  end

  # ------------------------------------------------------------------ T11, propagated

  # Codex 1fabb2d3 R1/R2: the non-business worker paths, each reached for
  # this operation and attempt and asserted at the oracle's own step: a
  # storage failure after the seam, a returned Forbidden, a returned Unknown
  # (both injected at the approval read), and a raised Unknown (the decision
  # fault).
  test "T11: a storage failure after the seam propagates to the worker boundary as Unknown" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    # The source is restored right after the drain, before the oracle's
    # checks read the receipts.
    propagated_attempt!(
      ctx,
      delivery,
      fn _op ->
        tamper!("ALTER TABLE delivery_receipts RENAME TO delivery_receipts_unavailable")
      end,
      after_drain: fn ->
        tamper!("ALTER TABLE delivery_receipts_unavailable RENAME TO delivery_receipts")
      end
    )

    no_capture!(ctx, delivery)
  end

  for {label, class} <- [forbidden: Ash.Error.Forbidden, unknown: Ash.Error.Unknown] do
    test "T11: an injected returned #{label} at the approval read propagates to the worker boundary" do
      ctx = prototype_drafted!()
      assert {:ok, approval} = operator_approve(ctx, ctx.draft)
      delivery = delivery_of!(ctx, approval)
      attempt = outreach!(ctx, delivery).attempt_count + 1
      ref = make_ref()
      result = {:error, unquote(class).exception([])}

      propagated_attempt!(ctx, delivery, fn _op -> :ok end,
        class: unquote(class),
        arm: [inject: %{ref: ref, stage: :approval, result: result}]
      )

      assert messages(ref) == [{:injected, delivery.id, attempt, :approval}],
             "prerequisite: the injection was not reached for this attempt"

      no_capture!(ctx, delivery)
    end
  end

  test "T11: a raised programming fault propagates to the worker boundary as Unknown" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    attempt = outreach!(ctx, delivery).attempt_count + 1
    ref = make_ref()

    propagated_attempt!(ctx, delivery, fn _op -> :ok end,
      arm: [fault: %{ref: ref, point: :decision}]
    )

    assert messages(ref) == [{:fault_raised, delivery.id, attempt, :decision}],
           "prerequisite: the decision fault was not reached for this attempt"

    no_capture!(ctx, delivery)
  end

  test "T10: the propagated-failure oracle rejects a typed business refusal at its typed step" do
    fixture = bound!(enter_runtime: false)
    ctx = demo!(fixture)
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    enter_window!(fixture)

    rejected_at!("S4-ORACLE propagated: typed refusal observed", fn ->
      propagated_attempt!(ctx, delivery, fn _op -> :ok end)
    end)

    no_capture!(ctx, delivery)
  end

  # ------------------------------------------------------------------ T19

  # Codex 1fabb2d3 R3: each distinct exit is checked at the real boundary on
  # a direct record of a held operation: a returned error (injected), a
  # raise (the decision fault) and a rollback throw (a renamed source). One
  # ordered stream of this process's repo statements and seam messages
  # shows that the boundary was reached, and that after the exit point no
  # later stage's source is read and no audit event is inserted. Nothing is
  # captured.
  defp stop_stream(fun, ref) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:sdr_agent, :repo, :query], &__MODULE__.observe_query/4, self())

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, ordered(ref, [])}
  end

  defp ordered(ref, acc) do
    receive do
      {__MODULE__, :query, source, command} -> ordered(ref, [{:query, source, command} | acc])
      {@capture, ^ref, kind, _op_id, _attempt, detail} -> ordered(ref, [{kind, detail} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The stream after the first `marker`, or :not_reached.
  defp after_marker(stream, marker) do
    case Enum.drop_while(stream, &(&1 != marker)) do
      [^marker | rest] -> rest
      [] -> :not_reached
    end
  end

  defp later_work(rest, sources) do
    Enum.filter(rest, fn
      {:query, "audit_events", :insert} -> true
      {:query, source, _command} -> source in sources
      _other -> false
    end)
  end

  defp stops_after!(stream, marker, sources) do
    rest = after_marker(stream, marker)
    assert rest != :not_reached, "prerequisite: the exit point was not reached"
    assert later_work(rest, sources) == []
  end

  defp injected_stream(ctx, operation, stage) do
    ref = make_ref()
    forbidden = {:error, Ash.Error.Forbidden.exception([])}

    scope = %{
      ref: ref,
      op_id: operation.id,
      attempt: operation.attempt_count,
      stage: stage,
      result: forbidden
    }

    stop_stream(
      fn -> with_seam(:inject, scope, fn -> direct_refusal(ctx, operation) end) end,
      ref
    )
  end

  test "T19: a returned error at the operation read stops the boundary there (control)" do
    {ctx, delivery, operation} = held!()
    {_outcome, stream} = injected_stream(ctx, operation, :operation)
    stops_after!(stream, {:injected, :operation}, ["approvals", "suppressions"])
    no_capture!(ctx, delivery)
  end

  test "T19: a returned error at the approval read stops the boundary there (control)" do
    {ctx, delivery, operation} = held!()
    {_outcome, stream} = injected_stream(ctx, operation, :approval)
    stops_after!(stream, {:injected, :approval}, ["suppressions"])
    no_capture!(ctx, delivery)
  end

  test "T19: a raise in decision code stops the boundary before any audit event (control)" do
    {ctx, delivery, operation} = held!()
    ref = make_ref()
    scope = %{ref: ref, op_id: operation.id, attempt: operation.attempt_count, point: :decision}

    {_outcome, stream} =
      stop_stream(
        fn -> with_seam(:fault, scope, fn -> direct_refusal(ctx, operation) end) end,
        ref
      )

    stops_after!(stream, {:fault_raised, :decision}, [])
    no_capture!(ctx, delivery)
  end

  for {table, later} <- [{"approvals", ["suppressions"]}, {"suppressions", []}] do
    test "T19: a rollback throw at the #{table} read stops the boundary there (control)" do
      {ctx, delivery, operation} = held!()
      table = unquote(table)
      tamper!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")

      {_outcome, stream} =
        try do
          stop_stream(fn -> direct_refusal(ctx, operation) end, make_ref())
        after
          tamper!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")
        end

      stops_after!(stream, {:query, table, :error}, unquote(later))
      no_capture!(ctx, delivery)
    end
  end
end
