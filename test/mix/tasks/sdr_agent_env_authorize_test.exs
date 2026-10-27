defmodule Mix.Tasks.Sdr.AgentEnvAuthorizeTest do
  @moduledoc """
  C2* S2 RED-3 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC9, §5
  "`bin/agent-env authorize`" steps 1-6 and §7 row
  "test/mix/tasks/sdr_agent_env_authorize_test.exs"; Codex plan/entity PASS
  `aa42492e`, OQ12-OQ14): the S2 subcommands of `mix sdr.agent_env`, run
  in-process in the order `bin/agent-env authorize` runs them (T-V6, S2
  part; T-V7, crash and re-run).

    1. `authorize-check` (check mode, no lease, files only): a complete
       authorization exits 0 and changes nothing; an empty registry refuses
       with "no authorization".
    2. `claim`: creates the claim for the registry's current entry, or
       accepts an equal existing claim unchanged.
    3. `lease provisioning`: the provisioning lease; prints
       `SDR_AGENT_ENV_NONCE <nonce>`.
    4. `step provision` (provisioning mode, step `provision`, that nonce):
       `SdrAgent.Agents.provision_delegated_grant/2` as the grant
       provisioner, then the receipt `instance.<nonce>.provision.exit` with
       `authorization_id`, `grant_id` and `event_id`. No `ModelInvocation`
       is written, and a business entry still raises `ModeRefused` (S1).
    5. `release provisioning` (S1): removes the lease after that receipt.
    6. `finalize`: `authorization.json` from the claim and the receipt
       (`revision: 1`, the claim's nonce, OQ13).

  Then, under a run lease, `SpendReady.at_boot/1` and `at_start/1` are `:ok`
  (before authorization `at_boot/1` refuses). A crash before `finalize`
  re-runs to the same grant: one provisioned event, the receipt's
  `event_id` the original one, then the final file.

  RED: S1's task answers each S2 subcommand (`authorize-check`, `claim`,
  `lease provisioning`, `step provision`, `finalize`) with its usage; the
  helper turns that usage error into an explicit `c2star-s2:` guard failure
  after the fixtures (structural). The empty-registry case fails on the
  usage message (structural).

  In-process (`Mix.Task.rerun/2`, as S1's `sdr_agent_env_test.exs`), in the
  SQL sandbox, against the live test database bound as the environment.
  Synthetic registry entries only; no model, port or real CLI.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureIO
  import SdrAgent.Test.AgentEnvGrantFixtures

  alias SdrAgent.AgentEnv.ModeRefused
  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.AgentEnv.SpendReady
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @moduletag :c2star_s2

  @task "sdr.agent_env"

  setup do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    BootFx.preserve_app_env!(:sdr_agent)
    tenant = bootstrap!()

    # A bound environment of the live test database, no lease, no claim; one
    # registry entry; check mode.
    env = provisioning_env!(lease: :none, claim: false)
    Fx.configure!(env.root, mode: :check, step: :check)
    %{tenant: tenant, env: env}
  end

  ## Helpers

  # Runs one subcommand; S1's usage error for an absent S2 subcommand is a
  # structural guard failure. Returns the captured output.
  defp mix!(args) do
    capture_io(fn -> Mix.Task.rerun(@task, args) end)
  rescue
    error in Mix.Error ->
      if error.message =~ ~r/usage/i do
        flunk("c2star-s2: mix #{@task} #{Enum.join(args, " ")} is not implemented (usage)")
      else
        reraise error, __STACKTRACE__
      end
  end

  defp nonce_of(output) do
    case Regex.run(~r/^SDR_AGENT_ENV_NONCE ([0-9a-f]{32})$/m, output) do
      [_line, nonce] -> nonce
      nil -> flunk("c2star-s2: no SDR_AGENT_ENV_NONCE line in #{inspect(output)}")
    end
  end

  defp check_mode!(env, nonce \\ nil),
    do: Fx.configure!(env.root, mode: :check, step: :check, nonce: nonce)

  defp provisioning_mode!(env, nonce),
    do: Fx.configure!(env.root, mode: :provisioning, step: :provision, nonce: nonce)

  # Steps 1-5 of `authorize`; returns the provisioning nonce.
  defp through_release!(env) do
    check_mode!(env)
    mix!(["authorize-check"])
    mix!(["claim"])
    nonce = nonce_of(mix!(["lease", "provisioning"]))
    provisioning_mode!(env, nonce)
    mix!(["step", "provision"])
    check_mode!(env, nonce)
    mix!(["release", "provisioning"])
    nonce
  end

  defp delegated_grants(tenant) do
    ModelCallGrant
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.tenant_id == tenant.id and &1.provisioning == :delegated))
  end

  defp read(env, name), do: State.read(env.root, name)

  defp state_digests(env) do
    Map.new(BootFx.state_files(env.root), fn name ->
      {name, BootFx.file_sha256!(Path.join([env.root, "state", name]))}
    end)
  end

  # The run side after authorization: a run lease of the binding and the
  # run configuration; the S1 callers' input shapes.
  defp run_side!(env) do
    nonce = Fx.write_lease!(env.root, :run, env.bound.binding_sha256)
    Fx.configure!(env.root, mode: :run, nonce: nonce)
    nonce
  end

  defp boot_input(env, nonce) do
    %{
      lease: read(env, :lease),
      environment: read(env, :environment),
      authorization: read(env, :authorization),
      claim: read(env, :claim),
      nonce: nonce
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

  ## T-V6

  describe "authorize, in order (T-V6, S2 part)" do
    test "before authorization at_boot refuses claude_cli", ctx do
      env = ctx.env
      nonce = run_side!(env)
      assert match?({:error, _reason}, invoke(SpendReady, :at_boot, [boot_input(env, nonce)]))
    end

    test "claim, provisioning lease, step provision, release and finalize authorize the entry",
         ctx do
      env = ctx.env
      check_mode!(env)
      mix!(["authorize-check"])

      mix!(["claim"])
      assert {:valid, _sha256, claim} = read(env, :claim)

      assert Map.take(claim, ["authorization_id", "authorization_sha256", "binding_sha256"]) ==
               %{
                 "authorization_id" => env.entry.id,
                 "authorization_sha256" => env.digest,
                 "binding_sha256" => env.bound.binding_sha256
               }

      nonce = nonce_of(mix!(["lease", "provisioning"]))
      assert {:valid, _sha256, %{"mode" => "provisioning", "nonce" => ^nonce}} = read(env, :lease)

      provisioning_mode!(env, nonce)
      mix!(["step", "provision"])

      assert [grant] = delegated_grants(ctx.tenant)
      assert grant.delegated_authorization_id == env.entry.id
      assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")
      assert event.payload["arguments"]["claim_nonce"] == claim["nonce"]
      assert Ash.count!(ModelInvocation, authorize?: false) == 0

      assert_raise ModeRefused, fn -> OperationSnapshot.enter(:sdr_action, fn -> :ok end) end

      assert {:valid, _sha256, receipt} = read(env, {:receipt, nonce, :provision})

      assert Map.take(receipt, ["authorization_id", "grant_id", "event_id", "step", "nonce"]) ==
               %{
                 "authorization_id" => env.entry.id,
                 "grant_id" => grant.id,
                 "event_id" => event.id,
                 "step" => "provision",
                 "nonce" => nonce
               }

      check_mode!(env, nonce)
      mix!(["release", "provisioning"])
      assert read(env, :lease) == :absent

      mix!(["finalize"])
      assert {:valid, _sha256, final} = read(env, :authorization)

      assert final == %{
               "authorization_id" => env.entry.id,
               "authorization_sha256" => env.digest,
               "binding_sha256" => env.bound.binding_sha256,
               "grant_id" => grant.id,
               "revision" => 1,
               "event_id" => event.id,
               "nonce" => claim["nonce"]
             }

      run_nonce = run_side!(env)
      assert invoke(SpendReady, :at_boot, [boot_input(env, run_nonce)]) == :ok
      assert invoke(SpendReady, :at_start, [start_input(env)]) == :ok
    end

    test "authorize-check on a complete authorization exits 0 and changes nothing", ctx do
      env = ctx.env
      nonce = through_release!(env)
      check_mode!(env, nonce)
      mix!(["finalize"])

      check_mode!(env)
      before = state_digests(env)
      mix!(["authorize-check"])
      assert state_digests(env) == before
      assert length(delegated_grants(ctx.tenant)) == 1
    end

    test "with an empty registry authorize-check refuses: no authorization", ctx do
      put_test_entries!([])
      check_mode!(ctx.env)

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Mix.Task.rerun(@task, ["authorize-check"]) end)
        end

      refute error.message =~ ~r/usage/i,
             "c2star-s2: mix #{@task} authorize-check is not implemented (usage)"

      assert error.message =~ "no authorization"
      assert read(ctx.env, :claim) == :absent
    end
  end

  ## T-V7

  describe "a crash before finalize (T-V7)" do
    test "the re-run replays the same grant and event, then writes the final file", ctx do
      env = ctx.env
      first = through_release!(env)
      assert [grant] = delegated_grants(ctx.tenant)
      assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")
      assert read(env, :authorization) == :absent
      claim_before = File.read!(Fx.path(env.root, :claim))

      second = through_release!(env)
      assert second != first
      assert File.read!(Fx.path(env.root, :claim)) == claim_before
      assert Enum.map(delegated_grants(ctx.tenant), & &1.id) == [grant.id]
      assert length(events_of_type(ctx.tenant, "model.grant.provisioned")) == 1

      assert {:valid, _sha256, receipt} = read(env, {:receipt, second, :provision})
      assert {receipt["grant_id"], receipt["event_id"]} == {grant.id, event.id}

      check_mode!(env, second)
      mix!(["finalize"])
      assert {:valid, _sha256, final} = read(env, :authorization)
      assert {final["grant_id"], final["event_id"]} == {grant.id, event.id}
    end
  end
end
