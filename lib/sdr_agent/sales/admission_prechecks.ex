defmodule SdrAgent.Sales.AdmissionPrechecks do
  @moduledoc """
  The lead admission migration pre-checks (packet section 3 Account and
  Lead, section 9 "Cutover"; plan r8 section 2.7, legacy-identity
  pre-check; D-174 Q-O6): the C3-02 additive migration runs `run!/1` before
  it builds any index, column, table or row change, so a database whose
  existing rows the new invariants would reject stops the migration with
  counts only. Rows are never repaired, rewritten or backfilled; the owner
  resolves an abort explicitly.

  Counts, over all tenants, each a number of accounts:

    * `canonical_collisions`: accounts in a group of two or more accounts of
      one tenant with the same `sdr_canonical_domain(domain)` (the unique
      expression index on accounts would refuse the group);
    * `double_open_leads`: accounts with more than one lead in an open
      status (the `one_open_per_account` index would refuse them); the open
      set is `SdrAgent.Outreach.Locks.open_leads/0`, as in
      `SdrAgent.Sales.CutoverFence`;
    * `legacy_identity`: accounts whose indexed value
      `c = sdr_canonical_domain(domain)` fails the section 2.7 predicate, i.e.
      `SdrAgent.Sales.Domain.canonical(c) != {:ok, c}` (a normalization to
      a different value, as stored `www.www.x.test`, or an invalid indexed
      form, as stored `www.test`).

  `run!/1` executes the one reviewed SQL text on the given repo (read-only;
  it needs `sdr_canonical_domain(text)`, which the migration creates first)
  and returns `:ok` when every count is zero, else raises
  `AdmissionPrechecks.Aborted`, whose `counts` and message carry the three
  counts and no value. There is no bypass.

  Because a migration calls it, the SQL here must stay valid over the schema
  at that migration: a later change to this text, or to a table it reads,
  must keep the historical migration replayable (on a fresh database every
  count is zero).
  """

  # Plan r8 section 2.7, verbatim: the legacy-identity predicate over
  # c = sdr_canonical_domain(stored domain).
  @counts_sql ~S"""
  SELECT
    (SELECT coalesce(sum(g.n), 0)
       FROM (SELECT count(*) AS n
               FROM accounts
              GROUP BY tenant_id, sdr_canonical_domain(domain::text)
             HAVING count(*) > 1) AS g)::bigint AS canonical_collisions,
    (SELECT count(*)
       FROM (SELECT 1
               FROM leads
              WHERE status IN ('new', 'assigned', 'researching', 'qualifying', 'qualified',
                               'in_outreach', 'replied', 'blocked')
              GROUP BY tenant_id, account_id
             HAVING count(*) > 1) AS o)::bigint AS double_open_leads,
    (SELECT count(*)
       FROM (SELECT sdr_canonical_domain(domain::text) AS c FROM accounts) AS s
      WHERE NOT coalesce(
              length(c) BETWEEN 1 AND 253
              AND c ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
              AND c !~ '^www\.'
              AND sdr_canonical_domain(c) = c,
              false))::bigint AS legacy_identity
  """

  @categories [:canonical_collisions, :double_open_leads, :legacy_identity]

  defmodule Aborted do
    @moduledoc """
    A pre-check refused the migration (see `SdrAgent.Sales.AdmissionPrechecks`).
    `counts` is `%{canonical_collisions:, double_open_leads:,
    legacy_identity:}`, integers only; the message carries the same counts
    and no value.
    """
    defexception [:counts]

    @impl true
    def message(%{counts: counts}) do
      "C3-02 admission pre-checks: existing rows violate the new invariants; " <>
        "the migration is aborted and nothing was changed (counts only: " <>
        Enum.map_join(
          [:canonical_collisions, :double_open_leads, :legacy_identity],
          ", ",
          &"#{&1}=#{Map.get(counts, &1)}"
        ) <> ")"
    end
  end

  @doc """
  Runs the pre-checks on `repo`: `:ok` when every count is zero, else raises
  `AdmissionPrechecks.Aborted` with the counts.
  """
  @spec run!(module()) :: :ok
  def run!(repo) do
    %{columns: columns, rows: [row]} = repo.query!(@counts_sql, [])
    totals = columns |> Enum.zip(row) |> Map.new()
    counts = Map.new(@categories, &{&1, Map.fetch!(totals, Atom.to_string(&1))})

    if Enum.all?(counts, fn {_category, count} -> count == 0 end),
      do: :ok,
      else: raise(Aborted, counts: counts)
  end
end
