defmodule SdrAgent.SDR.FollowupWorker do
  @moduledoc """
  Oban worker (queue `followup`) — the follow-up schedule (checklist 1.7;
  spec §5 "Oban followup due → sdr.followup.due → Jido"). The delivery path
  inserts one job per accepted step at the enrollment's `next_step_due_at`
  (computed in the campaign time zone), with `enrollment_id`, `tenant_id`
  and the accepted `step_position`.

  At due time, as the scheduler (SCH), it records one deterministic
  `followup_next_step` Decision about the enrollment: `draft_followup` when
  the enrollment is still active at that step, its campaign is active and
  its contact is not suppressed — then it appends the `sdr.followup.due`
  signal (lead, campaign, enrollment, next step) to the ledger — otherwise
  `stop`. Run before the due time it snoozes; run again for the same step it
  does nothing (the decision's key is per enrollment and step, checked under
  a lock on the enrollment row in the same transaction). Drafting the
  follow-up is the agent's (a route on `sdr.followup.due`, added with S9);
  every follow-up still needs human approval (Tier 0).
  """
  use Oban.Worker, queue: :followup, max_attempts: 3

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.SDR.Signals

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"enrollment_id" => id, "tenant_id" => tenant_id, "step_position" => position}
      }) do
    sch = Actor.system(:scheduler, tenant_id)
    key = "followup:#{id}:#{position}"

    # One execution at a time per enrollment (review #14 MF3): the row is
    # locked first, and due time, state and an earlier decision are checked
    # on the locked row, inside the transaction that records the decision and
    # its signal — a concurrent or repeated execution publishes nothing.
    {:ok, result} =
      Audit.transaction(fn ->
        enrollment = lock_enrollment(id, sch)

        cond do
          due_later?(enrollment) -> {:snooze, seconds_until(enrollment.next_step_due_at)}
          decided?(key, sch) -> :ok
          true -> decide(enrollment, position, key, sch)
        end
      end)

    result
  end

  defp lock_enrollment(id, sch) do
    {:ok, enrollment} =
      Sales.CampaignEnrollment
      |> Ash.Query.for_read(:read, %{}, actor: sch)
      |> Ash.Query.filter(id == ^id and tenant_id == ^sch.tenant_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one()

    enrollment
  end

  defp seconds_until(due), do: max(DateTime.diff(due, Clock.utc_now()), 1)

  defp due_later?(%{next_step_due_at: %DateTime{} = due}),
    do: DateTime.compare(due, Clock.utc_now()) == :gt

  defp due_later?(_enrollment), do: false

  defp decided?(key, sch) do
    Agents.Decision
    |> Ash.Query.for_read(:read, %{}, actor: sch)
    |> Ash.Query.filter(idempotency_key == ^key and tenant_id == ^sch.tenant_id)
    |> Ash.exists?()
  end

  defp decide(enrollment, position, key, sch) do
    {:ok, campaign} = Sales.fetch(Sales.Campaign, enrollment.campaign_id, actor: sch)
    {:ok, lead} = Sales.fetch(Sales.Lead, enrollment.lead_id, actor: sch)
    {:ok, contact} = Sales.fetch(Sales.Contact, lead.contact_id, actor: sch)
    {:ok, suppressions} = Outreach.matching_suppressions(to_string(contact.email), actor: sch)
    next = next_step(campaign.sequence_id, position, sch)

    go? =
      enrollment.status == :active and enrollment.current_step_position == position and
        campaign.status == :active and suppressions == [] and next != nil

    inputs = %{
      "enrollment_status" => to_string(enrollment.status),
      "current_step_position" => enrollment.current_step_position,
      "step_position" => position,
      "campaign_status" => to_string(campaign.status),
      "suppression_ids" => Enum.map(suppressions, & &1.id),
      "next_step_id" => next && next.id
    }

    with {:ok, _decision} <- record(enrollment, key, inputs, go?, sch),
         :ok <- signal(go?, lead, enrollment, next, sch) do
      :ok
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp record(enrollment, key, inputs, go?, sch) do
    Agents.record_decision(
      %{
        kind: :followup_next_step,
        mode: :deterministic,
        rule_id: "sdr.followup_next_step",
        rule_version: "1",
        subject_resource: inspect(Sales.CampaignEnrollment),
        subject_id: enrollment.id,
        inputs: inputs,
        outcome: if(go?, do: "draft_followup", else: "stop"),
        idempotency_key: key
      },
      actor: sch
    )
  end

  defp signal(false, _lead, _enrollment, _next, _sch), do: :ok

  defp signal(true, lead, enrollment, next, sch) do
    with {:ok, signal} <-
           Signals.build("sdr.followup.due", %{
             lead_id: lead.id,
             campaign_id: enrollment.campaign_id,
             enrollment_id: enrollment.id,
             sequence_step_id: next.id
           }),
         {:ok, _event} <- Signals.record(signal, sch),
         do: :ok
  end

  defp next_step(sequence_id, position, sch) do
    {:ok, steps} =
      Sales.list_records(Sales.SequenceStep, filter: [sequence_id: sequence_id], actor: sch)

    steps |> Enum.sort_by(& &1.position) |> Enum.find(&(&1.position > position))
  end
end
