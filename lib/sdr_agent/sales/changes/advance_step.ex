defmodule SdrAgent.Sales.Changes.AdvanceStep do
  @moduledoc """
  CampaignEnrollment `:advance_step` / `:complete` (S2: "advance_step (after
  a delivery is accepted) sets current_step_position and next_step_due_at =
  accepted_at + next step's delay_days, evaluated in campaign timezone; last
  step accepted → completed").

  Arguments `step_position` (the step whose message was accepted) and
  `accepted_at`. Runs on the row re-read under `FOR UPDATE`. The position
  only moves forward. With `final?: false` the campaign sequence must have a
  next step, whose due time is computed with `SdrAgent.Sales.LocalTime` in
  the campaign's time zone (DST-correct); with `final?: true` there must be
  none, and the due time is cleared.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.LocalTime
  alias SdrAgent.Sales.SequenceStep

  @impl true
  def change(changeset, opts, _context),
    do: Ash.Changeset.before_action(changeset, &advance(&1, opts[:final?]))

  defp advance(changeset, final?) do
    enrollment = changeset.data
    position = Ash.Changeset.get_argument(changeset, :step_position)
    accepted_at = Ash.Changeset.get_argument(changeset, :accepted_at)
    campaign = read_campaign(enrollment.campaign_id)
    next = next_step(campaign.sequence_id, position)

    cond do
      position <= enrollment.current_step_position ->
        error(
          changeset,
          :step_position,
          "must move forward from #{enrollment.current_step_position}"
        )

      final? and next != nil ->
        error(changeset, :step_position, "is not the last step")

      not final? and next == nil ->
        error(changeset, :step_position, "is the last step (complete the enrollment)")

      true ->
        due = next && LocalTime.add_days(accepted_at, next.delay_days, campaign.timezone)

        changeset
        |> Ash.Changeset.force_change_attribute(:current_step_position, position)
        |> Ash.Changeset.force_change_attribute(:next_step_due_at, due)
    end
  end

  @doc "True when `position` is the last step of the campaign's sequence."
  def last_step?(campaign_id, position) do
    campaign_id |> read_campaign() |> Map.fetch!(:sequence_id) |> next_step(position) |> is_nil()
  end

  # Internal reads of the campaign and its (immutable, active) sequence.
  defp read_campaign(id),
    do: Campaign |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)

  defp next_step(sequence_id, position) do
    SequenceStep
    |> Ash.Query.filter(sequence_id == ^sequence_id and position > ^position)
    |> Ash.Query.sort(position: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
