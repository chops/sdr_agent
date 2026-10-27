defmodule SdrAgent.AgentEnv.InstanceTest do
  @moduledoc """
  C2* S1 PR-B RED-2: the leased start phase P3, `SdrAgent.AgentEnv.Instance`
  (plan `claude-c2star-s1-environment-plan-r2.md` section 4.5, T-B3, S2
  request 2, as corrected by `claude-c2star-s1-prb-p5-correction-r1.md`
  section 2 item 1 and Codex `e01021f5` binding details 1-6).

  `Instance` is a pure boot gate, supervised immediately after the Repo as
  `{SdrAgent.AgentEnv.Instance, mode}`: `init(mode)` runs the P3 checks and
  returns `:ignore` or `{:stop, reason}` (which aborts the boot). It keeps no
  process, so it can write no exit receipt.

    * **bootstrap:** the live database's name and oid against
      `environment.created.json`; the step task's declaration
      (`Boot.declare_step!/1`) must exist and be `seed` or `probe`.
    * **provisioning:** name, oid and the singleton tenant against
      `environment.json`; the declaration must exist (`provision`).
    * **run:** name, oid and tenant against `environment.json`, and no
      migration recorded in the database that the build lacks. Then it
      exclusively creates the boot marker `instance.<nonce>.boot` (closed
      keys `nonce`, `boot_id` (32 lowercase hex), `booted_at`; canonical
      bytes) and puts `%{nonce:, boot_id:}` in `:persistent_term`
      `{SdrAgent.AgentEnv.Shutdown, :boot}`. An existing marker refuses
      (`:run_nonce_already_booted`), as does an existing run receipt for
      the nonce (`:run_receipt_exists`, P5-2(a) and (b) at P3); neither
      overwrites a file. Non-run modes write no marker and no binding.

  Reasons: `:database_name_mismatch`, `:database_oid_mismatch` and
  `:tenant_mismatch` (as `SdrAgent.AgentEnv.check_live_binding/2` and
  `check_tenant/2`), `:migration_not_in_build`, `:undeclared_step`,
  `:step_mode_mismatch`, `:run_nonce_already_booted`, `:run_receipt_exists`.

  RED: `SdrAgent.AgentEnv.Instance` and `SdrAgent.AgentEnv.Boot` do not
  exist (structural, guarded after the fixtures).

  Hermetic: SQL sandbox (the migration row is rolled back), physical roots
  under `tmp/agent-env-roots`, no port, process, real Mix or CLI.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @instance SdrAgent.AgentEnv.Instance
  @boot SdrAgent.AgentEnv.Boot

  setup do
    tenant = bootstrap!()
    root = Fx.root!("instance")
    Fx.unconfigure!()
    BootFx.preserve_app_env!(:sdr_agent)
    BootFx.erase_boot_binding!()
    %{tenant: tenant, root: root}
  end

  ## Helpers

  defp require!(module, functions) do
    assert Code.ensure_loaded?(module), "C2* S1 RED-2: #{inspect(module)} is not available"

    for {function, arity} <- functions do
      assert function_exported?(module, function, arity),
             "C2* S1 RED-2: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp init(mode) do
    require!(@instance, init: 1, child_spec: 1)
    apply(@instance, :init, [mode])
  end

  defp declare!(step) do
    require!(@boot, declare_step!: 1)
    assert apply(@boot, :declare_step!, [step]) == :ok
  end

  defp markers(root),
    do: root |> BootFx.state_files() |> Enum.filter(&String.ends_with?(&1, ".boot"))

  defp bootstrap_mode!(ctx, step, opts \\ []) do
    created = BootFx.bootstrap!(ctx.root, opts)
    Fx.configure!(ctx.root, mode: :bootstrap, nonce: created.nonce, step: step)
    created
  end

  defp provisioning_mode!(ctx, opts \\ []) do
    bound = Fx.bound!(ctx.root, Keyword.put(opts, :lease, :provisioning))
    Fx.configure!(ctx.root, mode: :provisioning, nonce: bound.nonce, step: :provision)
    bound
  end

  defp run_mode!(ctx, opts \\ []) do
    bound = Fx.bound!(ctx.root, Keyword.put(opts, :lease, :run))
    Fx.configure!(ctx.root, mode: :run, nonce: bound.nonce, step: :run)
    bound
  end

  defp assert_no_boot_side_effects(ctx) do
    assert markers(ctx.root) == [], "C2* S1 P5: only a successful run boot writes a marker"
    assert BootFx.boot_binding() == nil, "C2* S1 P5: only a successful run boot binds"
  end

  ## Bootstrap

  describe "identity: bootstrap" do
    test "control: the created database with a declared seed or probe step passes", ctx do
      for step <- [:seed, :probe] do
        bootstrap_mode!(ctx, step, done: [:create, :migrate])
        declare!(step)
        assert init(:bootstrap) == :ignore, "C2* S1 P3: bootstrap #{step} must pass"
      end

      assert_no_boot_side_effects(ctx)
    end

    test "a created database of another oid is refused", ctx do
      {_name, oid} = Fx.live_identity!()
      bootstrap_mode!(ctx, :seed, database_oid: oid + 1)
      declare!(:seed)

      assert init(:bootstrap) == {:stop, :database_oid_mismatch}
      assert_no_boot_side_effects(ctx)
    end

    test "a created database of another name is refused", ctx do
      {_name, oid} = Fx.live_identity!()
      bootstrap_mode!(ctx, :seed, database: "sdr_agent_agentenv", database_oid: oid)
      declare!(:seed)

      assert init(:bootstrap) == {:stop, :database_name_mismatch}
    end

    test "a start without the step task's declaration is refused", ctx do
      bootstrap_mode!(ctx, :seed)
      assert init(:bootstrap) == {:stop, :undeclared_step}
    end

    test "a declared step that never starts the application is refused", ctx do
      for step <- [:create, :migrate] do
        bootstrap_mode!(ctx, step)
        declare!(step)
        assert init(:bootstrap) == {:stop, :step_mode_mismatch}, inspect(step)
      end
    end
  end

  ## Provisioning

  describe "identity: provisioning" do
    test "control: the bound database and tenant with the declared step pass", ctx do
      provisioning_mode!(ctx)
      declare!(:provision)

      assert init(:provisioning) == :ignore
      assert_no_boot_side_effects(ctx)
    end

    test "a bound database of another oid is refused", ctx do
      {_name, oid} = Fx.live_identity!()
      provisioning_mode!(ctx, database_oid: oid + 1)
      declare!(:provision)

      assert init(:provisioning) == {:stop, :database_oid_mismatch}
    end

    test "a bound environment of another tenant is refused", ctx do
      provisioning_mode!(ctx, tenant_id: Ecto.UUID.generate())
      declare!(:provision)

      assert init(:provisioning) == {:stop, :tenant_mismatch}
    end

    test "a start without the step task's declaration is refused", ctx do
      provisioning_mode!(ctx)
      assert init(:provisioning) == {:stop, :undeclared_step}
    end
  end

  ## Run

  describe "identity: run" do
    test "control: the bound environment boots once, writing the marker and the binding", ctx do
      bound = run_mode!(ctx)

      assert init(:run) == :ignore

      marker = BootFx.boot_marker_path(ctx.root, bound.nonce)
      bytes = File.read!(marker)
      assert BootFx.canonical?(bytes), "C2* S1 P5: the boot marker must be canonical bytes"
      data = Jason.decode!(bytes)

      assert data |> Map.keys() |> Enum.sort() == ["boot_id", "booted_at", "nonce"]
      assert data["nonce"] == bound.nonce
      assert data["boot_id"] =~ ~r/\A[0-9a-f]{32}\z/
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["booted_at"])

      assert BootFx.boot_binding() == %{nonce: bound.nonce, boot_id: data["boot_id"]}
      refute File.exists?(BootFx.run_receipt_path(ctx.root, bound.nonce))
      assert markers(ctx.root) == ["instance.#{bound.nonce}.boot"]
    end

    test "a bound database of another oid is refused, with no marker", ctx do
      {_name, oid} = Fx.live_identity!()
      run_mode!(ctx, database_oid: oid + 1)

      assert init(:run) == {:stop, :database_oid_mismatch}
      assert_no_boot_side_effects(ctx)
    end

    test "a bound environment of another tenant is refused, with no marker", ctx do
      run_mode!(ctx, tenant_id: Ecto.UUID.generate())

      assert init(:run) == {:stop, :tenant_mismatch}
      assert_no_boot_side_effects(ctx)
    end

    test "a migration recorded in the database that the build lacks is refused", ctx do
      run_mode!(ctx)

      Repo.query!(
        "INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, now())",
        [99_991_231_235_959]
      )

      assert init(:run) == {:stop, :migration_not_in_build}
      assert_no_boot_side_effects(ctx)
    end

    test "P5-2(a): an existing boot marker refuses the boot and is not overwritten", ctx do
      bound = run_mode!(ctx)
      marker = BootFx.boot_marker_path(ctx.root, bound.nonce)
      sha = BootFx.write_boot_marker!(ctx.root, bound.nonce, Fx.hex(16))

      assert init(:run) == {:stop, :run_nonce_already_booted}
      assert BootFx.file_sha256!(marker) == sha
      assert BootFx.boot_binding() == nil
    end

    test "P5-2(a): a second boot under the nonce is refused; the first binding stands", ctx do
      bound = run_mode!(ctx)
      assert init(:run) == :ignore
      marker = BootFx.boot_marker_path(ctx.root, bound.nonce)
      sha = BootFx.file_sha256!(marker)
      binding = BootFx.boot_binding()

      assert init(:run) == {:stop, :run_nonce_already_booted}
      assert BootFx.file_sha256!(marker) == sha
      assert BootFx.boot_binding() == binding
    end

    test "P5-2(b): an existing run receipt refuses the boot, with no marker", ctx do
      bound = run_mode!(ctx)
      receipt = BootFx.run_receipt_path(ctx.root, bound.nonce)

      bytes =
        SdrAgent.Audit.Canonical.encode!(%{
          "nonce" => bound.nonce,
          "boot_id" => Fx.hex(16),
          "completed_at" => DateTime.utc_now()
        })

      File.write!(receipt, bytes)

      assert init(:run) == {:stop, :run_receipt_exists}
      assert File.read!(receipt) == bytes
      assert_no_boot_side_effects(ctx)
    end
  end
end
