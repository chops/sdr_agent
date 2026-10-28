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
    (`prototype_binding_mismatch`) record no captured receipt, failing
    closed on the existing failure path.
  - Non-HTML carriers: receipt event, approval event and the signed export
    payload carry the block; the captured message bytes never do.
  - The window `[2026-10-28T02:38:32Z, 2026-11-07T07:00:00Z)`: the
    inclusive start and the EXCLUSIVE end for delegated approval and
    capture; revocation still works after the end.

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

  test "a capture for an approval not by the anchor records no captured receipt (fails closed)" do
    fixture = bound!(enter_runtime: false)
    ctx = demo!(fixture)
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    enter_window!(fixture)

    assert raised(fn -> deliver!() end) =~ "prototype_approval_not_delegated"
    assert captured(ctx, delivery) == []
    assert captured_events(ctx) == []
  end

  test "a live binding mismatch at capture records no captured receipt (prototype_binding_mismatch)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    capture_hook!(:before_capture, fn _op ->
      :ok = PrototypeFixtures.put_live_identity(%{system_identifier: 1})
    end)

    assert raised(fn -> deliver!() end) =~ "prototype_binding_mismatch"
    assert captured(ctx, delivery) == []
    assert captured_events(ctx) == []
  end

  test "the capture validation names prototype_binding_mismatch" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    assert :ok = PrototypeFixtures.put_live_identity(%{database: "other"})
    dlv = Actor.system(:delivery_worker, ctx.tenant.id)
    {:ok, payload} = Audit.put_payload("synthetic message", "message/rfc822", actor: dlv)

    result =
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

    assert match?({:error, _}, result)
    assert inspect(result) =~ "prototype_binding_mismatch"
    assert captured(ctx, delivery) == []
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

  test "delegated approval: the window start is inclusive and its end exclusive; revoke works after it" do
    ctx = prototype_drafted!()
    us = fn at, n -> DateTime.add(at, n, :microsecond) end

    Clock.freeze(us.(window_start(), -1))
    assert {:error, error} = operator_approve(ctx, ctx.draft)
    assert inspect(error) =~ "prototype_outside_window"

    Clock.freeze(window_start())
    assert {:ok, first} = operator_approve(ctx, ctx.draft)
    assert {:ok, _} = Outreach.revoke(first, actor: ctx.operator)

    Clock.freeze(window_end())
    assert {:error, error} = operator_approve(ctx, ctx.draft)
    assert inspect(error) =~ "prototype_outside_window"

    Clock.freeze(us.(window_end(), -1))
    assert {:ok, last} = operator_approve(ctx, ctx.draft)

    Clock.freeze(DateTime.add(window_end(), 3600, :second))
    assert {:ok, revoked} = Outreach.revoke(last, actor: ctx.operator)
    assert revoked.status == :revoked
  end

  test "capture: at the exclusive window end no captured receipt is recorded" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    capture_hook!(:before_capture, fn _op -> Clock.freeze(window_end()) end)

    assert raised(fn -> deliver!() end) =~ "prototype_outside_window"
    assert captured(ctx, delivery) == []
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
