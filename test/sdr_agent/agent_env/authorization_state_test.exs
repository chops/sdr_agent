defmodule SdrAgent.AgentEnv.AuthorizationStateTest do
  @moduledoc """
  C2* S2 RED-3 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC9, §5
  "`lib/sdr_agent/agent_env/authorization_state.ex`" and §7 row
  "authorization_state_test.exs"; Codex plan/entity PASS `aa42492e`, OQ10,
  OQ13 and OQ14): `SdrAgent.AgentEnv.AuthorizationState`, the authorization
  lifecycle of `bin/agent-env authorize` (T-V3).

  `classify(root, db_facts)` returns `:unclaimed | {:claimed, claim} |
  {:complete, final} | {:quarantine, reason}` (`claim`/`final`: the decoded
  file, string keys). `db_facts` is `:unknown` (files only: the pre-lease
  check, never live consistency, OQ14) or `{:grant, grant_or_nil}` (the
  tenant's delegated grant for the claimed id, read by the caller after the
  lease). Quarantine reasons (plan §5): `:final_without_claim`,
  `:claim_other_authorization`, `:registry_digest_changed`,
  `:binding_mismatch`, `:grant_missing`, `:grant_inconsistent`,
  `:invalid_file`. Quarantine is classified, never repaired.

  Writers are create-only (S1 `State.create/3`): `write_claim(root, entry)`
  creates the claim for the registry entry bound to the environment (a fresh
  nonce), or accepts an existing claim for that same id, digest and binding
  unchanged; any other existing claim is refused untouched.
  `write_final(root, %{grant_id:, event_id:})` creates `authorization.json`
  from the claim (`revision: 1`, the claim's nonce, OQ13) once; a second
  write is refused untouched. `provisioned_event(grant)` is the grant's one
  `model.grant.provisioned` event (a kernel read).

  The `db_facts` shape and the writer arguments are fixed here by RED-3 for
  this S2-owned module; the plan names the functions and reasons only.

  RED: `SdrAgent.AgentEnv.AuthorizationState` does not exist; every test
  stops at an explicit `c2star-s2:` function guard after its fixtures
  (structural).
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @moduletag :c2star_s2

  @module SdrAgent.AgentEnv.AuthorizationState

  setup do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    %{tenant: bootstrap!()}
  end

  ## Helpers (guarded: the subject may not exist at RED)

  defp classify(env, facts) do
    require_function!(@module, :classify, 2)
    invoke(@module, :classify, [env.root, facts])
  end

  defp write_claim(env, entry) do
    require_function!(@module, :write_claim, 2)
    invoke(@module, :write_claim, [env.root, entry])
  end

  defp write_final(env, ids) do
    require_function!(@module, :write_final, 2)
    invoke(@module, :write_final, [env.root, ids])
  end

  defp file(env, name), do: File.read(Fx.path(env.root, name))

  # A provisioned grant and the final file naming it and its event.
  defp complete!(ctx) do
    env = provisioned!()
    assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")
    final = final!(env.root, env.claim, %{"grant_id" => env.grant.id, "event_id" => event.id})
    Map.merge(env, %{event: event, final: final})
  end

  ## classify/2

  describe "classify/2, files only" do
    test "no claim and no final file is :unclaimed", _ctx do
      env = provisioning_env!(claim: false)
      assert classify(env, :unknown) == :unclaimed
    end

    test "a claim alone is {:claimed, claim}", _ctx do
      env = provisioning_env!()
      result = classify(env, :unknown)
      id = env.entry.id
      nonce = env.claim.nonce

      assert match?({:claimed, %{"authorization_id" => ^id, "nonce" => ^nonce}}, result),
             "c2star-s2: #{inspect(result)}"
    end

    test "a claim and its final file are {:complete, final} (files only, OQ14)", ctx do
      env = complete!(ctx)
      result = classify(env, :unknown)
      grant_id = env.grant.id
      assert match?({:complete, %{"grant_id" => ^grant_id, "revision" => 1}}, result)
    end

    test "a final file without a claim is quarantined", ctx do
      env = complete!(ctx)
      File.rm!(Fx.path(env.root, :claim))
      assert classify(env, :unknown) == {:quarantine, :final_without_claim}
    end

    test "a claim for an id other than the registry's is quarantined", _ctx do
      env = provisioning_env!(claim_overrides: %{"authorization_id" => entry_id("test-s2-other")})
      assert classify(env, :unknown) == {:quarantine, :claim_other_authorization}
    end

    test "a claim whose digest is no longer the registry entry's is quarantined", _ctx do
      env = provisioning_env!()
      put_test_entries!([%{env.entry | total_attempts: 5}])
      assert classify(env, :unknown) == {:quarantine, :registry_digest_changed}
    end

    test "a claim bound to another environment is quarantined", _ctx do
      env = provisioning_env!(claim_overrides: %{"binding_sha256" => rand_hex(32)})
      assert classify(env, :unknown) == {:quarantine, :binding_mismatch}
    end

    test "invalid claim bytes are quarantined", _ctx do
      env = provisioning_env!()
      Fx.write_state!(env.root, :claim, "{\"authorization_id\": \"not canonical\"}\n")
      assert classify(env, :unknown) == {:quarantine, :invalid_file}
    end
  end

  describe "classify/2 with the grant" do
    test "a claim with no grant yet is {:claimed, claim} (a re-run provisions)", _ctx do
      env = provisioning_env!()
      assert match?({:claimed, _claim}, classify(env, {:grant, nil}))
    end

    test "a claim with its grant and no final file is {:claimed, claim} (re-run replays)", _ctx do
      env = provisioned!()
      assert match?({:claimed, _claim}, classify(env, {:grant, env.grant}))
    end

    test "a claim, a final file and the grant they name are {:complete, final}", ctx do
      env = complete!(ctx)
      assert match?({:complete, _final}, classify(env, {:grant, env.grant}))
    end

    test "a claim and a final file with the grant missing are quarantined", ctx do
      env = complete!(ctx)
      assert classify(env, {:grant, nil}) == {:quarantine, :grant_missing}
    end

    test "a final file naming another grant id is quarantined", ctx do
      env = complete!(ctx)
      other = delegated_row!(ctx.tenant)
      assert classify(env, {:grant, other}) == {:quarantine, :grant_inconsistent}
    end
  end

  ## Writers

  describe "write_claim/2" do
    test "creates the claim for the registry entry bound to the environment", _ctx do
      env = provisioning_env!(claim: false)
      result = write_claim(env, env.entry)
      assert match?({:ok, sha256} when is_binary(sha256), result), inspect(result)
      {:ok, sha256} = result
      assert {:valid, ^sha256, data} = State.read(env.root, :claim)

      assert Map.take(data, ["authorization_id", "authorization_sha256", "binding_sha256"]) == %{
               "authorization_id" => env.entry.id,
               "authorization_sha256" => env.digest,
               "binding_sha256" => env.bound.binding_sha256
             }

      assert data["nonce"] =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "accepts an existing claim for the same entry unchanged", _ctx do
      env = provisioning_env!()
      before = file(env, :claim)
      assert write_claim(env, env.entry) == {:ok, env.claim.sha256}
      assert file(env, :claim) == before
    end

    test "refuses over a claim for another entry, untouched", _ctx do
      env = provisioning_env!()
      before = file(env, :claim)
      other = test_entry()
      put_test_entries!([other])
      assert match?({:error, _reason}, write_claim(env, other))
      assert file(env, :claim) == before
    end
  end

  describe "write_final/2" do
    test "creates authorization.json from the claim once (revision 1, the claim's nonce)", ctx do
      env = provisioned!()
      assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")
      ids = %{grant_id: env.grant.id, event_id: event.id}
      result = write_final(env, ids)
      assert match?({:ok, sha256} when is_binary(sha256), result), inspect(result)
      {:ok, sha256} = result
      assert {:valid, ^sha256, data} = State.read(env.root, :authorization)

      assert data == %{
               "authorization_id" => env.entry.id,
               "authorization_sha256" => env.digest,
               "binding_sha256" => env.bound.binding_sha256,
               "grant_id" => env.grant.id,
               "revision" => 1,
               "event_id" => event.id,
               "nonce" => env.claim.nonce
             }

      before = file(env, :authorization)
      again = write_final(env, %{ids | grant_id: Ecto.UUID.generate()})
      assert match?({:error, _reason}, again), inspect(again)
      assert file(env, :authorization) == before
    end
  end

  describe "provisioned_event/1" do
    test "is the grant's one model.grant.provisioned event, carrying the claim's nonce", ctx do
      env = provisioned!()
      require_function!(@module, :provisioned_event, 1)
      result = invoke(@module, :provisioned_event, [env.grant])
      assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")
      assert match?({:ok, %{id: _}}, result), inspect(result)
      {:ok, found} = result
      assert found.id == event.id
      assert found.payload["arguments"]["claim_nonce"] == env.claim.nonce
    end
  end
end
