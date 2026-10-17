defmodule SdrAgent.Inbox.SyntheticScopeTest do
  @moduledoc "SQL count scope agrees with the authoritative Synthetic guard on edge cases."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [drafted!: 1]

  alias SdrAgent.Outreach
  alias SdrAgent.Sales.Synthetic

  test "list and count synthetic scope agree without reading draft bodies", ctx do
    %{draft: draft} = drafted!(ctx)

    for email <- [
          "a@example.com",
          "a@EXAMPLE.NET",
          "a@sub.example.org",
          "a@example.test",
          "a@sub.test",
          "a@a.example",
          "a@a.invalid",
          "a+b@example.test",
          "a@nonreserved.test.com",
          "a@example.com.evil",
          "a@.test",
          "a@-a.test",
          "a@a-.test",
          "a@a..test",
          "a@localhost",
          "a@a.test.",
          "a b@a.test",
          "a\tb@a.test",
          "a\nb@a.test",
          "a@a_test.test",
          "a@@a.test",
          "a@#{String.duplicate("a", 64)}.test",
          "a@#{String.duplicate("a.", 125)}test",
          "a@#{String.duplicate("a.", 123)}test",
          "a@a.İnvalid",
          "jō@a.test"
        ] do
      tamper!("UPDATE contacts SET email = $1 WHERE id = $2", [
        email,
        Ecto.UUID.dump!(draft.recipient_contact_id)
      ])

      if Synthetic.reserved_email?(email) do
        assert {:ok, [_]} = Outreach.list_inbox_drafts(ctx.admin, nil), email
        assert {:ok, 1} = Outreach.count_inbox_drafts(actor: ctx.admin), email
      else
        assert {:error, :withheld} = Outreach.list_inbox_drafts(ctx.admin, nil), email
        assert {:error, :withheld} = Outreach.count_inbox_drafts(actor: ctx.admin), email
      end
    end
  end
end
