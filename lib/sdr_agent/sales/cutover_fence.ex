defmodule SdrAgent.Sales.CutoverFence do
  @moduledoc """
  The A.5 cutover fence (plan r8 section 5.4, option A with A.5; packet
  section 6; D-174 Q-O1 = A): a migration pre-check that refuses to cut over
  while legacy company-domain suppressions leave a covered contact with an
  open lead or with eligible dependent work, because the unchanged gates
  match suppressions by email and email domain only.

  **Covered contacts CC.** Every contact `k` whose account `a` (same tenant)
  has a `domain`-scope suppression `s` (same tenant) with
  `s.value = sdr_canonical_domain(a.domain)`, whatever the lead status.

  **Counts** (one row of non-negative integer totals over all tenants; every
  join matches `tenant_id`):

    * `a`: leads of CC in an open status, the set of
      `SdrAgent.Outreach.Locks.open_leads/0` (pinned by a test);
    * over all leads `L` of CC, whatever their status (mirroring
      `SdrAgent.Outreach.Locks.targets/2`), with the candidate drafts `D`
      (`pending_review` or `queued` drafts of `L`):
      * `b1`: `active` or `paused` enrollments of `L`;
      * `b2`: unclaimed deliveries (`pending`, `failed_retryable`) of the
        `queued` drafts of `D`;
      * `b3`: eligible drafts, the `pending_review` drafts of `D` and the
        `queued` drafts of `D` with a delivery in `b2`;
      * `b4`: `granted` approvals of the eligible drafts;
    * `candidate_drafts`: the size of `D`, diagnostic only; it never
      aborts (a `queued` draft whose deliveries are all claimed is in `D`
      but not in `b3`).

  `counts_sql/0` is the one reviewed SQL text: it takes no parameter and
  no option, reads no session setting, application config or environment,
  and returns counts only. `run!/1` executes it on the given repo and
  returns `:ok` when `a`..`b4` are all zero, else raises
  `CutoverFence.Aborted`, whose `counts` and message carry the five
  aborting counts and nothing else. There is no bypass.

  The C3-02 additive migration calls `run!/1` before any index, column,
  table or row change, so the SQL here must stay valid over the schema at
  that migration: a later change to this text, or to a table it reads,
  must keep the historical migration replayable (on a fresh database every
  count is zero).
  """

  @counts_sql """
  WITH covered AS (
    SELECT DISTINCT k.id, k.tenant_id
      FROM contacts AS k
      JOIN accounts AS a ON a.id = k.account_id AND a.tenant_id = k.tenant_id
      JOIN suppressions AS s
        ON s.tenant_id = a.tenant_id
       AND s.scope = 'domain'
       AND s.value::text = sdr_canonical_domain(a.domain::text)
  ),
  covered_leads AS (
    SELECT l.id, l.tenant_id, l.status
      FROM leads AS l
      JOIN covered AS cc ON cc.id = l.contact_id AND cc.tenant_id = l.tenant_id
  ),
  candidate_drafts AS (
    SELECT d.id, d.tenant_id, d.status
      FROM drafts AS d
      JOIN covered_leads AS l ON l.id = d.lead_id AND l.tenant_id = d.tenant_id
     WHERE d.status IN ('pending_review', 'queued')
  ),
  unclaimed AS (
    SELECT o.id, o.tenant_id, o.draft_id
      FROM delivery_operations AS o
      JOIN candidate_drafts AS d ON d.id = o.draft_id AND d.tenant_id = o.tenant_id
     WHERE d.status = 'queued' AND o.state IN ('pending', 'failed_retryable')
  ),
  eligible_drafts AS (
    SELECT d.id, d.tenant_id
      FROM candidate_drafts AS d
     WHERE d.status = 'pending_review'
        OR EXISTS (
             SELECT 1 FROM unclaimed AS u
              WHERE u.draft_id = d.id AND u.tenant_id = d.tenant_id
           )
  )
  SELECT
    (SELECT count(*) FROM covered_leads AS l
      WHERE l.status IN ('new', 'assigned', 'researching', 'qualifying', 'qualified',
                         'in_outreach', 'replied', 'blocked'))::bigint AS a,
    (SELECT count(*) FROM campaign_enrollments AS e
       JOIN covered_leads AS l ON l.id = e.lead_id AND l.tenant_id = e.tenant_id
      WHERE e.status IN ('active', 'paused'))::bigint AS b1,
    (SELECT count(*) FROM unclaimed)::bigint AS b2,
    (SELECT count(*) FROM eligible_drafts)::bigint AS b3,
    (SELECT count(*) FROM approvals AS p
       JOIN eligible_drafts AS d ON d.id = p.draft_id AND d.tenant_id = p.tenant_id
      WHERE p.status = 'granted')::bigint AS b4,
    (SELECT count(*) FROM candidate_drafts)::bigint AS candidate_drafts
  """

  @aborting [a: "a", b1: "b1", b2: "b2", b3: "b3", b4: "b4"]

  defmodule Aborted do
    @moduledoc """
    The fence refused the cutover (see `SdrAgent.Sales.CutoverFence`).
    `counts` is `%{a:, b1:, b2:, b3:, b4:}`, integers only; the message
    carries the same counts and no value.
    """
    defexception [:counts]

    @impl true
    def message(%{counts: counts}) do
      "C3-02 cutover fence: legacy company-domain suppressions leave covered work; " <>
        "the migration is aborted and nothing was changed (counts only: " <>
        Enum.map_join([:a, :b1, :b2, :b3, :b4], ", ", &"#{&1}=#{Map.get(counts, &1)}") <>
        ")"
    end
  end

  @doc "The fence's one SQL text (see the moduledoc); no parameters."
  @spec counts_sql() :: String.t()
  def counts_sql, do: @counts_sql

  @doc """
  Runs `counts_sql/0` on `repo`: `:ok` when every aborting count is zero,
  else raises `CutoverFence.Aborted` with the counts.
  """
  @spec run!(module()) :: :ok
  def run!(repo) do
    %{columns: columns, rows: [row]} = repo.query!(@counts_sql, [])
    totals = columns |> Enum.zip(row) |> Map.new()

    counts =
      Map.new(@aborting, fn {category, column} -> {category, Map.fetch!(totals, column)} end)

    if Enum.all?(counts, fn {_category, count} -> count == 0 end),
      do: :ok,
      else: raise(Aborted, counts: counts)
  end
end
