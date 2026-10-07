defmodule SdrAgent.Demo.Status do
  @moduledoc """
  The local demo's health report (`bin/demo status`, `mix sdr.demo.status`;
  checklist 4.1): database reachable, migrations current, the fixture data
  set seeded (every fixture lead and the campaign present),
  Oban queues with their job counts, the pipeline counts an operator
  narrates (leads by status, drafts awaiting review, captured messages) and
  the audit chain verification.

  Domain data is read through the public domain APIs as the read-only
  `:auditor_cli` system actor; verifying the chain records a `chain_verify`
  AuditAccess, as every verification does. Oban's own table is read through
  `Oban.Job`. The report holds counts and ids only — never content or
  secrets.
  """

  import Ecto.Query, only: [from: 2]

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Repo
  alias SdrAgent.Sales

  @type report :: %{
          database: :reachable | {:unreachable, String.t()},
          migrations: %{applied: non_neg_integer(), pending: [integer()]} | :unknown,
          tenant: :seeded | :incomplete | :not_bootstrapped | :unavailable | :unknown,
          queues: [%{queue: String.t(), limit: non_neg_integer(), jobs: map()}],
          leads: %{optional(atom()) => non_neg_integer()},
          drafts_pending_review: non_neg_integer() | nil,
          captured_messages: non_neg_integer() | nil,
          chain:
            %{valid?: boolean(), last_sequence: non_neg_integer(), issues: non_neg_integer()}
            | nil
        }

  @doc """
  Builds the report. `queues:` — the configured Oban queues (`[{name,
  limit}]`; default: the application's Oban config).
  """
  @spec report(keyword()) :: report()
  def report(opts \\ []) do
    queues = Keyword.get_lazy(opts, :queues, &configured_queues/0)

    case Repo.query("SELECT 1") do
      {:ok, _} -> reachable(queues)
      {:error, error} -> unreachable(Exception.message(error))
    end
  end

  @doc """
  Whether the report shows a demo that can run: database reachable,
  migrations current, the fixture data set fully seeded, and the audit chain
  verified valid (an unavailable or failed verification is not ready).
  """
  @spec ready?(report()) :: boolean()
  def ready?(%{
        database: :reachable,
        migrations: %{pending: []},
        tenant: :seeded,
        chain: %{valid?: true}
      }),
      do: true

  def ready?(_report), do: false

  @doc "The Oban queues configured for the application, `[{name, limit}]`."
  @spec configured_queues() :: [{atom(), non_neg_integer()}]
  def configured_queues do
    :sdr_agent |> Application.get_env(Oban, []) |> Keyword.get(:queues, []) |> List.wrap()
  end

  defp unreachable(message) do
    %{
      database: {:unreachable, message},
      migrations: :unknown,
      tenant: :unknown,
      queues: [],
      leads: %{},
      drafts_pending_review: nil,
      captured_messages: nil,
      chain: nil
    }
  end

  defp reachable(queues) do
    base = %{
      database: :reachable,
      migrations: migrations(),
      tenant: :not_bootstrapped,
      queues: queue_report(queues),
      leads: %{},
      drafts_pending_review: nil,
      captured_messages: nil,
      chain: nil
    }

    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> Map.merge(base, domain_counts(tenant_id))
      {:error, _} -> base
    end
  end

  defp migrations do
    statuses = Ecto.Migrator.migrations(Repo)

    %{
      applied: Enum.count(statuses, &match?({:up, _, _}, &1)),
      pending: for({:down, version, _name} <- statuses, do: version)
    }
  end

  defp queue_report(queues) do
    counts =
      Repo.all(
        from(j in Oban.Job,
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
        )
      )

    for {queue, limit} <- queues do
      name = to_string(queue)
      jobs = for {^name, state, count} <- counts, into: %{}, do: {state, count}
      %{queue: name, limit: limit, jobs: jobs}
    end
  end

  defp domain_counts(tenant_id) do
    actor = Actor.system(:auditor_cli, tenant_id)
    opts = [actor: actor]

    with {:ok, leads} <- Sales.list_records(Sales.Lead, opts),
         {:ok, campaigns} <- Sales.list_records(Sales.Campaign, opts),
         {:ok, queue} <- Outreach.list_review_queue(opts),
         {:ok, captured} <-
           Outreach.list_records(
             Outreach.DeliveryReceipt,
             Keyword.put(opts, :filter, kind: :captured)
           ),
         {:ok, chain} <- Audit.verify_chain(actor: actor) do
      %{
        tenant: seed_state(leads, campaigns),
        leads: Enum.frequencies_by(leads, & &1.status),
        drafts_pending_review: length(queue),
        captured_messages: length(captured),
        chain: %{
          valid?: chain.valid?,
          last_sequence: chain.last_sequence,
          issues: length(chain.issues)
        }
      }
    else
      # Counts or verification unavailable: reported, and never ready.
      {:error, _reason} -> %{tenant: :unavailable}
    end
  end

  defp seed_state(leads, campaigns) do
    lead_ids = MapSet.new(leads, & &1.id)
    campaign? = Enum.any?(campaigns, &(&1.id == Fixtures.campaign().id))

    if campaign? and Enum.all?(Fixtures.leads(), &MapSet.member?(lead_ids, &1.id)),
      do: :seeded,
      else: :incomplete
  end

  @doc "Formats the report as plain lines for the terminal."
  @spec format(report()) :: [String.t()]
  def format(report) do
    [
      "database: #{database(report.database)}",
      "migrations: #{migrations_line(report.migrations)}",
      "tenant: #{tenant(report.tenant)}"
    ] ++ queue_lines(report.queues) ++ domain_lines(report)
  end

  defp database(:reachable), do: "reachable"
  defp database({:unreachable, message}), do: "UNREACHABLE (#{message})"

  defp migrations_line(:unknown), do: "unknown"
  defp migrations_line(%{applied: n, pending: []}), do: "current (#{n} applied)"

  defp migrations_line(%{applied: n, pending: pending}),
    do: "PENDING #{length(pending)} (#{n} applied; run bin/demo reset --yes or mix ecto.migrate)"

  defp tenant(:seeded), do: "seeded"
  defp tenant(:incomplete), do: "SEED INCOMPLETE (run bin/demo seed)"
  defp tenant(:not_bootstrapped), do: "NOT SEEDED (run bin/demo seed)"
  defp tenant(:unavailable), do: "UNAVAILABLE (domain reads or chain verification failed)"
  defp tenant(:unknown), do: "unknown"

  defp queue_lines([]), do: []

  defp queue_lines(queues) do
    lines =
      for %{queue: queue, limit: limit, jobs: jobs} <- queues do
        "  #{String.pad_trailing(queue, 15)} limit #{limit}: #{counts(jobs, "no jobs")}"
      end

    ["oban queues:" | lines]
  end

  defp counts(counts, empty) do
    case Enum.sort(counts) do
      [] -> empty
      sorted -> Enum.map_join(sorted, ", ", fn {key, n} -> "#{key} #{n}" end)
    end
  end

  defp domain_lines(%{chain: nil}), do: []

  defp domain_lines(report) do
    [
      "leads: #{counts(report.leads, "none")}",
      "drafts awaiting review: #{report.drafts_pending_review}",
      "captured messages: #{report.captured_messages}",
      "audit chain: #{chain(report.chain)}"
    ]
  end

  defp chain(%{valid?: true, last_sequence: n}), do: "valid (#{n} events)"

  defp chain(%{valid?: false, last_sequence: n, issues: issues}),
    do: "INVALID (#{issues} issues in #{n} events)"
end
