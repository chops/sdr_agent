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
  process, runs `fun` and ends the registration when `fun` returns or
  raises; inside a transaction it refuses with `{:error, :in_transaction}`
  and observes nothing. `current/0` is the registration (`{:ok, t}` or
  `:none`; no I/O) and `verify/1` accepts only that exact registration.

    * **levels:** a provisioning lease of the configured nonce, the bound
      environment and a claim naming the current registry entry's id and
      digest and the environment's binding give `:provisioning`; a run
      lease with `authorization.json` equal to the claim gives
      `:spend_ready`; anything else gives `:none` — a claim for another id,
      another digest or another binding, no registry entry, a lease nonce
      or mode other than the configuration's, run mode without the final
      file or with one that differs from the claim.
    * **registration:** process-bound, ended on return and on raise, never
      seen by another process; a copy with any field changed never
      verifies.

  RED: `SdrAgent.AgentEnv.Provisioning` does not exist. Every test stops at
  an explicit `c2star-s2:` module guard after its fixtures (structural).
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvFixtures

  @moduletag :c2star_s2

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

    test "inside within/2 the registration verifies", _ctx do
      env = provisioning_env!()

      result = within(env.entry.id, fn -> {current(), current() |> elem(1) |> verify()} end)
      assert match?({{:ok, _attestation}, _verified}, result), inspect(result)
      {{:ok, attestation}, verified} = result

      assert verified == {:ok, attestation},
             "c2star-s2: the active registration did not verify: #{inspect(verified)}"
    end

    test "a run lease with authorization.json equal to the claim gives :spend_ready", _ctx do
      env = provisioning_env!(mode: :run)
      final!(env.root, env.claim)
      assert level(env) == :spend_ready
    end

    test "run mode without the final file, or with one that differs from the claim, is :none",
         _ctx do
      env = provisioning_env!(mode: :run)
      assert level(env) == :none, "c2star-s2: run mode with only the claim"

      differing = provisioning_env!(mode: :run)
      final!(differing.root, differing.claim, %{"nonce" => AgentEnvFixtures.nonce()})
      assert level(differing) == :none, "c2star-s2: run mode, final nonce differs from the claim"
    end

    test "a claim naming another id, digest or binding is :none", _ctx do
      cases = [
        another_id: %{"authorization_id" => entry_id("test-s2-other")},
        another_digest: %{"authorization_sha256" => rand_hex(32)},
        another_binding: %{"binding_sha256" => rand_hex(32)}
      ]

      for {label, overrides} <- cases do
        env = provisioning_env!(claim_overrides: overrides)
        assert level(env) == :none, "c2star-s2: #{label}"
      end
    end

    test "with no registry entry the claim attests nothing", _ctx do
      env = provisioning_env!()
      put_test_entries!([])
      assert level(env) == :none
    end

    test "a lease nonce or mode other than the configuration's is :none", _ctx do
      nonce = provisioning_env!(nonce: AgentEnvFixtures.nonce())
      assert level(nonce) == :none, "c2star-s2: lease nonce differs from the configured nonce"

      mode = provisioning_env!(lease: :run)
      assert level(mode) == :none, "c2star-s2: a run lease under the provisioning mode"
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
    test "ends when within/2 returns and when its function raises", _ctx do
      env = provisioning_env!()
      {:ok, returned} = within(env.entry.id, fn -> current() end)
      assert current() == :none
      assert verify(returned) == {:error, :provisioning_unattested}

      assert_raise RuntimeError, "c2star-s2 raised inside", fn ->
        within(env.entry.id, fn -> raise "c2star-s2 raised inside" end)
      end

      assert current() == :none
    end

    test "another process sees no registration and cannot verify this one", _ctx do
      env = provisioning_env!()

      seen =
        within(env.entry.id, fn ->
          {:ok, attestation} = current()

          fn -> {current(), verify(attestation)} end
          |> Task.async()
          |> Task.await()
        end)

      assert seen == {:none, {:error, :provisioning_unattested}}
    end

    test "a copy with any field changed never verifies", _ctx do
      env = provisioning_env!()

      results =
        within(env.entry.id, fn ->
          {:ok, attestation} = current()

          for {field, value} <- [
                level: :spend_ready,
                authorization_id: entry_id("test-s2-forged"),
                authorization_sha256: rand_hex(32),
                tenant_id: Ecto.UUID.generate(),
                ref: make_ref()
              ],
              into: %{},
              do: {field, verify(Map.put(attestation, field, value))}
        end)

      for {field, result} <- results do
        assert result == {:error, :provisioning_unattested}, "c2star-s2: forged #{field} verified"
      end
    end
  end
end
