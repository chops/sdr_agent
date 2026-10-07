defmodule SdrAgent.Demo.Predeliver do
  @moduledoc """
  Runs fixture lead 01 (Brightpath Freight Systems) up to human review ahead
  of a live demo (`bin/demo predeliver`, `mix sdr.demo.predeliver`; dev/test
  only, seeded data set required): assigns the lead to the agent as the demo
  reviewer (`SDR.assign_lead/2`) and runs its research job (fake model by
  default) — evidence, qualification and a draft awaiting review.

  It **never approves** (ADR-0001 Tier 0: every outbound message needs a
  human approval bound to an immutable revision). The owner approves the
  draft in the console, which also rehearses the demo; the delivery then
  runs on the server's own delivery queue, subject to the send gate (quiet
  hours 18:00–08:00 America/Denver).

  Every step goes through the public domain APIs and the real Oban worker
  (drained inline; if a running dev server takes the job first, it waits,
  bounded, for the outcome). Idempotent: once the draft exists a re-run only
  reports — including the draft's delivery after a human approval.

  Returns `{:ok, %{stage: stage, lead_id, draft_id, delivery}}` with `stage`
  one of `:awaiting_review`, `:queued`, `:deferred` (`delivery.not_before`),
  `:captured`, or `{:error, reason}` (`:not_seeded`,
  `{:lead_not_ready, status}`, `{:run, status}`, …).
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SDR

  @lead_key 0

  @doc "Runs lead 01 to a draft awaiting human review. See the moduledoc."
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_ms, 30_000)

    with {:ok, reviewer} <- reviewer(),
         {:ok, lead} <- lead(reviewer),
         {:ok, lead} <- researched(lead, reviewer),
         {:ok, draft} <- await(fn -> draft(lead, reviewer) end, deadline) do
      report(lead, draft, reviewer)
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

  # A running dev server's own Oban queues may take the job before the
  # inline drain does; wait (bounded) for its outcome instead of failing.
  defp await(fun, deadline) do
    case fun.() do
      {:retry, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, reason}
        else
          Process.sleep(250)
          await(fun, deadline)
        end

      other ->
        other
    end
  end

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
