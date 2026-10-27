defmodule SdrAgent.Demo.HostedContainmentTest do
  @moduledoc """
  The hosted copy's follow-up containment (Codex M4; D-218 item 9 defers the
  D-206 suppression fix only under it):

    * config: production disables follow-ups (`config :sdr_agent,
      :follow_ups, :disabled`); dev and test enable them;
    * store check (`SdrAgent.Release.verify_hosted_containment/0`, run by
      `scripts/deploy.sh` from the staged release after the seed): passes
      after the hosted seed with follow-ups off, appends nothing, and fails on
      a planted active follow-up step, an open campaign on a sequence with
      one, a waiting follow-up job, or follow-ups switched on;
    * negative smoke on the hosted seed's own data: the suppressed seed
      contact's lead gets no draft, enrollment or delivery, and a delivered
      first touch completes its enrollment with no follow-up scheduled.

  Absent functions are reached through guarded references, so a missing one
  fails as an assertion.
  """
  use SdrAgent.AuditCase, async: false
  use Oban.Testing, repo: SdrAgent.Repo

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import SdrAgent.OutreachFixtures, only: [approve!: 3, deliver!: 0]

  alias SdrAgent.Accounts.User
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Release
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.FollowupWorker

  @owner "hosted.owner@example.test"
  @check {SdrAgent.Demo.HostedContainment, :check, 0}

  setup do
    previous_owner = System.get_env("SDR_OWNER_EMAIL")
    previous_seeding = Application.fetch_env(:sdr_agent, :seeding_allowed?)
    previous_follow_ups = Application.fetch_env(:sdr_agent, :follow_ups)

    on_exit(fn ->
      if previous_owner,
        do: System.put_env("SDR_OWNER_EMAIL", previous_owner),
        else: System.delete_env("SDR_OWNER_EMAIL")

      for {key, previous} <- [seeding_allowed?: previous_seeding, follow_ups: previous_follow_ups] do
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, key, value)
          :error -> Application.delete_env(:sdr_agent, key)
        end
      end

      Clock.unfreeze()
    end)

    # Production: no seeding flag, follow-ups off.
    Application.put_env(:sdr_agent, :seeding_allowed?, false)
    Application.put_env(:sdr_agent, :follow_ups, :disabled)
    System.put_env("SDR_OWNER_EMAIL", @owner)
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    :ok
  end

  defp tenant_id do
    {:ok, id} = Kernel.singleton_tenant_id()
    id
  end

  defp rows(resource) do
    resource
    |> Ash.read!(Kernel.opts(tenant_id()))
    |> Enum.sort_by(& &1.id)
  end

  defp seeded_owner! do
    {:ok, _summary} = Release.seed_hosted()
    [owner] = rows(User)
    owner
  end

  defp event_count, do: length(events(%{id: tenant_id()}))

  # The containment report, or {:absent, module} before it exists.
  defp check do
    {module, fun, arity} = @check

    if Code.ensure_loaded?(module) and function_exported?(module, fun, arity),
      do: Function.capture(module, fun, arity).(),
      else: {:absent, module}
  end

  # The deploy's store check: {{:ok, value} | {:raised, exception} | :absent, printed}.
  defp verify do
    Code.ensure_loaded!(Release)

    if function_exported?(Release, :verify_hosted_containment, 0) do
      printed =
        capture_io(fn ->
          outcome =
            try do
              {:ok, Function.capture(Release, :verify_hosted_containment, 0).()}
            rescue
              error -> {:raised, error}
            end

          send(self(), {:verify, outcome})
        end)

      assert_received {:verify, outcome}
      {outcome, printed}
    else
      {:absent, ""}
    end
  end

  defp raised_message({{:raised, error}, _printed}), do: Exception.message(error)
  defp raised_message(other), do: inspect(other, limit: 5)

  defp lead_of!(email, owner) do
    {:ok, [contact]} = Sales.list_records(Sales.Contact, filter: [email: email], actor: owner)
    {:ok, [lead]} = Sales.list_records(Sales.Lead, filter: [contact_id: contact.id], actor: owner)
    {contact, lead}
  end

  defp open_campaign!(owner) do
    {:ok, campaigns} = Sales.list_records(Sales.Campaign, actor: owner)
    [campaign] = Enum.filter(campaigns, &(&1.status == :active))
    campaign
  end

  # An active two-step sequence written by the owner (step 2: a follow-up).
  defp plant_follow_up_sequence!(owner) do
    opts = [actor: owner]
    {:ok, sequence} = Sales.create_sequence(%{name: "Planted two-step", version: 1}, opts)

    for step <- Fixtures.sequence_steps() do
      {:ok, _step} = Sales.add_sequence_step(sequence, Map.delete(step, :id), opts)
    end

    {:ok, sequence} = Sales.update(sequence, :activate, %{}, opts)
    sequence
  end

  test "production disables follow-ups; dev and test enable them" do
    follow_ups = fn env ->
      "config/config.exs"
      |> Config.Reader.read!(env: env, target: :host)
      |> get_in([:sdr_agent, :follow_ups])
    end

    assert {follow_ups.(:prod), follow_ups.(:dev), follow_ups.(:test)} ==
             {:disabled, :enabled, :enabled}
  end

  describe "the store check" do
    test "passes after the hosted seed with follow-ups off, and writes nothing" do
      _owner = seeded_owner!()
      count = event_count()

      assert check() ==
               {:ok,
                %{
                  follow_ups: :disabled,
                  active_followup_steps: 0,
                  open_followup_campaigns: 0,
                  followup_jobs: 0,
                  suppressed_seed: :ok
                }}

      result = verify()
      assert match?({{:ok, :ok}, _printed}, result), inspect(result, limit: 5)
      {_outcome, printed} = result
      assert printed =~ "hosted containment:"
      assert printed =~ "PASS"
      assert event_count() == count
    end

    test "fails on a planted active follow-up step and on an open campaign using one" do
      owner = seeded_owner!()
      sequence = plant_follow_up_sequence!(owner)

      assert match?({:error, %{active_followup_steps: 1, open_followup_campaigns: 0}}, check()),
             inspect(check())

      assert raised_message(verify()) =~ "active_followup_steps=1"

      [icp] = rows(Sales.IcpDefinition)

      {:ok, _campaign} =
        Fixtures.campaign()
        |> Map.delete(:id)
        |> Map.merge(%{
          name: "Planted campaign",
          icp_definition_id: icp.id,
          sequence_id: sequence.id
        })
        |> Sales.create_campaign(actor: owner)

      {:ok, _retired} = Sales.update(sequence, :retire, %{}, actor: owner)

      assert match?({:error, %{active_followup_steps: 0, open_followup_campaigns: 1}}, check()),
             inspect(check())

      assert raised_message(verify()) =~ "open_followup_campaigns=1"
    end

    test "fails on a waiting follow-up job" do
      _owner = seeded_owner!()

      {:ok, _job} =
        %{
          "enrollment_id" => Ecto.UUID.generate(),
          "tenant_id" => tenant_id(),
          "step_position" => 1
        }
        |> Oban.Job.new(
          worker: "SdrAgent.SDR.FollowupWorker",
          queue: :followup,
          scheduled_at: DateTime.add(Clock.utc_now(), 3, :day)
        )
        |> Oban.insert()

      assert match?({:error, %{followup_jobs: 1}}, check()), inspect(check())
      assert raised_message(verify()) =~ "followup_jobs=1"
    end

    test "fails when follow-ups are switched on" do
      _owner = seeded_owner!()
      Application.put_env(:sdr_agent, :follow_ups, :enabled)

      assert match?({:error, %{follow_ups: :enabled}}, check()), inspect(check())
      assert raised_message(verify()) =~ "follow_ups=enabled"
    end
  end

  test "negative smoke: the suppressed seed contact gets nothing; a first touch schedules no follow-up" do
    owner = seeded_owner!()
    campaign = open_campaign!(owner)
    [suppressed_email] = Fixtures.suppressed_contact_emails()
    {suppressed_contact, suppressed_lead} = lead_of!(suppressed_email, owner)
    assert suppressed_lead.status == :stopped

    refused = SDR.assign_lead(suppressed_lead, campaign_id: campaign.id, actor: owner)
    assert match?({:error, _}, refused), inspect(refused, limit: 5)

    # A deliverable lead of the same seed, through the real research, review
    # and delivery path (Fake model, capture adapter).
    {_contact, lead} = lead_of!(hd(Fixtures.contacts()).email, owner)
    {:ok, _assignment} = SDR.assign_lead(lead, campaign_id: campaign.id, actor: owner)
    assert %{success: 1} = Oban.drain_queue(queue: :research, with_safety: false)

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: owner)

    _approval = approve!(%{admin: owner}, draft, owner)
    _log = capture_log(fn -> send(self(), {:delivered, deliver!()}) end)
    assert_received {:delivered, %{success: 1}}

    {:ok, [enrollment]} =
      Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: owner)

    assert {enrollment.status, enrollment.next_step_due_at} == {:completed, nil}
    assert all_enqueued(worker: FollowupWorker) == []

    for {resource, filter} <- [
          {Outreach.Draft, [lead_id: suppressed_lead.id]},
          {Outreach.DeliveryOperation, [recipient_contact_id: suppressed_contact.id]}
        ] do
      assert Outreach.list_records(resource, filter: filter, actor: owner) == {:ok, []},
             inspect(resource)
    end

    assert Sales.list_records(Sales.CampaignEnrollment,
             filter: [lead_id: suppressed_lead.id],
             actor: owner
           ) == {:ok, []}

    result = verify()
    assert match?({{:ok, :ok}, _printed}, result), inspect(result, limit: 5)
  end
end
