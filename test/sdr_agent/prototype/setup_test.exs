defmodule SdrAgent.Prototype.SetupTest do
  @moduledoc """
  IF-2 setup bootstrap (interfaces r6; F1, must-fix R1), the parts that run
  inside a test sandbox: the phase-0 preflight refusals, the phase-1
  freshness and bounded-resume checks, the phase-2 single transaction and
  its rollback, the auditor credential file, and zero `oban_jobs`. The
  storage and Repo-only start are proven by the live G5 smoke on the
  scratch cluster, not here.
  """
  use SdrAgent.PrototypeCase, async: false

  @authority SdrAgent.Prototype.Authority

  @exact_repo [
    socket_dir: "/private/tmp/d237-pg",
    port: 5541,
    database: "sdr_agent_prototype"
  ]

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  # An exclusive, unpredictable, owned 0700 root (Codex 39a6fd61 R1).
  defp scratch_dir!, do: PrototypeFixtures.scratch_dir!()

  describe "phase 0 preflight" do
    test "the Repo target must be exactly the prototype socket, port and database" do
      assert call(@authority, :check_repo_target, [@exact_repo]) == :ok
      # dev.exs keeps hostname: "localhost"; Postgrex gives socket_dir precedence over it.
      assert call(@authority, :check_repo_target, [[{:hostname, "localhost"} | @exact_repo]]) ==
               :ok

      for wrong <- [
            Keyword.put(@exact_repo, :port, 5520),
            Keyword.put(@exact_repo, :database, "sdr_agent_dev"),
            Keyword.put(@exact_repo, :socket_dir, "/tmp/d237-pg"),
            Keyword.delete(@exact_repo, :socket_dir),
            Keyword.put(@exact_repo, :socket, "/private/tmp/d237-pg/.s.PGSQL.5520"),
            Keyword.put(@exact_repo, :url, "ecto://postgres@localhost:5520/sdr_agent_dev")
          ] do
        assert call(@authority, :check_repo_target, [wrong]) == {:error, :repo_target_mismatch},
               "repo target #{inspect(wrong)} was accepted"
      end
    end

    test "a running application refuses with :app_running" do
      # The test VM runs Oban and the endpoint.
      assert call(@authority, :check_app_stopped, []) == {:error, :app_running}
    end

    test "the credential file is created exclusively at mode 0600 and never overwritten" do
      dir = scratch_dir!()
      path = Path.join(dir, "auditor.credential")

      assert {:ok, password} = call(@authority, :write_credential, [path])
      assert byte_size(password) == 43
      assert {:ok, %File.Stat{mode: mode}} = File.lstat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert File.read!(path) == password

      assert call(@authority, :write_credential, [path]) == {:error, :credential_path_exists}
      assert File.read!(path) == password
    end
  end

  describe "phase 1 checks" do
    test "an empty database is fresh and resumable; any row refuses both" do
      assert call(@authority, :check_fresh, []) == :ok
      assert call(@authority, :check_resumable, []) == :ok
      bootstrap!()
      assert call(@authority, :check_fresh, []) == {:error, :database_not_fresh}
      assert call(@authority, :check_resumable, []) == {:error, :database_not_resumable}
    end

    test "resume refuses an extra or a missing migration version" do
      assert call(@authority, :check_resumable, []) == :ok

      Repo.query!(
        "INSERT INTO schema_migrations (version, inserted_at) VALUES (99990101000000, now())"
      )

      assert call(@authority, :check_resumable, []) == {:error, :database_not_resumable}
    end

    test "the pinned migration set ends with the seven d237 migrations, in order" do
      versions = call(@authority, :pinned_migrations, [])
      assert is_list(versions), "pinned_migrations/0 returned #{inspect(versions)}"
      names = Enum.map(versions, fn {_version, name} -> name end)

      assert Enum.take(names, -7) == [
               "d237_01_users",
               "d237_02_actor_types",
               "d237_03_prototype_database_bindings",
               "d237_04_prototype_delegations",
               "d237_05_release_decisions",
               "d237_06_sources",
               "d237_07_dossier"
             ]
    end
  end

  describe "phase 2 bootstrap" do
    test "one transaction creates the tenant, anchor, auditor, binding and setup delegation" do
      assert count("tenants") == 0

      result =
        call(@authority, :bootstrap, [
          [
            agent: :claude_code,
            session_correlation: "setup-session-0001",
            auditor_password: "a" |> String.duplicate(43)
          ]
        ])

      assert match?({:ok, %{}}, result), "bootstrap: #{inspect(result)}"
      {:ok, created} = result

      assert count("tenants") == 1
      assert count("users") == 2
      assert count("prototype_database_bindings") == 1
      assert count("prototype_delegations") == 1
      assert created.anchor.role == :agent_operator
      assert created.auditor.role == :auditor
      assert created.binding.operator_user_id == created.anchor.id
      assert created.binding.auditor_user_id == created.auditor.id
      assert created.delegation.agent == "claude_code"

      types = created.tenant |> events() |> Enum.map(& &1.event_type)
      assert "prototype.binding.created" in types
      assert "prototype.delegation.created" in types
      assert count("oban_jobs") == 0
    end

    # Codex 97b19ad4: the rollback proof must show that the failure came AFTER
    # earlier writes. The test-build hook `{Authority, :before_delegation}`
    # runs inside bootstrap's transaction, after the tenant, anchor and
    # binding writes and before the delegation's; here it reports the row
    # counts it sees there and then raises (the injected late failure).
    test "a failure after the earlier writes rolls back the tenant, users, binding and delegation" do
      test_pid = self()
      tables = ~w(tenants users prototype_database_bindings prototype_delegations)

      Process.put({@authority, :before_delegation}, fn _created ->
        send(test_pid, {:written, Map.new(tables, &{&1, count(&1)})})
        raise "injected late bootstrap failure"
      end)

      result =
        call(@authority, :bootstrap, [
          [agent: :claude_code, session_correlation: "setup-session-0002"]
        ])

      assert result == {:error, :bootstrap_failed},
             "a bootstrap failing before its last write returned #{inspect(result)}"

      assert_received {:written, written}, "the late failure point was never reached"

      assert written == %{
               "tenants" => 1,
               "users" => 1,
               "prototype_database_bindings" => 1,
               "prototype_delegations" => 0
             }

      for table <- tables do
        assert count(table) == 0, "#{table} kept a row after the rollback"
      end
    end

    test "a malformed agent or correlation is refused and writes nothing" do
      for opts <- [
            [agent: :claude_code, session_correlation: "bad"],
            [agent: :other_agent, session_correlation: "setup-session-0003"]
          ] do
        result = call(@authority, :bootstrap, [opts])

        assert result == {:error, :bootstrap_failed},
               "#{inspect(opts)} returned #{inspect(result)}"

        for table <- ~w(tenants users prototype_database_bindings prototype_delegations) do
          assert count(table) == 0, "#{inspect(opts)}: #{table} kept a row"
        end
      end
    end

    test "the setup-only actions refuse every caller but the setup marker" do
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      binding = loaded!(SdrAgent.Operations.PrototypeDatabaseBinding)

      for actor <- [admin, fx.actor, system_actor(:kernel, fx.tenant)] do
        result =
          binding
          |> Ash.Changeset.for_create(:create, %{instance_id: Ecto.UUID.generate()}, actor: actor)
          |> Ash.create()

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "binding :create was not forbidden: #{inspect(result)}"
      end
    end
  end
end
