defmodule SdrAgent.SDR.AdmissionDomainPathTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 D (T-D4, T-D5; T-D1..T-D3 and T-D6 are
  RED-1, in `sales/domain_test.exs`): the section 2.7 domain
  representations along the full admission path.

    * T-D4: the admission's company key, the nested Account `:create` and
      Lead `:create` `require_held` keys and a later Account `:update`'s
      old key are one id, `H("domain", tenant, c)`, with no
      `LateAcquisition`; the instrumented key seam shows the exact bytes
      `H` receives, stripped exactly once (raw `www.www.<c>` gives
      `www.<c>`, raw `www.test` gives `test`).
    * T-D5: `WWW.<C>.Test.` is stored as `<c>`, byte-equal to the hashed
      `company.domain`; a replay with `<c>` is a replay; a legacy
      stored-form `www.<c>` row is found and reused.

  Domains are unique per test (`acme-c302-<n>.test`, not the plan's
  literal `acme.test`): `Audit.bootstrap` returns the one singleton tenant,
  whose accounts table may hold committed rows of the [P] suites or the
  demo seed, so a literal domain would dedupe against them. The literal
  `acme.test`, `www.www.acme.test` and `www.test` vectors stay pinned
  DB-free through `IdentityKeys.id/3` for RED-1's fixed tenant uuid.

  RED form: every absent subject (`SDR.admit_lead/2`,
  `SDR.bootstrap_definitions/1`, `IdentityKeys.id/3`, the key seam, the
  `LeadAdmission` resource and its attributes) is guarded first and called
  through `apply/3`, so each test fails at a `C3-02:` assertion. Setup uses
  main's APIs only.

  Interface names chosen here for review:
    * the test-build key seam
      `SdrAgent.Audit.IdentityKeys.TestFaults.record_preimages/1`:
      `record_preimages(fun)` runs `fun` and returns `{result, records}`,
      `records` being every `H` computation made in this process during
      `fun`, in order, as `{op, kind, tenant_id, bytes}` with `op` the
      IdentityKeys entry that computed it (`:pass`, `:require_held` or
      `:id`), `kind` the key kind atom and `bytes` the exact preimage;
      compiled into test-seam builds only, as `with_fault/2` (RED-1);
    * `LeadAdmission` attributes `account_id`, `account_created` and
      `input_sha256` (lowercase hex), from packet section 3;
    * the admission input map and result shape of the shared RED-2 brief.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Account
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SettingsFixtures

  @sdr SdrAgent.SDR
  @keys SdrAgent.Audit.IdentityKeys
  @faults SdrAgent.Audit.IdentityKeys.TestFaults
  @admission SdrAgent.Sales.LeadAdmission
  @late SdrAgent.Audit.IdentityKeys.LateAcquisition

  @ops [:pass, :require_held, :id]
  @kinds [:domain, :email, :"admission-ref", :"reply-message"]

  # RED-1's fixed synthetic tenant and its independently computed ids
  # (`identity_keys_test.exs` T-A1: `shasum -a 256` over
  # "sdr-identity-key/1\0" <> kind <> "\0" <> tenant <> "\0" <> bytes).
  @tenant "00000000-0000-4000-8000-00000000c302"
  @pinned [
    # {raw domain key input, exact H preimage, signed id}
    {"acme.test", "acme.test", 5_030_586_291_530_585_766},
    {"www.www.acme.test", "www.acme.test", -4_314_510_134_007_135_717},
    {"www.test", "test", 1_159_817_370_203_734_342}
  ]

  setup do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    campaign = SalesFixtures.active_campaign!(tenant)
    SettingsFixtures.save_offering!(admin)
    %{tenant: tenant, admin: admin, campaign: campaign}
  end

  describe "T-D4 one company key along the admission path" do
    test "T-D4 the admission pass id is the nested Account :create, Lead :create and Account :update old-key id",
         ctx do
      guard_admission!()
      guard_seam!()
      pinned_literals!()
      definitions!(ctx.tenant)
      tenant_id = ctx.tenant.id
      n = SalesFixtures.unique()
      c = "acme-c302-#{n}.test"
      expected = h(:domain, tenant_id, c)
      assert key_id(tenant_id, :domain, c) == expected

      {result, records} =
        record_preimages(fn -> attempt(fn -> admit(ctx, input(ctx, c, "jo.#{n}@#{c}")) end) end)

      refute match?({:raised, @late}, result),
             "C3-02: a nested require_held raised LateAcquisition: its key differs from the pass"

      %{admission: admission, lead: lead} = admitted!(result)

      pass = domain_bytes(records, :pass, tenant_id)
      held = domain_bytes(records, :require_held, tenant_id)
      assert pass != [], "C3-02: the admission pass took no domain key"

      assert Enum.uniq(pass) == [c],
             "C3-02: every domain key of the pass must be H over the company's c"

      assert length(held) >= 2,
             "C3-02: nested Account :create and Lead :create must require_held the company key"

      assert Enum.uniq(held) == [c],
             "C3-02: the nested require_held keys must be H over the same c as the pass"

      assert Enum.uniq(for(bytes <- pass ++ held, do: h(:domain, tenant_id, bytes))) == [expected]
      assert lead.account_id == admission.account_id

      account = reread!(ctx.admin, admission.account_id)
      renamed = "renamed-c302-#{n}.test"

      {outcome, update_records} =
        record_preimages(fn ->
          attempt(fn ->
            Audit.transaction(fn ->
              {Sales.update(account, :update, %{domain: renamed}, actor: ctx.admin),
               pass_record_ids()}
            end)
          end)
        end)

      assert match?({:ok, {{:ok, _account}, _ids}}, outcome),
             "C3-02: Account :update with a domain change failed: #{inspect(outcome)}"

      {:ok, {{:ok, _account}, pass_ids}} = outcome
      update_pass = domain_bytes(update_records, :pass, tenant_id)

      assert Enum.sort(Enum.uniq(update_pass)) == Enum.sort([c, renamed]),
             "C3-02: Account :update must key the stored canonical_domain (old) and the new domain"

      assert is_struct(pass_ids, MapSet), "C3-02: no v1 sdr.identity_pass record after the update"

      assert expected in pass_ids,
             "C3-02: the Account :update old-key id must equal the admission's company key id"

      assert h(:domain, tenant_id, renamed) in pass_ids
    end

    test "T-D4 the key seam records H preimages stripped exactly once (www.www. and www.test)",
         ctx do
      guard_admission!()
      guard_seam!()
      pinned_literals!()
      definitions!(ctx.tenant)
      tenant_id = ctx.tenant.id
      n = SalesFixtures.unique()
      host = "acme-c302-#{n}.test"

      # {company c, email, raw email-domain input, its one-strip preimage,
      #  bytes that must never reach H for it}
      vectors = [
        {"co-c302-#{n}.test", "jo.#{n}@www.www.#{host}", "www.www.#{host}", "www.#{host}",
         ["www.www.#{host}", host]},
        {"beta-c302-#{n}.test", "jo.#{n}@www.test", "www.test", "test", ["www.test"]}
      ]

      for {company, email, raw, preimage, never} <- vectors do
        {result, records} =
          record_preimages(fn -> attempt(fn -> admit(ctx, input(ctx, company, email)) end) end)

        admitted!(result)
        domains = domain_bytes(records, :pass, tenant_id)

        assert Enum.sort(Enum.uniq(domains)) == Enum.sort([company, preimage]),
               "C3-02: email domain #{raw}: the H preimage must be #{preimage} (stripped once)"

        for bytes <- never do
          refute bytes in domains, "C3-02: #{inspect(bytes)} reached H for raw #{raw}"
        end

        assert key_id(tenant_id, :domain, raw) == h(:domain, tenant_id, preimage)

        assert Enum.uniq(for {:pass, :email, ^tenant_id, bytes} <- records, do: bytes) == [email],
               "C3-02: the email key's H preimage is the normalized address, unstripped"
      end
    end
  end

  describe "T-D5 stored company domain, replay and legacy lookup" do
    test "T-D5 WWW.<C>.Test. is stored as <c>, byte-equal to the hashed company.domain; a replay with <c> replays",
         ctx do
      guard_admission!()
      definitions!(ctx.tenant)
      n = SalesFixtures.unique()
      c = "acme-c302-#{n}.test"
      ref = "manual:#{Ecto.UUID.generate()}"
      email = "jo.#{n}@#{c}"
      first_input = input(ctx, "WWW.Acme-C302-#{n}.Test.", email, %{source_ref: ref})

      %{admission: admission} = admitted!(admit(ctx, first_input))
      assert admission.account_created == true
      stored = to_string(reread!(ctx.admin, admission.account_id).domain)

      assert stored == c, "C3-02: the account must store company(raw) = #{c}"

      assert admission.input_sha256 == input_sha256(ctx, first_input, stored),
             "C3-02: the hashed company.domain must be the stored bytes"

      accounts_before = account_ids(ctx.admin)
      replay = admit(ctx, %{first_input | company: %{first_input.company | domain: c}})

      assert match?({:ok, %{replayed?: true, outcome: :admitted}}, replay),
             "C3-02: the same ref with the canonical domain must replay: #{inspect(replay)}"

      {:ok, %{admission: replayed}} = replay
      assert replayed.id == admission.id
      assert account_ids(ctx.admin) == accounts_before
      assert admissions_for(ref) == 1
    end

    test "T-D5 a legacy stored-form www. row is found by the canonical admission domain and reused",
         ctx do
      guard_admission!()
      definitions!(ctx.tenant)
      n = SalesFixtures.unique()
      c = "orbit-c302-#{n}.example.org"
      legacy = legacy_account!(ctx.tenant, ctx.admin, "www." <> c)
      accounts_before = account_ids(ctx.admin)

      %{admission: admission, lead: lead} = admitted!(admit(ctx, input(ctx, c, "jo.#{n}@#{c}")))

      assert admission.account_id == legacy.id,
             "C3-02: the admission must find the legacy row by sdr_canonical_domain"

      assert admission.account_created == false
      assert lead.account_id == legacy.id
      assert account_ids(ctx.admin) == accounts_before
      assert to_string(reread!(ctx.admin, legacy.id).domain) == "www." <> c
    end
  end

  ## Guards and calls

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

  defp guard_admission! do
    present!(@sdr, :bootstrap_definitions, 1)
    present!(@sdr, :admit_lead, 2)
    assert Code.ensure_loaded?(@admission), "C3-02: #{inspect(@admission)} is not available"

    for attribute <- [:account_id, :account_created, :input_sha256] do
      assert Ash.Resource.Info.attribute(@admission, attribute),
             "C3-02: LeadAdmission attribute #{inspect(attribute)} is not defined"
    end
  end

  defp guard_seam! do
    present!(@keys, :id, 3)
    present!(@faults, :record_preimages, 1)
  end

  defp definitions!(tenant) do
    result = call(@sdr, :bootstrap_definitions, [tenant.id])

    assert match?({:ok, _definition}, result),
           "C3-02: bootstrap_definitions/1 must return the committed definition"
  end

  defp admit(ctx, input), do: call(@sdr, :admit_lead, [input, [actor: ctx.admin]])

  defp admitted!(result) do
    assert match?({:ok, %{outcome: :admitted, replayed?: false}}, result),
           "C3-02: the admission must be admitted: #{inspect(result)}"

    {:ok, admitted} = result
    admitted
  end

  defp key_id(tenant_id, kind, raw), do: call(@keys, :id, [tenant_id, kind, raw])

  defp record_preimages(fun) do
    recorded = call(@faults, :record_preimages, [fun])

    assert match?({_result, records} when is_list(records), recorded),
           "C3-02: record_preimages/1 must return {result, records}"

    {_result, records} = recorded

    assert Enum.all?(records, &record?/1),
           "C3-02: every record is {op, kind, tenant_id, bytes}: #{inspect(records)}"

    recorded
  end

  defp record?({op, kind, tenant_id, bytes}),
    do: op in @ops and kind in @kinds and is_binary(tenant_id) and is_binary(bytes)

  defp record?(_other), do: false

  defp domain_bytes(records, op, tenant_id),
    do: for({^op, :domain, ^tenant_id, bytes} <- records, do: bytes)

  defp pinned_literals! do
    for {raw, preimage, expected} <- @pinned do
      assert h(:domain, @tenant, preimage) == expected

      assert key_id(@tenant, :domain, raw) == expected,
             "C3-02: id(:domain, #{inspect(raw)}) must be H over #{inspect(preimage)}"
    end
  end

  # Raises other than assertion failures become `{:raised, module}`.
  defp attempt(fun) do
    fun.()
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> {:raised, error.__struct__}
  end

  ## The plan's H, over the exact bytes (independent of IdentityKeys)

  defp h(kind, tenant, bytes) do
    <<id::signed-64, _rest::binary>> =
      :crypto.hash(
        :sha256,
        "sdr-identity-key/1\0" <> Atom.to_string(kind) <> "\0" <> tenant <> "\0" <> bytes
      )

    id
  end

  # The ids of this transaction's v1 `sdr.identity_pass` record (section 2.3).
  defp pass_record_ids do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('sdr.identity_pass', true)")
    parse_record(value)
  end

  defp parse_record(value) when value in [nil, ""], do: :no_record

  defp parse_record(value) do
    case String.split(value, ";") do
      ["v1", _token, _pid, ""] -> MapSet.new()
      ["v1", _token, _pid, ids] -> ids |> String.split(",") |> MapSet.new(&String.to_integer/1)
      _other -> :unparseable
    end
  end

  ## Inputs and the section 5.2 hash

  defp input(ctx, domain, email, overrides \\ %{}) do
    Map.merge(
      %{
        source_kind: :manual,
        source_ref: "manual:#{Ecto.UUID.generate()}",
        campaign_id: ctx.campaign.id,
        company: %{domain: domain, name: "Acme C302 #{SalesFixtures.unique()}"},
        person: %{
          email: email,
          first_name: "Jo",
          last_name: "Doe",
          title: "VP Operations",
          timezone: "America/Denver"
        }
      },
      overrides
    )
  end

  # Packet section 5.2, version 1, with `company.domain` set to `domain`.
  # Every input value above is already in normalized form.
  defp input_sha256(ctx, input, domain) do
    doc = %{
      "v" => "c3-admission-input/1",
      "tenant_id" => ctx.tenant.id,
      "campaign_id" => input.campaign_id,
      "source_kind" => Atom.to_string(input.source_kind),
      "source_ref" => input.source_ref,
      "readmit" => false,
      "agent_run_id" => nil,
      "original_lead_id" => nil,
      "company" => %{
        "domain" => domain,
        "name" => input.company.name,
        "website_url" => nil,
        "industry" => nil,
        "employee_count" => nil,
        "geography" => nil
      },
      "person" => Map.new(input.person, fn {key, value} -> {Atom.to_string(key), value} end)
    }

    hex(Canonical.sha256(doc))
  end

  ## Rows

  # A row in its stored legacy form, as it exists before C3-02 (plan section
  # 2.7; RED-1 `domain_test.exs`): inserted directly, because C3-02's
  # `:create` stores company(raw).
  defp legacy_account!(tenant, admin, stored_domain) do
    id = Ecto.UUID.generate()

    tamper!(
      """
      INSERT INTO accounts
        (id, tenant_id, name, domain, source, status, trace_id, span_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'manual', 'active', $5, $6, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(tenant.id),
        "Legacy Orbit #{SalesFixtures.unique()}",
        stored_domain,
        hex(:crypto.strong_rand_bytes(16)),
        hex(:crypto.strong_rand_bytes(8))
      ]
    )

    reread!(admin, id)
  end

  defp reread!(admin, id) do
    assert {:ok, account} = GuardedCall.get(Account, id, actor: admin)
    account
  end

  defp account_ids(admin) do
    assert {:ok, accounts} = GuardedCall.list(Account, actor: admin)
    accounts |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp admissions_for(ref) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM lead_admissions WHERE source_ref = $1", [ref])

    count
  end
end
