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
    outcome (unchanged; the control).

  Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Outreach

  defp crashed?(fun) do
    fun.()
    false
  rescue
    _ -> true
  end

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

    _ = crashed?(fn -> deliver!() end)
    assert captured(ctx, delivery) == []
    refute outreach!(ctx, delivery).state in [:accepted, :delivered]
    refute Enum.any?(receipts!(ctx, delivery), &(&1.kind == :accepted))
  end

  test "suppressed (domain) immediately before capture: refused at the capture boundary" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    capture_hook!(:before_capture, fn _op ->
      suppress!(ctx, :domain, String.upcase(domain(ctx.contact.email)))
    end)

    _ = crashed?(fn -> deliver!() end)
    assert captured(ctx, delivery) == []
    refute outreach!(ctx, delivery).state in [:accepted, :delivered]
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
end
