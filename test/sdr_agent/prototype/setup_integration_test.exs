defmodule SdrAgent.Prototype.SetupIntegrationTest do
  @moduledoc """
  Setup contract r3 (Codex 85ab1090, 57fc6bb4) §6 B, C and T-twin, in the
  sandbox. Every B and C row is a PREREQUISITE GATE until GREEN: B1-B5 are
  not phase 2/3 proof and C is not exact-set proof (Codex 57fc6bb4).

  - B: `SdrAgent.Prototype.Setup.run/2` with the REAL phase 1b-3 calls
    (`in_transaction`, `target_identity`, `check_migrated`, `check_fresh`,
    `bootstrap/1`, `BootCheck.verify!/1` through the test-build boot seam,
    `operator_actor/1`) and phase 0/1a, `with_repo`, `migrate` and
    `seed_run` stubbed: success (exact rows, the prototype runtime, the
    seed called at top level with the resolved actor, zero jobs); a phase-2
    late failure (zero rows and audit events); a phase-3 boot refusal and a
    phase-3 seed refusal (the committed phase-2 rows SURVIVE, one
    bootstrap, zero jobs); a nested call (refused before the target read,
    the caller's transaction usable).
  - C: `Authority.check_migrated/0`, the exact pinned set: success, an
    extra and a missing version (labelled negative tamper).
  - T-twin: `setup.ex` compiled with the prototype flags false defines no
    module and emits no diagnostic.

  NOT proven here (r2 §7): a Repo-only startup, the real maintenance or
  target identity, storage creation, the real S3 seed (stubbed: "zero seed
  survivors" is pending S3) and the real sink. RED at the declarations:
  every B and C assertion is a prerequisite or later-unexecuted label until
  GREEN.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Authority
  alias SdrAgent.Prototype.BootCheck
  alias SdrAgent.Prototype.Setup
  alias SdrAgent.PrototypeSetupEffects, as: E

  @tables ~w(tenants users prototype_database_bindings prototype_delegations audit_events oban_jobs)
  @source Path.expand("../../../lib/sdr_agent/prototype/setup.ex", __DIR__)
  @flags [:prototype_authority_compiled, :prototype_test_seams]

  describe "B: Setup.run with the real phase 1b-3 calls" do
    test "B1: success binds once, fixes the prototype runtime and seeds at top level, zero jobs" do
      {effects, observer} = effects()
      result = Setup.run(effects, E.args())

      assert {:ok, %{binding_id: binding_id, delegation_id: delegation_id}} = result
      assert is_binary(binding_id) and is_binary(delegation_id)

      after_counts = counts()

      assert Map.delete(after_counts, "audit_events") ==
               %{
                 "tenants" => 1,
                 "users" => 1,
                 "prototype_database_bindings" => 1,
                 "prototype_delegations" => 1,
                 "oban_jobs" => 0
               }

      assert after_counts["audit_events"] > 0

      assert Prototype.runtime() == :prototype
      assert_received {:seed_run, seed, actor, in_transaction?}
      assert seed === observer.seed
      assert in_transaction? == false, "the seed was not called at top level"
      assert Prototype.operator_actor(delegation_id) == {:ok, actor}
    end

    test "B2: a phase-2 late failure retains no phase-2 row and calls no later phase (the measured rollback case)" do
      Process.put({Authority, :before_delegation}, fn _created ->
        raise "injected late bootstrap failure"
      end)

      {effects, observer} = effects()
      result = Setup.run(effects, E.args())

      # Presented as refused: the returned code does not itself establish a
      # rollback (Codex 57fc6bb4 S2); the zero-row counts below are the
      # measured no-retained-effects evidence, in the sandbox logical owner.
      assert result == {:error, %{phase: 2, result: :refused, reason: :bootstrap_failed}}
      assert counts() == zero()
      log = E.names(observer.log.())
      assert List.last(log) == :bootstrap
      refute :verify in log
      refute_received {:seed_run, _, _, _}
    end

    test "B3: a phase-3 boot refusal leaves the committed phase-2 rows, one bootstrap, zero jobs" do
      other = %{policy_id: "d237-prototype/1", instance_id: Ecto.UUID.generate()}

      {effects, observer} =
        effects(%{verify: fn _created -> BootCheck.verify!(switch: other) end})

      result = Setup.run(effects, E.args())

      assert result == {:error, %{phase: 3, result: :refused, reason: :boot_refused}}
      assert_survivors()
      log = E.names(observer.log.())
      assert Enum.count(log, &(&1 == :bootstrap)) == 1
      refute :seed_run in log
    end

    test "B4: a seed refusal from a no-transaction stub leaves the phase-2 rows, zero jobs" do
      {effects, observer} = effects(%{seed_run: fn _seed, _actor -> {:error, :seed_failed} end})
      result = Setup.run(effects, E.args())

      # A stub that refuses before any transaction: no rollback is claimed
      # (Codex 57fc6bb4 S2), and it proves nothing about seed survivors.
      assert result == {:error, %{phase: 3, result: :refused, reason: :seed_failed}}
      assert_survivors()
      assert Enum.count(E.names(observer.log.()), &(&1 == :bootstrap)) == 1
    end

    test "B5: with STUBBED storage, a nested call is refused before the target read" do
      {effects, observer} = effects()

      # Storage is stubbed here: this proves neither real create avoidance
      # nor durability (Codex 57fc6bb4 S3); supported entry is top level.
      {:ok, {result, probe}} =
        Repo.transaction(fn ->
          result = Setup.run(effects, E.args())
          {result, Repo.query("SELECT 1")}
        end)

      assert result == {:error, %{phase: 1, result: :refused, reason: :bootstrap_failed}}
      assert {:ok, %{rows: [[1]]}} = probe
      assert List.last(E.names(observer.log.())) == :in_transaction
      assert counts() == zero()
    end
  end

  describe "C: Authority.check_migrated/0" do
    test "the pinned set passes" do
      assert Authority.check_migrated() == :ok
    end

    test "an extra version refuses (labelled negative tamper)" do
      Repo.query!(
        "INSERT INTO public.schema_migrations (version, inserted_at) VALUES (99990101000000, now())"
      )

      assert Authority.check_migrated() == {:error, :migration_failed}
    end

    test "a missing version refuses (labelled negative tamper)" do
      {version, _name} = List.last(Authority.pinned_migrations())
      Repo.query!("DELETE FROM public.schema_migrations WHERE version = $1", [version])
      assert Authority.check_migrated() == {:error, :migration_failed}
    end
  end

  describe "T-twin: no setup code under false flags" do
    test "setup.ex compiled with the prototype flags false defines nothing and emits nothing" do
      source = File.read!(@source)
      previous = Map.new(@flags, &{&1, Application.fetch_env(:sdr_agent, &1)})

      {modules, diagnostics} =
        try do
          Enum.each(@flags, &Application.put_env(:sdr_agent, &1, false))

          Code.with_diagnostics(fn ->
            Code.compile_string(source, "setup_production_twin.ex")
          end)
        after
          Enum.each(previous, fn
            {flag, {:ok, value}} -> Application.put_env(:sdr_agent, flag, value)
            {flag, :error} -> Application.delete_env(:sdr_agent, flag)
          end)
        end

      assert modules == []
      assert diagnostics == []
    end
  end

  ## Helpers

  # The stub with the real phase 1b-3 calls bound; phase 0/1a agree with
  # the live identity of the test database (the test build aliases its
  # name to the prototype's), `with_repo` runs its callback in place (the
  # Repo is already running), `migrate` is a no-op, and `seed_run` records
  # its arguments and whether it runs inside a transaction.
  defp effects(overrides \\ %{}) do
    {:ok, live} = Authority.live_identity()
    test = self()

    real = %{
      cluster_marker: {:ok, %{system_identifier: live.system_identifier, data_dir: E.data_dir()}},
      maintenance_identity:
        {:ok,
         %{
           database: "postgres",
           system_identifier: live.system_identifier,
           data_directory: E.data_dir()
         }},
      in_transaction: &Repo.in_transaction?/0,
      target_identity: &Authority.live_identity/0,
      check_migrated: &Authority.check_migrated/0,
      check_fresh: &Authority.check_fresh/0,
      bootstrap: &Authority.bootstrap/1,
      verify: fn created ->
        BootCheck.verify!(
          switch: %{
            policy_id: created.binding.policy_id,
            instance_id: created.binding.instance_id
          }
        )
      end,
      operator_actor: &Prototype.operator_actor/1,
      seed_run: fn seed, actor ->
        send(test, {:seed_run, seed, actor, Repo.in_transaction?()})
        {:ok, %{}}
      end
    }

    E.stub(Map.merge(real, overrides))
  end

  defp counts do
    Map.new(@tables, fn table ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM public.#{table}")
      {table, n}
    end)
  end

  defp zero, do: Map.new(@tables, &{&1, 0})

  defp assert_survivors do
    after_counts = counts()

    assert Map.take(
             after_counts,
             ~w(tenants users prototype_database_bindings prototype_delegations)
           ) ==
             %{
               "tenants" => 1,
               "users" => 1,
               "prototype_database_bindings" => 1,
               "prototype_delegations" => 1
             }

    assert after_counts["oban_jobs"] == 0
    refute_received {:seed_run, _, _, _}
  end
end
