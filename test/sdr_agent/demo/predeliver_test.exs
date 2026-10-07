defmodule SdrAgent.Demo.PredeliverTest do
  @moduledoc """
  `bin/demo predeliver`: fixture lead 01 run to a draft awaiting review. It
  never approves (ADR-0001 Tier 0) — the owner approves in the console —
  and a re-run only reports, including the delivery after that human
  approval.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Predeliver

  defp approval_events(ctx) do
    ctx.tenant
    |> events()
    |> Enum.filter(&String.starts_with?(&1.event_type, "outreach.approval."))
  end

  test "lead 01 is researched and drafted, and waits for a human", ctx do
    assert {:ok, %{stage: :awaiting_review, draft_id: draft_id, delivery: nil}} =
             Predeliver.run()

    assert draft!(ctx, %{id: draft_id}).status == :pending_review
    assert fixture_lead!(ctx, "01").status == :in_outreach
  end

  test "never creates an Approval, whatever options it is given", ctx do
    assert {:ok, %{stage: :awaiting_review, draft_id: draft_id, delivery: nil}} =
             Predeliver.run(approve: true)

    assert approvals!(ctx, %{id: draft_id}) == []
    assert approval_events(ctx) == []
  end

  test "after a human approval a re-run reports the capture and writes nothing but its sign-in",
       ctx do
    {:ok, %{draft_id: draft_id}} = Predeliver.run()

    # The owner approves in the console (a human reviewer, through the domain).
    approve!(ctx, %{id: draft_id}, user!(ctx, :reviewer))
    deliver!()
    before = length(events(ctx.tenant))

    assert {:ok, %{stage: :captured, draft_id: ^draft_id, delivery: %{state: :accepted}}} =
             Predeliver.run()

    assert [_one_human_approval] = approvals!(ctx, %{id: draft_id})

    assert ctx.tenant |> events() |> Enum.drop(before) |> Enum.map(& &1.event_type) ==
             ["auth.sign_in.succeeded"]
  end
end

defmodule SdrAgent.Demo.PredeliverUnseededTest do
  @moduledoc "`bin/demo predeliver` on a database without the demo data set."
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Demo.Predeliver

  test "refuses with :not_seeded" do
    assert Predeliver.run() == {:error, :not_seeded}
  end

  test "fails closed where demo seeding is not allowed, before any sign-in or write" do
    tenant = bootstrap!()
    before = length(events(tenant))
    previous = Application.get_env(:sdr_agent, :seeding_allowed?)
    Application.put_env(:sdr_agent, :seeding_allowed?, false)
    on_exit(fn -> Application.put_env(:sdr_agent, :seeding_allowed?, previous) end)

    assert Predeliver.run() == {:error, :demo_not_allowed}
    assert length(events(tenant)) == before
  end
end
