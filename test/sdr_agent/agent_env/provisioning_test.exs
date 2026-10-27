defmodule SdrAgent.AgentEnv.ProvisioningTest do
  @moduledoc """
  C2* S2 RED-2 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC8,
  §4.3, §5 and §7 row 9; Codex plan/entity PASS `aa42492e`, OQ12: a
  separate no-spend registration, not a business operation-snapshot entry,
  with no file observation inside a transaction and no caller-supplied map
  or level as authority; ADR-0004 agent-environment item 4): the
  provisioning attestation `SdrAgent.AgentEnv.Provisioning`.

  `within(authorization_id, fun)` observes the agent environment's files
  outside any transaction, registers that observation in the calling
  process, runs `fun` and returns its result, and ends the registration
  when `fun` returns or raises; inside a transaction it refuses with
  `{:error, :in_transaction}`, observes nothing and never invokes `fun`.
  `current/0` is the registration (`{:ok, t}` inside `within/2`, `:none`
  outside; no I/O) and `verify/1` accepts only that exact registration.

    * **levels:** a provisioning lease of the configured nonce, the bound
      environment and a claim naming the current registry entry's id and
      digest and the environment's binding give `:provisioning`; a run
      lease with `authorization.json` equal to the claim gives
      `:spend_ready`, still carrying the registry ENTRY digest, not the
      final file's content digest (Q2). Anything else is a registration of
      level `:none` (Q1), which confers no authority: a claim for another
      id, another digest or another binding, no registry entry, a lease
      nonce or mode other than the configuration's, run mode without the
      final file (Q8) or with a final nonce, id, digest or binding other
      than the claim's.
    * **registration:** process-bound, ended on return and on raise, never
      seen by another process. A copy with any one of its twelve fields
      changed never verifies: one independent test per field (`ref`,
      `owner`, `level`, `authorization_id`, `authorization_sha256`,
      `binding_sha256`, `tenant_id`, `database`, `database_oid`,
      `claim_nonce`, `lease_nonce`, `observed_at`).

  RED: `SdrAgent.AgentEnv.Provisioning` does not exist. Every test stops at
  an explicit `c2star-s2:` module guard after its fixtures (structural).

  RED-2 supplement (Codex interface rulings `032335a9`, Q1, Q2 and Q8, and
  its registration-field qualification): the per-field tamper tests; one
  case per test where a test checked several; the registration is taken by
  assertion, never by a match that would crash on a wrong implementation.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvFixtures

  @moduletag :c2star_s2

  # The closed registration keys (Codex Q2).
  @registration_fields [
    :ref,
    :owner,
    :level,
    :authorization_id,
    :authorization_sha256,
    :binding_sha256,
    :tenant_id,
    :database,
    :database_oid,
    :claim_nonce,
    :lease_nonce,
    :observed_at
  ]

  setup do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    %{tenant: bootstrap!()}
  end

  # The registration as seen inside `within/2`, for `env`'s entry.
  defp observed(env) do
    within(env.entry.id, fn -> current() end)
  end

  defp level(env) do
    case observed(env) do
      {:ok, attestation} -> attestation.level
      other -> {:unexpected, other}
    end
  end

  # Inside `within/2`: the registration, by assertion.
  defp registration! do
    result = current()

    assert match?({:ok, _attestation}, result),
           "c2star-s2: no registration inside within/2: #{inspect(result)}"

    elem(result, 1)
  end

  # Another value of the same shape for `field`.
  defp tampered(:ref, _value), do: make_ref()
  defp tampered(:owner, _value), do: spawn(fn -> :ok end)
  defp tampered(:level, :spend_ready), do: :provisioning
  defp tampered(:level, _value), do: :spend_ready
  defp tampered(:authorization_id, _value), do: entry_id("test-s2-forged")
  defp tampered(:authorization_sha256, _value), do: rand_hex(32)
  defp tampered(:binding_sha256, _value), do: rand_hex(32)
  defp tampered(:tenant_id, _value), do: Ecto.UUID.generate()
  defp tampered(:database, _value), do: "sdr_agent_forged"
  defp tampered(:database_oid, value) when is_integer(value), do: value + 1
  defp tampered(:database_oid, _value), do: 1
  defp tampered(:claim_nonce, _value), do: AgentEnvFixtures.nonce()
  defp tampered(:lease_nonce, _value), do: AgentEnvFixtures.nonce()
  defp tampered(:observed_at, %DateTime{} = value), do: DateTime.add(value, 1, :microsecond)
  defp tampered(:observed_at, _value), do: DateTime.add(now(), 1, :microsecond)

  # A final-file value other than the claim's.
  defp other_final("nonce"), do: AgentEnvFixtures.nonce()
  defp other_final("authorization_id"), do: entry_id("test-s2-other")
  defp other_final(_digest), do: rand_hex(32)

  describe "levels" do
    test "a provisioning lease, the environment and the claim give :provisioning", ctx do
      env = provisioning_env!()
      {database, oid} = AgentEnvFixtures.live_identity!()
      result = observed(env)

      assert match?({:ok, %{level: :provisioning}}, result),
             "c2star-s2: expected a :provisioning registration, got #{inspect(result)}"

      {:ok, attestation} = result

      assert Map.take(attestation, [
               :authorization_id,
               :authorization_sha256,
               :binding_sha256,
               :tenant_id,
               :database,
               :database_oid,
               :claim_nonce,
               :lease_nonce,
               :observed_at,
               :owner
             ]) == %{
               authorization_id: env.entry.id,
               authorization_sha256: env.digest,
               binding_sha256: env.bound.binding_sha256,
               tenant_id: ctx.tenant.id,
               database: database,
               database_oid: oid,
               claim_nonce: env.claim.nonce,
               lease_nonce: env.bound.nonce,
               observed_at: now(),
               owner: self()
             }
    end

    test "control: inside within/2 the registration verifies", _ctx do
      env = provisioning_env!()

      result =
        within(env.entry.id, fn ->
          attestation = registration!()
          {:checked, attestation, verify(attestation)}
        end)

      assert match?({:checked, _attestation, _verified}, result), inspect(result)
      {:checked, attestation, verified} = result

      assert verified == {:ok, attestation},
             "c2star-s2: the active registration did not verify: #{inspect(verified)}"
    end

    test "outside within/2 there is no registration (Q1)", _ctx do
      provisioning_env!()
      require_function!(provisioning_module(), :within, 2)
      assert current() == :none
    end

    test "a run lease with authorization.json equal to the claim gives :spend_ready", _ctx do
      env = provisioning_env!(mode: :run)
      final = final!(env.root, env.claim)
      result = observed(env)

      assert match?({:ok, %{level: :spend_ready}}, result),
             "c2star-s2: expected a :spend_ready registration, got #{inspect(result)}"

      {:ok, attestation} = result
      # The registry ENTRY digest, never the final file's content digest (Q2).
      assert attestation.authorization_sha256 == env.digest
      assert attestation.authorization_sha256 != final.sha256
    end

    test "run mode with only the claim (no final file) is :none (Q8)", _ctx do
      env = provisioning_env!(mode: :run)
      assert level(env) == :none
    end

    for key <- ["nonce", "authorization_id", "authorization_sha256", "binding_sha256"] do
      @tag final_key: key
      test "run mode with a final #{key} other than the claim's is :none", ctx do
        env = provisioning_env!(mode: :run)
        final!(env.root, env.claim, %{ctx.final_key => other_final(ctx.final_key)})
        assert level(env) == :none, "c2star-s2: final #{ctx.final_key} differs from the claim"
      end
    end

    for key <- ["authorization_id", "authorization_sha256", "binding_sha256"] do
      @tag claim_key: key
      test "a claim with another #{key} is :none", ctx do
        overrides = %{ctx.claim_key => other_final(ctx.claim_key)}
        env = provisioning_env!(claim_overrides: overrides)
        assert level(env) == :none, "c2star-s2: claim #{ctx.claim_key} differs"
      end
    end

    test "with no registry entry the claim attests nothing", _ctx do
      env = provisioning_env!()
      put_test_entries!([])
      assert level(env) == :none
    end

    test "a lease nonce other than the configured nonce is :none", _ctx do
      env = provisioning_env!(nonce: AgentEnvFixtures.nonce())
      assert level(env) == :none
    end

    test "a run lease under the provisioning mode is :none", _ctx do
      env = provisioning_env!(lease: :run)
      assert level(env) == :none
    end
  end

  describe "transactions" do
    test "inside a transaction within/2 refuses and observes nothing", _ctx do
      env = provisioning_env!()
      require_function!(provisioning_module(), :within, 2)
      parent = self()

      {:ok, {result, calls}} =
        SdrAgent.Repo.transaction(fn ->
          AgentEnvFixtures.trace_file_calls(fn ->
            within(env.entry.id, fn -> send(parent, :fun_ran) end)
          end)
        end)

      assert result == {:error, :in_transaction}
      assert calls == [], "c2star-s2: file calls inside the transaction: #{inspect(calls)}"
      refute_received :fun_ran
      assert current() == :none
    end
  end

  describe "registration" do
    test "ends when within/2 returns", _ctx do
      env = provisioning_env!()
      returned = within(env.entry.id, &registration!/0)
      assert current() == :none
      assert verify(returned) == {:error, :provisioning_unattested}
    end

    test "ends when its function raises", _ctx do
      env = provisioning_env!()

      assert_raise RuntimeError, "c2star-s2 raised inside", fn ->
        within(env.entry.id, fn ->
          send(self(), {:registered, registration!()})
          raise "c2star-s2 raised inside"
        end)
      end

      assert_received {:registered, registered}
      assert current() == :none
      assert verify(registered) == {:error, :provisioning_unattested}
    end

    test "another process sees no registration and cannot verify this one", _ctx do
      env = provisioning_env!()

      seen =
        within(env.entry.id, fn ->
          attestation = registration!()

          fn -> {current(), verify(attestation)} end
          |> Task.async()
          |> Task.await()
        end)

      assert seen == {:none, {:error, :provisioning_unattested}}
    end

    for field <- @registration_fields do
      @tag registration_field: field
      test "a copy with #{field} changed never verifies", ctx do
        env = provisioning_env!()
        field = ctx.registration_field

        result =
          within(env.entry.id, fn ->
            attestation = registration!()
            forged = Map.put(attestation, field, tampered(field, Map.get(attestation, field)))
            {Map.get(forged, field) != Map.get(attestation, field), verify(forged)}
          end)

        assert result == {true, {:error, :provisioning_unattested}},
               "c2star-s2: a copy with #{field} changed: #{inspect(result)}"
      end
    end
  end
end
