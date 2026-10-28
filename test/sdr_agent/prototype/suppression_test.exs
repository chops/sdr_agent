defmodule SdrAgent.Prototype.SuppressionTest do
  @moduledoc """
  The execution-time suppression gate for D-237 delegated approvals
  (amendment item 7 "Suppression", item 8 "Checks that remain"; plan r7
  section 6 row "Suppression", S4's part; S3 covers import-side
  normalisation).

  - A recipient suppressed after a delegated approval and before the claim
    is handled by the existing suppression side effects: the pending
    delivery is cancelled and the approval invalidated (`suppressed`); no
    captured receipt.
  - A recipient suppressed after the claim, immediately before the capture
    (email or domain scope, normalised value), is refused at the capture
    boundary in prototype runtime: no captured receipt, the operation is
    not accepted, and the refusal fails closed on the existing failure
    path. In ordinary runtime an already-claimed delivery is left to its
    outcome (unchanged; the control). An unavailable suppression source at
    capture refuses closed (`prototype_suppression_unchecked`).
  - R10 (supplement 1 r2 section 7): a suppressed contact cannot be
    assigned by the operator (the Store check), and the NoStore check
    refuses prototype boot. Home stays fail-closed for
    `released_unverified` output; that case needs a real prototype release
    and is asserted in the G4 journey.

  Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Outreach

  defp captured(ctx, delivery), do: Enum.filter(receipts!(ctx, delivery), &(&1.kind == :captured))

  defp suppress!(ctx, scope, value) do
    assert {:ok, _} = Outreach.suppress(%{scope: scope, value: value}, actor: ctx.admin)
  end

  defp domain(email), do: email |> to_string() |> String.split("@") |> List.last()

  test "suppressed after a delegated approval, before the claim: delivery cancelled, approval invalidated" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    suppress!(ctx, :email, to_string(ctx.contact.email))
    deliver!()

    assert outreach!(ctx, approval).status == :invalidated
    assert outreach!(ctx, approval).invalidated_reason == :suppressed
    assert outreach!(ctx, delivery).state == :cancelled
    assert captured(ctx, delivery) == []
  end

  test "suppressed (email, normalised) immediately before capture: refused at the capture boundary" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    variant = "  " <> String.upcase(to_string(ctx.contact.email)) <> " "
    capture_hook!(:before_capture, fn _op -> suppress!(ctx, :email, variant) end)

    assert raised(fn -> deliver!() end) =~ "prototype_recipient_suppressed"
    no_capture!(ctx, delivery)
  end

  test "suppressed (domain) immediately before capture: refused at the capture boundary" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    capture_hook!(:before_capture, fn _op ->
      suppress!(ctx, :domain, String.upcase(domain(ctx.contact.email)))
    end)

    assert raised(fn -> deliver!() end) =~ "prototype_recipient_suppressed"
    no_capture!(ctx, delivery)
  end

  # Codex 845d0959: a failed or unavailable suppression lookup at capture is a
  # closed refusal, never "not suppressed". Negative synthetic tampering: the
  # suppression source is made unavailable immediately before the capture by
  # renaming its table inside the test's own sandbox transaction (rolled
  # back with it); no NoStore fallback is involved.
  test "an unavailable suppression source at capture refuses closed (prototype_suppression_unchecked), nothing written" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    capture_hook!(:before_capture, fn _op ->
      tamper!("ALTER TABLE suppressions RENAME TO suppressions_unavailable")
    end)

    assert raised(fn -> deliver!() end) =~ "prototype_suppression_unchecked"
    no_capture!(ctx, delivery)
  end

  test "ordinary runtime: an already-claimed delivery is left to its outcome (control, unchanged)" do
    ctx = demo!(nil)
    %{draft: draft, lead: lead} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    email = to_string(contact!(ctx, lead).email)
    capture_hook!(:before_capture, fn _op -> suppress!(ctx, :email, email) end)

    deliver!()
    assert [_] = captured(ctx, delivery)
  end

  # ------------------------------------------------------------------ R10: enrollment and boot

  test "R10 enrollment: a suppressed (normalised) contact cannot be assigned by the operator" do
    fixture = bound!(enter_runtime: false)
    ctx = demo!(fixture)
    SdrAgent.SDRCase.ensure_offering!(ctx)
    lead = SdrAgent.SDRCase.fixture_lead!(ctx, "06")
    email = to_string(contact!(ctx, lead).email)
    suppress!(ctx, :email, " " <> String.upcase(email))
    enter_window!(fixture)

    assert {:ok, :suppressed, %{"suppression_ids" => [_ | _]}} =
             SdrAgent.SDR.SuppressionCheck.Store.check(email, %{tenant_id: ctx.tenant.id})

    result =
      SdrAgent.SDR.assign_lead(reload!(ctx, lead),
        campaign_id: ctx.campaign_id,
        actor: fixture.actor
      )

    refute match?({:ok, _}, result), "the operator assigned a suppressed contact's lead"
    assert reload!(ctx, lead).status == :stopped
  end

  test "R10 boot: the NoStore suppression check refuses prototype boot" do
    fixture = bound!(enter_runtime: false)
    put_env!(:suppression_check, SdrAgent.SDR.SuppressionCheck.NoStore)
    switch = PrototypeFixtures.switch(fixture)

    assert call(SdrAgent.Prototype.BootCheck, :check, [switch]) ==
             {:error, :suppression_not_store}
  end
end
