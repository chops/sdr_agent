defmodule SdrAgent.Outreach.RecipientBindingTest do
  @moduledoc """
  PR #17 MF1 (action-contract delta; entity PASS, Codex
  m_1791395301801790000_7391018e): an approval binds
  the recipient email the reviewer saw. `Outreach.approve/3` takes it as
  `recipient_email`; under the grant's locks it must equal the contact's
  current email, otherwise the verdict is stale and nothing is written (no
  Approval, no DeliveryOperation, no delivery job) until an explicit
  re-review with the new email.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  @moved "avery.moved@brightpath-freight.test"

  setup ctx, do: Map.merge(ctx, drafted!(ctx))

  test "a changed recipient is refused; nothing is granted until re-reviewed", ctx do
    contact = contact!(ctx, ctx.lead)
    seen = to_string(contact.email)
    reviewer = operator!(ctx, :reviewer)
    {:ok, _moved} = Sales.update(contact, :change_email, %{email: @moved}, actor: ctx.admin)

    binding = Map.put(approval_input(ctx.revision), :recipient_email, seen)

    assert {:error, %Ash.Error.Invalid{} = error} =
             Outreach.approve(ctx.draft, binding, actor: reviewer)

    assert Exception.message(error) =~ "stale review"

    assert approvals!(ctx, ctx.draft) == []

    assert {:ok, []} =
             Outreach.list_records(Outreach.DeliveryOperation,
               filter: [draft_id: ctx.draft.id],
               actor: ctx.admin
             )

    refute_enqueued(worker: SdrAgent.Outreach.DeliveryWorker)
    assert events_of_type(ctx.tenant, "outreach.approval.granted") == []

    rereviewed = Map.put(approval_input(ctx.revision), :recipient_email, @moved)
    assert {:ok, approval} = Outreach.approve(ctx.draft, rereviewed, actor: reviewer)
    assert to_string(approval.recipient_email) == @moved
  end

  for {label, value} <- [{"missing", :delete}, {"nil", nil}, {"blank", ""}, {"whitespace", "   "}] do
    test "an approval with a #{label} reviewed recipient is refused (no implicit current email)",
         ctx do
      reviewer = operator!(ctx, :reviewer)

      binding =
        case unquote(value) do
          :delete -> Map.delete(approval_input(ctx.revision), :recipient_email)
          other -> Map.put(approval_input(ctx.revision), :recipient_email, other)
        end

      assert {:error, %Ash.Error.Invalid{}} =
               Outreach.approve(ctx.draft, binding, actor: reviewer)

      assert approvals!(ctx, ctx.draft) == []

      assert {:ok, []} =
               Outreach.list_records(Outreach.DeliveryOperation,
                 filter: [draft_id: ctx.draft.id],
                 actor: ctx.admin
               )
    end
  end

  test "a caller cannot overwrite the bound snapshot; it is derived from the locked contact",
       ctx do
    contact = contact!(ctx, ctx.lead)

    binding =
      Map.put(
        approval_input(ctx.revision),
        :recipient_email,
        String.upcase(to_string(contact.email))
      )

    assert {:ok, approval} =
             Outreach.approve(ctx.draft, binding, actor: operator!(ctx, :reviewer))

    assert approval.recipient_email == contact.email
    assert to_string(approval.recipient_email) == to_string(contact.email)
  end

  test "a rejection does not need the recipient", ctx do
    binding =
      approval_input(ctx.revision)
      |> Map.delete(:recipient_email)
      |> Map.put(:reason, "off-tone")

    assert {:ok, %{verdict: :rejected}} =
             Outreach.reject(ctx.draft, binding, actor: operator!(ctx, :reviewer))
  end

  test "the recipient comparison ignores case", ctx do
    contact = contact!(ctx, ctx.lead)

    binding =
      Map.put(
        approval_input(ctx.revision),
        :recipient_email,
        String.upcase(to_string(contact.email))
      )

    assert {:ok, _approval} =
             Outreach.approve(ctx.draft, binding, actor: operator!(ctx, :reviewer))
  end
end
