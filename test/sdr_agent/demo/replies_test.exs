defmodule SdrAgent.Demo.RepliesTest do
  @moduledoc """
  The demo reply helper (S9b, `mix sdr.demo.reply`): builds correctly signed
  simulated provider requests for a delivered message — an interested
  reply, an unsubscribe reply, the unsubscribe link, delivered, bounce — and
  posts them to the webhook endpoint (here in-process through the Endpoint
  plug; never a real mail system). Dev and test only.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Demo.Replies

  defp delivered!(ctx) do
    approved = approved!(ctx)
    assert %{success: 1} = deliver!()
    Map.put(approved, :delivery, outreach!(ctx, approved.delivery))
  end

  test "an interested demo reply is accepted, matched and classified", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)

    assert {:ok, 202} = Replies.post(:interested, op, plug: SdrAgentWeb.Endpoint)
    assert %{success: 1} = process!()
    assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)

    assert [%{match_status: :matched, lead_id: lead_id}] = replies!(ctx)
    assert lead_id == lead.id

    assert {:ok, [%{assessment: %{classification: :interested}}]} =
             SdrAgent.Outreach.list_handoff_queue(actor: ctx.admin)
  end

  test "an unsubscribe demo reply suppresses the recipient", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    assert {:ok, 202} = Replies.post(:unsubscribe, op, plug: SdrAgentWeb.Endpoint)
    assert %{success: 1} = process!()

    assert [_] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))
    assert reload!(ctx, lead).status == :stopped
  end

  test "the unsubscribe link, delivered and bounce demo events are signed and accepted", ctx do
    %{delivery: op} = delivered!(ctx)
    assert {:ok, 202} = Replies.post(:delivered, op, plug: SdrAgentWeb.Endpoint)
    assert {:ok, 202} = Replies.post(:unsubscribe_link, op, plug: SdrAgentWeb.Endpoint)
    assert %{success: 2} = process!()
    assert outreach!(ctx, op).state == :delivered
    assert [_] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_link))
  end

  test "the same demo event posted twice is a duplicate", ctx do
    %{delivery: op} = delivered!(ctx)
    request = Replies.build(:interested, op)
    assert {:ok, 202} = Replies.send_request(request, plug: SdrAgentWeb.Endpoint)
    assert {:ok, 200} = Replies.send_request(request, plug: SdrAgentWeb.Endpoint)
  end

  test "a redirect from the endpoint is not followed (the signed request stays local)", ctx do
    %{delivery: op} = delivered!(ctx)
    parent = self()

    redirecting = fn conn ->
      send(parent, :called)

      conn
      |> Plug.Conn.put_resp_header("location", "http://remote.example.test/steal")
      |> Plug.Conn.send_resp(302, "")
    end

    assert {:ok, 302} = Replies.post(:interested, op, plug: redirecting)
    assert_received :called
    refute_received :called
  end

  test "the helper refuses to send outside dev/test (seeding disabled)", ctx do
    %{delivery: op} = delivered!(ctx)
    put_env!(:seeding_allowed?, false)
    assert {:error, :demo_disabled} = Replies.post(:interested, op, plug: SdrAgentWeb.Endpoint)
    assert webhook_events!(ctx) == []
  end

  test "the mix task runs only in dev and test" do
    assert Mix.Tasks.Sdr.Demo.Reply.allowed_env?(:dev)
    assert Mix.Tasks.Sdr.Demo.Reply.allowed_env?(:test)
    refute Mix.Tasks.Sdr.Demo.Reply.allowed_env?(:prod)
  end
end
