defmodule SdrAgent.Sales.IdentityWritersTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 M (T-M1..T-M6): the Sales identity
  writers of section 2.6 and their key sets (packet section 5.1 as amended,
  ADR-0009 C3-02 amendment item 4):

    * T-M1: Account `:create`/`:seed` key the new company domain (the stored
      `company(raw)` form, section 2.7);
    * T-M2: Account `:update` with a domain change keys the old and the new
      domain; a stale struct (its old domain no longer the locked row's) is
      a typed conflict with nothing written and no late key; a repeated
      `www.` is refused (D-174 Q-O6);
    * T-M3: Contact `:create`/`:seed` key the new email;
    * T-M4: Contact `:change_email` keys the old email, the new email and
      the new email's domain; OQ6 (ii) (D-174 Q-O2): to a suppressed address
      or to an address whose domain is suppressed, it is refused under those
      keys with a typed error and nothing written, in the suppression-first
      order (sequential, not a race);
    * T-M5: Lead `:seed` keys its account's `canonical_domain` as read from
      the database (section 4.4). The locked re-check's failing branch needs
      a rename between the pass and the account `FOR SHARE`, a race: it is
      RED-3 (T-I8, "vs Lead :seed");
    * T-M6: Lead `:reopen` is refused while another lead of the account is
      open (section 4.3 step 6), under the company key and before the
      transition.

  How keys are observed (no seam): a successful writer runs inside an
  `Audit.transaction` the test opens; the nested action joins that
  application scope, and the section 2.4 state query then shows the scope's
  `sdr.identity_pass` record (its token and exact id set), `require_held/2`
  of the writer's keys is `:ok` and a key outside the pass is
  `LateAcquisition`. A refused action fails its transaction, after which
  DBConnection refuses further statements in an enclosing one, so a refusal
  is observed through the traced pass statements: the published record
  (`set_config('sdr.identity_pass', $1, true)`, whose ids are the pass's
  keys) and any `pg_advisory_xact_lock($1::bigint)` (RED-1 T-A15), and
  through what was not executed. A key already held from an earlier
  sandbox scope gets no lock statement (section 2.4 rule 8), so the record
  is the observation of which keys were taken.
  Expected ids are the plan's `H` over the exact preimage bytes (`h/3`, as
  RED-1 T-A1), for the live tenant id.

  RED form: every case is behavioural except where noted: the writers exist
  on main, which publishes no pass, accepts a stale struct, a repeated
  `www.`, an email change to a suppressed address and a second open lead at
  an account. The record and refusal assertions come before any
  IdentityKeys call; `IdentityKeys` is guarded (`Code.ensure_loaded?/1`,
  `function_exported?/3`) before it is called through `apply/3`. The T-M6
  re-open without another open lead is a control.

  Interface names chosen here for review:
    * every refusal is `{:error, %Ash.Error.Invalid{}}` carrying an
      `Ash.Error.Changes.InvalidAttribute`: on `:domain` for the Account
      `:update` stale conflict ("typed `:conflict`") and the repeated
      `www.`; on `:email` for OQ6 (ii); the Lead `:reopen` open-lead
      refusal's field is not pinned (the plan names none); no refusal
      renders the refused or the keyed values;
    * the stale-struct conflict keys the struct's old domain and the new
      one (the old key input is the changeset's data, re-checked on the
      locked row), and requests no key for the row's current domain.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures

  @keys SdrAgent.Audit.IdentityKeys
  @scope_key {SdrAgent.Audit.IdentityKeys, :scope}
  @late SdrAgent.Audit.IdentityKeys.LateAcquisition

  # Section 2.3: "v1;<token>;<backend pid>;<id>,<id>,…".
  @record_format ~r/^v1;[0-9a-f]{32};\d+;(-?\d+(,-?\d+)*)?$/

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

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      seeder: system_actor(:seeder, tenant)
    }
  end

  describe "T-M1 Account :create and :seed" do
    test "T-M1 :create keys the new company domain in the caller's scope", ctx do
      t = ctx.tenant.id
      c = "m1-#{SalesFixtures.unique()}.test"

      assert {:ok, {{:ok, account}, observed}} =
               in_scope(t, [{:domain, c}], fn ->
                 Sales.create_account(account_attrs(c), actor: ctx.admin)
               end)

      assert_pass!(observed, [h(:domain, t, c)])
      assert to_string(account.domain) == c
    end

    test "T-M1 :create keys the stored company form of a www. and case variant", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      c = "m1w-#{n}.test"

      assert {:ok, {{:ok, account}, observed}} =
               in_scope(t, [{:domain, c}], fn ->
                 Sales.create_account(account_attrs("WWW.M1W-#{n}.Test"), actor: ctx.admin)
               end)

      assert_pass!(observed, [h(:domain, t, c)])
      assert to_string(account.domain) == c
    end

    test "T-M1 :seed keys the new company domain", ctx do
      t = ctx.tenant.id
      c = "m1s-#{SalesFixtures.unique()}.test"
      attrs = Map.put(account_attrs(c), :id, Ecto.UUID.generate())

      assert {:ok, {{:ok, _account}, observed}} =
               in_scope(t, [{:domain, c}], fn ->
                 Sales.seed_account(attrs, actor: ctx.seeder)
               end)

      assert_pass!(observed, [h(:domain, t, c)])
    end
  end

  describe "T-M2 Account :update" do
    test "T-M2 a domain change keys the old and the new domain", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      old = "m2-old-#{n}.test"
      new = "m2-new-#{n}.test"
      account = account!(ctx, old)

      assert {:ok, {{:ok, updated}, observed}} =
               in_scope(t, [{:domain, old}, {:domain, new}], fn ->
                 Sales.update(account, :update, %{domain: new}, actor: ctx.admin)
               end)

      assert_pass!(observed, [h(:domain, t, old), h(:domain, t, new)])
      assert to_string(updated.domain) == new
    end

    test "T-M2 a stale struct is a typed conflict: nothing written, no late key", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      first = "m2-first-#{n}.test"
      current = "m2-current-#{n}.test"
      target = "m2-target-#{n}.test"
      stale = account!(ctx, first)
      assert {:ok, _renamed} = Sales.update(stale, :update, %{domain: current}, actor: ctx.admin)
      updated = length(events_of_type(ctx.tenant, "sales.account.updated"))

      {result, queries} =
        trace_queries(fn -> Sales.update(stale, :update, %{domain: target}, actor: ctx.admin) end)

      assert_refused!(result, :domain, [first, current, target])
      assert to_string(reload!(ctx, stale).domain) == current
      assert length(events_of_type(ctx.tenant, "sales.account.updated")) == updated

      assert MapSet.new(lock_ids(queries)) ==
               MapSet.new([h(:domain, t, first), h(:domain, t, target)]),
             "C3-02: the conflict keys the struct's old and the new domain, and no other"

      refute Enum.any?(queries, &statement?(&1, :update, "accounts"))
    end

    test "T-M2 a repeated www. is refused without echoing it", ctx do
      n = SalesFixtures.unique()
      old = "m2-www-#{n}.test"
      canary = "c302canary#{n}"
      account = account!(ctx, old)
      updated = length(events_of_type(ctx.tenant, "sales.account.updated"))

      result =
        Sales.update(account, :update, %{domain: "www.www.#{canary}.test"}, actor: ctx.admin)

      assert_refused!(result, :domain, [canary])
      assert to_string(reload!(ctx, account).domain) == old
      assert length(events_of_type(ctx.tenant, "sales.account.updated")) == updated
    end
  end

  describe "T-M3 Contact :create and :seed" do
    test "T-M3 :create keys the new email", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      account = account!(ctx, "m3-#{n}.test")
      email = "jo.m3-#{n}@mail-m3-#{n}.example"

      assert {:ok, {{:ok, _contact}, observed}} =
               in_scope(t, [{:email, email}], fn ->
                 Sales.create_contact(contact_attrs(account, email), actor: ctx.admin)
               end)

      assert_pass!(observed, [h(:email, t, email)])
    end

    test "T-M3 :seed keys the new email", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      account = account!(ctx, "m3s-#{n}.test")
      email = "jo.m3s-#{n}@m3s-#{n}.test"
      attrs = Map.put(contact_attrs(account, email), :id, Ecto.UUID.generate())

      assert {:ok, {{:ok, _contact}, observed}} =
               in_scope(t, [{:email, email}], fn ->
                 Sales.seed_contact(attrs, actor: ctx.seeder)
               end)

      assert_pass!(observed, [h(:email, t, email)])
    end
  end

  describe "T-M4 Contact :change_email and OQ6 (ii)" do
    test "T-M4 :change_email keys the old email, the new email and the new email's domain", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      %{contact: contact, email: old} = contact!(ctx, "m4-#{n}")
      domain = "mail-m4-#{n}.example"
      new = "jo.m4-#{n}@#{domain}"
      keys = [{:email, old}, {:email, new}, {:domain, domain}]

      assert {:ok, {{:ok, changed}, observed}} =
               in_scope(t, keys, fn ->
                 Sales.update(contact, :change_email, %{email: new}, actor: ctx.admin)
               end)

      assert_pass!(observed, [h(:email, t, old), h(:email, t, new), h(:domain, t, domain)])
      assert to_string(changed.email) == new
    end

    test "T-M4 OQ6 (ii) a change to a suppressed address is refused under the keys", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      %{contact: contact, email: old} = contact!(ctx, "m4a-#{n}")
      domain = "mail-m4a-#{n}.example"
      new = "jo.m4a-#{n}@#{domain}"
      assert {:ok, _} = Outreach.suppress(%{scope: :email, value: new}, actor: ctx.admin)

      assert_change_refused!(ctx, contact, new, [
        h(:email, t, old),
        h(:email, t, new),
        h(:domain, t, domain)
      ])
    end

    test "T-M4 OQ6 (ii) a change to an address whose domain is suppressed is refused under the keys",
         ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      %{contact: contact, email: old} = contact!(ctx, "m4b-#{n}")
      domain = "mail-m4b-#{n}.example"
      new = "jo.m4b-#{n}@#{domain}"
      assert {:ok, _} = Outreach.suppress(%{scope: :domain, value: domain}, actor: ctx.admin)

      assert_change_refused!(ctx, contact, new, [
        h(:email, t, old),
        h(:email, t, new),
        h(:domain, t, domain)
      ])
    end
  end

  describe "T-M5 Lead :seed" do
    test "T-M5 :seed keys its account's canonical domain", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      c = "m5-#{n}.test"
      %{contact: contact} = contact!(ctx, "m5-#{n}", c)

      assert {:ok, {{:ok, _lead}, observed}} =
               in_scope(t, [{:domain, c}], fn -> seed_lead(ctx, contact) end)

      assert_pass!(observed, [h(:domain, t, c)])
    end

    test "T-M5 :seed keys the account's current domain as read from the database", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      before = "m5-before-#{n}.test"
      after_rename = "m5-after-#{n}.test"
      %{contact: contact, account: account} = contact!(ctx, "m5r-#{n}", before)

      assert {:ok, _renamed} =
               Sales.update(account, :update, %{domain: after_rename}, actor: ctx.admin)

      assert {:ok, {{:ok, _lead}, observed}} =
               Audit.transaction(fn ->
                 seeded = seed_lead(ctx, contact)
                 observed = observe(t, [{:domain, after_rename}])
                 stale = if keys_present?(), do: outcome(fn -> held(t, [{:domain, before}]) end)
                 {seeded, Map.put(observed, :stale, stale)}
               end)

      assert_pass!(observed, [h(:domain, t, after_rename)])

      assert observed.stale == {:raised, @late},
             "C3-02: the seed must not have keyed the account's former domain"
    end
  end

  describe "T-M6 Lead :reopen" do
    # Control: passes on main and must stay green (no other open lead).
    test "T-M6 (control) a disqualified lead reopens when no other lead of its account is open",
         ctx do
      %{lead: lead} = SalesFixtures.qualified_lead!(ctx.tenant, false)
      assert lead.status == :disqualified
      assert {:ok, %{status: :assigned}} = Sales.update(lead, :reopen, %{}, actor: ctx.admin)
    end

    test "T-M6 :reopen is refused while another lead of the account is open", ctx do
      t = ctx.tenant.id
      %{lead: lead} = SalesFixtures.qualified_lead!(ctx.tenant, false)
      assert lead.status == :disqualified
      assert {:ok, account} = Sales.fetch(Sales.Account, lead.account_id, actor: ctx.admin)
      company = to_string(account.domain)
      other = SalesFixtures.contact!(ctx.tenant, account)
      assert {:ok, %{status: :new}} = seed_lead(ctx, other)
      reopened = length(events_of_type(ctx.tenant, "sales.lead.reopened"))

      {result, queries} =
        trace_queries(fn -> Sales.update(lead, :reopen, %{}, actor: ctx.admin) end)

      assert_refused!(result, nil, [company])
      assert reload!(ctx, lead).status == :disqualified
      assert length(events_of_type(ctx.tenant, "sales.lead.reopened")) == reopened

      assert h(:domain, t, company) in lock_ids(queries),
             "C3-02: the refusal must be made under the company key"

      refute Enum.any?(queries, &statement?(&1, :update, "leads")),
             "C3-02: the open-lead refusal precedes the transition (section 4.3 step 6)"
    end
  end

  ## Key observation

  # Runs `writer` inside an application scope the test opens and reads the
  # scope's pass after it returned.
  defp in_scope(tenant_id, keys, writer) do
    Audit.transaction(fn -> {writer.(), observe(tenant_id, keys)} end)
  end

  # The IdentityKeys calls run only when the module is present; their results
  # are asserted after the record, behind `guard_keys!/0`.
  defp observe(tenant_id, keys) do
    present? = keys_present?()

    %{
      record: record(),
      scope: Process.get(@scope_key),
      held: if(present?, do: outcome(fn -> held(tenant_id, keys) end)),
      late: if(present?, do: outcome(fn -> held(tenant_id, [unrelated_key()]) end))
    }
  end

  defp assert_pass!(observed, expected) do
    assert observed.record,
           "C3-02: the writer published no identity pass in the enclosing application scope"

    assert observed.record.ids == MapSet.new(expected),
           "C3-02: the pass must hold exactly the writer's keys"

    assert match?(%{token: _}, observed.scope) and observed.scope.token == observed.record.token,
           "C3-02: the pass must belong to the enclosing scope"

    guard_keys!()
    assert observed.held == :ok, "C3-02: require_held/2 of the writer's keys must be :ok"

    assert observed.late == {:raised, @late},
           "C3-02: a key outside the pass must raise LateAcquisition"
  end

  defp assert_change_refused!(ctx, contact, new, expected_ids) do
    changed = length(events_of_type(ctx.tenant, "sales.contact.email_changed"))
    old = to_string(contact.email)

    {result, queries} =
      trace_queries(fn ->
        Sales.update(contact, :change_email, %{email: new}, actor: ctx.admin)
      end)

    assert_refused!(result, :email, [new, old])
    assert to_string(reload!(ctx, contact).email) == old
    assert length(events_of_type(ctx.tenant, "sales.contact.email_changed")) == changed

    assert MapSet.new(lock_ids(queries)) == MapSet.new(expected_ids),
           "C3-02: the refusal must be made under the old, the new and the new domain's keys"

    refute Enum.any?(queries, &statement?(&1, :update, "contacts"))
  end

  defp unrelated_key, do: {:domain, "c302-unrelated-#{SalesFixtures.unique()}.test"}

  # Every id keyed by the traced statements: the ids of each published pass
  # record (section 2.3; a key already held from an earlier sandbox scope,
  # such as the old domain from the account's create, is in the record
  # without a lock statement, section 2.4 rule 8), plus each lock
  # statement's single integer parameter.
  defp lock_ids(queries) do
    published = for query <- queries, publication?(query), id <- record_ids(query), do: id

    locked =
      for {sql, params} = query <- queries, advisory_lock?(query), param <- params do
        assert sql =~ ~r/pg_advisory_xact_lock\(\$1::bigint\)/
        param
      end

    Enum.uniq(published ++ locked)
  end

  defp record_ids({_sql, [record]}) do
    assert record =~ @record_format, "C3-02: the published record is not v1"
    [_version, _token, _pid, ids] = String.split(record, ";")
    MapSet.to_list(parse_ids(ids))
  end

  defp advisory_lock?({sql, _params}), do: sql =~ "pg_advisory_xact_lock"
  defp publication?({sql, _params}), do: sql =~ ~r/set_config\(\s*'sdr\.identity_pass'/

  defp statement?({sql, _params}, :update, table), do: sql =~ ~r/^\s*UPDATE "#{table}"/

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp keys_present? do
    Code.ensure_loaded?(@keys) and function_exported?(@keys, :require_held, 2) and
      function_exported?(@keys, :pass, 2)
  end

  defp guard_keys! do
    present!(@keys, :pass, 2)
    present!(@keys, :require_held, 2)

    assert Code.ensure_loaded?(@late) and function_exported?(@late, :exception, 1),
           "C3-02: exception #{inspect(@late)} is not defined"
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp held(tenant_id, keys), do: call(@keys, :require_held, [tenant_id, keys])

  # The plan's H (section 2.7), over the exact preimage bytes.
  defp h(kind, tenant_id, bytes) do
    <<id::signed-64, _rest::binary>> =
      :crypto.hash(
        :sha256,
        "sdr-identity-key/1\0" <> Atom.to_string(kind) <> "\0" <> tenant_id <> "\0" <> bytes
      )

    id
  end

  ## Database state

  defp record do
    %{rows: [[setting, _pid, _ids]]} = Repo.query!(@state_sql)

    case setting do
      value when value in [nil, ""] ->
        nil

      value ->
        assert value =~ @record_format, "C3-02: sdr.identity_pass is not a v1 record"
        [_version, token, pid, ids] = String.split(value, ";")
        %{token: token, pid: String.to_integer(pid), ids: parse_ids(ids)}
    end
  end

  defp parse_ids(""), do: MapSet.new()
  defp parse_ids(ids), do: ids |> String.split(",") |> MapSet.new(&String.to_integer/1)

  defp trace_queries(fun) do
    parent = self()
    handler = "c3-02-identity-writers-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent do
            send(
              parent,
              {:c302_query, IO.iodata_to_binary(metadata.query), metadata[:params] || []}
            )
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:c302_query, sql, params} -> drain_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## Builders (main's APIs and the seed boundary)

  defp account_attrs(domain), do: SalesFixtures.account_attrs(%{domain: domain})

  defp contact_attrs(account, email),
    do: SalesFixtures.contact_attrs(account, %{email: email})

  defp account!(ctx, domain) do
    assert {:ok, account} = Sales.create_account(account_attrs(domain), actor: ctx.admin)
    account
  end

  # A contact `jo.<label>@<domain>` at a new account with `domain`.
  defp contact!(ctx, label, domain \\ nil) do
    domain = domain || "#{label}.test"
    account = account!(ctx, domain)
    email = "jo.#{label}@#{domain}"
    assert {:ok, contact} = Sales.create_contact(contact_attrs(account, email), actor: ctx.admin)
    %{account: account, contact: contact, email: email}
  end

  # The dev/test :seed boundary (Lead :create is admission-only after G5).
  defp seed_lead(ctx, contact) do
    Sales.seed_lead(
      %{
        id: Ecto.UUID.generate(),
        contact_id: contact.id,
        account_id: contact.account_id,
        source: :fixture
      },
      actor: ctx.seeder
    )
  end

  defp reload!(ctx, %resource{id: id}) do
    assert {:ok, record} = Sales.fetch(resource, id, actor: ctx.admin)
    record
  end

  ## Outcomes

  defp assert_refused!(result, field, values) do
    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "C3-02: expected a typed refusal, got #{inspect(result, limit: 4)}"

    {:error, error} = result
    attributes = for %Ash.Error.Changes.InvalidAttribute{} = e <- error.errors, do: e
    assert attributes != [], "C3-02: the refusal must be an InvalidAttribute"

    if field do
      assert field in Enum.map(attributes, & &1.field),
             "C3-02: the refusal must name #{inspect(field)}"
    end

    for value <- values do
      refute rendered(error) =~ value, "C3-02: the refusal must not echo the value"
    end
  end

  defp outcome(fun) do
    case fun.() do
      :ok -> :ok
      other -> {:returned, other}
    end
  rescue
    error -> {:raised, error.__struct__}
  end

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)
end
