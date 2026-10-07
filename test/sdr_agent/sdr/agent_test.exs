defmodule SdrAgent.SDR.AgentTest do
  @moduledoc """
  The SDRAgent definition (spec §4) and its Signals (spec §5): the state
  holds only the assignment's working state — never CRM records — the
  routes cover the S7 signals, there is no send action, and every signal
  type builds a valid Jido signal.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.SDR.Signals
  alias SdrAgent.SDR.SDRAgent

  @working_state ~w(tenant_id campaign_id lead_id phase objective evidence_ids
                    qualification proposal_id budget run_id)a

  test "the state schema is exactly the spec §4 working state" do
    %Zoi.Types.Map{fields: fields} = SDRAgent.domain_schema()
    assert Enum.sort(Keyword.keys(fields)) == Enum.sort(@working_state)
  end

  test "an instance rejects CRM fields in its state" do
    assert {:ok, agent} = SDRAgent.new(id: "run-1", state: %{lead_id: "lead-1"})
    assert agent.state.phase == :discover
    assert agent.state.evidence_ids == []

    assert {:error, _} =
             SDRAgent.new(
               id: "run-2",
               state: %{lead_id: "lead-1", contact_email: "x@example.test"}
             )
  end

  test "routes cover the S7 signals and no route sends email" do
    routed = SDRAgent.routed_signal_types()

    for type <- ~w(sdr.lead.assigned sdr.research.requested sdr.research.completed
                   sdr.qualification.requested sdr.qualification.completed sdr.draft.requested
                   sdr.lead.suppressed sdr.campaign.paused) do
      assert type in routed, type
    end

    targets = Enum.map_join(SDRAgent.route_targets(), " ", &inspect/1)
    refute targets =~ ~r/Send|Deliver/i
    refute Code.ensure_loaded?(SdrAgent.SDR.Actions.SendEmail)
  end

  test "every spec §5 signal type builds a valid Jido signal" do
    for type <- ~w(sdr.lead.assigned sdr.research.requested sdr.research.completed
                   sdr.qualification.requested sdr.qualification.completed sdr.draft.requested
                   sdr.draft.completed sdr.approval.granted sdr.approval.rejected
                   sdr.delivery.completed sdr.delivery.failed sdr.reply.received
                   sdr.followup.due sdr.lead.suppressed sdr.campaign.paused) do
      assert type in Signals.types()

      assert {:ok, %Jido.Signal{type: ^type, source: "/sdr_agent/sdr"} = signal} =
               Signals.build(type, %{lead_id: Ecto.UUID.generate()})

      assert {:ok, _uuid} = Ecto.UUID.cast(signal.id)
    end

    assert {:error, :unknown_signal_type} = Signals.build("sdr.email.send", %{})
  end
end
