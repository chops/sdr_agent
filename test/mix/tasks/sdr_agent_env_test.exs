defmodule Mix.Tasks.Sdr.AgentEnvTest do
  @moduledoc """
  C2* S1 PR-B RED-3: the guarded bootstrap steps and `mix sdr.agent_env`
  (plan `claude-c2star-s1-environment-plan-r2.md` section 5.4, OQ 2/3, T-V9
  steps; ADR-0004 agent-environment amendment item 3 steps 1-8).

  `SdrAgent.AgentEnv.Bootstrap` holds the effects; the Mix task dispatches
  `check | preflight | lease bootstrap|run | step create|migrate|seed|probe
  | publish | release bootstrap|provisioning|run`, prints machine lines
  `SDR_AGENT_ENV_<KEY> <value>`, and refuses anything else (no reset, no
  drop) with its usage.

    * `preflight` — the root is fresh (`State.classify/2`) and
      `storage_status/1` on exactly `database: "sdr_agent_agentenv"`,
      `maintenance_database: "postgres"` is `:down`; else `:not_fresh`,
      `:database_exists` or `:storage_status_unavailable`.
    * `step(s)` — after `Boot.declare_step!/1` of the configured bootstrap
      step, with the bootstrap lease of the configured nonce and the
      bootstrap order, it validates and only then acts:
      `create` needs the Repo target exactly `sdr_agent_agentenv` @
      `localhost:5520`, then `storage_up` (`:already_up` is
      `:database_exists`: quarantine, never a re-create), the created
      database's oid, `environment.created.json`, the receipt; `migrate`,
      `seed` and `probe` need the live name and oid of `created.json`, then
      the migrator, the demo seed or the tenant read, then the receipt
      (`probe` with `tenant_id`). Refusals: `:undeclared_step`,
      `:agent_env_lease_mismatch`, `:step_out_of_order`,
      `:bootstrap_target_mismatch`, `:database_name_mismatch`,
      `:database_oid_mismatch`, `:database_exists`.
    * `publish` — under the held bootstrap lease with all four receipts,
      creates `environment.json` from `created.json` and the probe's tenant
      and returns `{:ok, binding_sha256}`.

  Test builds only (`:claude_cli_test_seams`): `preflight/1`, `step/2` and
  `publish/1` take `adapter:`, a map of stand-ins for every effect
  (`repo_config`, `storage_status`, `storage_up`, `database_oid`,
  `live_identity`, `migrate`, `seed`, `tenant_id`), so no database is
  created, migrated, seeded or read. Production arity: `preflight/0`,
  `step/1`, `publish/0`.

  RED: `SdrAgent.AgentEnv.Bootstrap` and the Mix task do not exist
  (structural, guarded after the fixtures).

  Hermetic: physical roots under `tmp/agent-env-roots`, stand-in effects; no
  database, port, real CLI or application start.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @bootstrap SdrAgent.AgentEnv.Bootstrap
  @boot SdrAgent.AgentEnv.Boot
  @state SdrAgent.AgentEnv.State
  @task "sdr.agent_env"
  @oid 424_242
  @target [database: "sdr_agent_agentenv", hostname: "localhost", port: 5520]

  setup do
    root = Fx.root!("bootstrap")
    File.mkdir_p!(Path.join(root, "state"))
    File.chmod!(Path.join(root, "state"), 0o700)
    Fx.unconfigure!()
    BootFx.preserve_app_env!(:sdr_agent)
    effects = start_supervised!(%{id: :effects, start: {Agent, :start_link, [fn -> [] end]}})
    %{root: root, effects: effects, tenant_id: Ecto.UUID.generate()}
  end

  ## Helpers

  defp require_bootstrap! do
    assert Code.ensure_loaded?(@bootstrap),
           "C2* S1 RED-3: #{inspect(@bootstrap)} is not available"

    for {function, arity} <- [
          preflight: 0,
          preflight: 1,
          step: 1,
          step: 2,
          publish: 0,
          publish: 1
        ] do
      assert function_exported?(@bootstrap, function, arity),
             "C2* S1 RED-3: #{inspect(@bootstrap)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp bootstrap(function, args) do
    require_bootstrap!()
    apply(@bootstrap, function, args)
  end

  defp record(ctx, effect, result) do
    Agent.update(ctx.effects, &[effect | &1])
    result
  end

  defp effects(ctx), do: ctx.effects |> Agent.get(& &1) |> Enum.reverse()
  defp effect_names(ctx), do: Enum.map(effects(ctx), &elem(&1, 0))

  # Stand-ins for every effect; `overrides` replace single ones.
  defp adapter(ctx, overrides) do
    Map.merge(
      %{
        repo_config: fn -> @target end,
        storage_status: fn config -> record(ctx, {:storage_status, config}, :down) end,
        storage_up: fn config -> record(ctx, {:storage_up, config}, :ok) end,
        database_oid: fn config -> record(ctx, {:database_oid, config}, {:ok, @oid}) end,
        live_identity: fn ->
          record(
            ctx,
            {:live_identity, nil},
            {:ok, %{database: "sdr_agent_agentenv", database_oid: @oid}}
          )
        end,
        migrate: fn -> record(ctx, {:migrate, nil}, :ok) end,
        seed: fn -> record(ctx, {:seed, nil}, :ok) end,
        tenant_id: fn -> record(ctx, {:tenant_id, nil}, {:ok, ctx.tenant_id}) end
      },
      overrides
    )
  end

  defp seams(ctx, overrides \\ %{}), do: [adapter: adapter(ctx, overrides)]

  # The bootstrap lease of a fresh nonce (pending + lease) and the receipts
  # of `done`, with created.json when :create is done.
  defp leased!(ctx, done) do
    nonce = Fx.nonce()

    Fx.write_state!(ctx.root, :pending, %{
      "environment_id" => "agentenv-1",
      "nonce" => nonce,
      "started_at" => DateTime.utc_now()
    })

    BootFx.bootstrap_lease!(ctx.root, nonce)

    if :create in done do
      Fx.write_state!(ctx.root, :created, %{
        "database" => "sdr_agent_agentenv",
        "database_oid" => @oid,
        "nonce" => nonce
      })
    end

    for step <- done do
      extra = if step == :probe, do: %{"tenant_id" => ctx.tenant_id}, else: %{}

      data =
        Map.merge(
          %{
            "nonce" => nonce,
            "step" => Atom.to_string(step),
            "completed_at" => DateTime.utc_now()
          },
          extra
        )

      Fx.write_state!(ctx.root, {:receipt, nonce, step}, data)
    end

    nonce
  end

  defp declared!(ctx, step, nonce) do
    Fx.configure!(ctx.root, mode: :bootstrap, step: step, nonce: nonce)
    assert apply(@boot, :declare_step!, [step]) == :ok
  end

  defp step!(ctx, step, nonce, overrides \\ %{}) do
    declared!(ctx, step, nonce)
    bootstrap(:step, [step, seams(ctx, overrides)])
  end

  defp digests(root) do
    Map.new(BootFx.state_files(root), &{&1, BootFx.file_sha256!(Path.join([root, "state", &1]))})
  end

  defp object(root, name), do: BootFx.read_object!(Fx.path(root, name))

  ## Preflight

  describe "preflight" do
    test "a fresh root and an absent database pass; storage_status gets exactly the target",
         ctx do
      Fx.configure!(ctx.root, mode: :check, step: :check)

      assert bootstrap(:preflight, [seams(ctx)]) == :ok
      assert [{:storage_status, config}] = effects(ctx)
      assert Keyword.get(config, :database) == "sdr_agent_agentenv"
      assert Keyword.get(config, :maintenance_database) == "postgres"
      assert BootFx.state_files(ctx.root) == []
    end

    test "an existing database or an unclear status is refused", ctx do
      Fx.configure!(ctx.root, mode: :check, step: :check)

      up = %{storage_status: fn config -> record(ctx, {:storage_status, config}, :up) end}
      assert bootstrap(:preflight, [seams(ctx, up)]) == {:error, :database_exists}

      unclear = %{storage_status: fn _config -> {:error, :econnrefused} end}
      assert bootstrap(:preflight, [seams(ctx, unclear)]) == {:error, :storage_status_unavailable}
    end

    test "a root that is not fresh is refused before any database read", ctx do
      Fx.configure!(ctx.root, mode: :check, step: :check)
      leased!(ctx, [])

      assert bootstrap(:preflight, [seams(ctx)]) == {:error, :not_fresh}
      assert effects(ctx) == []
    end
  end

  ## The steps, in order, and publish

  describe "steps" do
    test "create, migrate, seed and probe run in order and each writes its receipt", ctx do
      nonce = leased!(ctx, [])

      assert step!(ctx, :create, nonce) == :ok

      assert object(ctx.root, :created) == %{
               "database" => "sdr_agent_agentenv",
               "database_oid" => @oid,
               "nonce" => nonce
             }

      for step <- [:create, :migrate, :seed, :probe] do
        if step != :create, do: assert(step!(ctx, step, nonce) == :ok, inspect(step))

        assert match?({:valid, _, _}, apply(@state, :read, [ctx.root, {:receipt, nonce, step}])),
               "C2* S1: the #{step} receipt"
      end

      assert object(ctx.root, {:receipt, nonce, :probe})["tenant_id"] == ctx.tenant_id

      names = Enum.reject(effect_names(ctx), &(&1 == :live_identity))
      assert names == [:storage_up, :database_oid, :migrate, :seed, :tenant_id]

      assert [{:storage_up, config} | _] =
               Enum.filter(effects(ctx), &(elem(&1, 0) == :storage_up))

      assert Keyword.take(config, [:database, :hostname, :port]) == @target
    end

    test "publish creates environment.json from the history; release then binds", ctx do
      nonce = leased!(ctx, [:create, :migrate, :seed, :probe])
      Fx.configure!(ctx.root, mode: :check, step: :check, nonce: nonce)

      assert {:ok, binding} = bootstrap(:publish, [seams(ctx)])
      assert binding == Fx.file_sha256!(ctx.root, :environment)

      assert Map.drop(object(ctx.root, :environment), ["created_at"]) == %{
               "environment_id" => "agentenv-1",
               "database" => "sdr_agent_agentenv",
               "database_oid" => @oid,
               "tenant_id" => ctx.tenant_id,
               "nonce" => nonce
             }

      assert apply(@state, :classify, [ctx.root, :unknown]) == {:leased, "bootstrap"}
      assert apply(@state, :release, [ctx.root, :bootstrap, nonce]) == :ok
      assert {:bound, %{sha256: ^binding}} = apply(@state, :classify, [ctx.root, :unknown])
    end

    test "publish without every receipt, or a second time, writes nothing", ctx do
      nonce = leased!(ctx, [:create, :migrate, :seed])
      Fx.configure!(ctx.root, mode: :check, step: :check, nonce: nonce)
      before = digests(ctx.root)

      assert bootstrap(:publish, [seams(ctx)]) == {:error, :receipts_missing}
      assert digests(ctx.root) == before

      File.rm_rf!(Path.join(ctx.root, "state"))
      nonce = leased!(ctx, [:create, :migrate, :seed, :probe])
      Fx.configure!(ctx.root, mode: :check, step: :check, nonce: nonce)
      assert {:ok, _binding} = bootstrap(:publish, [seams(ctx)])
      published = digests(ctx.root)

      assert bootstrap(:publish, [seams(ctx)]) == {:error, :exists}
      assert digests(ctx.root) == published
    end
  end

  ## Validation before effect

  describe "validation before effect" do
    test "create on an existing database quarantines with no re-create and nothing written",
         ctx do
      nonce = leased!(ctx, [])
      before = digests(ctx.root)

      exists = %{
        storage_up: fn config -> record(ctx, {:storage_up, config}, {:error, :already_up}) end
      }

      assert step!(ctx, :create, nonce, exists) == {:error, :database_exists}
      assert effect_names(ctx) == [:storage_up]
      assert digests(ctx.root) == before
    end

    test "create against another target is refused before storage_up", ctx do
      nonce = leased!(ctx, [])

      for target <- [
            Keyword.put(@target, :database, "sdr_agent_dev"),
            Keyword.put(@target, :database, "sdr_agent_test"),
            Keyword.put(@target, :hostname, "db.example.invalid"),
            Keyword.put(@target, :port, 5432)
          ] do
        other = %{repo_config: fn -> target end}

        assert step!(ctx, :create, nonce, other) == {:error, :bootstrap_target_mismatch},
               inspect(target)
      end

      assert effects(ctx) == []
      refute File.exists?(Fx.path(ctx.root, :created))
    end

    test "a step whose nonce is not the lease's is refused before any effect", ctx do
      leased!(ctx, [])
      assert step!(ctx, :create, Fx.nonce()) == {:error, :agent_env_lease_mismatch}
      assert effects(ctx) == []
    end

    test "an undeclared step is refused before any effect", ctx do
      nonce = leased!(ctx, [])
      Fx.configure!(ctx.root, mode: :bootstrap, step: :create, nonce: nonce)

      assert bootstrap(:step, [:create, seams(ctx)]) == {:error, :undeclared_step}
      assert effects(ctx) == []
    end

    test "a step out of order is refused before any effect", ctx do
      nonce = leased!(ctx, [:create])
      assert step!(ctx, :seed, nonce) == {:error, :step_out_of_order}
      assert effects(ctx) == []

      nonce = leased!(ctx, [:create, :migrate])
      assert step!(ctx, :migrate, nonce) == {:error, :step_out_of_order}
      refute :migrate in effect_names(ctx)
    end

    for step <- [:migrate, :seed, :probe] do
      @step step

      test "#{step}: a live database of another oid or name is refused before the effect", ctx do
        done = Enum.take_while([:create, :migrate, :seed], &(&1 != @step))
        effect = %{migrate: :migrate, seed: :seed, probe: :tenant_id}[@step]

        for {identity, reason} <- [
              {%{database: "sdr_agent_agentenv", database_oid: @oid + 1}, :database_oid_mismatch},
              {%{database: "sdr_agent_dev", database_oid: @oid}, :database_name_mismatch}
            ] do
          File.rm_rf!(Path.join(ctx.root, "state"))
          nonce = leased!(ctx, done)
          before = digests(ctx.root)
          live = %{live_identity: fn -> {:ok, identity} end}

          assert step!(ctx, @step, nonce, live) == {:error, reason}, inspect(identity)
          refute effect in effect_names(ctx)
          assert digests(ctx.root) == before
        end
      end
    end
  end

  ## The Mix task

  defp task!,
    do: assert(Mix.Task.get(@task), "C2* S1 RED-3: the Mix task #{@task} does not exist")

  describe "mix sdr.agent_env" do
    test "reset, drop, an unknown command or none is refused with the usage", ctx do
      task!()
      Fx.configure!(ctx.root, mode: :check, step: :check)

      for args <- [["reset"], ["drop"], ["bogus"], [], ["step", "drop"], ["lease", "reset"]] do
        assert_raise Mix.Error, ~r/usage/i, fn ->
          capture_io(fn -> Mix.Task.rerun(@task, args) end)
        end
      end

      assert BootFx.state_files(ctx.root) == []
    end

    test "lease bootstrap on a fresh root prints the nonce of the lease it took", ctx do
      task!()
      Fx.configure!(ctx.root, mode: :check, step: :check)

      output = capture_io(fn -> Mix.Task.rerun(@task, ["lease", "bootstrap"]) end)

      assert [_, nonce] = Regex.run(~r/^SDR_AGENT_ENV_NONCE ([0-9a-f]{32})$/m, output)
      assert object(ctx.root, :lease)["nonce"] == nonce
      assert object(ctx.root, :pending)["nonce"] == nonce
    end
  end
end
