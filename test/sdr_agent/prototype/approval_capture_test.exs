defmodule SdrAgent.Prototype.ApprovalCaptureTest do
  @moduledoc """
  D-237 delegated approval, capture and assurance in data (interfaces r6
  IF-3 "Delegated approval", IF-5 block carriers, IF-1 capture boundary;
  amendment items 8 and 9; plan r7 section 6 rows "Delegated approval /
  capture / assurance (residual 2)" and "Window (residual 3)", S4's part).

  - The operator's approval states delegated machine approval: the granted
    event records `prototype_operator` + the delegation id as its actor and
    carries `approval_mode: "delegated_machine"`, the delegation id and the
    assurance block; the approver is the anchor. It still binds the exact
    revision, content hash and recipient: a stale revision, a changed
    recipient or a suppressed recipient refuses it.
  - Capture: a NEW captured receipt in prototype runtime carries the block,
    only for an approval by the anchor; a duplicate capture gives one
    receipt; a non-anchor approval's capture and a live binding mismatch
    (`prototype_binding_mismatch`) record no captured receipt. Per the
    capture-boundary contract (S4 proposal r3, Codex 6b79bfb3), such a
    refusal is a typed business refusal: at the worker it is a permanent
    delivery outcome (`refused_attempt!/4`, T9), and on a direct record it is
    the singleton `CaptureRefused` matched by struct name (T3). Every
    refused capture writes nothing (`no_capture!/2`). An ordinary-runtime
    capture is unchanged.
  - Non-HTML carriers: receipt event, approval event and the signed export
    payload carry the block; the captured message bytes never do.
  - The window `[2026-10-30T15:05:40Z, 2026-11-07T07:00:00Z)`: the
    inclusive start and the EXCLUSIVE end for delegated approval (at the
    raw `Approval :approve`) and capture; after the end the human path is
    unchanged: `:revoke` stays human-only and a human revokes and approves.

  Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Export
  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Prototype
  alias SdrAgent.Sales

  @label "UNVERIFIED (PROTOTYPE)"

  defp block! do
    result = Prototype.assurance()
    assert match?({:ok, %{}}, result), "no assurance block: #{inspect(result)}"
    {:ok, block} = result
    block |> Jason.encode!() |> Jason.decode!()
  end

  defp captured(ctx, delivery), do: Enum.filter(receipts!(ctx, delivery), &(&1.kind == :captured))

  defp captured_events(ctx) do
    ctx.tenant
    |> events_of("outreach.delivery.receipt_recorded")
    |> Enum.filter(&(&1.payload["changes"]["kind"] == "captured"))
  end

  # ------------------------------------------------------------------ delegated approval

  test "the operator's approval is a recorded delegated machine approval with the block" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)

    assert approval.approver_id == ctx.anchor.id
    assert {approval.status, approval.verdict} == {:granted, :approved}
    assert approval.draft_revision_id == ctx.revision.id
    assert approval.revision_content_sha256 == ctx.revision.content_sha256
    assert to_string(approval.recipient_email) == to_string(ctx.contact.email)
    assert draft!(ctx, ctx.draft).status == :queued

    [granted] = events_of(ctx.tenant, "outreach.approval.granted")
    assert {granted.actor_type, granted.actor_id} == {:prototype_operator, ctx.operator.id}
    args = granted.payload["arguments"]
    assert args["approval_mode"] == "delegated_machine"
    assert args["delegation_id"] == ctx.operator.id
    assert args["prototype"] == block!()
    assert args["prototype"]["label"] == @label
    refute granted.actor_id == ctx.anchor.id
  end

  test "ordinary approvals are unchanged: no delegated mode, no block (control)" do
    ctx = demo!(nil)
    %{draft: draft} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)

    assert {:ok, _} =
             Outreach.approve(draft, approval_input(revision!(ctx, draft.current_revision_id)),
               actor: reviewer
             )

    [granted] = events_of(ctx.tenant, "outreach.approval.granted")
    args = granted.payload["arguments"]
    refute Map.has_key?(args, "approval_mode")
    refute Map.has_key?(args, "delegation_id")
    refute Map.has_key?(args, "prototype")
  end

  # The delegated arguments are server-derived at the raw action (Codex S4 B1
  # bounded PASS order, step 4): a caller's values never reach the event.
  @forged %{
    approval_mode: "human_reviewed",
    delegation_id: "00000000-0000-0000-0000-000000000001",
    prototype: %{"label" => "forged"}
  }

  defp raw_approve(ctx, actor) do
    {draft, input} = reviewed(ctx, ctx.draft)

    Approval
    |> Ash.Changeset.for_create(
      :approve,
      input |> Map.put(:draft_id, draft.id) |> Map.merge(@forged),
      actor: actor
    )
    |> Ash.create()
  end

  test "the operator's forged delegated inputs are replaced by the server values at the raw action" do
    ctx = prototype_drafted!()
    result = raw_approve(ctx, ctx.operator)

    assert match?({:ok, %{status: :granted}}, result),
           "raw operator approve: #{inspect(result, limit: 5)}"

    [granted] = events_of(ctx.tenant, "outreach.approval.granted")
    args = granted.payload["arguments"]
    assert args["approval_mode"] == "delegated_machine"
    assert args["delegation_id"] == ctx.operator.id
    assert args["prototype"] == block!()
  end

  test "a human's raw :approve in prototype runtime records none of the forged delegated inputs" do
    ctx = prototype_drafted!()
    result = raw_approve(ctx, ctx.admin)

    assert match?({:ok, %{status: :granted}}, result),
           "raw human approve: #{inspect(result, limit: 5)}"

    [granted] = events_of(ctx.tenant, "outreach.approval.granted")
    args = granted.payload["arguments"]
    refute Map.has_key?(args, "approval_mode")
    refute Map.has_key?(args, "delegation_id")
    refute args["prototype"] == @forged.prototype

    # Codex b84b0491: in prototype runtime a human's granted event carries
    # the server-derived assurance block (the label belongs to the runtime,
    # not the actor), never approval_mode or delegation_id.
    assert args["prototype"] == block!()
  end

  test "a stale revision is refused for the operator" do
    ctx = prototype_drafted!()
    {draft, stale} = reviewed(ctx, ctx.draft)
    PrototypeFixtures.leave_runtime()

    {:ok, _edited} =
      Outreach.edit_draft(draft, %{subject: "Newer", body_text: ctx.revision.body_text},
        actor: ctx.admin
      )

    enter_window!(ctx.fixture)

    assert {:error, %Ash.Error.Invalid{}} =
             Outreach.approve(draft!(ctx, draft), stale, actor: ctx.operator)

    assert approvals!(ctx, draft) == []
  end

  test "a changed recipient is refused for the operator" do
    ctx = prototype_drafted!()
    {draft, input} = reviewed(ctx, ctx.draft)

    {:ok, _} =
      Sales.update(ctx.contact, :change_email, %{email: "moved@example.test"}, actor: ctx.admin)

    assert {:error, %Ash.Error.Invalid{}} = Outreach.approve(draft, input, actor: ctx.operator)
    assert approvals!(ctx, draft) == []
  end

  test "a suppressed recipient is refused for the operator" do
    ctx = prototype_drafted!()
    {draft, input} = reviewed(ctx, ctx.draft)

    {:ok, _} =
      Outreach.suppress(%{scope: :email, value: to_string(ctx.contact.email)}, actor: ctx.admin)

    assert {:error, %Ash.Error.Invalid{}} = Outreach.approve(draft, input, actor: ctx.operator)
    assert approvals!(ctx, draft) == []
  end

  # The operator's approval needs the live operator (resolver re-run) AND the
  # active anchor (Codex S4 RED-2, staged GREEN 1); everything else is refused
  # with nothing written.

  test "a forged operator struct cannot approve: Forbidden, nothing written" do
    ctx = prototype_drafted!()
    {draft, input} = reviewed(ctx, ctx.draft)

    # Both forgeries keep the binding tenant: the guarded denial is audited in
    # the actor's tenant chain, which a random tenant does not have here (a
    # random-tenant delegation is the resolver's own case, S1, and the
    # ActorUser forged test).
    forged = [
      %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id},
      %Actor{type: :prototype_operator, id: nil, tenant_id: ctx.tenant.id}
    ]

    for actor <- forged do
      result = Outreach.approve(draft, input, actor: actor)

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "a forged operator approved: #{inspect(result)}"
    end

    assert approvals!(ctx, draft) == []
    assert draft!(ctx, draft).status == :pending_review
    assert events_of(ctx.tenant, "outreach.approval.granted") == []
  end

  test "outside prototype runtime the operator's delegation cannot approve" do
    ctx = prototype_drafted!()
    {draft, input} = reviewed(ctx, ctx.draft)
    PrototypeFixtures.leave_runtime()

    result = Outreach.approve(draft, input, actor: ctx.operator)

    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "the operator approved in ordinary runtime: #{inspect(result)}"

    assert approvals!(ctx, draft) == []
    assert draft!(ctx, draft).status == :pending_review
    assert events_of(ctx.tenant, "outreach.approval.granted") == []
  end

  test "a disabled anchor: the live operator's approval is refused as inactive, nothing written" do
    ctx = prototype_drafted!()
    {draft, input} = reviewed(ctx, ctx.draft)
    PrototypeFixtures.leave_runtime()

    disabled = SdrAgent.Accounts.change_status(ctx.anchor, :disabled, actor: ctx.admin)

    assert match?({:ok, %{status: :disabled}}, disabled),
           "anchor not disabled: #{inspect(disabled)}"

    enter_window!(ctx.fixture)

    result = Outreach.approve(draft, input, actor: ctx.operator)

    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "not refused as invalid (an inactive approver): #{inspect(result)}"

    assert inspect(result) =~ "must be an active operator"
    assert approvals!(ctx, draft) == []
    assert draft!(ctx, draft).status == :pending_review
    assert events_of(ctx.tenant, "outreach.approval.granted") == []
  end

  # A documented limit of the singleton schema (tenants are check-constrained
  # to one row, so no initialized foreign tenant exists; Codex 21453441): the
  # reachable row control is a draft id absent from the operator's tenant,
  # refused as Invalid (nonexistent), paired with the current positive. It is
  # not measured foreign-row behaviour and not a Forbidden. Negative synthetic
  # tampering, not a domain-write success path.
  test "an absent draft id is refused as Invalid (nonexistent) with nothing written; the real draft then approves" do
    ctx = prototype_drafted!()
    {_draft, input} = reviewed(ctx, ctx.draft)
    absent = %{id: Ecto.UUID.generate()}

    result = Outreach.approve(absent, input, actor: ctx.operator)

    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "an approval for an absent draft: #{inspect(result, limit: 5)}"

    assert inspect(result) =~ "does not exist"
    assert approvals!(ctx, ctx.draft) == []
    assert draft!(ctx, ctx.draft).status == :pending_review
    assert events_of(ctx.tenant, "outreach.approval.granted") == []

    # The current positive: the same operator and input approve the real draft.
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    assert {approval.status, approval.draft_id} == {:granted, ctx.draft.id}
    assert [_] = events_of(ctx.tenant, "outreach.approval.granted")
  end

  # ------------------------------------------------------------------ capture

  test "a NEW captured receipt carries the block; a duplicate capture gives one receipt" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    deliver!()

    assert [receipt] = captured(ctx, delivery)
    [event] = captured_events(ctx)
    assert event.payload["arguments"]["prototype"] == block!()

    dlv = Actor.system(:delivery_worker, ctx.tenant.id)
    delivery = outreach!(ctx, delivery)

    assert {:ok, again} =
             Outreach.record_receipt(
               %{
                 delivery_operation_id: delivery.id,
                 idempotency_key: delivery.idempotency_key,
                 kind: :captured,
                 provider: :capture,
                 provider_message_id: receipt.provider_message_id,
                 rendered_sha256: delivery.rendered_sha256
               },
               actor: dlv
             )

    assert again.id == receipt.id
    assert [_] = captured(ctx, delivery)
    assert [_] = captured_events(ctx)
  end

  test "the captured message bytes are unchanged and never hold the label" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    deliver!()
    [receipt] = captured(ctx, delivery)
    {:ok, bytes} = Audit.read_content(receipt.rendered_sha256, actor: ctx.admin)
    assert :crypto.hash(:sha256, bytes) == receipt.rendered_sha256
    refute bytes =~ @label
    refute bytes =~ "d237-prototype/1"
  end

  defp human_approved!(fixture) do
    ctx = demo!(fixture)
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    enter_window!(fixture)
    {ctx, delivery}
  end

  test "T9: a capture for an approval not by the anchor is a typed permanent refusal at the worker" do
    {ctx, delivery} = human_approved!(bound!(enter_runtime: false))
    refused_attempt!(ctx, delivery, :prototype_approval_not_delegated)
  end

  test "T3: a direct capture for an approval not by the anchor returns the typed refusal" do
    {ctx, delivery} = human_approved!(bound!(enter_runtime: false))
    operation = hold_before_capture!(ctx, delivery)
    assert direct_refusal(ctx, operation) == {:refused, :prototype_approval_not_delegated}
    no_capture!(ctx, delivery)
  end

  test "T9: a live binding mismatch at capture is a typed permanent refusal at the worker" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    refused_attempt!(ctx, delivery, :prototype_binding_mismatch, fn _op ->
      :ok = PrototypeFixtures.put_live_identity(%{system_identifier: 1})
    end)
  end

  test "T3: the capture validation returns the typed prototype_binding_mismatch refusal" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    assert :ok = PrototypeFixtures.put_live_identity(%{database: "other"})
    dlv = Actor.system(:delivery_worker, ctx.tenant.id)
    {:ok, payload} = Audit.put_payload("synthetic message", "message/rfc822", actor: dlv)

    # A typed business refusal is returned, never raised (proposal r3
    # section 2.4); the worker path is T9 above.
    refused =
      outcome(fn ->
        Outreach.record_receipt(
          %{
            delivery_operation_id: delivery.id,
            idempotency_key: delivery.idempotency_key,
            kind: :captured,
            provider: :capture,
            provider_message_id: "capture-mismatch",
            rendered_sha256: payload.sha256
          },
          actor: dlv
        )
      end)

    assert refused == {:refused, :prototype_binding_mismatch}
    no_capture!(ctx, delivery)
  end

  test "ordinary runtime: a human approval is captured as before, one receipt, no prototype block (control)" do
    ctx = demo!(nil)
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    deliver!()

    assert [_] = captured(ctx, delivery)
    assert [event] = captured_events(ctx)
    refute Map.has_key?(event.payload["arguments"] || %{}, "prototype")
  end

  # Codex f9a45a0c R2: the boundary reads the receipt's operation and approval
  # through the policy-authorized DLV path, by id AND the binding tenant. A
  # missing or foreign row (negative synthetic tampering: deleted or moved to
  # a random tenant by SQL with triggers off) refuses as not delegated with
  # nothing kept; the valid delegation (the captured controls above) passes.

  defp foreign_tenant!(table, id) do
    tamper!("UPDATE #{table} SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(id)
    ])
  end

  # T3: the closed business refusal is the singleton typed CaptureRefused,
  # matched by struct name (proposal r3 section 2.3).
  defp not_delegated!(ctx, delivery, record) do
    assert outcome(record) == {:refused, :prototype_approval_not_delegated}
    no_capture!(ctx, delivery)
  end

  test "the boundary refuses a capture whose approval row is missing (not delegated, nothing kept)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    operation = hold_before_capture!(ctx, delivery)
    tamper!("DELETE FROM approvals WHERE id = $1", [Ecto.UUID.dump!(approval.id)])

    not_delegated!(ctx, delivery, fn -> record_operation(ctx, operation) end)
  end

  test "the boundary refuses a capture whose approval row is in a foreign tenant (not delegated, nothing kept)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    operation = hold_before_capture!(ctx, delivery)
    foreign_tenant!("approvals", approval.id)

    not_delegated!(ctx, delivery, fn -> record_operation(ctx, operation) end)
  end

  test "the boundary refuses a capture whose operation row is in a foreign tenant (not delegated, nothing kept)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    operation = hold_before_capture!(ctx, delivery)
    foreign_tenant!("delivery_operations", operation.id)

    refusal = outcome(fn -> record_operation(ctx, operation) end)

    tamper!("UPDATE delivery_operations SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(ctx.tenant.id),
      Ecto.UUID.dump!(operation.id)
    ])

    assert refusal == {:refused, :prototype_approval_not_delegated}
    no_capture!(ctx, delivery)
  end

  # ------------------------------------------------------------------ replay
  #
  # Codex 845d0959 / e9688dca: a genuine existing captured receipt replays
  # (the stored row, identified by the upsert from the authoritative tenant
  # row, never by a caller flag) without the current window, suppression or
  # binding checks and without another event; normal caller authorization
  # still applies (the delivery worker records it).

  defp captured_once!(ctx) do
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    deliver!()
    assert [receipt] = captured(ctx, delivery)
    assert [event] = captured_events(ctx)
    assert event.payload["arguments"]["prototype"] == block!()
    {delivery, receipt, event}
  end

  defp replays_unchanged!(ctx, delivery, receipt, event) do
    replay = record_captured(ctx, delivery)
    assert match?({:ok, %{id: _}}, replay), "the replay was refused: #{inspect(replay, limit: 3)}"
    {:ok, again} = replay
    assert again.id == receipt.id
    assert again.rendered_sha256 == receipt.rendered_sha256
    assert [stored] = captured(ctx, delivery)
    assert stored.id == receipt.id
    assert captured_events(ctx) == [event], "a replay appended another receipt event"
  end

  test "replay after the window end: the original captured receipt, no new event" do
    ctx = prototype_drafted!()
    {delivery, receipt, event} = captured_once!(ctx)

    Clock.freeze(window_end())
    replays_unchanged!(ctx, delivery, receipt, event)
  end

  test "replay after the recipient is suppressed: the original captured receipt, no new event" do
    ctx = prototype_drafted!()
    {delivery, receipt, event} = captured_once!(ctx)

    {:ok, _} =
      Outreach.suppress(%{scope: :email, value: to_string(ctx.contact.email)}, actor: ctx.admin)

    replays_unchanged!(ctx, delivery, receipt, event)
  end

  test "replay after a binding drift: the original captured receipt, no new event" do
    ctx = prototype_drafted!()
    {delivery, receipt, event} = captured_once!(ctx)

    assert :ok = PrototypeFixtures.put_live_identity(%{system_identifier: 1})
    replays_unchanged!(ctx, delivery, receipt, event)
  end

  # ------------------------------------------------------------------ signed export

  test "the signed export payload carries the block as the key prototype" do
    ctx = prototype_drafted!(auditor: true)
    assert {:ok, _approval} = operator_approve(ctx, ctx.draft)
    deliver!()

    kernel = Actor.system(:kernel, ctx.tenant.id)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, _key} =
      Audit.register_signing_key(%{key_id: "d237-export", public_key: public_key}, actor: kernel)

    # The export file lives in a root this test created exclusively.
    path = Path.join(exclusive_root!("d237-export"), "export.json")

    assert {:ok, _result} =
             Export.build(%{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.fixture.auditor,
               anchor_actor: Actor.system(:anchorer, ctx.tenant.id),
               private_key: private_key,
               sinks: [],
               output: path,
               output_root: Path.dirname(path)
             )

    wrapper = path |> File.read!() |> Jason.decode!()
    payload = wrapper["payload"] |> Base.decode64!() |> Jason.decode!()
    assert payload["prototype"] == block!()
  end

  # ------------------------------------------------------------------ the window

  # The window is the compiled funding entry's [starts_at, expires_at),
  # applied at the operator's raw Approval :approve (Codex S4 B1 bounded PASS
  # must-fix); the human path and the human-only :revoke are unchanged.

  defp funding! do
    result = Prototype.funding_entry()

    assert match?({:ok, %{starts_at: %DateTime{}, expires_at: %DateTime{}}}, result),
           "no funding entry: #{inspect(result)}"

    {:ok, entry} = result
    entry
  end

  defp refused_outside_window!(ctx, at) do
    Clock.freeze(at)
    result = operator_approve(ctx, ctx.draft)

    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "the operator approved at #{DateTime.to_iso8601(at)}: #{inspect(result, limit: 5)}"

    assert inspect(result) =~ "prototype_outside_window"
    assert approvals!(ctx, ctx.draft) == []
    assert draft!(ctx, ctx.draft).status == :pending_review
    assert events_of(ctx.tenant, "outreach.approval.granted") == []
  end

  test "the operator's raw :approve is refused before the window start and from its exclusive end, nothing written" do
    ctx = prototype_drafted!()
    funding = funding!()
    assert {funding.starts_at, funding.expires_at} == {window_start(), window_end()}

    refused_outside_window!(ctx, DateTime.add(funding.starts_at, -1, :microsecond))
    refused_outside_window!(ctx, funding.expires_at)
    refused_outside_window!(ctx, DateTime.add(funding.expires_at, 3600, :second))
  end

  test "the operator approves at the inclusive window start and one microsecond before its end (control)" do
    ctx = prototype_drafted!()

    Clock.freeze(window_start())
    assert {:ok, first} = operator_approve(ctx, ctx.draft)
    assert {:ok, _} = Outreach.revoke(first, actor: ctx.admin)

    Clock.freeze(DateTime.add(window_end(), -1, :microsecond))
    assert {:ok, last} = operator_approve(ctx, ctx.draft)
    assert last.status == :granted
  end

  test "after the window the human path is unchanged: :revoke stays human-only, a human revokes and approves (control)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    Clock.freeze(DateTime.add(window_end(), 3600, :second))

    operator_revoke = Outreach.revoke(approval, actor: ctx.operator)

    assert match?({:error, %Ash.Error.Forbidden{}}, operator_revoke),
           "the operator revoked: #{inspect(operator_revoke, limit: 5)}"

    assert {:ok, revoked} = Outreach.revoke(approval, actor: ctx.admin)
    assert revoked.status == :revoked

    {draft, input} = reviewed(ctx, ctx.draft)
    assert {:ok, %{status: :granted}} = Outreach.approve(draft, input, actor: ctx.admin)
  end

  test "T9: capture at the exclusive window end is a typed permanent refusal at the worker" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    refused_attempt!(ctx, delivery, :prototype_outside_window, fn _op ->
      Clock.freeze(window_end())
    end)
  end

  test "T3: a direct capture at the exclusive window end returns the typed refusal" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    operation = hold_before_capture!(ctx, delivery)
    Clock.freeze(window_end())

    assert direct_refusal(ctx, operation) == {:refused, :prototype_outside_window}
    no_capture!(ctx, delivery)
  end

  test "capture: one microsecond before the window end the receipt is captured with the block" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    capture_hook!(:before_capture, fn _op ->
      Clock.freeze(DateTime.add(window_end(), -1, :microsecond))
    end)

    deliver!()
    assert [_] = captured(ctx, delivery)
    [event] = captured_events(ctx)
    assert event.payload["arguments"]["prototype"] == block!()
  end
end
