defmodule SdrAgent.Sales.CutoverFenceTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 E (T-E14): the cutover fence of plan
  section 5.4 A.5 (packet section 6), `SdrAgent.Sales.CutoverFence.counts_sql/0`,
  the one SQL text the cutover migration runs and these tests run.

  Covered contacts CC: every contact whose account has a `domain`-scope
  suppression of the same tenant equal to `sdr_canonical_domain(a.domain)`.
  Counts (a) open leads of CC, and across all leads of CC (b1) active or
  paused enrollments, (b2) unclaimed deliveries (`pending`,
  `failed_retryable`) of `queued` candidate drafts, (b3) eligible drafts
  (`pending_review`, or `queued` with a delivery in (b2)) and (b4) `granted`
  approvals of (b3). The candidate set D (`pending_review` or `queued`
  drafts) is diagnostic only. Any non-zero (a)..(b4) aborts.

  States are built on the demo data (`SdrAgent.SDRCase`) with main's APIs:
  the agent's own draft (`OutreachFixtures.drafted!/2`), a reviewer's
  approval and its pending delivery (`approved!/2`), Lead `:stop`,
  enrollment `:stop`/`:pause` and draft rejection by operators. Raw SQL in
  the sandbox (`AuditCase.tamper!/2`) is used, and says so, only for what
  those APIs cannot build:
    * every covering suppression row: on main a domain suppression of the
      account's domain stops the work through the contact's email domain
      (demo emails are at the account domain), and after C3-02 through the
      strengthened company match (A.1); the legacy state the fence exists
      for, a suppression committed without those effects, exists only as
      pre-cutover data;
    * a delivery already claimed while its draft stays `queued` (the claim
      itself is the delivery worker's, behind the send gate), a second
      pending delivery on that draft, and approval states beside a claim;
    * lead statuses for the open-set pin, and one approval revocation used
      only to isolate (b2) from (b4).

  RED form: `CutoverFence.counts_sql/0` is guarded before any state is
  built (`Code.ensure_loaded?/1`, `function_exported?/3`) and called through
  `apply/3`; every test fails at that `C3-02:` assertion on main.

  Interface names chosen here for review:
    * result shape: `counts_sql/0` takes no parameters and returns one row
      of non-negative integer totals over all tenants, with columns `a`,
      `b1`, `b2`, `b3`, `b4` and, optionally, the non-aborting diagnostic
      `candidate_drafts`; no other column (counts only, no values);
    * no options: there is no `counts_sql/1`, and the text is independent
      of application config, OS environment and session settings.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Locks
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Lead

  @fence SdrAgent.Sales.CutoverFence
  @categories ["a", "b1", "b2", "b3", "b4"]
  @diagnostic "candidate_drafts"

  describe "T-E14 aborting states" do
    test "T-E14 a covered contact with an open lead aborts", ctx do
      guard_fence!()
      lead = fixture_lead!(ctx, "01")
      cover!(ctx, lead)

      assert_counts!(counts!(), [a: 1], "covered contact with an open lead")
    end

    test "T-E14 zero open leads but an active enrollment on a stopped lead aborts", ctx do
      guard_fence!()
      %{draft: draft, revision: revision, lead: lead} = drafted!(ctx)
      reject!(ctx, draft, revision)
      stop_lead!(ctx, lead)
      cover!(ctx, lead)

      assert_counts!(counts!(), [b1: 1], "active enrollment on a stopped lead")
    end

    test "T-E14 zero open leads but a paused enrollment on a stopped lead aborts", ctx do
      guard_fence!()
      %{draft: draft, revision: revision, lead: lead} = drafted!(ctx)
      reject!(ctx, draft, revision)
      assert {:ok, _} = Sales.update(enrollment!(ctx, lead), :pause, %{}, actor: ctx.admin)
      stop_lead!(ctx, lead)
      cover!(ctx, lead)

      assert_counts!(counts!(), [b1: 1], "paused enrollment on a stopped lead")
    end

    test "T-E14 zero open leads but a pending_review draft aborts", ctx do
      guard_fence!()
      %{lead: lead} = drafted!(ctx)
      stop_all!(ctx, lead)
      cover!(ctx, lead)

      assert_counts!(counts!(), [b3: 1], "pending_review draft")
    end

    test "T-E14 zero open leads but a queued draft with a pending or failed_retryable delivery aborts",
         ctx do
      guard_fence!()
      %{lead: lead, approval: approval, delivery: delivery} = approved!(ctx)
      stop_all!(ctx, lead)
      cover!(ctx, lead)
      # Raw SQL: isolates (b2)/(b3) from (b4); no operator API revokes
      # without returning the draft to review.
      set_raw!("approvals", approval.id, "status = 'revoked', revoked_at = now()")

      assert_counts!(counts!(), [b2: 1, b3: 1], "queued draft with a pending delivery")

      set_raw!(
        "delivery_operations",
        delivery.id,
        "state = 'failed_retryable', attempt_count = 1"
      )

      assert_counts!(counts!(), [b2: 1, b3: 1], "queued draft with a failed_retryable delivery")
    end

    test "T-E14 zero open leads but a granted approval on an eligible draft aborts", ctx do
      guard_fence!()
      %{lead: lead} = approved!(ctx)
      stop_all!(ctx, lead)
      cover!(ctx, lead)

      assert_counts!(counts!(), [b2: 1, b3: 1, b4: 1], "granted approval on an eligible draft")
    end

    test "T-E14 a contact covered by email and by company domain with eligible work aborts",
         ctx do
      guard_fence!()
      %{lead: lead} = drafted!(ctx)
      email = to_string(contact!(ctx, lead).email)
      # Raw SQL: on main the email suppression would stop this work.
      suppress_raw!(ctx, :email, email)
      cover!(ctx, lead)

      assert_counts!(counts!(), [a: 1, b1: 1, b3: 1], "covered by email and company domain")
    end

    test "T-E14 the claimed-only state plus one pending delivery on that queued draft aborts",
         ctx do
      guard_fence!()
      %{delivery: delivery, approval: approval} = claimed_only!(ctx)
      add_pending_delivery!(delivery, approval)

      assert_counts!(counts!(), [b2: 1, b3: 1], "claimed delivery plus a pending one")
    end
  end

  describe "T-E14 passing states" do
    test "T-E14 claimed-only negative control (R3-2): a queued draft whose only delivery is claimed passes",
         ctx do
      guard_fence!()
      claimed_only!(ctx)
      counts = counts!()

      assert_counts!(counts, [], "claimed-only")

      if Map.has_key?(counts, @diagnostic) do
        assert counts[@diagnostic] == 1, "C3-02: the candidate draft is reported, not counted"
      end
    end

    test "T-E14 the claimed-only state plus a granted approval on that queued draft passes",
         ctx do
      guard_fence!()
      %{approval: approval} = claimed_only!(ctx)
      # Raw SQL: a granted approval beside a claimed delivery (the claim consumes it).
      set_raw!("approvals", approval.id, "status = 'granted'")

      assert_counts!(counts!(), [], "granted approval on a non-eligible draft")
    end

    test "T-E14 another tenant's suppression passes", ctx do
      guard_fence!()
      lead = fixture_lead!(ctx, "01")
      suppress_raw!(ctx, :domain, account_domain(ctx, lead), Ecto.UUID.generate())

      assert_counts!(counts!(), [], "another tenant's suppression")
    end

    test "T-E14 a www.-valued domain suppression is not a company's canonical_domain", ctx do
      guard_fence!()
      lead = fixture_lead!(ctx, "01")
      suppress_raw!(ctx, :domain, "www." <> account_domain(ctx, lead))

      assert_counts!(counts!(), [], "www.-valued domain suppression")
    end

    test "T-E14 clean passes", ctx do
      guard_fence!()
      approved!(ctx)

      assert_counts!(counts!(), [], "clean demo data with live work")
    end
  end

  describe "T-E14 fence contract" do
    test "T-E14 the SQL open-status list equals Locks.open_leads/0", ctx do
      guard_fence!()
      lead = fixture_lead!(ctx, "01")
      cover!(ctx, lead)

      # Raw SQL: each status set directly on the covered contact's lead.
      counted = Enum.filter(Lead.statuses(), &counted_open?(lead, &1))

      assert MapSet.new(counted) == MapSet.new(Locks.open_leads()),
             "C3-02: the fence's open set must be Locks.open_leads/0"
    end

    test "T-E14 no override: an aborting state stays aborting whatever config or environment is set",
         ctx do
      guard_fence!()
      lead = fixture_lead!(ctx, "01")
      cover!(ctx, lead)
      sql = call(@fence, :counts_sql, [])

      refute function_exported?(@fence, :counts_sql, 1), "C3-02: the fence takes no options"
      refute sql =~ ~r/current_setting/i, "C3-02: the fence reads no session setting"

      for key <- [:cutover_fence, :cutover_fence_bypass, :skip_cutover_fence, :allow_legacy_work],
          do: put_env!(key, true)

      for name <- ["SDR_CUTOVER_FENCE", "SDR_CUTOVER_FENCE_BYPASS", "SKIP_CUTOVER_FENCE"],
          do: put_os_env!(name, "1")

      for name <- ["sdr.cutover_fence", "sdr.cutover_fence_bypass"],
          do: Repo.query!("SELECT set_config($1, 'off', true)", [name])

      assert call(@fence, :counts_sql, []) == sql, "C3-02: the fence text is fixed"
      assert_counts!(counts!(), [a: 1], "covered open lead under every override attempt")
    end
  end

  ## Fence

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp guard_fence!, do: present!(@fence, :counts_sql, 0)

  defp counts! do
    sql = call(@fence, :counts_sql, [])
    assert is_binary(sql), "C3-02: counts_sql/0 returns the SQL text"
    %{columns: columns, rows: rows} = Repo.query!(sql, [])

    assert match?([_], rows), "C3-02: the fence returns exactly one row of totals"
    assert @categories -- columns == [], "C3-02: the fence names columns a, b1, b2, b3, b4"
    assert columns -- [@diagnostic | @categories] == [], "C3-02: the fence returns counts only"

    [row] = rows
    assert Enum.all?(row, &(is_integer(&1) and &1 >= 0)), "C3-02: counts only, no values"
    columns |> Enum.zip(row) |> Map.new()
  end

  defp assert_counts!(counts, expected, label) do
    expected = Map.merge(Map.new(@categories, &{&1, 0}), Map.new(expected, &stringify/1))
    actual = Map.take(counts, @categories)
    assert actual == expected, "C3-02: #{label}: counts #{inspect(actual)}"
    assert aborts?(actual) == aborts?(expected)
  end

  defp stringify({key, value}), do: {Atom.to_string(key), value}
  defp aborts?(counts), do: Enum.any?(counts, fn {_category, count} -> count > 0 end)

  ## States (main's APIs)

  defp reject!(ctx, draft, revision) do
    binding = Map.put(approval_input(revision), :reason, "c302 not now")

    assert {:ok, _} =
             Outreach.reject(draft, binding, actor: operator!(ctx, :reviewer))
  end

  defp stop_lead!(ctx, lead) do
    assert {:ok, _} =
             Sales.update(reload!(ctx, lead), :stop, %{status_reason: "c302 operator stop"},
               actor: ctx.admin
             )
  end

  defp stop_all!(ctx, lead) do
    assert {:ok, _} =
             Sales.update(enrollment!(ctx, lead), :stop, %{stop_reason: :manual},
               actor: ctx.admin
             )

    stop_lead!(ctx, lead)
  end

  # Covered, zero open leads, only enrollment stopped, one queued draft whose
  # only delivery is claimed (raw: attempting, approval consumed, as the
  # delivery worker's claim leaves them), no granted approval.
  defp claimed_only!(ctx) do
    %{lead: lead, approval: approval, delivery: delivery} = state = approved!(ctx)
    stop_all!(ctx, lead)
    cover!(ctx, lead)

    set_raw!(
      "delivery_operations",
      delivery.id,
      "state = 'attempting', attempt_count = 1, attempting_at = now()"
    )

    set_raw!("approvals", approval.id, "status = 'consumed'")
    assert draft!(ctx, state.draft).status == :queued
    state
  end

  # Raw: a second, pending delivery on the same queued draft, under its own
  # (revoked) approval copy.
  defp add_pending_delivery!(delivery, approval) do
    approval_id = Ecto.UUID.generate()

    copy_raw!("approvals", approval.id, %{
      "id" => approval_id,
      "status" => "revoked",
      "revoked_at" => DateTime.to_iso8601(DateTime.utc_now())
    })

    copy_raw!("delivery_operations", delivery.id, %{
      "id" => Ecto.UUID.generate(),
      "approval_id" => approval_id,
      "idempotency_key" => "delivery:" <> approval_id,
      "state" => "pending",
      "attempt_count" => 0,
      "attempting_at" => nil,
      "provider_message_id" => nil
    })
  end

  ## Raw SQL in the sandbox (database administrator)

  defp cover!(ctx, lead), do: suppress_raw!(ctx, :domain, account_domain(ctx, lead))

  defp suppress_raw!(ctx, scope, value, tenant_id \\ nil) do
    tamper!(
      """
      INSERT INTO suppressions
        (id, tenant_id, scope, value, reason, created_by_user_id, effective_at,
         trace_id, span_id, inserted_at)
      VALUES ($1, $2, $3, $4, 'manual', $5, now(), $6, $7, now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(tenant_id || ctx.tenant.id),
        Atom.to_string(scope),
        value,
        Ecto.UUID.dump!(ctx.admin.id),
        hex(:crypto.strong_rand_bytes(16)),
        hex(:crypto.strong_rand_bytes(8))
      ]
    )
  end

  defp set_raw!(table, id, assignments),
    do: tamper!("UPDATE #{table} SET #{assignments} WHERE id = $1", [Ecto.UUID.dump!(id)])

  defp copy_raw!(table, id, overrides) do
    tamper!(
      "INSERT INTO #{table} SELECT (jsonb_populate_record(NULL::#{table}, " <>
        "to_jsonb(t) || $2::jsonb)).* FROM #{table} AS t WHERE t.id = $1",
      [Ecto.UUID.dump!(id), overrides]
    )
  end

  defp counted_open?(lead, status) do
    set_raw!("leads", lead.id, "status = '#{status}', status_reason = 'c302 probe'")
    counts!()["a"] == 1
  end

  ## Reads and environment

  defp account_domain(ctx, lead) do
    assert {:ok, account} = Sales.fetch(Sales.Account, lead.account_id, actor: ctx.admin)
    to_string(account.domain)
  end

  defp put_os_env!(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end
end
