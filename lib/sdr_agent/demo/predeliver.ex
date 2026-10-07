defmodule SdrAgent.Demo.Predeliver do
  @moduledoc """
  Runs fixture lead 01 (Brightpath Freight Systems) along the golden path
  ahead of a live demo (`bin/demo predeliver`, `mix sdr.demo.predeliver`;
  dev/test only, seeded data set required):

    1. assign the lead to the agent as the demo reviewer (`SDR.assign_lead/2`)
       and run its research job (fake model by default): evidence,
       qualification and a draft awaiting review;
    2. only with `approve: true` — approve the draft's current revision as
       the demo **reviewer** (signed in with the fixture password), bound to
       the revision id, its content hash and the recipient email the console
       displays (the contact's current email), then run the delivery job:
       the local capture adapter captures the exact message.

  The approval is a real, audited approval attributed to the Demo Reviewer
  operator: the person running the command is approving as that fixture
  operator (Tier 0 still holds — nothing is delivered without it). Without
  `approve: true` the draft waits for a human in the console.

  Every step goes through the public domain APIs and the real Oban workers
  (drained inline; scheduled jobs are not forced), so the send gate applies:
  inside quiet hours (18:00–08:00 America/Denver) the delivery is deferred
  and reported as such. Idempotent: a step already done is skipped, so a
  re-run only reports.

  Returns `{:ok, %{stage: stage, lead_id, draft_id, delivery}}` with `stage`
  one of `:awaiting_review`, `:queued`, `:captured`, `:deferred` (with
  `delivery.not_before`), or `{:error, reason}` (`:not_seeded`,
  `{:lead_not_ready, status}`, `{:run, status}`, …).
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SDR

  @lead_key 0

  @doc "Runs lead 01 to a draft (or, with `approve: true`, to a captured email). See the moduledoc."
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_ms, 30_000)

    with {:ok, reviewer} <- reviewer(),
         {:ok, lead} <- lead(reviewer),
         {:ok, lead} <- researched(lead, reviewer),
         {:ok, draft} <- await(fn -> draft(lead, reviewer) end, deadline) do
      if Keyword.get(opts, :approve, false),
        do: delivered(lead, draft, reviewer, deadline),
        else: report(lead, draft, reviewer)
    end
  end

  # A running dev server's own Oban queues may take a job before the inline
  # drain does; wait (bounded) for its outcome instead of failing.
  defp await(fun, deadline) do
    case fun.() do
      {:retry, _reason} = retry -> retry_until(fun, deadline, retry)
      other -> other
    end
  end

  defp retry_until(fun, deadline, {:retry, reason}) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, reason}
    else
      Process.sleep(250)
      await(fun, deadline)
    end
  end

  defp reviewer do
    fixture = Enum.find(Fixtures.users(), &(&1.role == :reviewer))

    case Accounts.sign_in(fixture.email, fixture.password) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, :not_seeded}
    end
  end

  defp lead(reviewer) do
    case Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), @lead_key).id, actor: reviewer) do
      {:ok, lead} -> {:ok, lead}
      {:error, _} -> {:error, :not_seeded}
    end
  end

  defp researched(%{status: :new} = lead, reviewer) do
    with {:ok, _assignment} <-
           SDR.assign_lead(lead, actor: reviewer, campaign_id: Fixtures.campaign().id) do
      Oban.drain_queue(queue: :research)
      Sales.fetch(Sales.Lead, lead.id, actor: reviewer)
    end
  end

  defp researched(lead, _reviewer), do: {:ok, lead}

  defp draft(lead, reviewer) do
    case Outreach.list_records(Outreach.Draft,
           filter: [lead_id: lead.id],
           sort: [inserted_at: :desc, id: :asc],
           actor: reviewer
         ) do
      {:ok, [draft | _]} -> {:ok, draft}
      {:ok, []} -> no_draft(lead, reviewer)
      error -> error
    end
  end

  defp no_draft(lead, reviewer) do
    case Agents.list_runs(actor: reviewer, lead_id: lead.id) do
      {:ok, [%{status: status} | _]} when status in [:queued, :running] ->
        {:retry, {:run, status}}

      {:ok, [%{status: status} | _]} when status != :succeeded ->
        {:error, {:run, status}}

      _ ->
        {:error, {:lead_not_ready, lead.status}}
    end
  end

  defp delivered(lead, %{status: :pending_review} = draft, reviewer, deadline) do
    with {:ok, revision} <-
           Outreach.fetch(Outreach.DraftRevision, draft.current_revision_id, actor: reviewer),
         {:ok, contact} <- Sales.fetch(Sales.Contact, draft.recipient_contact_id, actor: reviewer),
         {:ok, _approval} <-
           Outreach.approve(
             draft,
             %{
               draft_revision_id: revision.id,
               content_sha256: Base.encode16(revision.content_sha256, case: :lower),
               recipient_email: to_string(contact.email)
             },
             actor: reviewer
           ) do
      Oban.drain_queue(queue: :delivery)
      await(fn -> settled(lead, draft, reviewer) end, deadline)
    end
  end

  defp delivered(lead, draft, reviewer, _deadline), do: report(lead, draft, reviewer)

  defp settled(lead, draft, reviewer) do
    with {:ok, draft} <- Outreach.fetch(Outreach.Draft, draft.id, actor: reviewer),
         {:ok, %{stage: :queued}} <- report(lead, draft, reviewer) do
      {:retry, :delivery_not_settled}
    end
  end

  defp report(lead, draft, reviewer) do
    with {:ok, deliveries} <-
           Outreach.list_records(Outreach.DeliveryOperation,
             filter: [draft_id: draft.id],
             sort: [inserted_at: :desc, id: :asc],
             actor: reviewer
           ) do
      delivery = List.first(deliveries)

      {:ok,
       %{stage: stage(draft, delivery), lead_id: lead.id, draft_id: draft.id, delivery: delivery}}
    end
  end

  defp stage(%{status: :pending_review}, _delivery), do: :awaiting_review
  defp stage(_draft, %{state: state}) when state in [:accepted, :delivered], do: :captured

  defp stage(_draft, %{state: :pending, not_before: %DateTime{}}), do: :deferred
  defp stage(_draft, %{state: state}) when state in [:pending, :attempting], do: :queued
  defp stage(draft, nil), do: {:draft, draft.status}
  defp stage(_draft, %{state: state}), do: {:delivery, state}
end
