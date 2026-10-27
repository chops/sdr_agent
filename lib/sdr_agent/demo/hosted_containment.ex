defmodule SdrAgent.Demo.HostedContainment do
  @moduledoc """
  The hosted copy's follow-up containment check (Codex M4; D-218 item 9
  defers the D-206 suppression fix only under it). `scripts/deploy.sh` runs it
  from the staged release, after the seed and before the switch, through
  `SdrAgent.Release.verify_hosted_containment/0`; a failure stops the deploy.

  Read-only: Sales and Outreach rows through the domain list APIs as the
  auditor CLI system actor, and a count of Oban jobs. It passes only when

    * **config** — this release's follow-up switch is off
      (`SdrAgent.Outreach.FollowUps.enabled?/0` is false);
    * **store** — no active sequence has a step after the first, no open
      campaign (draft, active or paused) uses a sequence that has one, and no
      `SdrAgent.SDR.FollowupWorker` job is incomplete (suspended, available,
      scheduled, executing or retryable);
    * **suppressed-seed smoke** — each suppressed seed contact
      (`SdrAgent.Demo.Fixtures.suppressed_contact_emails/0`) exists once, has
      its email Suppression, all its leads are stopped, and it has no
      enrollment, draft or delivery.

  `check/0` returns `{:ok, report}` or `{:error, report}`; the report holds
  atoms and counts only (`format/1` renders it on one line), never row values.
  """
  import Ecto.Query, only: [from: 2]

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.FollowUps
  alias SdrAgent.Repo
  alias SdrAgent.Sales

  @worker "SdrAgent.SDR.FollowupWorker"
  # Oban's incomplete job states (`Oban.Job` :incomplete unique states).
  @incomplete ~w(suspended available scheduled executing retryable)
  @open_campaign [:draft, :active, :paused]
  @keys [
    :follow_ups,
    :active_followup_steps,
    :open_followup_campaigns,
    :followup_jobs,
    :suppressed_seed
  ]

  @type report :: %{
          follow_ups: :enabled | :disabled,
          active_followup_steps: non_neg_integer(),
          open_followup_campaigns: non_neg_integer(),
          followup_jobs: non_neg_integer(),
          suppressed_seed: :ok | :failed
        }

  @doc "Checks the containment (see the moduledoc)."
  @spec check() :: {:ok, report()} | {:error, report() | %{tenant: :absent}}
  def check do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> tenant_id |> report() |> verdict()
      {:error, _reason} -> {:error, %{tenant: :absent}}
    end
  end

  @doc "The report on one line (`key=value` pairs; atoms and counts only)."
  @spec format(map()) :: String.t()
  def format(%{tenant: :absent}), do: "tenant=absent"

  def format(report),
    do: Enum.map_join(@keys, " ", &"#{&1}=#{Map.fetch!(report, &1)}")

  defp verdict(report) do
    contained? =
      report.follow_ups == :disabled and report.active_followup_steps == 0 and
        report.open_followup_campaigns == 0 and report.followup_jobs == 0 and
        report.suppressed_seed == :ok

    if contained?, do: {:ok, report}, else: {:error, report}
  end

  defp report(tenant_id) do
    opts = [actor: Actor.system(:auditor_cli, tenant_id)]

    active =
      for sequence <- sales!(Sales.Sequence, [], opts),
          sequence.status == :active,
          into: MapSet.new(),
          do: sequence.id

    follow_up_steps =
      for step <- sales!(Sales.SequenceStep, [], opts), step.position > 1, do: step

    with_follow_up = MapSet.new(follow_up_steps, & &1.sequence_id)

    %{
      follow_ups: if(FollowUps.enabled?(), do: :enabled, else: :disabled),
      active_followup_steps: Enum.count(follow_up_steps, &MapSet.member?(active, &1.sequence_id)),
      open_followup_campaigns:
        Sales.Campaign
        |> sales!([], opts)
        |> Enum.count(
          &(&1.status in @open_campaign and MapSet.member?(with_follow_up, &1.sequence_id))
        ),
      followup_jobs: followup_jobs(),
      suppressed_seed: suppressed_seed(opts)
    }
  end

  defp followup_jobs do
    from(job in Oban.Job, where: job.worker == @worker and job.state in @incomplete)
    |> Repo.aggregate(:count)
  end

  defp suppressed_seed(opts) do
    if Enum.all?(Fixtures.suppressed_contact_emails(), &suppressed?(&1, opts)),
      do: :ok,
      else: :failed
  end

  defp suppressed?(email, opts) do
    with [contact] <- sales!(Sales.Contact, [email: email], opts),
         [_ | _] <- outreach!(Outreach.Suppression, [scope: :email, value: email], opts),
         [_ | _] = leads <- sales!(Sales.Lead, [contact_id: contact.id], opts),
         true <- Enum.all?(leads, &(&1.status == :stopped)) do
      Enum.all?(leads, &(sales!(Sales.CampaignEnrollment, [lead_id: &1.id], opts) == [])) and
        Enum.all?(leads, &(outreach!(Outreach.Draft, [lead_id: &1.id], opts) == [])) and
        outreach!(Outreach.DeliveryOperation, [recipient_contact_id: contact.id], opts) == []
    else
      _missing_or_open -> false
    end
  end

  defp sales!(resource, filter, opts), do: rows!(Sales, resource, filter, opts)
  defp outreach!(resource, filter, opts), do: rows!(Outreach, resource, filter, opts)

  defp rows!(domain, resource, filter, opts) do
    case domain.list_records(resource, Keyword.put(opts, :filter, filter)) do
      {:ok, rows} ->
        rows

      {:error, error} ->
        raise "hosted containment: reading #{inspect(resource)} failed: #{kind(error)}"
    end
  end

  # The error's kind, never its values.
  defp kind(%{__struct__: module}), do: inspect(module)
  defp kind(_other), do: "error"
end
