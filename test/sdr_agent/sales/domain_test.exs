defmodule SdrAgent.Sales.DomainTest do
  @moduledoc """
  C3-02 RED-1, plan r8 section 11 D (T-D1..T-D3 and T-D6; T-D4 and T-D5
  are RED-2, in `sdr/admission_domain_path_test.exs`): the three domain
  representations of section 2.7, `IdentityKeys.Normalize.strip/1` (the
  key and index form, character for character the SQL
  `sdr_canonical_domain`), `Normalize.company/1` (company identity, a
  valid fixed point; `Sales.Domain.canonical/1`) and `Normalize.key_value/2`
  (representation only), the Account `canonical_domain` calculation over
  legacy rows, and content-free refusals.

  RED form: every absent subject (module, function, SQL function,
  calculation) is guarded before use and called through `apply/3`, so each
  test fails at a `C3-02:` assertion. The Account `:create` refusal in T-D6
  is behavioural: main accepts a repeated `www.`.

  The corpus avoids non-ASCII input that needs case folding, because SQL
  `lower/1` depends on the database's LC_CTYPE while Elixir's does not;
  non-ASCII cases are already lowercase.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Account
  alias SdrAgent.SalesFixtures
  alias SdrAgent.Telemetry.InMemoryExporter

  @normalize SdrAgent.Audit.IdentityKeys.Normalize
  @domain SdrAgent.Sales.Domain
  @keys SdrAgent.Audit.IdentityKeys
  @invalid_key SdrAgent.Audit.IdentityKeys.InvalidKeyValue

  @label63 String.duplicate("a", 63)
  @max_host "#{@label63}.#{@label63}.#{@label63}.#{String.duplicate("d", 61)}"
  @long_host @max_host <> "d"

  # {raw, strip(raw) = SQL sdr_canonical_domain(raw), company(raw)}
  # strip = lower(btrim(x)), then one trailing ".", then one leading "www."
  # (btrim without a character list trims spaces only).
  @corpus [
    {"acme.test", "acme.test", {:ok, "acme.test"}},
    {"ACME.Test", "acme.test", {:ok, "acme.test"}},
    {"  acme.test  ", "acme.test", {:ok, "acme.test"}},
    {"acme.test.", "acme.test", {:ok, "acme.test"}},
    {"acme.test. ", "acme.test", {:ok, "acme.test"}},
    {"www.acme.test", "acme.test", {:ok, "acme.test"}},
    {"WWW.Acme.Test.", "acme.test", {:ok, "acme.test"}},
    {"www.x.test", "x.test", {:ok, "x.test"}},
    {"sales.acme.test", "sales.acme.test", {:ok, "sales.acme.test"}},
    {"xn--bcher-kva.test", "xn--bcher-kva.test", {:ok, "xn--bcher-kva.test"}},
    {@max_host, @max_host, {:ok, @max_host}},
    # repeated www.: stripped exactly once, refused as company identity
    {"www.www.acme.test", "www.acme.test", {:error, :invalid_domain}},
    {" WWW.WWW.Acme.Test. ", "www.acme.test", {:error, :invalid_domain}},
    {"www.www.www.acme.test", "www.www.acme.test", {:error, :invalid_domain}},
    {"www.www.x.test", "www.x.test", {:error, :invalid_domain}},
    # www. alone, and fewer than two labels after the strip
    {"www.", "www", {:error, :invalid_domain}},
    {"www", "www", {:error, :invalid_domain}},
    {"www.test", "test", {:error, :invalid_domain}},
    {"WWW.test", "test", {:error, :invalid_domain}},
    {"acme", "acme", {:error, :invalid_domain}},
    # trailing dots, consecutive dots, empty labels
    {"acme.test..", "acme.test.", {:error, :invalid_domain}},
    {"acme..test", "acme..test", {:error, :invalid_domain}},
    {"www..acme.test", ".acme.test", {:error, :invalid_domain}},
    {".acme.test", ".acme.test", {:error, :invalid_domain}},
    {".", "", {:error, :invalid_domain}},
    {"", "", {:error, :invalid_domain}},
    {"   ", "", {:error, :invalid_domain}},
    # whitespace other than spaces is not trimmed by SQL btrim
    {"\tacme.test", "\tacme.test", {:error, :invalid_domain}},
    {"acme .test", "acme .test", {:error, :invalid_domain}},
    # labels and length
    {"-acme.test", "-acme.test", {:error, :invalid_domain}},
    {"acme-.test", "acme-.test", {:error, :invalid_domain}},
    {"#{@label63}a.test", "#{@label63}a.test", {:error, :invalid_domain}},
    {@long_host, @long_host, {:error, :invalid_domain}},
    # URL, port, path, address, non-ASCII
    {"https://acme.test", "https://acme.test", {:error, :invalid_domain}},
    {"acme.test:443", "acme.test:443", {:error, :invalid_domain}},
    {"acme.test/path", "acme.test/path", {:error, :invalid_domain}},
    {"a@acme.test", "a@acme.test", {:error, :invalid_domain}},
    {"bücher.test", "bücher.test", {:error, :invalid_domain}},
    {"www.bücher.test", "bücher.test", {:error, :invalid_domain}}
  ]

  describe "T-D1 corpus" do
    test "T-D1 Elixir strip/1 over the corpus" do
      present!(@normalize, :strip, 1)

      for {raw, expected, _company} <- @corpus do
        assert call(@normalize, :strip, [raw]) == expected, "C3-02: strip(#{inspect(raw)})"
      end
    end

    test "T-D1 SQL sdr_canonical_domain/1 over the corpus" do
      assert sql_canonical_function?(),
             "C3-02: SQL function sdr_canonical_domain(text) is not defined"

      for {raw, expected, _company} <- @corpus do
        assert %{rows: [[actual]]} = Repo.query!("SELECT sdr_canonical_domain($1)", [raw])
        assert actual == expected, "C3-02: sdr_canonical_domain(#{inspect(raw)})"
      end
    end

    test "T-D1 company/1 over the corpus; every accepted value is a fixed point" do
      present!(@normalize, :strip, 1)
      present!(@normalize, :company, 1)

      for {raw, _strip, expected} <- @corpus do
        assert call(@normalize, :company, [raw]) == expected, "C3-02: company(#{inspect(raw)})"
      end

      for {_raw, _strip, {:ok, c}} <- @corpus do
        assert call(@normalize, :strip, [c]) == c
        assert call(@normalize, :company, [c]) == {:ok, c}
      end
    end

    test "T-D1 Sales.Domain.canonical/1 is company/1" do
      present!(@normalize, :company, 1)
      present!(@domain, :canonical, 1)

      for {raw, _strip, _company} <- @corpus do
        assert call(@domain, :canonical, [raw]) == call(@normalize, :company, [raw])
      end
    end
  end

  describe "T-D2 and T-D3 legacy rows" do
    test "T-D2 a legacy www. row dedupes; a subdomain does not" do
      guard_canonical!()
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      c = "orbit-#{SalesFixtures.unique()}.example.org"
      legacy = legacy_account!(tenant, admin, "www." <> c)

      assert lookup(admin, c) == [legacy.id]
      assert lookup(admin, "sales." <> c) == []

      legacy_hash = RecordHash.hex(legacy)
      ids_before = account_ids(admin)

      # The supported typed uniqueness refusal of an Ash create (AshPostgres
      # maps a registered unique index to InvalidAttribute with
      # `constraint_type: :unique`); the plan names the index, the unique
      # `(tenant_id, sdr_canonical_domain(domain))` expression index, not a
      # new error surface. Called directly: any other exception fails here.
      duplicate = Sales.create_account(attrs(c), actor: admin)
      assert_unique_domain_refusal!(duplicate, c)

      assert account_ids(admin) == ids_before
      assert lookup(admin, c) == [legacy.id]
      legacy_now = reread!(admin, legacy)
      assert to_string(legacy_now.domain) == "www." <> c
      assert RecordHash.hex(legacy_now) == legacy_hash

      assert {:ok, subdomain} = Sales.create_account(attrs("sales." <> c), actor: admin)
      assert lookup(admin, "sales." <> c) == [subdomain.id]
      assert lookup(admin, c) == [legacy.id]
    end

    test "T-D3 old rows keep their stored domain and record_sha256" do
      guard_canonical!()
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      n = SalesFixtures.unique()
      c = "orbit-#{n}.example.org"
      legacy = legacy_account!(tenant, admin, "www." <> c)
      legacy_hash = RecordHash.hex(legacy)

      assert {:ok, plain} = Sales.create_account(attrs("plain-#{n}.example.org"), actor: admin)
      plain_hash = created_record_sha256(tenant, plain)

      loaded = Ash.load!([legacy, plain], :canonical_domain, actor: admin)
      assert Enum.map(loaded, &to_string(&1.canonical_domain)) == [c, "plain-#{n}.example.org"]
      assert lookup(admin, c) == [legacy.id]
      _refused = attempt(fn -> Sales.create_account(attrs(c), actor: admin) end)

      legacy_now = reread!(admin, legacy)
      plain_now = reread!(admin, plain)
      assert to_string(legacy_now.domain) == "www." <> c
      assert RecordHash.hex(legacy_now) == legacy_hash
      assert RecordHash.hex(plain_now) == plain_hash
    end
  end

  describe "T-D6 content-free refusals" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      InMemoryExporter.reset()

      on_exit(fn ->
        Logger.configure(level: level)
        InMemoryExporter.reset()
      end)

      :ok
    end

    test "T-D6 company/1 and Sales.Domain.canonical/1 refuse with a fixed, value-free error" do
      present!(@normalize, :company, 1)
      present!(@domain, :canonical, 1)
      canary = canary()

      for raw <- refused_company_inputs(canary) do
        log =
          capture_log([level: :debug], fn ->
            assert call(@normalize, :company, [raw]) == {:error, :invalid_domain}
            assert call(@domain, :canonical, [raw]) == {:error, :invalid_domain}
          end)

        refute log =~ canary
      end

      refute rendered_spans() =~ canary
    end

    test "T-D6 key_value/2 raises InvalidKeyValue carrying the kind only" do
      present!(@normalize, :key_value, 2)
      assert Code.ensure_loaded?(@invalid_key), "C3-02: #{inspect(@invalid_key)} is not defined"
      canary = canary()

      inputs = [
        {:email, "no-at-sign-#{canary}.test"},
        {:email, "a@b@#{canary}.test"},
        {:email, "@#{canary}.test"},
        {:email, "jo #{canary}@x.test"},
        {:domain, "jo@#{canary}.test"},
        {:domain, "#{canary} x.test"},
        {:domain, "#{canary}\u0000.test"},
        {:domain, ""}
      ]

      log =
        capture_log([level: :debug], fn ->
          for {kind, raw} <- inputs do
            error = raised(fn -> call(@normalize, :key_value, [kind, raw]) end)
            assert error.__struct__ == @invalid_key
            assert rendered(error) =~ Atom.to_string(kind)
            refute rendered(error) =~ canary, "C3-02: InvalidKeyValue must not echo the value"
          end
        end)

      refute log =~ canary
      refute rendered_spans() =~ canary
    end

    test "T-D6 an invalid key value inside a pass leaves no value in the error, logs or spans" do
      present!(@keys, :pass, 2)
      canary = canary()
      tenant_id = Ecto.UUID.generate()

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, error} =
                   Repo.transaction(fn ->
                     raised(fn ->
                       call(@keys, :pass, [tenant_id, [{:email, "no-at-sign-#{canary}.test"}]])
                     end)
                   end)

          assert error.__struct__ == @invalid_key
          refute rendered(error) =~ canary
        end)

      refute log =~ canary
      refute rendered_spans() =~ canary
    end

    # Behavioural RED: main's Account :create exists and accepts a repeated www.
    test "T-D6 Account :create refuses a company-invalid domain without echoing it" do
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      canary = canary()

      for raw <- ["www.www.#{canary}.test", "www.#{canary}", "#{canary}.test.."] do
        log =
          capture_log([level: :debug], fn ->
            result = Sales.create_account(attrs(raw), actor: admin)
            assert match?({:error, %Ash.Error.Invalid{}}, result), "C3-02: #{raw} must be refused"
            {:error, error} = result
            assert Enum.any?(error.errors, &(Map.get(&1, :field) == :domain))
            refute rendered(error) =~ canary, "C3-02: the refusal must not echo the domain"
          end)

        refute log =~ canary
      end

      refute rendered_spans() =~ canary
      assert lookup_raw(admin, canary) == []
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

  defp guard_canonical! do
    assert Ash.Resource.Info.calculation(Account, :canonical_domain),
           "C3-02: the Account calculation :canonical_domain is not defined"

    assert sql_canonical_function?(),
           "C3-02: SQL function sdr_canonical_domain(text) is not defined"
  end

  defp sql_canonical_function? do
    %{rows: [[present?]]} =
      Repo.query!("SELECT to_regprocedure('sdr_canonical_domain(text)') IS NOT NULL")

    present?
  end

  ## Accounts

  defp attrs(domain), do: SalesFixtures.account_attrs(%{domain: domain})

  # A row in its stored legacy form, as it exists before C3-02 (plan section
  # 2.7): inserted directly, because C3-02's `:create` stores company(raw).
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

    assert {:ok, account} = GuardedCall.get(Account, id, actor: admin)
    account
  end

  defp reread!(admin, account) do
    assert {:ok, fresh} = GuardedCall.get(Account, account.id, actor: admin)
    fresh
  end

  defp lookup(admin, canonical) do
    Account
    |> GuardedCall.read_query(actor: admin)
    |> Ash.Query.filter(canonical_domain == ^canonical)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp account_ids(admin) do
    assert {:ok, accounts} = GuardedCall.list(Account, actor: admin)
    accounts |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp assert_unique_domain_refusal!(result, c) do
    assert match?({:error, %Ash.Error.Invalid{errors: [_ | _]}}, result),
           "C3-02: new input #{c} must be refused as a duplicate of the legacy row"

    {:error, %Ash.Error.Invalid{errors: errors}} = result

    for error <- errors do
      assert match?(%Ash.Error.Changes.InvalidAttribute{}, error),
             "C3-02: the duplicate refusal must be a typed uniqueness error"

      assert Keyword.get(error.private_vars || [], :constraint_type) == :unique,
             "C3-02: the duplicate refusal must come from a unique constraint"
    end

    assert :domain in Enum.map(errors, & &1.field)
  end

  defp lookup_raw(admin, fragment) do
    {:ok, accounts} = GuardedCall.list(Account, actor: admin)
    for account <- accounts, to_string(account.domain) =~ fragment, do: account.id
  end

  defp created_record_sha256(tenant, account) do
    subject = to_string(account.id)

    assert [event] =
             for(
               event <- events_of_type(tenant, "sales.account.created"),
               event.subject_id == subject,
               do: event
             )

    event.payload["record_sha256"] || event.payload[:record_sha256]
  end

  defp attempt(fun) do
    fun.()
  rescue
    error -> {:raised, error.__struct__}
  end

  ## Privacy

  defp canary, do: "c302canary#{SalesFixtures.unique()}"

  defp refused_company_inputs(canary) do
    [
      "www.www.#{canary}.test",
      "www.#{canary}",
      "#{canary}.test..",
      "#{canary}..test",
      "https://#{canary}.test",
      "#{canary}.test:443",
      "jo@#{canary}.test"
    ]
  end

  defp raised(fun) do
    result = fun.()
    flunk("C3-02: expected an exception, got #{inspect(result)}")
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> error
  end

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)

  defp rendered_spans do
    Process.sleep(50)
    inspect(InMemoryExporter.spans(), limit: :infinity, printable_limit: :infinity)
  end
end
