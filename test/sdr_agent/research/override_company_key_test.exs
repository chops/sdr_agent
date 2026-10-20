defmodule SdrAgent.Research.OverrideCompanyKeyTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 L (T-L1..T-L6): the Qualification
  `:override` company key and its pre-INSERT order (section 4.2), the
  re-open refusal while another lead at the account is open (section 4.2
  step 6), the company-changed conflict (section 4.2 step 5) and the
  converted `research_test.exs:412-437` rollback case (section 4.5).

  Observation: a telemetry trace of the statements this test process sends
  while the override runs (the pattern of RED-1 T-A15): the key statement
  `pg_advisory_xact_lock($1::bigint)`, the pass's publication
  (`set_config('sdr.identity_pass', ...)`), account `FOR SHARE`, lead
  `FOR UPDATE`, the `qualifications` INSERT and the chain head
  `FOR UPDATE` (the first append), in order. No production seam is used.
  T-L5 and T-L6 interleave a change inside the override's own transaction
  from the telemetry handler, right after a named statement (T-L5: the
  pass's publication, so the locked re-check sees a moved company; T-L6:
  the `qualifications` INSERT, so the later evidence link fails). The
  change is raw test-only SQL (`tamper!/2`), it is not traced, and the
  override's rollback reverts it.

  RED form: absent subjects (`IdentityKeys.id/3`, `SDR.admit_lead/2`,
  `SDR.bootstrap_definitions/1`) are guarded (`Code.ensure_loaded?/1`,
  `function_exported?/3`) and called through `apply/3`. T-L1, T-L2, T-L3,
  T-L5 and T-L6 are behavioural: `Research.override_qualification/2`
  exists on main and takes no key and no account lock. T-L4 is structural
  (its newer lead comes from `admit_lead(manual, readmit: true)`).

  Interface names chosen here for review: the re-open and company-changed
  refusals are `{:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field:
  :lead_id}]}}` with no value; the account lock is `FOR SHARE` (not
  `FOR KEY SHARE`); T-L6's failure after the INSERT is the cited claim
  withdrawn inside the transaction, so its evidence link fails on its
  foreign key (the plan's "evidence link to another lead's claim" is
  refused by `QualificationRules` before the INSERT,
  `qualification_rules.ex:87-90`).
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  @keys SdrAgent.Audit.IdentityKeys
  @sdr SdrAgent.SDR
  @injected {__MODULE__, :injected}
  @injecting {__MODULE__, :injecting}

  @key_lock ~r/pg_advisory_xact_lock/
  @publication ~r/set_config\(\s*'sdr\.identity_pass'/
  @account_share ~r/FROM "accounts".*\bFOR SHARE\b/s
  @lead_update ~r/FROM "leads".*\bFOR UPDATE\b/s
  @row_lock ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/
  @head_lock ~r/FROM "audit_chain_heads".*\bFOR UPDATE\b/s
  @qualification_insert ~r/INSERT INTO "qualifications"/
  @lead_write ~r/UPDATE "leads"/

  # Section 2.4, verbatim: the one state query, no lock clause.
  @state_sql """
  SELECT current_setting('sdr.identity_pass', true),
         pg_backend_pid(),
         coalesce(array_agg((l.classid::bigint << 32) | l.objid::bigint)
                  FILTER (WHERE l.pid IS NOT NULL), '{}')
  FROM (SELECT 1) AS one
  LEFT JOIN pg_locks l
    ON  l.locktype = 'advisory'
    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND l.pid      = pg_backend_pid()
    AND l.objsubid = 1
    AND l.mode     = 'ExclusiveLock'
    AND l.granted
  """

  setup do
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant), reviewer: human(:reviewer, tenant)}
  end

  describe "T-L1..T-L3 the key and the locks before the INSERT (qualified lead)" do
    setup ctx do
      %{subject: F.qualified_lead!(ctx.tenant)}
    end

    test "T-L1 the company key is taken before the qualification INSERT", ctx do
      subject = subject!(ctx)

      {result, queries} =
        trace(fn -> Research.override_qualification(override(subject), actor: ctx.reviewer) end)

      assert match?({:ok, _}, result), "the flip override must still succeed: #{short(result)}"
      key = index(queries, @key_lock)
      insert = index(queries, @qualification_insert)
      assert key, "C3-02: the override must take its company key (IdentityKeys.pass)"
      assert insert
      assert key < insert, "C3-02: the company key must be taken before the INSERT"

      expected = key_id(ctx.tenant.id, subject.domain)

      assert Enum.map(matching(queries, @key_lock), &lock_params/1) == [[expected]],
             "C3-02: exactly one key, the domain key of the lead's account, and none later"
    end

    test "T-L2 account FOR SHARE, then lead FOR UPDATE, before the INSERT and the first append",
         ctx do
      subject = subject!(ctx)

      {result, queries} =
        trace(fn -> Research.override_qualification(override(subject), actor: ctx.reviewer) end)

      assert match?({:ok, _}, result), "the flip override must still succeed: #{short(result)}"
      order = pre_insert_order!(queries, subject)
      head = index(queries, @head_lock)
      assert head, "the flip override appends events"
      assert order.insert < head, "C3-02: the first append (head) comes after the INSERT"

      late =
        for {{sql, _params, _cast}, at} <- Enum.with_index(queries),
            at > head,
            sql =~ @row_lock and not (sql =~ @head_lock),
            do: sql

      assert late == [], "C3-02: no row lock is taken after the head"
    end

    test "T-L3 a same-outcome override takes the same locks, moves nothing, one lead row lock",
         ctx do
      subject = subject!(ctx)
      lead_events = lead_events(ctx.tenant)

      {result, queries} =
        trace(fn ->
          Research.override_qualification(override(subject, %{qualified: true, score: 95}),
            actor: ctx.reviewer
          )
        end)

      assert match?({:ok, _}, result), "the same-outcome override succeeds: #{short(result)}"
      pre_insert_order!(queries, subject)

      row_locks =
        for {sql, _params, _cast} = query <- queries,
            sql =~ @row_lock and not (sql =~ @head_lock),
            do: query

      assert Enum.map(row_locks, &lock_kind/1) == [:account_share, :lead_update],
             "C3-02: contention is bounded: one account FOR SHARE and one lead FOR UPDATE"

      assert mentions?(Enum.at(row_locks, 1), subject.lead.id)
      assert matching(queries, @lead_write) == [], "a same-outcome override writes no lead"
      assert lead_status(ctx, subject.lead) == :qualified
      assert lead_events(ctx.tenant) == lead_events
    end
  end

  describe "T-L4 and T-L6 a re-opening override of a disqualified lead" do
    setup ctx do
      %{subject: F.qualified_lead!(ctx.tenant, false)}
    end

    test "T-L4 a re-open is refused before its INSERT while another lead at the account is open",
         ctx do
      subject = subject!(ctx)
      present!(@sdr, :bootstrap_definitions, 1)
      present!(@sdr, :admit_lead, 2)
      definitions = call(@sdr, :bootstrap_definitions, [ctx.tenant.id])

      assert match?({:ok, _}, definitions),
             "C3-02: bootstrap_definitions/1: #{short(definitions)}"

      campaign = F.active_campaign!(ctx.tenant)
      newer = readmitted!(ctx, subject, campaign)
      before = length(events(ctx.tenant))

      {result, queries} =
        trace(fn ->
          Research.override_qualification(override(subject, %{qualified: true, score: 80}),
            actor: ctx.admin
          )
        end)

      error = refusal!(result, [subject.domain, subject.email])
      assert index(queries, @lead_update), "C3-02: the refusal is decided on the locked lead"

      refute index(queries, @qualification_insert),
             "C3-02: the re-open refusal comes before the INSERT"

      assert error.field == :lead_id
      assert lead_status(ctx, subject.lead) == :disqualified
      assert lead_status(ctx, newer) == :assigned
      assert current_id(ctx, subject.lead) == subject.qualification.id
      assert length(events(ctx.tenant)) == before
    end

    # The converted research_test.exs:412-437 case (section 4.5): the
    # "a failing transition rolls the whole override back" intent, with a
    # failure after the INSERT and the same rollback assertions.
    test "T-L6 a failure after the INSERT rolls the whole override back", ctx do
      subject = subject!(ctx)
      before = length(events(ctx.tenant))

      {result, queries} =
        trace(
          fn ->
            Research.override_qualification(override(subject, %{qualified: true, score: 80}),
              actor: ctx.admin
            )
          end,
          {@qualification_insert, fn -> withdraw_claim!(subject.claim) end}
        )

      assert match?({:error, %Ash.Error.Invalid{}}, result), "got: #{short(result)}"
      assert Process.get(@injected), "the override must reach its INSERT"
      assert lead_status(ctx, subject.lead) == :disqualified
      assert current_id(ctx, subject.lead) == subject.qualification.id
      assert length(events(ctx.tenant)) == before
      assert claim_count(subject.claim) == 1, "the in-transaction change must be rolled back"

      pre_insert_order!(queries, subject)

      refute key_id(ctx.tenant.id, subject.domain) in held(),
             "C3-02: the rolled-back override releases its company key"
    end
  end

  describe "T-L5 the company changed after the key" do
    setup ctx do
      %{subject: F.qualified_lead!(ctx.tenant)}
    end

    test "T-L5 a moved company is a typed conflict, writes nothing and requests no further key",
         ctx do
      subject = subject!(ctx)
      moved = "c302canary#{F.unique()}.test"
      before = length(events(ctx.tenant))

      {result, queries} =
        trace(
          fn ->
            Research.override_qualification(override(subject, %{qualified: true, score: 95}),
              actor: ctx.reviewer
            )
          end,
          {@publication, fn -> move_company!(subject.account, moved) end}
        )

      error = refusal!(result, [subject.domain, moved])
      assert error.field == :lead_id
      assert Process.get(@injected), "C3-02: the company moved after the pass was published"
      publication = index(queries, @publication)
      keys = for {{sql, _, _}, at} <- Enum.with_index(queries), sql =~ @key_lock, do: at
      assert length(keys) == 1, "C3-02: the conflict requests no further key"
      assert Enum.all?(keys, &(&1 < publication))
      refute index(queries, @qualification_insert), "C3-02: the conflict comes before the INSERT"
      assert account_domain(ctx, subject.account) == subject.domain
      assert current_id(ctx, subject.lead) == subject.qualification.id
      assert length(events(ctx.tenant)) == before
    end
  end

  ## Subjects

  defp subject!(ctx) do
    %{lead: lead} = subject = ctx.subject
    assert {:ok, account} = Sales.fetch(Sales.Account, lead.account_id, actor: ctx.admin)
    assert {:ok, contact} = Sales.fetch(Sales.Contact, lead.contact_id, actor: ctx.admin)

    Map.merge(subject, %{
      account: account,
      contact: contact,
      domain: to_string(account.domain),
      email: to_string(contact.email)
    })
  end

  defp override(subject, overrides \\ %{}) do
    Map.merge(
      %{
        lead_id: subject.lead.id,
        icp_definition_id: subject.qualification.icp_definition_id,
        supersedes_id: subject.qualification.id,
        qualified: false,
        score: 30,
        criteria: %{
          company_size: :pass,
          industry: :fail,
          geography: :pass,
          persona: :unknown,
          trigger: :pass
        },
        confidence: 0.9,
        reason: "Industry does not fit after manual review.",
        output_schema_version: "qualification_result/1",
        evidence_claim_ids: [subject.claim.id]
      },
      overrides
    )
  end

  # Section 4.5: the newer open lead at the same account, for the same
  # contact, through the admission (manual, readmit).
  defp readmitted!(ctx, subject, campaign) do
    input = %{
      source_kind: :manual,
      source_ref: "manual:#{Ecto.UUID.generate()}",
      campaign_id: campaign.id,
      readmit: true,
      company: %{domain: subject.domain, name: subject.account.name},
      person: %{
        email: subject.email,
        first_name: subject.contact.first_name,
        last_name: subject.contact.last_name,
        title: subject.contact.title,
        timezone: subject.contact.timezone
      }
    }

    result = call(@sdr, :admit_lead, [input, [actor: ctx.admin]])

    assert match?({:ok, %{outcome: :admitted, lead: %{id: _}}}, result),
           "C3-02: admit_lead(manual, readmit: true) must admit: #{short(result)}"

    {:ok, %{lead: newer}} = result
    assert newer.id != subject.lead.id
    assert newer.account_id == subject.lead.account_id
    newer
  end

  ## Assertions

  defp pre_insert_order!(queries, subject) do
    key = index(queries, @key_lock)
    account = index(queries, @account_share)
    lead = index(queries, @lead_update)
    insert = index(queries, @qualification_insert)
    assert key, "C3-02: the override must take its company key"
    assert account, "C3-02: the override must take the account FOR SHARE"
    assert lead, "C3-02: the override must take the lead FOR UPDATE"
    assert insert
    assert key < account, "C3-02: the key comes before the first domain row lock"
    assert account < lead, "C3-02: account FOR SHARE, then lead FOR UPDATE"
    assert lead < insert, "C3-02: the lead is locked before the INSERT"
    assert mentions?(Enum.at(queries, account), subject.account.id)
    assert mentions?(Enum.at(queries, lead), subject.lead.id)
    %{key: key, account: account, lead: lead, insert: insert}
  end

  defp refusal!(result, values) do
    assert match?(
             {:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field: :lead_id}]}},
             result
           ),
           "C3-02: expected the typed InvalidAttribute on :lead_id, got: #{short(result)}"

    {:error, %Ash.Error.Invalid{errors: [refusal]} = error} = result
    assert refusal.value == nil, "C3-02: the refusal carries no value"
    text = rendered(error) <> " " <> rendered(refusal)

    for value <- values do
      refute text =~ value, "C3-02: the refusal must not echo a domain or an address"
    end

    refusal
  end

  defp lock_kind({sql, _params, _cast}) do
    cond do
      sql =~ @account_share -> :account_share
      sql =~ @lead_update -> :lead_update
      true -> {:other, sql}
    end
  end

  ## Reads

  defp lead_status(ctx, lead) do
    assert {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    lead.status
  end

  defp current_id(ctx, lead) do
    assert {:ok, current} = Research.current_qualification(lead.id, actor: ctx.admin)
    current.id
  end

  defp account_domain(ctx, account) do
    assert {:ok, account} = Sales.fetch(Sales.Account, account.id, actor: ctx.admin)
    to_string(account.domain)
  end

  defp lead_events(tenant) do
    for event <- events(tenant),
        String.starts_with?(event.event_type, "sales.lead."),
        do: event.id
  end

  defp claim_count(claim) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM evidence_claims WHERE id = $1", [dump(claim.id)])

    count
  end

  defp held do
    %{rows: [[_setting, _pid, ids]]} = Repo.query!(@state_sql)
    MapSet.new(ids)
  end

  ## In-transaction changes (test-only, raw SQL, rolled back with the override)

  defp move_company!(account, domain),
    do: tamper!("UPDATE accounts SET domain = $1 WHERE id = $2", [domain, dump(account.id)])

  defp withdraw_claim!(claim),
    do: tamper!("DELETE FROM evidence_claims WHERE id = $1", [dump(claim.id)])

  ## Presence guards and calls

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

  defp key_id(tenant_id, domain), do: call(@keys, :id, [tenant_id, :domain, domain])

  ## Query tracing (and the optional in-transaction change)

  defp trace(fun, inject \\ nil) do
    parent = self()
    handler = "c3-02-override-#{System.unique_integer([:positive])}"
    Process.delete(@injected)

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, metadata, _config -> observe(parent, metadata, inject) end,
        nil
      )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp observe(parent, metadata, inject) do
    if self() == parent and not Process.get(@injecting, false) do
      sql = IO.iodata_to_binary(metadata.query)

      send(
        parent,
        {:c302_query, sql, List.wrap(metadata[:params]), List.wrap(metadata[:cast_params])}
      )

      maybe_inject(sql, inject)
    end
  end

  defp maybe_inject(_sql, nil), do: :ok

  defp maybe_inject(sql, {pattern, change}) do
    if sql =~ pattern and not Process.get(@injected, false), do: inject!(change)
    :ok
  end

  defp inject!(change) do
    Process.put(@injecting, true)

    try do
      change.()
      Process.put(@injected, true)
    after
      Process.delete(@injecting)
    end
  end

  defp drain(acc) do
    receive do
      {:c302_query, sql, params, cast} -> drain([{sql, params, cast} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp index(queries, pattern),
    do: Enum.find_index(queries, fn {sql, _params, _cast} -> sql =~ pattern end)

  defp matching(queries, pattern),
    do: for({sql, _params, _cast} = query <- queries, sql =~ pattern, do: query)

  defp lock_params({_sql, params, _cast}), do: params

  defp mentions?({_sql, params, cast}, id),
    do: Enum.any?(params ++ cast, &(&1 in [id, dump(id)]))

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp short(term), do: inspect(term, limit: 12, printable_limit: 300)

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)
end
