defmodule SdrAgent.AgentEnv.StateTest do
  @moduledoc """
  C2* S1 PR-B RED-3: the agent environment's state writers, leases and
  classification (plan `claude-c2star-s1-environment-plan-r2.md` section
  4.2, as corrected by `claude-c2star-s1-prb-p5-correction-r1.md` section 2
  items 1 and 5 and section 4; T-V2, T-V4, T-V9 crash points; ADR-0004
  agent-environment amendment items 3 and 5).

    * `acquire_lease(root, mode, opts)` → `{:ok, nonce}` or `{:error,
      reason}`. `:bootstrap` needs `classify(root, :unknown) == :fresh` and
      creates `environment.pending`, then the bootstrap lease, both with one
      fresh nonce. `:provisioning` and `:run` need `{:bound, _}` and target
      the environment's binding digest (run: port 4130). A held lease gives
      `:lease_held`; otherwise `:not_fresh` (bootstrap) or `:not_bound`.
    * `release(root, mode, nonce)` → `:ok` removes only the lease, and only
      with that lease's mode and nonce (`:lease_missing`, `:lease_mismatch`)
      and its mode's receipts (`:receipts_missing`): bootstrap, the four
      step receipts and `environment.json`; provisioning, the provision
      receipt; run, the run receipt, whose `boot_id` must equal the boot
      marker's (`:boot_id_mismatch`, P5-2(c)). Nothing else is ever removed.
    * `classify(root, db_facts)` → `:fresh` (no state file), `{:bound,
      %{sha256, data}}`, `{:leased, mode}` (a held or stale lease; any
      launch refuses) or `{:quarantine, reason}`: `:invalid_file`,
      `:unrecognised_file`, `:pending_without_environment`,
      `:created_without_pending`, `:database_without_pending`,
      `:binding_inconsistent`, `:missing_bootstrap_receipt`,
      `:database_oid_mismatch`, `:tenant_mismatch`. Boot markers, run
      receipts and the S2 authorization files are recognised.

  `create/3` (GREEN-2) is the only other writer; no writer replaces or
  removes a published file.

  Codex `b684dba9` rulings applied here: a valid lease over recognised
  history is `{:leased, mode}`, but masks no unrecognised or invalid file
  (quarantine; nothing removed), and an invalid lease is `:invalid_file`
  (Q2); a bootstrap release needs each same-nonce step receipt and
  `environment.json` independently (`:receipts_missing`) and a history
  consistent with the probe's tenant (`:binding_inconsistent`), with the
  lease and every byte unchanged on refusal (Q3); a run receipt with an
  absent, invalid or different boot marker is `:boot_id_mismatch` with
  nothing changed (Q7); an absent `state/` is `:fresh` for `:unknown` or
  `:absent` facts and classify creates nothing, while a `state` path that
  is a file, a symlink or unreadable is not absence (Q8); bound files with
  the database observed `:absent` are `:binding_inconsistent` (Q9).

  RED: `acquire_lease/3`, `release/3` and `classify/2` do not exist
  (structural). Each call is guarded on its own function (Codex `b684dba9`
  M1), so the `create/3` and `read/2` regression locks execute now.

  Hermetic: physical roots under `tmp/agent-env-roots`; no database (the
  database facts are given).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @state SdrAgent.AgentEnv.State
  @bootstrap_target %{"database" => "sdr_agent_agentenv", "host" => "localhost", "port" => 5520}

  setup do
    root = Fx.root!("state")
    File.mkdir_p!(Path.join(root, "state"))
    File.chmod!(Path.join(root, "state"), 0o700)
    %{root: root}
  end

  ## Helpers

  # Function-specific (Codex b684dba9 M1): a call needs only its own function,
  # so the existing create/3 and read/2 never wait on the new writers.
  defp require_state!(function, arity) do
    assert Code.ensure_loaded?(@state), "C2* S1 RED-3: #{inspect(@state)} is not available"

    assert function_exported?(@state, function, arity),
           "C2* S1 RED-3: #{inspect(@state)}.#{function}/#{arity} is not exported"

    :ok
  end

  defp state(function, args) do
    require_state!(function, length(args))
    apply(@state, function, args)
  end

  defp classify(root, facts \\ :unknown), do: state(:classify, [root, facts])
  defp acquire(root, mode), do: state(:acquire_lease, [root, mode, []])
  defp release(root, mode, nonce), do: state(:release, [root, mode, nonce])

  defp files(root), do: BootFx.state_files(root)

  defp digests(root) do
    Map.new(files(root), &{&1, BootFx.file_sha256!(Path.join([root, "state", &1]))})
  end

  # A complete bootstrap under `nonce` and its published environment (no
  # lease), as the bootstrap leaves it: {environment digest, tenant id}.
  defp bound_state!(root, opts \\ []) do
    bound = BootFx.agentenv_bound!(root, Keyword.put(opts, :lease, :none))
    {bound.binding_sha256, bound.tenant_id, bound.bootstrap_nonce}
  end

  defp lease_data(root), do: BootFx.read_object!(Fx.path(root, :lease))

  defp receipt(nonce, step, extra \\ %{}) do
    Map.merge(
      %{"nonce" => nonce, "step" => Atom.to_string(step), "completed_at" => DateTime.utc_now()},
      extra
    )
  end

  defp run_receipt!(root, nonce, boot_id) do
    Fx.write_state!(root, {:run_receipt, nonce}, %{
      "nonce" => nonce,
      "boot_id" => boot_id,
      "completed_at" => DateTime.utc_now()
    })
  end

  # The complete bootstrap history of a fresh nonce under its held bootstrap
  # lease (fixtures only: pending, lease, created, the four step receipts and
  # environment.json), omitting the items in `except` (`:create`, `:migrate`,
  # `:seed`, `:probe` receipts, `:environment`). `environment_tenant:` gives
  # environment.json another tenant than the probe's. Returns the nonce.
  defp bootstrap_history!(root, except, opts \\ []) do
    nonce = Fx.nonce()
    tenant_id = Ecto.UUID.generate()

    Fx.write_state!(root, :pending, %{
      "environment_id" => "agentenv-1",
      "nonce" => nonce,
      "started_at" => DateTime.utc_now()
    })

    BootFx.bootstrap_lease!(root, nonce)

    Fx.write_state!(root, :created, %{
      "database" => "sdr_agent_agentenv",
      "database_oid" => 424_242,
      "nonce" => nonce
    })

    for step <- [:create, :migrate, :seed, :probe], step not in except do
      extra = if step == :probe, do: %{"tenant_id" => tenant_id}, else: %{}
      Fx.write_state!(root, {:receipt, nonce, step}, receipt(nonce, step, extra))
    end

    if :environment not in except do
      Fx.write_state!(root, :environment, %{
        "environment_id" => "agentenv-1",
        "database" => "sdr_agent_agentenv",
        "database_oid" => 424_242,
        "tenant_id" => Keyword.get(opts, :environment_tenant, tenant_id),
        "nonce" => nonce,
        "created_at" => DateTime.utc_now()
      })
    end

    nonce
  end

  ## Classification

  describe "classify" do
    test "an empty state directory is fresh, with unknown or absent database facts", ctx do
      assert classify(ctx.root) == :fresh
      assert classify(ctx.root, :absent) == :fresh
    end

    test "a database present without the pending marker quarantines", ctx do
      assert classify(ctx.root, {:present, %{database_oid: 424_242, tenant_id: nil}}) ==
               {:quarantine, :database_without_pending}
    end

    test "a bound environment with its full bootstrap history is bound", ctx do
      {binding, tenant_id, _nonce} = bound_state!(ctx.root)
      data = BootFx.read_object!(Fx.path(ctx.root, :environment))

      for facts <- [:unknown, {:present, %{database_oid: 424_242, tenant_id: tenant_id}}] do
        assert classify(ctx.root, facts) == {:bound, %{sha256: binding, data: data}},
               inspect(facts)
      end
    end

    test "the live database's oid or tenant differing from the binding quarantines", ctx do
      {_binding, tenant_id, _nonce} = bound_state!(ctx.root)

      assert classify(ctx.root, {:present, %{database_oid: 424_243, tenant_id: tenant_id}}) ==
               {:quarantine, :database_oid_mismatch}

      assert classify(
               ctx.root,
               {:present, %{database_oid: 424_242, tenant_id: Ecto.UUID.generate()}}
             ) ==
               {:quarantine, :tenant_mismatch}
    end

    test "a valid held lease over recognised history is leased", ctx do
      bound_state!(ctx.root)
      Fx.write_lease!(ctx.root, :run, Fx.file_sha256!(ctx.root, :environment))
      assert classify(ctx.root) == {:leased, "run"}
    end

    test "a lease masks no unrecognised or invalid file: quarantine, nothing removed", ctx do
      bound_state!(ctx.root)
      Fx.write_lease!(ctx.root, :run, Fx.file_sha256!(ctx.root, :environment))
      stray = Path.join([ctx.root, "state", "notes.txt"])
      File.write!(stray, "x")
      before = digests(ctx.root)

      assert classify(ctx.root) == {:quarantine, :unrecognised_file}
      assert digests(ctx.root) == before

      File.rm!(stray)
      File.write!(Fx.path(ctx.root, :created), "not canonical\n")
      before = digests(ctx.root)

      assert classify(ctx.root) == {:quarantine, :invalid_file}
      assert digests(ctx.root) == before
    end

    test "an invalid lease is invalid_file, never leased, fresh or bound", ctx do
      File.write!(Fx.path(ctx.root, :lease), "not canonical\n")
      assert classify(ctx.root) == {:quarantine, :invalid_file}
      File.rm!(Fx.path(ctx.root, :lease))

      bound_state!(ctx.root)

      Fx.write_state!(ctx.root, :lease, %{
        "environment_id" => "agentenv-1",
        "mode" => "reset",
        "nonce" => Fx.nonce(),
        "target" => %{"binding_sha256" => Fx.file_sha256!(ctx.root, :environment)},
        "port" => nil,
        "started_at" => DateTime.utc_now()
      })

      before = digests(ctx.root)
      assert classify(ctx.root) == {:quarantine, :invalid_file}
      assert digests(ctx.root) == before
    end

    test "an absent state directory is fresh, and classify creates nothing", ctx do
      state_dir = Path.join(ctx.root, "state")
      File.rmdir!(state_dir)

      assert classify(ctx.root) == :fresh
      assert classify(ctx.root, :absent) == :fresh
      refute File.exists?(state_dir)

      assert classify(ctx.root, {:present, %{database_oid: 424_242, tenant_id: nil}}) ==
               {:quarantine, :database_without_pending}

      refute File.exists?(state_dir)
    end

    test "a state path that is a file, a symlink or unreadable is not absence", ctx do
      state_dir = Path.join(ctx.root, "state")
      File.rmdir!(state_dir)

      File.write!(state_dir, "")
      assert {:quarantine, reason} = classify(ctx.root)
      assert is_atom(reason)
      assert File.read!(state_dir) == ""
      File.rm!(state_dir)

      elsewhere = Fx.root!("state-elsewhere")
      :ok = File.ln_s(elsewhere, state_dir)
      assert {:quarantine, reason} = classify(ctx.root)
      assert is_atom(reason)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(state_dir)
      File.rm!(state_dir)

      File.mkdir!(state_dir)
      File.chmod!(state_dir, 0o000)
      on_exit(fn -> File.chmod(state_dir, 0o700) end)
      assert {:quarantine, reason} = classify(ctx.root)
      assert is_atom(reason)
    end

    test "bound files with the database observed absent are binding_inconsistent", ctx do
      bound_state!(ctx.root)
      before = digests(ctx.root)

      assert classify(ctx.root, :absent) == {:quarantine, :binding_inconsistent}
      assert digests(ctx.root) == before
    end

    test "boot markers, run receipts and S2 authorization files do not unbind", ctx do
      {binding, _tenant_id, _nonce} = bound_state!(ctx.root)
      run_nonce = Fx.nonce()
      boot_id = Fx.hex(16)
      BootFx.write_boot_marker!(ctx.root, run_nonce, boot_id)
      run_receipt!(ctx.root, run_nonce, boot_id)
      Fx.authorized!(ctx.root)

      assert {:bound, %{sha256: ^binding}} = classify(ctx.root)
    end

    test "an unrecognised or invalid file quarantines", ctx do
      bound_state!(ctx.root)
      File.write!(Path.join([ctx.root, "state", "notes.txt"]), "x")
      assert classify(ctx.root) == {:quarantine, :unrecognised_file}

      File.rm!(Path.join([ctx.root, "state", "notes.txt"]))
      File.write!(Fx.path(ctx.root, :environment), "not canonical\n")
      assert classify(ctx.root) == {:quarantine, :invalid_file}
    end

    test "a published environment inconsistent with its history quarantines", ctx do
      bound_state!(ctx.root)
      Fx.tamper!(ctx.root, :created)
      assert classify(ctx.root) == {:quarantine, :binding_inconsistent}
    end

    test "a bound environment missing a bootstrap receipt quarantines", ctx do
      {_binding, _tenant_id, nonce} = bound_state!(ctx.root)
      File.rm!(Fx.path(ctx.root, {:receipt, nonce, :seed}))
      assert classify(ctx.root) == {:quarantine, :missing_bootstrap_receipt}
    end

    test "a created database file without the pending marker quarantines", ctx do
      Fx.write_state!(ctx.root, :created, %{
        "database" => "sdr_agent_agentenv",
        "database_oid" => 424_242,
        "nonce" => Fx.nonce()
      })

      assert classify(ctx.root) == {:quarantine, :created_without_pending}
    end
  end

  ## The five bootstrap crash points (T-V9) and the control

  describe "crash points" do
    test "after the pending marker, before the lease: quarantine, no lease can be taken", ctx do
      Fx.write_state!(ctx.root, :pending, %{
        "environment_id" => "agentenv-1",
        "nonce" => Fx.nonce(),
        "started_at" => DateTime.utc_now()
      })

      assert classify(ctx.root) == {:quarantine, :pending_without_environment}
      before = digests(ctx.root)

      for mode <- [:bootstrap, :provisioning, :run] do
        assert {:error, _reason} = acquire(ctx.root, mode)
      end

      assert digests(ctx.root) == before
    end

    test "after the lease (before the CREATE, before migrate, before publish): leased", ctx do
      assert {:ok, nonce} = acquire(ctx.root, :bootstrap)
      assert classify(ctx.root) == {:leased, "bootstrap"}

      Fx.write_state!(ctx.root, :created, %{
        "database" => "sdr_agent_agentenv",
        "database_oid" => 424_242,
        "nonce" => nonce
      })

      Fx.write_state!(ctx.root, {:receipt, nonce, :create}, receipt(nonce, :create))
      assert classify(ctx.root) == {:leased, "bootstrap"}

      for step <- [:migrate, :seed] do
        Fx.write_state!(ctx.root, {:receipt, nonce, step}, receipt(nonce, step))
      end

      assert classify(ctx.root) == {:leased, "bootstrap"}
      assert acquire(ctx.root, :run) == {:error, :lease_held}
    end

    test "after the published environment, before the lease is released: a stale lease", ctx do
      {binding, _tenant_id, nonce} = bound_state!(ctx.root)
      BootFx.bootstrap_lease!(ctx.root, nonce)

      assert classify(ctx.root) == {:leased, "bootstrap"}
      assert acquire(ctx.root, :run) == {:error, :lease_held}
      assert Fx.file_sha256!(ctx.root, :environment) == binding
    end

    test "control: a full bootstrap leaves exactly the bound state, and a run lease follows",
         ctx do
      assert {:ok, nonce} = acquire(ctx.root, :bootstrap)

      Fx.write_state!(ctx.root, :created, %{
        "database" => "sdr_agent_agentenv",
        "database_oid" => 424_242,
        "nonce" => nonce
      })

      tenant_id = Ecto.UUID.generate()

      for step <- [:create, :migrate, :seed, :probe] do
        extra = if step == :probe, do: %{"tenant_id" => tenant_id}, else: %{}
        Fx.write_state!(ctx.root, {:receipt, nonce, step}, receipt(nonce, step, extra))
      end

      binding =
        Fx.write_state!(ctx.root, :environment, %{
          "environment_id" => "agentenv-1",
          "database" => "sdr_agent_agentenv",
          "database_oid" => 424_242,
          "tenant_id" => tenant_id,
          "nonce" => nonce,
          "created_at" => DateTime.utc_now()
        })

      assert release(ctx.root, :bootstrap, nonce) == :ok
      refute File.exists?(Fx.path(ctx.root, :lease))
      assert {:bound, %{sha256: ^binding}} = classify(ctx.root)

      assert {:ok, run_nonce} = acquire(ctx.root, :run)
      assert run_nonce != nonce
    end
  end

  ## Leases

  describe "acquire_lease" do
    test "bootstrap on a fresh root writes the pending marker and the lease, one nonce", ctx do
      assert {:ok, nonce} = acquire(ctx.root, :bootstrap)
      assert nonce =~ ~r/\A[0-9a-f]{32}\z/
      assert files(ctx.root) == ["environment.pending", "instance.lease"]

      assert %{"environment_id" => "agentenv-1", "nonce" => ^nonce} =
               BootFx.read_object!(Fx.path(ctx.root, :pending))

      lease = lease_data(ctx.root)

      assert {lease["mode"], lease["nonce"], lease["target"], lease["port"]} ==
               {"bootstrap", nonce, @bootstrap_target, nil}

      for name <- [:pending, :lease] do
        assert match?({:valid, _sha256, _data}, state(:read, [ctx.root, name])), inspect(name)
      end
    end

    test "bootstrap on anything but a fresh root is refused and writes nothing", ctx do
      bound_state!(ctx.root)
      before = digests(ctx.root)

      assert acquire(ctx.root, :bootstrap) == {:error, :not_fresh}
      assert digests(ctx.root) == before
    end

    for {mode, port} <- [run: 4130, provisioning: nil] do
      @mode mode
      @port port

      test "#{mode} on a bound root targets the binding digest", ctx do
        {binding, _tenant_id, _nonce} = bound_state!(ctx.root)

        assert {:ok, nonce} = acquire(ctx.root, @mode)
        lease = lease_data(ctx.root)

        assert {lease["mode"], lease["nonce"], lease["target"], lease["port"]} ==
                 {Atom.to_string(@mode), nonce, %{"binding_sha256" => binding}, @port}
      end

      test "#{mode} on a fresh root is refused", ctx do
        assert acquire(ctx.root, @mode) == {:error, :not_bound}
        assert files(ctx.root) == []
      end
    end

    test "a second lease in any mode is refused while one is held", ctx do
      bound_state!(ctx.root)
      assert {:ok, _nonce} = acquire(ctx.root, :run)
      before = digests(ctx.root)

      for mode <- [:bootstrap, :provisioning, :run] do
        assert acquire(ctx.root, mode) == {:error, :lease_held}, inspect(mode)
      end

      assert digests(ctx.root) == before
    end
  end

  describe "release" do
    test "bootstrap without every receipt and the environment is refused; the lease stays", ctx do
      assert {:ok, nonce} = acquire(ctx.root, :bootstrap)
      lease = Fx.file_sha256!(ctx.root, :lease)

      assert release(ctx.root, :bootstrap, nonce) == {:error, :receipts_missing}
      assert Fx.file_sha256!(ctx.root, :lease) == lease
    end

    test "a release of another mode or nonce, or with no lease, is refused", ctx do
      bound_state!(ctx.root)
      assert release(ctx.root, :run, Fx.nonce()) == {:error, :lease_missing}

      assert {:ok, nonce} = acquire(ctx.root, :run)
      assert release(ctx.root, :run, Fx.nonce()) == {:error, :lease_mismatch}
      assert release(ctx.root, :provisioning, nonce) == {:error, :lease_mismatch}
      assert File.exists?(Fx.path(ctx.root, :lease))
    end

    test "provisioning needs its provision receipt", ctx do
      bound_state!(ctx.root)
      assert {:ok, nonce} = acquire(ctx.root, :provisioning)
      assert release(ctx.root, :provisioning, nonce) == {:error, :receipts_missing}

      Fx.write_state!(
        ctx.root,
        {:receipt, nonce, :provision},
        receipt(nonce, :provision, %{
          "authorization_id" => "test-synthetic-1",
          "grant_id" => Ecto.UUID.generate(),
          "event_id" => Ecto.UUID.generate()
        })
      )

      assert release(ctx.root, :provisioning, nonce) == :ok
      refute File.exists?(Fx.path(ctx.root, :lease))
    end

    test "run needs its run receipt", ctx do
      bound_state!(ctx.root)
      assert {:ok, nonce} = acquire(ctx.root, :run)
      boot_id = Fx.hex(16)
      BootFx.write_boot_marker!(ctx.root, nonce, boot_id)

      assert release(ctx.root, :run, nonce) == {:error, :receipts_missing}

      receipt_sha = run_receipt!(ctx.root, nonce, boot_id)
      marker_sha = BootFx.file_sha256!(BootFx.boot_marker_path(ctx.root, nonce))

      assert release(ctx.root, :run, nonce) == :ok
      refute File.exists?(Fx.path(ctx.root, :lease))
      assert Fx.file_sha256!(ctx.root, {:run_receipt, nonce}) == receipt_sha
      assert BootFx.file_sha256!(BootFx.boot_marker_path(ctx.root, nonce)) == marker_sha
    end

    test "P5-2(c): a run receipt whose boot_id is not the marker's is refused; the lease stays",
         ctx do
      bound_state!(ctx.root)
      assert {:ok, nonce} = acquire(ctx.root, :run)
      BootFx.write_boot_marker!(ctx.root, nonce, Fx.hex(16))
      run_receipt!(ctx.root, nonce, Fx.hex(16))
      before = digests(ctx.root)

      assert release(ctx.root, :run, nonce) == {:error, :boot_id_mismatch}
      assert digests(ctx.root) == before
    end

    test "a run receipt without its boot marker is refused", ctx do
      bound_state!(ctx.root)
      assert {:ok, nonce} = acquire(ctx.root, :run)
      run_receipt!(ctx.root, nonce, Fx.hex(16))
      before = digests(ctx.root)

      assert release(ctx.root, :run, nonce) == {:error, :boot_id_mismatch}
      assert File.exists?(Fx.path(ctx.root, :lease))
      assert digests(ctx.root) == before
    end

    test "a run receipt with an invalid or another nonce's boot marker is refused; nothing changes",
         ctx do
      bound = BootFx.agentenv_bound!(ctx.root, lease: :run)
      nonce = bound.nonce
      boot_id = Fx.hex(16)
      run_receipt!(ctx.root, nonce, boot_id)
      marker = BootFx.boot_marker_path(ctx.root, nonce)

      for bytes <- [
            "not canonical\n",
            Canonical.encode!(%{
              "nonce" => Fx.nonce(),
              "boot_id" => boot_id,
              "booted_at" => DateTime.utc_now()
            })
          ] do
        File.write!(marker, bytes)
        File.chmod!(marker, 0o600)
        before = digests(ctx.root)

        assert release(ctx.root, :run, nonce) == {:error, :boot_id_mismatch}, inspect(bytes)
        assert digests(ctx.root) == before, inspect(bytes)
      end
    end

    for item <- [:create, :migrate, :seed, :probe, :environment] do
      @item item

      test "bootstrap release without the #{item} item alone is refused; every byte stays", ctx do
        nonce = bootstrap_history!(ctx.root, [@item])
        before = digests(ctx.root)

        assert release(ctx.root, :bootstrap, nonce) == {:error, :receipts_missing}
        assert digests(ctx.root) == before
      end
    end

    test "bootstrap release control: the complete history releases, removing only the lease",
         ctx do
      nonce = bootstrap_history!(ctx.root, [])
      before = digests(ctx.root)

      assert release(ctx.root, :bootstrap, nonce) == :ok
      assert digests(ctx.root) == Map.delete(before, "instance.lease")
    end

    test "bootstrap release with an environment inconsistent with the probe is refused", ctx do
      nonce = bootstrap_history!(ctx.root, [], environment_tenant: Ecto.UUID.generate())
      before = digests(ctx.root)

      assert release(ctx.root, :bootstrap, nonce) == {:error, :binding_inconsistent}
      assert digests(ctx.root) == before
    end
  end

  ## create/3 (GREEN-2) regression locks

  describe "create" do
    test "create is exclusive and never replaces a published file", ctx do
      nonce = Fx.nonce()
      data = %{"nonce" => nonce, "boot_id" => Fx.hex(16), "booted_at" => DateTime.utc_now()}

      assert {:ok, sha256} = state(:create, [ctx.root, {:boot, nonce}, data])
      bytes = File.read!(BootFx.boot_marker_path(ctx.root, nonce))
      assert BootFx.file_sha256!(BootFx.boot_marker_path(ctx.root, nonce)) == sha256

      assert Canonical.encode!(BootFx.read_object!(BootFx.boot_marker_path(ctx.root, nonce))) ==
               bytes

      assert state(:create, [ctx.root, {:boot, nonce}, %{data | "boot_id" => Fx.hex(16)}]) ==
               {:error, :exists}

      assert File.read!(BootFx.boot_marker_path(ctx.root, nonce)) == bytes
      assert files(ctx.root) == ["instance.#{nonce}.boot"]
    end

    test "create refuses content that would not read back valid, writing nothing", ctx do
      nonce = Fx.nonce()

      assert state(:create, [ctx.root, {:boot, nonce}, %{"nonce" => nonce}]) == {:error, :invalid}
      assert files(ctx.root) == []
    end
  end
end
