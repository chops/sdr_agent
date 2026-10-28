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
    boundary in prototype runtime. It is a typed business refusal
    (`prototype_recipient_suppressed`): a permanent delivery outcome at the
    worker (T9), and the singleton `CaptureRefused` on a direct record (T3).
    No captured receipt is written, and the operation is not accepted. In
    ordinary runtime an already-claimed delivery is left to its outcome
    (unchanged; the control).
  - An unavailable suppression source at capture is a lossy failure, so it
    is never classified (Codex 6d1ead6d; S4 proposal r3 section 2.5, the
    contract correction accepted by Codex 4c72c150). It propagates
    unchanged: the worker boundary's exact sanitized line for this attempt
    (`propagated_attempt!/3`), and the original class on a direct record.
    Nothing is captured, and the source is never read as "not suppressed"
    (T6).
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

  test "T9: suppressed (email, normalised) immediately before capture: a typed permanent refusal at the worker" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    variant = "  " <> String.upcase(to_string(ctx.contact.email)) <> " "

    refused_attempt!(ctx, delivery, :prototype_recipient_suppressed, fn _op ->
      suppress!(ctx, :email, variant)
    end)
  end

  test "T9: suppressed (domain) immediately before capture: a typed permanent refusal at the worker" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    refused_attempt!(ctx, delivery, :prototype_recipient_suppressed, fn _op ->
      suppress!(ctx, :domain, String.upcase(domain(ctx.contact.email)))
    end)
  end

  test "T3: a direct capture of a recipient suppressed after the claim returns the typed refusal" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    operation = hold_before_capture!(ctx, delivery)
    suppress!(ctx, :email, to_string(ctx.contact.email))

    assert direct_refusal(ctx, operation) == {:refused, :prototype_recipient_suppressed}
    no_capture!(ctx, delivery)
  end

  # T6, a contract correction (S4 proposal r3 section 2.5; Codex 6d1ead6d and
  # 4c72c150 Q1). A failed suppression lookup at capture is lossy, so it is
  # never classified. It is never read as "not suppressed" either: it
  # propagates unchanged, with nothing captured. The proof of reach is kept.
  # Negative synthetic tampering: the source is made unavailable inside the
  # before_capture hook, after the send gate's claim, by renaming its table
  # inside the test's own sandbox transaction (rolled back with it).
  test "T6: an unavailable suppression source at capture propagates the failure unchanged, nothing written" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    propagated_attempt!(ctx, delivery, fn _op ->
      tamper!("ALTER TABLE suppressions RENAME TO suppressions_unavailable")
    end)

    # A direct record, with the source still unavailable, returns the
    # original propagated class (struct names only, never the value) and no
    # typed refusal.
    assert direct_refusal(ctx, outreach!(ctx, delivery)) == {:returned, :error, Ash.Error.Unknown}
    no_capture!(ctx, delivery)

    # The connection is still usable and the fixture is restored.
    tamper!("ALTER TABLE suppressions_unavailable RENAME TO suppressions")
    restored = Outreach.matching_suppressions(to_string(ctx.contact.email), actor: ctx.admin)

    assert match?({:ok, []}, restored),
           "the suppression source is not restored: #{inspect(restored)}"
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
