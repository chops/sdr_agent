defmodule SdrAgent.Prototype.CRMPrototypeTest do
  @moduledoc """
  ResearchLeadFlow step "crm" in D-237 prototype runtime (D-268 M8, Codex
  review 88558f94): an imported dossier contact has no CRM record, so the
  step records no CRM artifact and calls no CRM adapter; it never invents
  CRM evidence. Ordinary runtime keeps the adapter path.

  Synthetic `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures, only: [enter_window!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.SDR.Actions.GetCRMHistory

  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport

  defmodule RecordingCRM do
    @moduledoc false
    # Reports every call to the calling process and answers with a known
    # fixture CRM record, whatever the id.
    alias SdrAgent.Demo.Fixtures
    alias SdrAgent.Integrations.Fixtures, as: CRMFixtures

    def fetch_contact(crm_id) do
      send(self(), {:crm_called, crm_id})
      [contact | _] = Fixtures.contacts()
      {:ok, CRMFixtures.crm_record(contact.crm_external_id)}
    end
  end

  setup do
    integrations = Application.get_env(:sdr_agent, :integrations, [])

    SdrAgent.OutreachFixtures.put_env!(
      :integrations,
      Keyword.put(integrations, :crm, RecordingCRM)
    )

    :ok
  end

  setup do
    fixture = bound!()
    enter_window!(fixture)
    actor = fixture.actor
    assert match?({:ok, _}, call(@seed, :run, [F.seed_read(), actor]))

    [row] = F.route_rows!([F.company(1)], ["row-1"])
    {:ok, :imported, %{lead_id: lead_id}} = call(@import, :import_row, [row, actor])

    agent = SdrAgent.Actor.system(:agent_runtime, fixture.tenant.id)
    definition = AgentsFixtures.definition!(fixture.tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, lead_id)
    {:ok, run} = Agents.create_run(attrs, actor: agent)
    {:ok, run} = Agents.start_run(run, actor: agent)
    tool = SdrAgent.SalesFixtures.tool_invocation!(fixture.tenant, run)

    sdr_ctx = %SdrAgent.SDR.Context{
      actor: agent,
      tenant_id: fixture.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      tool_invocation: tool
    }

    %{lead_id: lead_id, sdr_ctx: sdr_ctx}
  end

  defp artifacts do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM research_artifacts", [])
    n
  end

  defp perform(ctx) do
    GetCRMHistory.perform(%{lead_id: ctx.lead_id}, ctx.sdr_ctx)
  rescue
    error -> {:raised, error}
  end

  test "an imported contact in prototype runtime has no CRM artifact and no adapter call", ctx do
    before = artifacts()
    assert perform(ctx) == {:ok, %{artifacts: []}, [], []}
    refute_received {:crm_called, _id}
    assert artifacts() == before
  end

  test "ordinary runtime keeps the CRM adapter path and records its record", ctx do
    SdrAgent.PrototypeFixtures.leave_runtime()
    before = artifacts()

    assert {:ok, %{artifacts: [artifact]}, [], [_ref]} = perform(ctx)
    assert_received {:crm_called, nil}
    assert artifact.source_type == :crm_record
    assert artifact.trust_level == :high
    assert artifacts() == before + 1
  end
end
