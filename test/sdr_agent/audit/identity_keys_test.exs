defmodule SdrAgent.Audit.IdentityKeysTest do
  @moduledoc """
  C3-02 RED-1, plan r8 section 11 A (T-A1..T-A18): the identity-key id
  derivation, the pure pass decision (section 2.4), the application-scope
  root hook in `SdrAgent.Repo` (section 2.2), the rollback-aware membership
  record `sdr.identity_pass` (section 2.3) and acquisition failure (section
  2.5), all under the Ecto SQL sandbox (application scope = savepoint).

  RED form: every subject that does not exist yet is guarded first
  (`Code.ensure_loaded?/1` and `function_exported?/3`) and called through
  `apply/3`, so each test fails at a `C3-02:` assertion, never at compile
  time or with an `UndefinedFunctionError`. T-A16 and T-A17 are controls:
  they pass on main and must stay green after G1.

  Interface names the plan leaves open, chosen here for review:
  `IdentityKeys.id/3` (`id(tenant_id, kind, raw)`, the key id `K_kind(raw)`;
  callers never call `H`), `pass/2` and `require_held/2` returning `:ok`,
  `Decision.decide/5` taking the `%IdentityKeys.Scope{}` (token and state)
  as its first argument and returning `:ok` (rule 3) or the next state
  `{:acquiring, prior, planned_new}` (rules 6 and 8), and the test-build
  fault seam `IdentityKeys.TestFaults.with_fault/2` with the points
  `:before_first_lock`, `{:after_locks, k}` and `:at_publication`.
  """
  use SdrAgent.AuditCase, async: false

  alias Ecto.Multi
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Sales.Account
  alias SdrAgent.SalesFixtures

  @keys SdrAgent.Audit.IdentityKeys
  @decision SdrAgent.Audit.IdentityKeys.Decision
  @scope_struct SdrAgent.Audit.IdentityKeys.Scope
  @faults SdrAgent.Audit.IdentityKeys.TestFaults
  @scope_key {SdrAgent.Audit.IdentityKeys, :scope}

  @late SdrAgent.Audit.IdentityKeys.LateAcquisition
  @inconsistent SdrAgent.Audit.IdentityKeys.PassInconsistent
  @missing SdrAgent.Audit.IdentityKeys.MissingPass
  @failed SdrAgent.Audit.IdentityKeys.AcquisitionFailed
  @invalid SdrAgent.Audit.IdentityKeys.InvalidKeyValue
  @not_in_transaction SdrAgent.Audit.IdentityKeys.NotInTransaction
  @unscoped SdrAgent.Audit.IdentityKeys.UnscopedTransaction
  @conflict SdrAgent.Audit.IdentityKeys.ScopeConflict
  @exceptions [
    @late,
    @inconsistent,
    @missing,
    @failed,
    @invalid,
    @not_in_transaction,
    @unscoped,
    @conflict
  ]

  # Section 2.3: "v1;<token>;<backend pid>;<id>,<id>,…"; an empty set ends with ";".
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

  # T-A1 vectors for the fixed synthetic tenant uuid below. The signed ids
  # were computed outside the VM, by an independent sha256 implementation
  # (`shasum -a 256`) over the exact preimage bytes of section 2.7
  #   "sdr-identity-key/1\0" <> kind <> "\0" <> tenant_id <> "\0" <> bytes
  # and the first 8 bytes read as a two's-complement signed 64-bit integer:
  #   printf 'sdr-identity-key/1\0%s\0%s\0%s' "$kind" "$tenant" "$bytes" \
  #     | shasum -a 256 | cut -c1-16
  #   domain/acme.test     -> 45d03b9436a156a6 ->  5030586291530585766
  #   domain/www.acme.test -> c41fc7e472ae821b -> -4314510134007135717
  #   domain/test          -> 10187fc0d3524146 ->  1159817370203734342
  #   email/a@www.test     -> e5aac29f9bcf1e7b -> -1897490302213611909
  #   email/a@acme.test    -> c0f3c5c8ca2fe7c2 -> -4543070132910430270
  #   domain/acme.test, tenant ...c303 -> 944a76dace727efa -> -7761260325681070342
  @tenant "00000000-0000-4000-8000-00000000c302"
  @other_tenant "00000000-0000-4000-8000-00000000c303"
  @vectors [
    # {kind, raw key input, exact H preimage bytes, signed id}
    {:domain, "acme.test", "acme.test", 5_030_586_291_530_585_766},
    {:domain, "www.acme.test", "acme.test", 5_030_586_291_530_585_766},
    {:domain, "WWW.Acme.Test.", "acme.test", 5_030_586_291_530_585_766},
    # stripped exactly once: the preimage is www.acme.test, not acme.test
    {:domain, "www.www.acme.test", "www.acme.test", -4_314_510_134_007_135_717},
    # suppression www.test, and the email domain of a@www.test
    {:domain, "www.test", "test", 1_159_817_370_203_734_342},
    {:email, "a@www.test", "a@www.test", -1_897_490_302_213_611_909},
    {:email, " A@Acme.Test ", "a@acme.test", -4_543_070_132_910_430_270}
  ]

  describe "T-A1 id derivation" do
    test "T-A1 pinned signed 64-bit ids over the section 2.7 preimages" do
      present!(@keys, :id, 3)

      for {kind, raw, preimage, expected} <- @vectors do
        # Cross-checks the recorded literal against the plan's H definition.
        assert h(kind, @tenant, preimage) == expected

        actual = key_id(@tenant, kind, raw)

        assert actual == expected,
               "C3-02: id(#{inspect(kind)}, #{inspect(raw)}) must be H over #{inspect(preimage)}"

        assert actual in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF
      end
    end

    test "T-A1 kinds and tenants are separate namespaces" do
      present!(@keys, :id, 3)

      assert key_id(@other_tenant, :domain, "acme.test") == -7_761_260_325_681_070_342
      refute key_id(@tenant, :domain, "acme.test") == key_id(@other_tenant, :domain, "acme.test")
      # Kind separation over valid inputs only: each pinned K differs from H
      # over the same bytes under the other kind (computed outside the VM as
      # above): email/acme.test -> ac278c2640241987 -> -6041706279181477497;
      # domain/a@acme.test -> 896fb6ac0a97d3c5 -> -8543409118070189115.
      # (A domain key input containing "@" is unrepresentable, section 2.7.)
      assert key_id(@tenant, :domain, "acme.test") == 5_030_586_291_530_585_766
      assert h(:email, @tenant, "acme.test") == -6_041_706_279_181_477_497
      refute key_id(@tenant, :domain, "acme.test") == -6_041_706_279_181_477_497
      assert key_id(@tenant, :email, "a@acme.test") == -4_543_070_132_910_430_270
      assert h(:domain, @tenant, "a@acme.test") == -8_543_409_118_070_189_115
      refute key_id(@tenant, :email, "a@acme.test") == -8_543_409_118_070_189_115
      # K_domain("www.acme.test") = H("acme.test"), never H("www.acme.test").
      refute key_id(@tenant, :domain, "www.acme.test") ==
               key_id(@tenant, :domain, "www.www.acme.test")
    end
  end

  @t "0123456789abcdef0123456789abcdef"
  @u "fedcba9876543210fedcba9876543210"
  @pid 4242
  @other_pid 4243
  @a -3
  @b 5
  @c 7
  @x 11

  # C3-02 G4 (plan r8 section 14, ruling 1): the admission's `admission-ref`
  # kind. Its raw key input is the exact `source_ref` (the admission
  # validates the grammar first): no trim, case or host normalization, the
  # same tenant and kind separation and signed-int64 formula. The literals
  # were computed outside the VM (Python `hashlib.sha256` over
  # "sdr-identity-key/1\0admission-ref\0" <> tenant <> "\0" <> ref, the
  # first 8 bytes read as a signed big-endian int64).
  describe "T-A1 (G4) the admission-ref kind" do
    test "T-A1 (G4) admission-ref ids: the exact ref, separate per tenant and kind, stable" do
      present!(@keys, :id, 3)
      manual = "manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c2f"

      vectors = [
        {manual, 4_104_483_232_722_833_990, -6_785_165_038_799_197_174},
        {"csv:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c5c:7", -4_433_594_401_147_850_906,
         -3_822_347_956_748_115_077},
        {"hubspot:123456:789", 5_766_568_727_716_675_439, 7_781_447_160_973_226_631}
      ]

      for {ref, expected, other_tenant} <- vectors do
        assert h(:"admission-ref", @tenant, ref) == expected
        assert key_id(@tenant, :"admission-ref", ref) == expected
        assert key_id(@tenant, :"admission-ref", ref) == expected, "C3-02: the same ref is stable"
        assert key_id(@other_tenant, :"admission-ref", ref) == other_tenant
      end

      assert vectors |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 3,
             "C3-02: distinct refs give distinct ids"

      # Kind separation: H over the same bytes under the email kind.
      assert h(:email, @tenant, manual) == -9_192_477_763_250_758_533
      refute key_id(@tenant, :"admission-ref", manual) == -9_192_477_763_250_758_533

      # Exact: no trim, no case folding.
      refute key_id(@tenant, :"admission-ref", " " <> manual) == 4_104_483_232_722_833_990
      refute key_id(@tenant, :"admission-ref", String.upcase(manual)) == 4_104_483_232_722_833_990

      # The existing kinds are unchanged (T-A1 above pins them all).
      assert key_id(@tenant, :domain, "acme.test") == 5_030_586_291_530_585_766

      # An unrepresentable ref raises InvalidKeyValue carrying the kind only.
      for raw <- ["", <<0xFF>>, nil] do
        invalid = assert_raise(@invalid, fn -> key_id(@tenant, :"admission-ref", raw) end)
        assert invalid.kind == :"admission-ref"
      end
    end
  end

  # C3-02 G6 (plan r8 section 16.4, 16.13 R-A1/R-A2; Codex G6-R1/G6-R2): the
  # `reply-message` kind. The helper input is the represented Message-ID (the
  # webhook derives it once with the Reply attribute's own constraints); the
  # preimage is the exact helper bytes: no trim, no case folding. The
  # literals were computed outside the VM (Python `hashlib.sha256` over
  # "sdr-identity-key/1\0reply-message\0" <> tenant <> "\0" <> bytes, the
  # first 8 bytes read as a signed big-endian int64); the same computation
  # reproduces the T-A1 acme.test pins for both tenants, and Codex recomputed
  # all of them independently (codex-c302-g6r2-plan-review.org).
  describe "T-A1 (G6) the reply-message kind" do
    test "T-A1 (G6) reply-message ids: the exact helper bytes, separate per tenant and kind, stable" do
      present!(@keys, :id, 3)
      plain = "<c302-a@prospect.example.test>"

      # {helper input, id for @tenant, id for @other_tenant}
      vectors = [
        {plain, -2_961_466_829_739_951_965, -6_122_150_999_814_710_842},
        # case kept: a distinct Message-ID and a distinct id
        {"<C302-A@Prospect.Example.test>", 7_032_449_472_738_624_118, 7_765_332_955_089_300_185},
        {"<c302-b.1700000000@mail.example.test>", -711_627_853_640_270_851,
         -7_656_837_646_547_798_945},
        # helper whitespace kept (the webhook represents before it calls the helper)
        {" " <> plain <> " ", 8_594_672_828_337_064_874, 7_085_218_719_716_432_101}
      ]

      for {raw, expected, other_tenant} <- vectors do
        # Cross-checks the recorded literals against the plan's H.
        assert h(:"reply-message", @tenant, raw) == expected
        assert h(:"reply-message", @other_tenant, raw) == other_tenant

        assert id_outcome(@tenant, :"reply-message", raw) == {:ok, expected},
               "C3-02: id(:\"reply-message\", ...) must be H over the exact helper bytes"

        assert id_outcome(@tenant, :"reply-message", raw) == {:ok, expected},
               "C3-02: the same Message-ID is stable"

        assert id_outcome(@other_tenant, :"reply-message", raw) == {:ok, other_tenant},
               "C3-02: tenants are separate namespaces"
      end

      assert vectors |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 4,
             "C3-02: distinct helper inputs give distinct ids"

      # Kind separation: H over the same bytes under the email and the
      # admission-ref kinds (computed outside the VM as above).
      assert h(:email, @tenant, plain) == -8_547_734_143_584_886_394
      assert h(:"admission-ref", @tenant, plain) == 4_189_496_421_725_156_895
      refute id_outcome(@tenant, :"reply-message", plain) == {:ok, -8_547_734_143_584_886_394}
      refute id_outcome(@tenant, :"reply-message", plain) == {:ok, 4_189_496_421_725_156_895}

      # The existing kinds are unchanged (T-A1 above pins them all).
      assert key_id(@tenant, :domain, "acme.test") == 5_030_586_291_530_585_766
      assert key_id(@other_tenant, :domain, "acme.test") == -7_761_260_325_681_070_342
    end

    test "T-A1 (G6) an unrepresentable reply-message helper input raises the closed InvalidKeyValue" do
      present!(@keys, :id, 3)
      sentinel = "c302-reply-message-sentinel"
      expected = {:raised, @invalid, :"reply-message", "invalid reply-message identity key value"}

      for raw <- ["", <<0xFF>>, sentinel <> <<0xFF>>, nil, 123, :c302_atom] do
        outcome = id_outcome(@tenant, :"reply-message", raw)

        assert outcome == expected,
               "C3-02: an unrepresentable reply-message input must raise the closed InvalidKeyValue"

        refute inspect(outcome) =~ sentinel
      end
    end
  end

  describe "T-A2 decision table (section 2.4, rules 1-9)" do
    test "T-A2 every rule and the section 2.4 worked examples" do
      present!(@scope_struct, :__struct__, 0)
      present!(@decision, :decide, 5)
      Enum.each(@exceptions, &exception!/1)

      for {label, state, setting, held, requested, expected} <- rows() do
        scope = struct!(@scope_struct, token: @t, state: as_sets(state))
        actual = decided(scope, setting, @pid, MapSet.new(held), requested)

        assert actual == normalize_expected(expected),
               "C3-02: decision rule #{label}: got #{inspect(actual)}"
      end
    end
  end

  describe "T-A3..T-A11 the pass under the sandbox" do
    test "T-A3 two standalone scopes in one sandbox owner each pass once" do
      guard_keys!()
      t = tenant()
      first = {:domain, "t-a3-first.test"}
      second = {:domain, "t-a3-second.test"}

      assert {:ok, {token1, record1}} =
               Repo.transaction(fn ->
                 assert pass(t, [first]) == :ok
                 {scope_token(), record()}
               end)

      assert scope() == nil

      assert {:ok, {token2, record2, stale?}} =
               Repo.transaction(fn ->
                 stale? = id(t, first) in held()
                 assert pass(t, [second]) == :ok
                 assert require_held(t, [second]) == :ok
                 {scope_token(), record(), stale?}
               end)

      assert token1 != token2
      assert record1.token == token1
      assert record2.token == token2
      assert record2.ids == MapSet.new([id(t, second)])
      # Section 2.2: a released savepoint leaves its key held under the
      # sandbox; it neither counts as the second scope's pass nor blocks it.
      assert stale?
      assert scope() == nil
    end

    test "T-A4 two different-key writes in one Audit.transaction without an outer pass" do
      guard_keys!()
      t = tenant()

      assert_raise @late, fn ->
        Audit.transaction(fn ->
          assert pass(t, [{:domain, "t-a4-first.test"}]) == :ok
          pass(t, [{:domain, "t-a4-second.test"}])
        end)
      end

      assert scope() == nil
    end

    test "T-A5 an outer pass covering both writes" do
      guard_keys!()
      t = tenant()
      company = {:domain, "t-a5.test"}
      person = {:email, "jo@t-a5.test"}

      result =
        Audit.transaction(fn ->
          assert pass(t, [person, company]) == :ok
          assert pass(t, [company]) == :ok
          assert pass(t, [person, person]) == :ok
          assert require_held(t, [company, person]) == :ok
          assert record().ids == MapSet.new([id(t, company), id(t, person)])
          :both
        end)

      assert result == {:ok, :both}
    end

    test "T-A6 an empty pass, then a new key, is LateAcquisition" do
      guard_keys!()
      t = tenant()

      assert {:ok, outcomes} =
               Repo.transaction(fn ->
                 empty = outcome(fn -> pass(t, []) end)
                 manifest = record().ids
                 {empty, manifest, outcome(fn -> pass(t, [{:domain, "t-a6.test"}]) end)}
               end)

      assert outcomes == {:ok, MapSet.new(), {:raised, @late}}
    end

    test "T-A7a a first non-empty pass rolled back allows a fresh pass" do
      guard_keys!()
      t = tenant()
      a = {:domain, "t-a7a-a.test"}
      b = {:domain, "t-a7a-b.test"}

      assert {:ok, :done} =
               Repo.transaction(fn ->
                 savepoint!("c302_t_a7a")
                 assert pass(t, [a]) == :ok
                 assert id(t, a) in held()
                 rollback_to!("c302_t_a7a")
                 refute id(t, a) in held()
                 assert setting() == nil

                 assert pass(t, [b]) == :ok
                 assert record().ids == MapSet.new([id(t, b)])
                 assert require_held(t, [b]) == :ok
                 assert outcome(fn -> require_held(t, [a]) end) == {:raised, @late}
                 :done
               end)
    end

    test "T-A7b a first-ever empty pass rolled back reads absent, then a fresh pass" do
      guard_keys!()
      t = tenant()
      x = {:domain, "t-a7b.test"}

      assert {:ok, :done} =
               Repo.transaction(fn ->
                 assert setting() == nil
                 savepoint!("c302_t_a7b")
                 assert pass(t, []) == :ok
                 assert record().ids == MapSet.new()
                 rollback_to!("c302_t_a7b")
                 # Absent and empty both read as absent (section 2.3).
                 assert setting() == nil

                 assert pass(t, [x]) == :ok
                 assert record().ids == MapSet.new([id(t, x)])
                 :done
               end)
    end

    test "T-A8 a savepoint after the pass keeps the outer pass" do
      guard_keys!()
      t = tenant()
      a = {:domain, "t-a8-a.test"}
      b = {:domain, "t-a8-b.test"}

      assert {:ok, :done} =
               Repo.transaction(fn ->
                 assert pass(t, [a, b]) == :ok
                 published = setting()
                 savepoint!("c302_t_a8")
                 assert require_held(t, [a]) == :ok
                 assert pass(t, [b]) == :ok
                 rollback_to!("c302_t_a8")

                 assert setting() == published
                 assert require_held(t, [a, b]) == :ok
                 assert pass(t, [a]) == :ok

                 assert outcome(fn -> pass(t, [{:domain, "t-a8-c.test"}]) end) ==
                          {:raised, @late}

                 :done
               end)
    end

    test "T-A9 a record naming this scope with an unheld manifest id is PassInconsistent" do
      guard_keys!()
      t = tenant()
      a = {:domain, "t-a9-a.test"}
      unheld = id(t, {:domain, "t-a9-unheld.test"})

      assert {:ok, outcomes} =
               Repo.transaction(fn ->
                 assert pass(t, [a]) == :ok
                 %{token: token, pid: pid} = record()
                 forge!("v1;#{token};#{pid};#{Enum.join(Enum.sort([id(t, a), unheld]), ",")}")
                 {outcome(fn -> require_held(t, [a]) end), outcome(fn -> pass(t, [a]) end)}
               end)

      assert outcomes == {{:raised, @inconsistent}, {:raised, @inconsistent}}
    end

    test "T-A10 a foreign record mid-scope is PassInconsistent" do
      guard_keys!()
      t = tenant()
      a = {:domain, "t-a10.test"}

      assert {:ok, outcomes} =
               Repo.transaction(fn ->
                 assert pass(t, [a]) == :ok
                 %{pid: pid} = record()
                 forge!("v1;#{String.duplicate("ab", 16)};#{pid};#{id(t, a)}")
                 {outcome(fn -> require_held(t, [a]) end), outcome(fn -> pass(t, [a]) end)}
               end)

      assert outcomes == {{:raised, @inconsistent}, {:raised, @inconsistent}}
    end

    test "T-A11 a revert to prior with new ids still held is PassInconsistent" do
      guard_keys!()
      t = tenant()
      a = {:domain, "t-a11-a.test"}
      c = {:domain, "t-a11-c.test"}

      assert {:ok, outcomes} =
               Repo.transaction(fn ->
                 assert setting() == nil
                 assert pass(t, [a]) == :ok
                 # The prior was absent; an empty value reads as absent.
                 forge!("")
                 still_held? = id(t, a) in held()
                 {still_held?, outcome(fn -> pass(t, [c]) end)}
               end)

      assert outcomes == {true, {:raised, @inconsistent}}
    end
  end

  describe "T-A12 exception content" do
    test "T-A12 exceptions carry kinds and counts only" do
      guard_keys!()
      t = tenant()
      n = System.unique_integer([:positive])
      domain = "canary-dom-#{n}.test"
      email = "canary-mail-#{n}@canary-host-#{n}.test"

      assert {:ok, late} =
               Repo.transaction(fn ->
                 assert pass(t, []) == :ok
                 raised(fn -> pass(t, [{:domain, domain}]) end)
               end)

      assert {:ok, inconsistent} =
               Repo.transaction(fn ->
                 assert pass(t, [{:domain, domain}]) == :ok
                 %{token: token, pid: pid} = record()
                 unheld = id(t, {:domain, "t-a12-unheld.test"})

                 forge!(
                   "v1;#{token};#{pid};#{Enum.join(Enum.sort([id(t, {:domain, domain}), unheld]), ",")}"
                 )

                 raised(fn -> require_held(t, [{:domain, domain}]) end)
               end)

      assert {:ok, missing} =
               Repo.transaction(fn -> raised(fn -> require_held(t, [{:email, email}]) end) end)

      assert {:ok, invalid} =
               Repo.transaction(fn ->
                 raised(fn -> pass(t, [{:email, "no-at-sign-#{n}.test"}]) end)
               end)

      outside = raised(fn -> pass(t, [{:email, email}]) end)

      assert late.__struct__ == @late
      assert inconsistent.__struct__ == @inconsistent
      assert missing.__struct__ == @missing
      assert invalid.__struct__ == @invalid
      assert outside.__struct__ == @not_in_transaction
      assert rendered(invalid) =~ "email", "C3-02: InvalidKeyValue must carry its kind"

      forbidden = [
        domain,
        email,
        "no-at-sign-#{n}",
        "canary",
        t,
        Integer.to_string(id(t, {:domain, domain})),
        Integer.to_string(id(t, {:email, email}))
      ]

      for error <- [late, inconsistent, missing, invalid, outside], value <- forbidden do
        refute rendered(error) =~ value,
               "C3-02: #{inspect(error.__struct__)} must carry kinds and counts only"
      end
    end
  end

  describe "T-A13 transaction preconditions" do
    test "T-A13 NotInTransaction outside any transaction" do
      guard_keys!()
      t = tenant()

      assert_raise @not_in_transaction, fn -> pass(t, [{:domain, "t-a13.test"}]) end
      assert_raise @not_in_transaction, fn -> require_held(t, [{:domain, "t-a13.test"}]) end
      assert_raise @not_in_transaction, fn -> pass(t, []) end
    end

    test "T-A13 UnscopedTransaction inside a standalone Ecto.Multi" do
      guard_keys!()
      t = tenant()

      multi =
        Multi.run(Multi.new(), :pass, fn _repo, _changes ->
          {:ok, pass(t, [{:domain, "t-a13-multi.test"}])}
        end)

      assert_raise @unscoped, fn -> Repo.transaction(multi) end
      assert scope() == nil
    end
  end

  describe "T-A14 the root hook matrix (section 2.2)" do
    test "T-A14 prepare_transaction/2 wraps only an outermost function, keeping opts" do
      guard_scope!()
      opts = [timeout: 12_345, log: false]
      zero = fn -> :zero end
      one = fn _repo -> :one end

      assert {wrapped0, ^opts} = Repo.prepare_transaction(zero, opts)
      assert is_function(wrapped0, 0)
      refute wrapped0 == zero, "C3-02: an outermost arity-0 function must be wrapped"

      assert {wrapped1, ^opts} = Repo.prepare_transaction(one, opts)
      assert is_function(wrapped1, 1)
      refute wrapped1 == one, "C3-02: an outermost arity-1 function must be wrapped"

      multi = Multi.put(Multi.new(), :k, :v)
      assert Repo.prepare_transaction(multi, opts) == {multi, opts}

      assert {:ok, {same, same_opts}} =
               Repo.transaction(fn -> Repo.prepare_transaction(zero, opts) end)

      assert same == zero
      assert same_opts == opts
    end

    test "T-A14 transaction/2 and transact/2, arity 0 and 1, each register one fresh scope" do
      guard_scope!()

      results = [
        Repo.transaction(fn -> observe(:value) end),
        Repo.transaction(fn _repo -> observe(:value) end, timeout: 15_000),
        Repo.transact(fn -> {:ok, observe(:value)} end),
        Repo.transact(fn _repo -> {:ok, observe(:value)} end, timeout: 15_000)
      ]

      assert results == List.duplicate({:ok, :value}, 4)
      scopes = observed(4)
      Enum.each(scopes, &assert_fresh_scope!/1)
      assert scopes |> Enum.map(& &1.token) |> Enum.uniq() |> length() == 4
      assert scope() == nil
    end

    test "T-A14 every exit path deletes the entry" do
      guard_scope!()

      assert Repo.transaction(fn -> observe(:returned) end) == {:ok, :returned}
      assert Repo.transact(fn -> {:error, observe(:c302_error)} end) == {:error, :c302_error}

      assert Repo.transaction(fn -> Repo.rollback(observe(:c302_rollback)) end) ==
               {:error, :c302_rollback}

      assert_raise RuntimeError, "c302 raise", fn ->
        Repo.transaction(fn ->
          observe(:raise)
          raise "c302 raise"
        end)
      end

      assert catch_exit(
               Repo.transaction(fn ->
                 observe(:exit)
                 exit(:c302_exit)
               end)
             ) == :c302_exit

      scopes = observed(5)
      Enum.each(scopes, &assert_fresh_scope!/1)
      assert scope() == nil
    end

    test "T-A14 nested transactions and a nested Multi join the open scope" do
      guard_scope!()

      nested_multi = Multi.run(Multi.new(), :scope, fn _repo, _changes -> {:ok, scope()} end)

      assert {:ok, {outer, inner}} =
               Repo.transaction(fn ->
                 {scope(),
                  [
                    Repo.transaction(fn -> scope() end),
                    Repo.transact(fn -> {:ok, scope()} end),
                    Audit.transaction(fn -> scope() end),
                    AuditKernel.in_transaction(fn -> {:ok, scope()} end),
                    Repo.transaction(nested_multi)
                  ]}
               end)

      assert_fresh_scope!(outer)

      assert inner == [
               {:ok, outer},
               {:ok, outer},
               {:ok, outer},
               {:ok, outer},
               {:ok, %{scope: outer}}
             ]

      assert scope() == nil
    end

    test "T-A14 a standalone Multi has no scope" do
      guard_scope!()
      # Precondition: the hook does register a scope for a function.
      assert {:ok, function_scope} = Repo.transaction(fn -> scope() end)
      assert_fresh_scope!(function_scope)

      multi = Multi.run(Multi.new(), :scope, fn _repo, _changes -> {:ok, scope()} end)
      assert Repo.transaction(multi) == {:ok, %{scope: nil}}
      assert scope() == nil
    end

    test "T-A14 an Ash action with hooks opens its own scope" do
      guard_scope!()
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      parent = self()

      assert {:ok, _account} =
               Account
               |> Ash.Changeset.for_create(:create, SalesFixtures.account_attrs(), actor: admin)
               |> Ash.Changeset.before_action(
                 fn changeset ->
                   send(parent, {:c302_scope, scope()})
                   changeset
                 end,
                 prepend?: true
               )
               |> Ash.create()

      assert_received {:c302_scope, action_scope}

      assert match?(
               %{__struct__: @scope_struct, token: token} when is_binary(token),
               action_scope
             ),
             "C3-02: the Ash action's transaction must be an application scope"

      assert scope() == nil
    end

    test "T-A14 an existing entry raises ScopeConflict and is never overwritten or deleted" do
      guard_scope!()
      exception!(@conflict)
      sentinel = {:c302_foreign_scope, make_ref()}

      Process.put(@scope_key, sentinel)

      try do
        assert_raise @conflict, fn -> Repo.transaction(fn -> :never end) end
        assert Process.get(@scope_key) == sentinel
      after
        Process.delete(@scope_key)
      end

      # The wrapper deletes the entry only while it still holds its own token.
      try do
        assert {:ok, own} =
                 Repo.transaction(fn ->
                   own = scope()
                   Process.put(@scope_key, sentinel)
                   own
                 end)

        assert_fresh_scope!(own)
        assert Process.get(@scope_key) == sentinel
      after
        Process.delete(@scope_key)
      end
    end

    test "T-A14 a sandbox-shared process opens its own scope with its own token" do
      guard_scope!()

      assert {:ok, parent_scope} = Repo.transaction(fn -> scope() end)

      {task_result, task_after} =
        Task.await(Task.async(fn -> {Repo.transaction(fn -> scope() end), scope()} end), 15_000)

      assert_fresh_scope!(parent_scope)
      assert {:ok, task_scope} = task_result
      assert_fresh_scope!(task_scope)
      refute task_scope.token == parent_scope.token
      assert task_after == nil
      assert scope() == nil
    end
  end

  describe "T-A15 lock statements" do
    test "T-A15 lock ids are sent as integer parameters only, ascending, deduplicated" do
      guard_keys!()
      t = tenant()
      n = System.unique_integer([:positive])
      domain = "canary-t-a15-#{n}.test"
      email = "canary-t-a15-#{n}@mail-#{n}.test"
      keys = [{:email, email}, {:domain, domain}, {:email, email}]
      expected = keys |> Enum.map(&id(t, &1)) |> Enum.uniq() |> Enum.sort()

      {result, queries} =
        trace_queries(fn -> Repo.transaction(fn -> pass(t, keys) end) end)

      assert result == {:ok, :ok}

      locks = for {sql, params} <- queries, sql =~ "pg_advisory", do: {sql, params}

      for {sql, params} <- locks do
        assert sql =~ ~r/pg_advisory_xact_lock\(\$1::bigint\)/
        assert match?([lock_id] when is_integer(lock_id), params)
      end

      assert Enum.map(locks, fn {_sql, [lock_id]} -> lock_id end) == expected,
             "C3-02: one integer-parameter lock per id, in ascending signed order"

      assert [[published]] = for({sql, params} <- queries, sql =~ "set_config", do: params)
      assert published =~ @record_format

      for {sql, params} <- queries do
        refute sql =~ "canary"
        Enum.each(params, &assert_safe_param!/1)
      end
    end
  end

  describe "T-A16 and T-A17 controls" do
    # Control: passes on main (there is no hook yet) and must stay green
    # after G1 (section 2.2, "Cost").
    test "T-A16 (control) non-identity transactions: no extra statement, same results, clean dictionary" do
      assert {:ok, _warm} = Repo.transaction(fn -> Repo.query!("SELECT 1") end)
      keys_before = Enum.sort(Process.get_keys())

      {results, queries} =
        trace_queries(fn ->
          [
            Repo.transaction(fn ->
              Repo.query!("SELECT 1 AS c302_t_a16")
              :value
            end),
            Repo.transaction(fn _repo -> :arity_one end),
            Repo.transact(fn -> {:ok, :transact} end),
            Repo.transact(fn -> {:error, :c302} end),
            Repo.transaction(fn -> Repo.rollback(:rolled_back) end),
            Audit.transaction(fn -> :audit end),
            AuditKernel.in_transaction(fn -> {:ok, :kernel} end)
          ]
        end)

      assert results == [
               {:ok, :value},
               {:ok, :arity_one},
               {:ok, :transact},
               {:error, :c302},
               {:error, :rolled_back},
               {:ok, :audit},
               {:ok, :kernel}
             ]

      statements = for {sql, _params} <- queries, not transaction_control?(sql), do: sql
      assert statements == ["SELECT 1 AS c302_t_a16"]

      for {sql, _params} <- queries do
        refute sql =~ ~r/sdr\.identity_pass|pg_advisory|pg_locks|set_config/
      end

      assert Enum.sort(Process.get_keys()) == keys_before
      assert scope() == nil
    end

    # Control: passes on main (nothing names the setting yet) and must stay
    # green: only IdentityKeys writes sdr.identity_pass (section 2.3, Q-C12).
    # A regression guard for the trusted-writer convention, not a security
    # boundary: it cannot see setting names built at runtime.
    test "T-A17 (control) only IdentityKeys names sdr.identity_pass, and set_config stays where it is" do
      root = Path.expand("../../..", __DIR__)
      files = Path.wildcard(Path.join(root, "lib/**/*.{ex,exs}"))
      assert files != []

      relative = fn path -> Path.relative_to(path, root) end

      identity? = fn path ->
        rel = relative.(path)

        rel == "lib/sdr_agent/audit/identity_keys.ex" or
          String.starts_with?(rel, "lib/sdr_agent/audit/identity_keys/")
      end

      allowed_set_config = [
        "lib/sdr_agent/agents/ledger_call.ex",
        "lib/sdr_agent/agents/profile_switch_drain.ex",
        "lib/sdr_agent/agents/release_decision/prelocked.ex"
      ]

      naming = for path <- files, File.read!(path) =~ "sdr.identity_pass", do: path
      assert Enum.reject(naming, identity?) == []

      # G3-1 (Codex 944d822): the definition bootstrap's registration
      # transaction sets its own lock and statement timeouts (plan r8 section
      # 7.3). Allowed by exact call: only those two setting names, only
      # transaction-local (`true`), only a bound parameter as the value.
      timeouts_only = %{
        "lib/sdr_agent/sdr/definition_bootstrap.ex" => [
          "set_config('lock_timeout', $1, true)",
          "set_config('statement_timeout', $1, true)"
        ]
      }

      for {path, allowed} <- timeouts_only do
        calls =
          ~r/set_config\([^)]*\)/
          |> Regex.scan(File.read!(Path.join(root, path)))
          |> List.flatten()

        assert calls != [], "#{path} no longer sets its timeouts: update this guard"

        assert Enum.reject(calls, &(&1 in allowed)) == [],
               "#{path} calls set_config beyond its pinned transaction-local timeouts"
      end

      set_config = for path <- files, File.read!(path) =~ "set_config", do: path
      unexpected = for path <- set_config, not identity?.(path), do: relative.(path)
      assert unexpected -- (allowed_set_config ++ Map.keys(timeouts_only)) == []
    end
  end

  describe "T-A18 acquisition failure (section 2.5)" do
    @fault_points [
      before_first_lock: :before_first_lock,
      after_one_of_two_locks: {:after_locks, 1},
      at_publication: :at_publication
    ]

    for {label, point} <- @fault_points do
      @tag fault_point: point
      test "T-A18 fault #{label}, (i) rescued: every later request is PassInconsistent",
           %{fault_point: point} do
        guard_faults!()
        t = tenant()
        keys = [{:domain, "t-a18-a.test"}, {:domain, "t-a18-b.test"}]

        assert {:ok, {failure, published, later}} =
                 Repo.transaction(fn ->
                   failure = raised(fn -> with_fault(point, fn -> pass(t, keys) end) end)

                   {failure, setting(),
                    [
                      outcome(fn -> pass(t, keys) end),
                      outcome(fn -> require_held(t, [hd(keys)]) end),
                      outcome(fn -> pass(t, []) end)
                    ]}
                 end)

        assert failure.__struct__ == @failed

        for value <- [t | Enum.map(keys, &Integer.to_string(id(t, &1)))] do
          refute rendered(failure) =~ value, "C3-02: AcquisitionFailed carries its class only"
        end

        assert published == nil, "C3-02: a failed acquisition publishes no record"
        assert later == List.duplicate({:raised, @inconsistent}, 3)
      end

      @tag fault_point: point
      test "T-A18 fault #{label}, (ii) ROLLBACK TO a savepoint before the pass stays poisoned",
           %{fault_point: point} do
        guard_faults!()
        t = tenant()
        keys = [{:domain, "t-a18-a.test"}, {:domain, "t-a18-b.test"}]

        assert {:ok, {failure, held_after, later}} =
                 Repo.transaction(fn ->
                   savepoint!("c302_t_a18")
                   failure = outcome(fn -> with_fault(point, fn -> pass(t, keys) end) end)
                   rollback_to!("c302_t_a18")

                   {failure, held(),
                    [
                      outcome(fn -> pass(t, keys) end),
                      outcome(fn -> require_held(t, keys) end)
                    ]}
                 end)

        assert failure == {:raised, @failed}
        assert MapSet.disjoint?(held_after, MapSet.new(keys, &id(t, &1)))
        assert later == List.duplicate({:raised, @inconsistent}, 2)
      end

      @tag fault_point: point
      test "T-A18 fault #{label}, (iii) a rolled-back application transaction, then a clean scope",
           %{fault_point: point} do
        guard_faults!()
        t = tenant()
        keys = [{:domain, "t-a18-a.test"}, {:domain, "t-a18-b.test"}]

        assert_raise @failed, fn ->
          Repo.transaction(fn -> with_fault(point, fn -> pass(t, keys) end) end)
        end

        assert scope() == nil

        assert {:ok, {:ok, manifest}} =
                 Repo.transaction(fn -> {pass(t, keys), record().ids} end)

        assert manifest == MapSet.new(keys, &id(t, &1))
      end
    end

    test "T-A18 a nested Ash action's failure swallowed by a caller-owned Audit.transaction" do
      guard_faults!()
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      keys = [{:domain, "t-a18-ash-a.test"}, {:domain, "t-a18-ash-b.test"}]
      parent = self()

      Audit.transaction(fn ->
        attempt =
          try do
            with_fault(:before_first_lock, fn ->
              Account
              |> Ash.Changeset.for_create(:create, SalesFixtures.account_attrs(), actor: admin)
              |> Ash.Changeset.before_action(
                fn changeset ->
                  :ok = pass(tenant.id, keys)
                  changeset
                end,
                prepend?: true
              )
              |> Ash.create()
            end)
          rescue
            error -> {:raised, error.__struct__}
          end

        send(parent, {:c302_attempt, attempt})

        send(
          parent,
          {:c302_after,
           [
             outcome(fn -> pass(tenant.id, keys) end),
             outcome(fn -> require_held(tenant.id, keys) end)
           ]}
        )

        :swallowed
      end)

      assert_received {:c302_attempt, attempt}
      refute match?({:ok, _}, attempt), "C3-02: the faulted nested action must fail"
      assert_received {:c302_after, later}
      assert later == List.duplicate({:raised, @inconsistent}, 2)
      assert scope() == nil
    end
  end

  ## T-A2 rows

  defp rec(token, pid, ids), do: "v1;#{token};#{pid};#{Enum.join(ids, ",")}"

  defp rows do
    ab = rec(@t, @pid, [@a, @b])
    empty = rec(@t, @pid, [])
    foreign = rec(@u, @pid, [@x])

    [
      # rule 1: poisoned, any setting
      {"1 poisoned, absent", :poisoned, nil, [], [@a], {:raise, @inconsistent}},
      {"1 poisoned, own record", :poisoned, rec(@t, @pid, [@a]), [@a], [@a],
       {:raise, @inconsistent}},
      {"1 poisoned, empty request", :poisoned, nil, [], [], {:raise, @inconsistent}},
      # rule 2: re-entrancy, or a rescued failure that missed poisoning
      {"2 acquiring", {:acquiring, nil, [@a]}, nil, [], [@a], {:raise, @inconsistent}},
      {"2 acquiring, lock taken", {:acquiring, nil, [@a]}, nil, [@a], [@a],
       {:raise, @inconsistent}},
      # rule 3: requested in the manifest, the whole manifest held
      {"3 pass [A,B], require [A]", {:passed, nil, [@a, @b]}, ab, [@a, @b], [@a], :ok},
      {"3 [] after a pass", {:passed, nil, [@a, @b]}, ab, [@a, @b], [], :ok},
      {"3 duplicates", {:passed, nil, [@a, @b]}, ab, [@a, @b], [@a, @b, @a], :ok},
      {"3 extra held keys", {:passed, nil, [@a, @b]}, ab, [@a, @b, @x], [@b], :ok},
      {"3 empty pass, empty request", {:passed, nil, []}, empty, [], [], :ok},
      # rule 4: a requested id outside the held manifest
      {"4 new key", {:passed, nil, [@a, @b]}, ab, [@a, @b], [@c], {:raise, @late}},
      {"4 one new key", {:passed, nil, [@a, @b]}, ab, [@a, @b], [@a, @c], {:raise, @late}},
      {"4 empty pass, then [X]", {:passed, nil, []}, empty, [], [@x], {:raise, @late}},
      {"4 empty pass, X held elsewhere", {:passed, nil, []}, empty, [@x], [@x], {:raise, @late}},
      # rule 5: own token, but the manifest is not held, or pid/format wrong
      {"5 B released", {:passed, nil, [@a, @b]}, ab, [@a], [@a], {:raise, @inconsistent}},
      {"5 B released, new key", {:passed, nil, [@a, @b]}, ab, [@a], [@c],
       {:raise, @inconsistent}},
      {"5 pid mismatch", {:passed, nil, [@a, @b]}, rec(@t, @other_pid, [@a, @b]), [@a, @b], [@a],
       {:raise, @inconsistent}},
      {"5 unparseable ids", {:passed, nil, [@a, @b]}, "v1;#{@t};#{@pid};-3,zz", [@a, @b], [@a],
       {:raise, @inconsistent}},
      {"5 truncated record", {:passed, nil, [@a, @b]}, "v1;#{@t};#{@pid}", [@a, @b], [@a],
       {:raise, @inconsistent}},
      {"5 unknown version", {:passed, nil, [@a, @b]}, "v2;#{@t};#{@pid};-3,5", [@a, @b], [@a],
       {:raise, @inconsistent}},
      # rule 6: proven revert (setting back at prior, no new id held) → fresh pass
      {"6 reverted to absent", {:passed, nil, [@a, @b]}, nil, [], [@c], {:acquiring, nil, [@c]}},
      {"6 reverted to empty", {:passed, nil, [@a, @b]}, "", [], [@c], {:acquiring, nil, [@c]}},
      {"6 reverted to a foreign prior", {:passed, foreign, [@a]}, foreign, [@x], [@a, @x],
       {:acquiring, foreign, [@a]}},
      {"6 empty pass reverted (vacuous)", {:passed, nil, []}, nil, [], [@x],
       {:acquiring, nil, [@x]}},
      {"6 unrelated key held", {:passed, nil, [@a, @b]}, nil, [@c], [@c, @a],
       {:acquiring, nil, [@a]}},
      # rule 7: not this token, and not a proven revert
      {"7 revert, A still held", {:passed, nil, [@a, @b]}, nil, [@a], [@c],
       {:raise, @inconsistent}},
      {"7 revert, both still held", {:passed, nil, [@a, @b]}, nil, [@a, @b], [@c],
       {:raise, @inconsistent}},
      {"7 foreign record mid-scope", {:passed, nil, [@a]}, rec(@u, @pid, []), [], [@a],
       {:raise, @inconsistent}},
      {"7 foreign record, not the prior", {:passed, foreign, [@a]}, rec(@u, @pid, []), [@x], [@a],
       {:raise, @inconsistent}},
      # rule 8: first pass
      {"8 absent", :none, nil, [], [@a, @b], {:acquiring, nil, [@a, @b]}},
      {"8 empty", :none, "", [], [@a], {:acquiring, nil, [@a]}},
      {"8 another token's record", :none, foreign, [@x], [@x, @a], {:acquiring, foreign, [@a]}},
      {"8 empty pass", :none, nil, [], [], {:acquiring, nil, []}},
      {"8 duplicates", :none, nil, [], [@a, @a], {:acquiring, nil, [@a]}},
      {"8 unparseable record", :none, "garbage", [], [@a], {:raise, @inconsistent}},
      {"8 unknown version", :none, "v2;#{@u};#{@pid};", [], [@a], {:raise, @inconsistent}},
      # rule 9: this token without a pass is impossible under the writer convention
      {"9 own record", :none, rec(@t, @pid, [@a]), [@a], [@a], {:raise, @inconsistent}},
      {"9 own empty record", :none, empty, [], [], {:raise, @inconsistent}}
    ]
  end

  # The state's id collections are sets (MapSet), like the held set.
  defp as_sets({phase, prior, ids}), do: {phase, prior, MapSet.new(ids)}
  defp as_sets(state), do: state

  defp normalize_expected({:acquiring, prior, planned}),
    do: {:acquiring, prior, MapSet.new(planned)}

  defp normalize_expected(other), do: other

  defp decided(scope, setting, pid, held, requested) do
    case call(@decision, :decide, [scope, setting, pid, held, requested]) do
      {:acquiring, prior, planned} -> {:acquiring, prior, MapSet.new(planned)}
      other -> other
    end
  rescue
    error -> {:raise, error.__struct__}
  end

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp exception!(module) do
    assert Code.ensure_loaded?(module) and function_exported?(module, :exception, 1),
           "C3-02: exception #{inspect(module)} is not defined"

    module
  end

  defp guard_keys! do
    present!(@keys, :pass, 2)
    present!(@keys, :require_held, 2)
    present!(@keys, :id, 3)
    Enum.each(@exceptions, &exception!/1)
  end

  defp guard_scope! do
    present!(@scope_struct, :__struct__, 0)
  end

  defp guard_faults! do
    guard_keys!()
    present!(@faults, :with_fault, 2)
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp pass(tenant, keys), do: call(@keys, :pass, [tenant, keys])
  defp require_held(tenant, keys), do: call(@keys, :require_held, [tenant, keys])
  defp key_id(tenant, kind, raw), do: call(@keys, :id, [tenant, kind, raw])

  # `id/3`'s result or its raised exception as a value (struct, kind and
  # message), so a RED assertion compares values instead of raising.
  defp id_outcome(tenant, kind, raw) do
    {:ok, key_id(tenant, kind, raw)}
  rescue
    error -> {:raised, error.__struct__, Map.get(error, :kind), Exception.message(error)}
  end

  defp id(tenant, {kind, raw}), do: key_id(tenant, kind, raw)
  defp with_fault(point, fun), do: call(@faults, :with_fault, [point, fun])

  ## The plan's H, for cross-checking the recorded literals only

  defp h(kind, tenant, bytes) do
    <<id::signed-64, _rest::binary>> =
      :crypto.hash(
        :sha256,
        "sdr-identity-key/1\0" <> Atom.to_string(kind) <> "\0" <> tenant <> "\0" <> bytes
      )

    id
  end

  ## Database state

  defp tenant, do: Ecto.UUID.generate()

  defp state do
    %{rows: [[setting, pid, ids]]} = Repo.query!(@state_sql)
    %{setting: setting, pid: pid, held: MapSet.new(ids)}
  end

  defp held, do: state().held

  defp setting do
    case state().setting do
      "" -> nil
      value -> value
    end
  end

  defp record do
    case setting() do
      nil ->
        nil

      value ->
        assert value =~ @record_format, "C3-02: sdr.identity_pass is not a v1 record"
        [_version, token, pid, ids] = String.split(value, ";")
        %{token: token, pid: String.to_integer(pid), ids: parse_ids(ids)}
    end
  end

  defp parse_ids(""), do: MapSet.new()
  defp parse_ids(ids), do: ids |> String.split(",") |> MapSet.new(&String.to_integer/1)

  # Test-only: simulates a record no trusted writer would publish.
  defp forge!(value),
    do: Repo.query!("SELECT set_config('sdr.identity_pass', $1, true)", [value])

  defp savepoint!(name), do: Repo.query!("SAVEPOINT #{name}")
  defp rollback_to!(name), do: Repo.query!("ROLLBACK TO SAVEPOINT #{name}")

  ## Scope observation

  defp scope, do: Process.get(@scope_key)

  defp scope_token do
    assert %{token: token} = scope()
    token
  end

  defp observe(value) do
    send(self(), {:c302_scope, scope()})
    value
  end

  defp observed(count) do
    for _ <- 1..count do
      assert_received {:c302_scope, seen}
      seen
    end
  end

  defp assert_fresh_scope!(observed) do
    assert match?(%{__struct__: @scope_struct, state: :none}, observed),
           "C3-02: no fresh application scope was registered: #{inspect(observed)}"

    assert observed.token =~ ~r/^[0-9a-f]{32}$/
  end

  ## Outcomes

  defp outcome(fun) do
    case fun.() do
      :ok -> :ok
      other -> {:returned, other}
    end
  rescue
    error -> {:raised, error.__struct__}
  end

  defp raised(fun) do
    result = fun.()
    flunk("C3-02: expected an IdentityKeys exception, got #{inspect(result)}")
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> error
  end

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)

  ## Query tracing

  defp trace_queries(fun) do
    parent = self()
    handler = "c3-02-identity-keys-#{System.unique_integer([:positive])}"

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

  defp transaction_control?(sql),
    do: sql =~ ~r/^\s*(begin|commit|rollback|savepoint|release)\b/i

  defp assert_safe_param!(param) when is_integer(param), do: :ok

  defp assert_safe_param!(param) do
    assert is_binary(param) and param =~ @record_format,
           "C3-02: only integer lock ids and the id-only record may be parameters"
  end
end
