defmodule SdrAgent.AgentEnv.SpendReadyTest do
  @moduledoc """
  C2* S2 RED-3 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC8 and
  AC11, §4.3 and §7 row "spend_ready_test.exs"; Codex plan/entity PASS
  `aa42492e`, OQ10 and OQ14; ADR-0004 agent-environment items 4, 5 and 11):
  the S2 bodies of `SdrAgent.AgentEnv.SpendReady`, whose S1 stubs refuse
  every input.

    * **`level/1`** (pure: no file call, no query): `:spend_ready` for an
      operation snapshot with a run lease targeting the environment's
      binding, a valid `authorization.json` bound to it, and the compiled
      registry's current entry with that id and digest; `:none` when any one
      of those differs.
    * **`preflight/1`** (pre-lease, views of `environment.json`,
      `authorization.json` and the claim; never authority): `:ok` for
      consistent files with no lease and no database query; a refusal when
      the claim is missing, the final file differs from the claim, or the
      registry has no such entry.
    * **`at_boot/1`** (post-lease, views plus the run lease and its nonce; no
      database): `:ok` when consistent; a refusal for a missing claim or a
      final file other than the claim (T-V8 cases 1-2); `:agent_env_expired`
      at or after the registry entry's `expires_at` or the environment end
      (T-W5, boot, S2 half).
    * **`at_start/1`** (post-lease, the bound environment, the final file's
      view and the tenant; reads the grant): `:ok` for the delegated grant
      the final file names; `:grant_inconsistent` when that grant is missing,
      has another digest, or is owner-form (T-V8 case 3, OQ10);
      `:agent_env_expired` for a revoked grant (T-W5).

  The inputs are exactly the shapes S1's callers pass (`Launcher`,
  `Boot.spend_ready/3`, `Instance.spend_ready/2`). The refusal reasons the
  plan does not name are asserted only as `{:error, _}`; each such case has
  a positive counterpart that the S1 stubs refuse, so the file as a whole
  discriminates.

  RED: `level/1` does not exist (structural guard); the S1 stubs refuse
  every input, so each positive case and each named-reason case fails its
  assertion (behavioural). The unnamed-reason refusals pass today (refuse-
  all; discriminating only together with the positives).

  Fixtures: a delegated grant provisioned through the GREEN-2 route
  (`provisioned!/1`), then the run side written with S1's fixtures (a run
  lease, the run configuration, the final file naming the grant and its
  `model.grant.provisioned` event). Synthetic registry entries only.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.AgentEnv.SpendReady
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Agents
  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @moduletag :c2star_s2

  setup do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## Fixtures

  # A delegated grant provisioned in the environment, then the run side: a
  # run lease of its binding, the run configuration with that nonce, and the
  # final file naming the grant and its provisioned event.
  defp spend_ready_env!(ctx, opts \\ []) do
    env = provisioned!(opts)
    assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")
    lease_nonce = Fx.write_lease!(env.root, :run, env.bound.binding_sha256)
    Fx.configure!(env.root, mode: :run, nonce: lease_nonce)
    final = final!(env.root, env.claim, %{"grant_id" => env.grant.id, "event_id" => event.id})
    Map.merge(env, %{lease_nonce: lease_nonce, final: final, event: event})
  end

  defp read(env, name), do: State.read(env.root, name)

  # The three callers' input shapes.
  defp preflight_input(env) do
    %{
      environment: read(env, :environment),
      authorization: read(env, :authorization),
      claim: read(env, :claim)
    }
  end

  defp boot_input(env) do
    %{
      lease: read(env, :lease),
      environment: read(env, :environment),
      authorization: read(env, :authorization),
      claim: read(env, :claim),
      nonce: env.lease_nonce
    }
  end

  defp start_input(env) do
    {:valid, _sha256, environment} = read(env, :environment)

    %{
      environment: environment,
      authorization: read(env, :authorization),
      tenant_id: environment["tenant_id"]
    }
  end

  defp snapshot(env) do
    %OperationSnapshot{
      ref: make_ref(),
      owner: self(),
      generation: 1,
      observed_at: now(),
      lease: read(env, :lease),
      environment: read(env, :environment),
      authorization: read(env, :authorization)
    }
  end

  # The S1 stubs are typed to refuse; calls go through invoke/3 (run time),
  # so the RED assertions compile without a type warning.
  defp preflight(input), do: invoke(SpendReady, :preflight, [input])
  defp at_boot(input), do: invoke(SpendReady, :at_boot, [input])
  defp at_start(input), do: invoke(SpendReady, :at_start, [input])

  defp level(snapshot) do
    require_function!(SpendReady, :level, 1)
    invoke(SpendReady, :level, [snapshot])
  end

  # A final file other than the claim's: replaces it with `overrides`.
  defp rewrite_final!(env, overrides) do
    {:valid, _sha256, data} = read(env, :authorization)
    Fx.write_state!(env.root, :authorization, Map.merge(data, overrides))
  end

  defp assert_refused(result, label) do
    assert match?({:error, reason} when is_atom(reason), result),
           "c2star-s2: #{label}: expected a refusal, got #{inspect(result)}"
  end

  ## level/1

  describe "level/1" do
    test "a run lease, the bound environment and the registry's authorization give :spend_ready",
         ctx do
      env = spend_ready_env!(ctx)
      assert level(snapshot(env)) == :spend_ready
    end

    test "is pure: no file call and no database query", ctx do
      env = spend_ready_env!(ctx)
      snapshot = snapshot(env)
      require_function!(SpendReady, :level, 1)

      {{result, calls}, events} =
        Fx.trace_snapshots(
          fn -> Fx.trace_file_calls(fn -> invoke(SpendReady, :level, [snapshot]) end) end,
          queries: fn _metadata -> true end
        )

      assert result == :spend_ready
      assert calls == [], "c2star-s2: level/1 called the file system: #{inspect(calls)}"
      assert Enum.filter(events, &(&1.kind == :query)) == []
    end

    test "a provisioning lease is :none", ctx do
      env = spend_ready_env!(ctx)
      Fx.write_lease!(env.root, :provisioning, env.bound.binding_sha256)
      assert level(snapshot(env)) == :none
    end

    test "a run lease targeting another binding is :none", ctx do
      env = spend_ready_env!(ctx)
      Fx.write_lease!(env.root, :run, rand_hex(32))
      assert level(snapshot(env)) == :none
    end

    test "no authorization.json is :none", ctx do
      env = spend_ready_env!(ctx)
      File.rm!(Fx.path(env.root, :authorization))
      assert level(snapshot(env)) == :none
    end

    test "an authorization.json bound to another binding is :none", ctx do
      env = spend_ready_env!(ctx)
      rewrite_final!(env, %{"binding_sha256" => rand_hex(32)})
      assert level(snapshot(env)) == :none
    end

    test "no registry entry is :none", ctx do
      env = spend_ready_env!(ctx)
      put_test_entries!([])
      assert level(snapshot(env)) == :none
    end

    test "a registry entry whose digest differs from the authorization's is :none", ctx do
      env = spend_ready_env!(ctx)
      changed = %{env.entry | total_attempts: 5}
      put_test_entries!([changed])
      assert level(snapshot(env)) == :none
    end

    test "an authorization naming another registry id is :none", ctx do
      env = spend_ready_env!(ctx)
      rewrite_final!(env, %{"authorization_id" => entry_id("test-s2-other")})
      assert level(snapshot(env)) == :none
    end
  end

  ## preflight/1

  describe "preflight/1" do
    test "consistent files are :ok with no lease and no database query", ctx do
      env = spend_ready_env!(ctx)
      File.rm!(Fx.path(env.root, :lease))
      input = preflight_input(env)

      {result, events} =
        Fx.trace_snapshots(fn -> preflight(input) end, queries: fn _ -> true end)

      assert result == :ok, "c2star-s2: preflight of consistent files: #{inspect(result)}"
      assert Enum.filter(events, &(&1.kind == :query)) == []
    end

    test "a missing claim is refused", ctx do
      env = spend_ready_env!(ctx)
      File.rm!(Fx.path(env.root, :claim))
      assert_refused(preflight(preflight_input(env)), "no claim")
    end

    test "a final file other than the claim is refused", ctx do
      env = spend_ready_env!(ctx)
      Fx.tamper!(env.root, :authorization)
      assert_refused(preflight(preflight_input(env)), "final nonce != claim nonce")
    end

    test "no registry entry is refused", ctx do
      env = spend_ready_env!(ctx)
      put_test_entries!([])
      assert_refused(preflight(preflight_input(env)), "empty registry")
    end
  end

  ## at_boot/1

  describe "at_boot/1" do
    test "a consistent run environment is :ok", ctx do
      env = spend_ready_env!(ctx)
      result = at_boot(boot_input(env))
      assert result == :ok, "c2star-s2: at_boot of a consistent environment: #{inspect(result)}"
    end

    test "a missing claim is refused (T-V8 case 1)", ctx do
      env = spend_ready_env!(ctx)
      File.rm!(Fx.path(env.root, :claim))
      assert_refused(at_boot(boot_input(env)), "no claim")
    end

    test "a final file other than the claim is refused (T-V8 case 2)", ctx do
      env = spend_ready_env!(ctx)
      Fx.tamper!(env.root, :authorization)
      assert_refused(at_boot(boot_input(env)), "final nonce != claim nonce")
    end

    test "at the registry entry's expires_at the environment is expired (T-W5)", ctx do
      env = spend_ready_env!(ctx)
      Clock.freeze(env.entry.expires_at)
      assert at_boot(boot_input(env)) == {:error, :agent_env_expired}
    end

    test "at the environment end the environment is expired (T-W5)", ctx do
      entry = test_entry(%{expires_at: ~U[2026-11-02 00:00:00.000000Z]})
      assert SdrAgent.AgentEnv.Registry.validate(entry) == :ok, "fixture: the entry validates"
      env = spend_ready_env!(ctx, entry: entry)
      Clock.freeze(AgentEnv.environment_end())
      assert at_boot(boot_input(env)) == {:error, :agent_env_expired}
    end
  end

  ## at_start/1

  describe "at_start/1" do
    test "the delegated grant the final file names is :ok", ctx do
      env = spend_ready_env!(ctx)
      result = at_start(start_input(env))
      assert result == :ok, "c2star-s2: at_start of a consistent grant: #{inspect(result)}"
    end

    test "a missing grant is :grant_inconsistent (T-V8 case 3)", ctx do
      env = spend_ready_env!(ctx)
      rewrite_final!(env, %{"grant_id" => Ecto.UUID.generate()})
      assert at_start(start_input(env)) == {:error, :grant_inconsistent}
    end

    test "a delegated grant with another digest is :grant_inconsistent (T-V8 case 3)", ctx do
      env = provisioning_env!(mode: :run)

      # A raw stand-in under the registry id with a digest other than the
      # entry's (fixture only, not an application write route).
      row =
        delegated_row!(ctx.tenant,
          authorization_id: env.entry.id,
          authorization_sha256: rand_hex(32)
        )

      final!(env.root, env.claim, %{"grant_id" => row.id})
      assert at_start(start_input(env)) == {:error, :grant_inconsistent}
    end

    test "an owner-form grant is :grant_inconsistent (T-V8 case 3)", ctx do
      env = spend_ready_env!(ctx)

      owner =
        inert(fn ->
          Agents.create_grant(
            %{
              name: "G-OWNER",
              purpose: "Owner-form grant named by the final file",
              profile_ids: [:claude_cli_opus],
              total_attempts: 2,
              starts_at: ~U[2026-10-27 00:00:00.000000Z],
              expires_at: ~U[2026-10-31 00:00:00.000000Z],
              allocations: [%{key: :b1, applies_to: [:b1], attempts: 2}]
            },
            actor: ctx.admin
          )
        end)

      assert match?({:ok, _grant}, owner), "fixture: owner grant: #{inspect(owner)}"
      rewrite_final!(env, %{"grant_id" => elem(owner, 1).id})
      assert at_start(start_input(env)) == {:error, :grant_inconsistent}
    end

    test "a revoked grant is expired (T-W5)", ctx do
      env = spend_ready_env!(ctx)
      revoked = Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: ctx.admin)
      assert match?({:ok, %{status: :revoked}}, revoked), "fixture: revoke: #{inspect(revoked)}"
      assert at_start(start_input(env)) == {:error, :agent_env_expired}
    end
  end
end
