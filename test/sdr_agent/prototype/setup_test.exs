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
    socket_dir: "/private/tmp/d237-pg-5542",
    port: 5542,
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
            Keyword.put(@exact_repo, :socket, "/private/tmp/d237-pg-5542/.s.PGSQL.5520"),
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

    test "the pinned migration set ends with the seven d237 migrations, then S-B1's two d270 and S-B2's d270_03" do
      versions = call(@authority, :pinned_migrations, [])
      assert is_list(versions), "pinned_migrations/0 returned #{inspect(versions)}"
      names = Enum.map(versions, fn {_version, name} -> name end)

      assert Enum.take(names, -3) == [
               "d270_01_relocation_chain",
               "d270_02_relocation_event_position",
               "d270_03_remote_calls"
             ]

      assert Enum.slice(names, -10, 7) == [
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

      # Valid inputs, so a refusal is the authorization's, never Invalid.
      params = %{
        instance_id: Ecto.UUID.generate(),
        operator_user_id: fx.anchor.id,
        policy_entry_sha256: fx.snapshot.policy_entry_sha256,
        database_oid: fx.snapshot.database_oid,
        system_identifier: fx.snapshot.system_identifier
      }

      for actor <- [admin, fx.actor, system_actor(:kernel, fx.tenant)] do
        result =
          binding
          |> Ash.Changeset.for_create(:create, params, actor: actor)
          |> Ash.create()

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "binding :create was not forbidden: #{inspect(result)}"
      end
    end
  end

  # Codex f3036a14 queue 2: success AND refusal coverage for each
  # non-credential phase-0/1 helper, beyond the first REDs above.
  describe "phase 0 and 1 helpers: success and refusal coverage" do
    defmodule FreshProbeWorker do
      @moduledoc "A test-only Oban worker; its jobs are inserted, never run (testing: :manual)."
      use Oban.Worker, queue: :default

      @impl Oban.Worker
      def perform(_job), do: :ok
    end

    # Every base table of the public schema except schema_migrations, from
    # the catalog, with its row presence.
    defp public_tables_with_rows do
      %{rows: rows} =
        Repo.query!(
          "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' " <>
            "AND tablename <> 'schema_migrations' ORDER BY tablename",
          []
        )

      for [table] <- rows,
          match?(
            %{rows: [[true]]},
            Repo.query!(~s[SELECT EXISTS (SELECT 1 FROM "public"."#{table}")], [])
          ),
          do: table
    end

    defp migration_files do
      Path.wildcard("priv/repo/migrations/*.exs")
      |> Enum.map(&Path.basename(&1, ".exs"))
      |> Enum.map(fn base ->
        [version, name] = String.split(base, "_", parts: 2)
        {String.to_integer(version), name}
      end)
      |> Enum.sort()
    end

    test "conflicting or extra Repo target selectors refuse" do
      for wrong <- [
            [{:port, 5520} | @exact_repo],
            [{:database, "sdr_agent_dev"} | @exact_repo],
            [{:socket_dir, "/private/tmp/d237-pg-5542-other"} | @exact_repo],
            Keyword.put(@exact_repo, :endpoints, [{"localhost", 5542}]),
            Keyword.put(@exact_repo, :hostname, "db.example.test"),
            Keyword.put(@exact_repo, :socket_dir, "/private/tmp/d237-pg-5542/"),
            Map.new(@exact_repo)
          ] do
        result = call(@authority, :check_repo_target, [wrong])

        assert result == {:error, :repo_target_mismatch},
               "repo target #{inspect(wrong)} gave #{inspect(result)}"
      end
    end

    test "the app-running names are exactly IF-2's: Oban, the endpoint and the provider tree" do
      assert call(@authority, :app_names, []) == [
               {:oban, Oban},
               {:process, SdrAgentWeb.Endpoint},
               {:process, SdrAgent.AI.ModelProvider.ProfileSupervisor},
               {:process, SdrAgent.AI.ModelProvider.ServerSupervisor},
               {:process, SdrAgent.AI.ModelProvider.Coordinator},
               {:process, SdrAgent.AI.ModelProvider.OperationSupervisor},
               {:process, SdrAgent.AI.ModelProvider.ClaudeCLI}
             ]
    end

    test "names that are not alive pass; a live registered name or Oban instance refuses" do
      n = System.unique_integer([:positive])
      absent_process = :"d237_setup_absent_#{n}"
      absent_oban = Module.concat(__MODULE__, "AbsentOban#{n}")

      assert call(@authority, :check_app_stopped, [
               [{:process, absent_process}, {:oban, absent_oban}]
             ]) ==
               :ok

      live = :"d237_setup_live_#{n}"
      Process.register(self(), live)

      try do
        assert call(@authority, :check_app_stopped, [
                 [{:process, absent_process}, {:process, live}]
               ]) ==
                 {:error, :app_running}
      after
        Process.unregister(live)
      end

      oban = Module.concat(__MODULE__, "LiveOban#{n}")

      start_supervised!(
        {Oban,
         [name: oban, repo: Repo, testing: :disabled] ++
           SdrAgent.Prototype.Session.oban_insert_only_opts()}
      )

      assert call(@authority, :check_app_stopped, [[{:oban, oban}]]) == {:error, :app_running}
    end

    test "a row in any public table refuses freshness and resume: an Oban job alone" do
      assert public_tables_with_rows() == [],
             "prerequisite: the sandbox did not start empty: #{inspect(public_tables_with_rows())}"

      assert call(@authority, :check_fresh, []) == :ok
      assert call(@authority, :check_resumable, []) == :ok

      assert {:ok, _job} = Oban.insert(FreshProbeWorker.new(%{}))
      assert public_tables_with_rows() == ["oban_jobs"]

      assert call(@authority, :check_fresh, []) == {:error, :database_not_fresh}
      assert call(@authority, :check_resumable, []) == {:error, :database_not_resumable}
    end

    test "resume refuses a missing migration version (labelled negative tamper)" do
      assert call(@authority, :check_resumable, []) == :ok

      # Synthetic negative tamper inside the sandbox transaction (rolled back):
      # one pinned version row removed from schema_migrations.
      Repo.query!("DELETE FROM schema_migrations WHERE version = 20261028052425", [])

      assert call(@authority, :check_resumable, []) == {:error, :database_not_resumable}
    end

    test "the pinned migration set is exactly the migration files, in version order" do
      pinned = call(@authority, :pinned_migrations, [])
      assert is_list(pinned), "pinned_migrations/0 returned #{inspect(pinned)}"
      assert pinned == migration_files()
      assert pinned == Enum.sort(pinned)
      assert length(pinned) == 37

      %{rows: rows} =
        Repo.query!("SELECT version FROM schema_migrations ORDER BY version", [])

      assert Enum.map(rows, fn [v] -> v end) == Enum.map(pinned, &elem(&1, 0))
    end
  end

  # Codex dd9c0f20 F1-F3: corrective REDs for the phase-0/1 helpers.
  describe "setup F corrective coverage (F1-F3)" do
    @catalog_seam {SdrAgent.Prototype.Authority, :catalog_tables}

    defp observed_public_tables do
      %{rows: rows} =
        Repo.query!(
          "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' " <>
            "AND tablename <> 'schema_migrations' ORDER BY tablename",
          []
        )

      Enum.map(rows, fn [table] -> table end)
    end

    # The synthetic transactional seam (test builds only): this process's
    # one-argument function is applied to the observed public-table list.
    # No schema object is created, altered or dropped.
    defp with_catalog(fun, body) do
      Process.put(@catalog_seam, fun)

      try do
        body.()
      after
        Process.delete(@catalog_seam)
      end
    end

    defp fresh_and_resumable,
      do: {call(@authority, :check_fresh, []), call(@authority, :check_resumable, [])}

    test "F1: the pinned public-table inventory equals this migration set's catalog" do
      pinned = call(@authority, :public_tables, [])
      observed = observed_public_tables()
      assert pinned == observed, "pinned #{inspect(pinned)}; observed #{inspect(observed)}"
    end

    test "F1: a missing non-named table refuses both, with exact version rows" do
      assert fresh_and_resumable() == {:ok, :ok},
             "prerequisite: exact versions and no rows"

      result = with_catalog(&(&1 -- ["contacts"]), &fresh_and_resumable/0)
      assert result == {{:error, :database_not_fresh}, {:error, :database_not_resumable}}
    end

    test "F1: a missing named table refuses both" do
      result = with_catalog(&(&1 -- ["users"]), &fresh_and_resumable/0)
      assert result == {{:error, :database_not_fresh}, {:error, :database_not_resumable}}
    end

    test "F1: an unexpected extra public table refuses both" do
      result =
        with_catalog(&Enum.sort(["d237_unexpected" | &1]), &fresh_and_resumable/0)

      assert result == {{:error, :database_not_fresh}, {:error, :database_not_resumable}}
    end

    test "F1: the identity seam keeps both passing (control)" do
      assert with_catalog(& &1, &fresh_and_resumable/0) == {:ok, :ok}
    end

    test "F2: a configure callback, fun or MFA, refuses without being called" do
      test_pid = self()

      configure_fun = fn opts ->
        send(test_pid, :configure_called)
        Keyword.put(opts, :socket_dir, "/private/tmp/d237-elsewhere")
      end

      for configure <- [
            configure_fun,
            {Keyword, :put, [:socket_dir, "/private/tmp/d237-elsewhere"]}
          ] do
        result =
          call(@authority, :check_repo_target, [Keyword.put(@exact_repo, :configure, configure)])

        assert result == {:error, :repo_target_mismatch},
               "configure #{inspect(configure)} gave #{inspect(result)}"
      end

      refute_received :configure_called
    end

    test "F2: a nil configure and plain non-selector pool options pass (control)" do
      assert call(@authority, :check_repo_target, [Keyword.put(@exact_repo, :configure, nil)]) ==
               :ok

      plain =
        @exact_repo ++
          [
            hostname: "localhost",
            username: "postgres",
            pool_size: 2,
            timeout: 15_000,
            show_sensitive_data_on_connection_error: false
          ]

      assert call(@authority, :check_repo_target, [plain]) == :ok
    end

    test "F3: resume reads public.schema_migrations, never a search_path shadow" do
      # Synthetic negative: a transaction-scoped TEMP shadow (pg_temp is
      # searched first for unqualified names) holding every pinned version,
      # rolled back with the test.
      Repo.query!(
        "CREATE TEMP TABLE schema_migrations ON COMMIT DROP AS " <>
          "SELECT version, inserted_at FROM public.schema_migrations",
        []
      )

      assert call(@authority, :check_resumable, []) == :ok,
             "control: an identical shadow with an intact public table"

      # Labelled negative tamper (rolled back): one pinned version removed
      # from the PUBLIC table only; the shadow still holds all of them.
      Repo.query!("DELETE FROM public.schema_migrations WHERE version = 20261028052425", [])

      assert call(@authority, :check_resumable, []) == {:error, :database_not_resumable}
    end
  end

  # Codex 54f4263b P0-2: bootstrap/1 is top-level only. Inside a caller's
  # open transaction it refuses with its closed code before any query or
  # write, and the caller's transaction stays usable: its own
  # transaction-local work survives, SELECT 1 works, and no rollback is
  # thrown through it.
  describe "phase 2 bootstrap inside an open transaction (P0-2)" do
    @doc false
    def handle_query(_event, _measurements, metadata, pid),
      do: send(pid, {:p02_query, metadata[:source]})

    defp query_sources(fun) do
      id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(id, [:sdr_agent, :repo, :query], &__MODULE__.handle_query/4, self())

      try do
        result = fun.()
        {result, drain_queries([])}
      after
        :telemetry.detach(id)
      end
    end

    defp drain_queries(sources) do
      receive do
        {:p02_query, source} -> drain_queries([source | sources])
      after
        0 -> Enum.reverse(sources)
      end
    end

    defp bootstrap_opts(correlation),
      do: [
        agent: :claude_code,
        session_correlation: correlation,
        auditor_password: String.duplicate("a", 43)
      ]

    test "a nested call is refused before any query or write; the caller's transaction is usable" do
      before =
        Enum.map(~w(tenants users prototype_database_bindings prototype_delegations), &count/1)

      outer =
        Repo.transaction(fn ->
          Repo.query!("SELECT set_config('sdr.p02_caller', 'kept', true)", [])

          {result, sources} =
            query_sources(fn ->
              call(@authority, :bootstrap, [bootstrap_opts("setup-nested-0001")])
            end)

          %{rows: [[marker]]} = Repo.query!("SELECT current_setting('sdr.p02_caller', true)", [])
          %{rows: [[one]]} = Repo.query!("SELECT 1", [])
          %{result: result, sources: sources, marker: marker, one: one}
        end)

      assert match?({:ok, %{}}, outer), "the caller's transaction gave #{inspect(outer)}"
      {:ok, observed} = outer

      assert observed.sources == [],
             "bootstrap issued Repo queries with sources #{inspect(observed.sources)}"

      assert observed.result == {:error, :bootstrap_failed}
      assert {observed.marker, observed.one} == {"kept", 1}

      assert Enum.map(
               ~w(tenants users prototype_database_bindings prototype_delegations),
               &count/1
             ) ==
               before
    end
  end
end
