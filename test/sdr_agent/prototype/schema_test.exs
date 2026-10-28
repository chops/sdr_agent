defmodule SdrAgent.Prototype.SchemaTest do
  @moduledoc """
  The D-237 schema freeze (Increment A-full; plan r7 section 4; interfaces r6
  IF-2, IF-3, IF-4, IF-6; the entity/action delta r5), checked dependency
  first against the migrated schema with raw SQL and the catalog:

  1. users (d237_01): the role value, the password-role CHECK, the nullable
     password column and UNIQUE (id, tenant_id);
  2. actor type (d237_02, guard-only): the Ash value set and the applied
     migration;
  3. bindings (d237_03) and 4. delegations (d237_04): the table, every
     fixed-value CHECK, the keys, the composite foreign keys and the
     create-only triggers, then their enforcement on inserts;
  5. releases (d237_05): the frozen values and the SQL pair rule (S1's;
     `allowed_pair?/2` and the decision behaviour are S2's);
  6. sources (d237_06, guard-only): the Ash value sets and the applied
     migration;
  7. dossier tables (d237_07): tables, keys, triggers, payload foreign keys;
  8. the seven migrations, applied last and in order.

  Every enforcement case first asserts the catalog object it exercises, so
  on a schema without it the case fails at that structural assertion, never
  in a fixture. Fixtures are per test and synthetic (`.test`).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts.User
  alias SdrAgent.Agents.ModelResultRelease

  @hex64 String.duplicate("a", 64)
  @trace String.duplicate("a", 32)
  @span String.duplicate("b", 16)

  ## Catalog helpers (plain reads; absent objects read as nil or [])

  defp regclass(table) do
    %{rows: [[name]]} = Repo.query!("SELECT to_regclass($1)::text", [table])
    name
  end

  defp constraint_def(name) do
    case Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [
           name
         ]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp index_def(name) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp nullable?(table, column) do
    %{rows: rows} =
      Repo.query!(
        "SELECT is_nullable FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    rows == [["YES"]]
  end

  defp triggers(table) do
    case regclass(table) do
      nil ->
        []

      _name ->
        %{rows: rows} =
          Repo.query!(
            "SELECT tgname FROM pg_trigger WHERE tgrelid = $1::regclass AND NOT tgisinternal",
            [table]
          )

        rows |> List.flatten() |> Enum.sort()
    end
  end

  # `{version, name}` of every migration file whose version is applied.
  defp applied_migrations do
    %{rows: rows} = Repo.query!("SELECT version FROM schema_migrations", [])
    applied = MapSet.new(List.flatten(rows))

    for file <- Path.wildcard("priv/repo/migrations/*.exs"),
        [version, name] = String.split(Path.basename(file, ".exs"), "_", parts: 2),
        MapSet.member?(applied, String.to_integer(version)),
        do: {String.to_integer(version), name}
  end

  defp assert_table!(table) do
    assert regclass(table) == table, "table #{table} does not exist"
  end

  defp assert_constraint!(name, fragments) do
    definition = constraint_def(name)
    assert is_binary(definition), "constraint #{name} does not exist"

    for fragment <- fragments do
      assert definition =~ fragment,
             "constraint #{name} lacks #{inspect(fragment)}: #{definition}"
    end
  end

  ## Fixture helpers (called only after their prerequisites are asserted)

  defp uuid, do: Ecto.UUID.generate()
  defp dump(id), do: Ecto.UUID.dump!(id)

  defp insert_user!(tenant, role, hash) do
    id = uuid()

    Repo.query!(
      "INSERT INTO users (id, email, hashed_password, role, status, display_name, tenant_id, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'active', 'Fixture', $5, now(), now())",
      [
        dump(id),
        "#{role}-#{System.unique_integer([:positive])}@prototype.test",
        hash,
        role,
        dump(tenant.id)
      ]
    )

    id
  end

  # The anchor fixture needs d237_01 (a nil password for agent_operator).
  defp anchor!(tenant) do
    assert nullable?("users", "hashed_password"),
           "prerequisite d237_01: users.hashed_password is NOT NULL"

    insert_user!(tenant, "agent_operator", nil)
  end

  @binding_columns ~w(id singleton prototype instance_id dataset_class policy_id policy_entry_sha256
                      funding_id witness_mode database database_oid system_identifier bound_at
                      trace_id span_id tenant_id operator_user_id auditor_user_id)

  defp binding_row(tenant, operator_id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => dump(uuid()),
        "singleton" => true,
        "prototype" => true,
        "instance_id" => dump(uuid()),
        "dataset_class" => "real_prototype",
        "policy_id" => "d237-prototype/1",
        "policy_entry_sha256" => @hex64,
        "funding_id" => "d237-funding/1",
        "witness_mode" => "absent",
        "database" => "sdr_agent_prototype",
        "database_oid" => 16_384,
        "system_identifier" => 7_000_000_000_000_000_001,
        "bound_at" => DateTime.utc_now(),
        "trace_id" => @trace,
        "span_id" => @span,
        "tenant_id" => dump(tenant.id),
        "operator_user_id" => dump(operator_id),
        "auditor_user_id" => nil
      },
      overrides
    )
  end

  @delegation_columns ~w(id tenant_id binding_id operator_user_id delegation_ref agent
                         session_correlation started_at trace_id span_id)

  defp delegation_row(binding, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => dump(uuid()),
        "tenant_id" => binding["tenant_id"],
        "binding_id" => binding["id"],
        "operator_user_id" => binding["operator_user_id"],
        "delegation_ref" => "D-243",
        "agent" => "claude_code",
        "session_correlation" => "schema-session-0001",
        "started_at" => DateTime.utc_now(),
        "trace_id" => @trace,
        "span_id" => @span
      },
      overrides
    )
  end

  defp insert_sql(table, columns) do
    params = Enum.map_join(1..length(columns), ", ", &"$#{&1}")
    "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{params})"
  end

  defp try_insert(table, columns, row),
    do: raw_error(insert_sql(table, columns), Enum.map(columns, &row[&1]))

  defp insert!(table, columns, row) do
    Repo.query!(insert_sql(table, columns), Enum.map(columns, &row[&1]))
    row
  end

  defp pg_code({:error, %Postgrex.Error{postgres: %{code: code} = pg}}),
    do: {code, pg[:constraint]}

  defp pg_code(other), do: other

  ## 1. users (d237_01)

  describe "1. users" do
    test "the role CHECK admits agent_operator and the Ash role set includes it" do
      assert_constraint!("users_role", ["'agent_operator'"])
      assert :agent_operator in Ash.Resource.Info.attribute(User, :role).constraints[:one_of]
      assert User.roles() == [:admin, :reviewer, :auditor]
    end

    test "the password-role CHECK exists and the password column is nullable" do
      assert_constraint!("users_agent_operator_password", [
        "agent_operator",
        "hashed_password IS NULL"
      ])

      assert nullable?("users", "hashed_password")
    end

    test "UNIQUE (id, tenant_id) exists" do
      definition = index_def("users_unique_id_tenant_index")
      assert is_binary(definition), "users_unique_id_tenant_index does not exist"
      assert definition =~ "UNIQUE INDEX"
      assert definition =~ "(id, tenant_id)"
    end
  end

  ## 2. actor type (d237_02)

  describe "2. actor type" do
    test "the actor value sets include prototype_operator and d237_02 is applied" do
      assert :prototype_operator in SdrAgent.Actor.types()

      for resource <- [SdrAgent.Audit.AuditEvent, SdrAgent.Audit.AuditAccess] do
        values = Ash.Resource.Info.attribute(resource, :actor_type).constraints[:one_of]
        assert :prototype_operator in values, "#{inspect(resource)} actor_type lacks it"
      end

      assert Enum.any?(applied_migrations(), &match?({_, "d237_02_actor_types"}, &1))
    end
  end

  ## 3. prototype_database_bindings (d237_03)

  describe "3. bindings: catalog" do
    test "the table, its fixed-value CHECKs and its keys exist" do
      assert_table!("prototype_database_bindings")

      for {name, fragments} <- [
            {"prototype_database_bindings_singleton", ["singleton IS TRUE"]},
            {"prototype_database_bindings_prototype", ["prototype IS TRUE"]},
            {"prototype_database_bindings_auditor_not_operator",
             ["auditor_user_id <> operator_user_id"]},
            {"prototype_database_bindings_dataset_class", ["'real_prototype'"]},
            {"prototype_database_bindings_policy_id", ["'d237-prototype/1'"]},
            {"prototype_database_bindings_policy_entry_sha256", ["[0-9a-f]{64}"]},
            {"prototype_database_bindings_funding_id", ["'d237-funding/1'"]},
            {"prototype_database_bindings_witness_mode", ["'absent'"]},
            {"prototype_database_bindings_database", ["'sdr_agent_prototype'"]},
            {"prototype_database_bindings_database_oid", ["database_oid > 0"]},
            {"prototype_database_bindings_trace_ids", ["trace_id"]},
            {"prototype_database_bindings_operator_user_id_fkey",
             ["(operator_user_id, tenant_id)", "users(id, tenant_id)", "MATCH FULL"]},
            {"prototype_database_bindings_auditor_user_id_fkey",
             ["(auditor_user_id, tenant_id)", "users(id, tenant_id)"]}
          ] do
        assert_constraint!(name, fragments)
      end

      assert index_def("prototype_database_bindings_unique_singleton_index") =~ "(singleton)"

      assert index_def("prototype_database_bindings_unique_id_tenant_operator_index") =~
               "(id, tenant_id, operator_user_id)"

      assert triggers("prototype_database_bindings") ==
               ~w(prototype_database_bindings_guard_row prototype_database_bindings_guard_truncate)
    end
  end

  describe "3. bindings: enforcement" do
    setup do
      assert_table!("prototype_database_bindings")
      tenant = bootstrap!()
      %{tenant: tenant, anchor_id: anchor!(tenant)}
    end

    test "a valid row inserts; a second is a singleton unique violation", ctx do
      insert!(
        "prototype_database_bindings",
        @binding_columns,
        binding_row(ctx.tenant, ctx.anchor_id)
      )

      second = binding_row(ctx.tenant, ctx.anchor_id)

      assert pg_code(try_insert("prototype_database_bindings", @binding_columns, second)) ==
               {:unique_violation, "prototype_database_bindings_unique_singleton_index"}
    end

    test "every fixed value is refused by its CHECK", ctx do
      for {column, value, constraint} <- [
            {"singleton", false, "prototype_database_bindings_singleton"},
            {"prototype", false, "prototype_database_bindings_prototype"},
            {"dataset_class", "synthetic", "prototype_database_bindings_dataset_class"},
            {"policy_id", "d237-prototype/2", "prototype_database_bindings_policy_id"},
            {"policy_entry_sha256", "ABC", "prototype_database_bindings_policy_entry_sha256"},
            {"funding_id", "d237-funding/2", "prototype_database_bindings_funding_id"},
            {"witness_mode", "trusted", "prototype_database_bindings_witness_mode"},
            {"database", "sdr_agent_dev", "prototype_database_bindings_database"},
            {"database_oid", 0, "prototype_database_bindings_database_oid"},
            {"trace_id", String.duplicate("0", 32), "prototype_database_bindings_trace_ids"}
          ] do
        row = binding_row(ctx.tenant, ctx.anchor_id, %{column => value})

        assert pg_code(try_insert("prototype_database_bindings", @binding_columns, row)) ==
                 {:check_violation, constraint},
               "#{column} = #{inspect(value)} was not refused by #{constraint}"
      end
    end

    test "the auditor is never the anchor, and both must be users of the tenant", ctx do
      cases = [
        {%{"auditor_user_id" => dump(ctx.anchor_id)},
         {:check_violation, "prototype_database_bindings_auditor_not_operator"}},
        {%{"operator_user_id" => dump(uuid())},
         {:foreign_key_violation, "prototype_database_bindings_operator_user_id_fkey"}},
        {%{"auditor_user_id" => dump(uuid())},
         {:foreign_key_violation, "prototype_database_bindings_auditor_user_id_fkey"}}
      ]

      for {overrides, expected} <- cases do
        row = binding_row(ctx.tenant, ctx.anchor_id, overrides)

        assert pg_code(try_insert("prototype_database_bindings", @binding_columns, row)) ==
                 expected
      end
    end

    test "the row is create-only", ctx do
      row =
        insert!(
          "prototype_database_bindings",
          @binding_columns,
          binding_row(ctx.tenant, ctx.anchor_id)
        )

      for sql <- [
            "UPDATE prototype_database_bindings SET database_oid = 2 WHERE id = $1",
            "DELETE FROM prototype_database_bindings WHERE id = $1"
          ] do
        assert pg_code(raw_error(sql, [row["id"]])) == {:restrict_violation, nil}
      end

      assert pg_code(raw_error("TRUNCATE prototype_database_bindings CASCADE")) ==
               {:restrict_violation, nil}
    end
  end

  ## 4. prototype_delegations (d237_04)

  describe "4. delegations: catalog" do
    test "the table, its CHECKs, the composite foreign key and the keys exist" do
      assert_table!("prototype_delegations")

      for {name, fragments} <- [
            {"prototype_delegations_ref", ["'D-243'"]},
            {"prototype_delegations_agent", ["'claude_code'", "'codex_cli'"]},
            {"prototype_delegations_session_correlation", ["{8,128}"]},
            {"prototype_delegations_trace_ids", ["trace_id"]},
            {"prototype_delegations_binding_id_fkey",
             [
               "(binding_id, tenant_id, operator_user_id)",
               "prototype_database_bindings(id, tenant_id, operator_user_id)",
               "MATCH FULL"
             ]}
          ] do
        assert_constraint!(name, fragments)
      end

      assert index_def("prototype_delegations_unique_session_index") =~
               "(binding_id, agent, session_correlation)"

      assert triggers("prototype_delegations") ==
               ~w(prototype_delegations_guard_row prototype_delegations_guard_truncate)
    end
  end

  describe "4. delegations: enforcement" do
    setup do
      assert_table!("prototype_delegations")
      tenant = bootstrap!()
      anchor_id = anchor!(tenant)

      binding =
        insert!("prototype_database_bindings", @binding_columns, binding_row(tenant, anchor_id))

      %{tenant: tenant, binding: binding}
    end

    test "a valid delegation inserts; a duplicate session is a unique violation", ctx do
      insert!("prototype_delegations", @delegation_columns, delegation_row(ctx.binding))

      assert pg_code(
               try_insert(
                 "prototype_delegations",
                 @delegation_columns,
                 delegation_row(ctx.binding)
               )
             ) ==
               {:unique_violation, "prototype_delegations_unique_session_index"}
    end

    test "the composite foreign key refuses another anchor of the same tenant", ctx do
      other = insert_user!(ctx.tenant, "reviewer", "x")
      row = delegation_row(ctx.binding, %{"operator_user_id" => dump(other)})

      assert pg_code(try_insert("prototype_delegations", @delegation_columns, row)) ==
               {:foreign_key_violation, "prototype_delegations_binding_id_fkey"}
    end

    test "the reference, agent and correlation are refused by their CHECKs", ctx do
      for {column, value, constraint} <- [
            {"delegation_ref", "D-244", "prototype_delegations_ref"},
            {"agent", "gpt_cli", "prototype_delegations_agent"},
            {"session_correlation", "short", "prototype_delegations_session_correlation"},
            {"session_correlation", "has space-1234",
             "prototype_delegations_session_correlation"},
            {"session_correlation", String.duplicate("a", 129),
             "prototype_delegations_session_correlation"}
          ] do
        row = delegation_row(ctx.binding, %{column => value})

        assert pg_code(try_insert("prototype_delegations", @delegation_columns, row)) ==
                 {:check_violation, constraint},
               "#{column} = #{inspect(value)} was not refused by #{constraint}"
      end
    end

    test "a delegation is create-only", ctx do
      row = insert!("prototype_delegations", @delegation_columns, delegation_row(ctx.binding))

      for sql <- [
            "UPDATE prototype_delegations SET agent = 'codex_cli' WHERE id = $1",
            "DELETE FROM prototype_delegations WHERE id = $1"
          ] do
        assert pg_code(raw_error(sql, [row["id"]])) == {:restrict_violation, nil}
      end
    end
  end

  ## 5. releases (d237_05)

  describe "5. releases" do
    test "the frozen values and the SQL pair rule" do
      assert :released_unverified in ModelResultRelease.dispositions()

      assert call(ModelResultRelease, :prototype_withheld_reasons, []) == [
               :prototype_authority_refused
             ]

      codes = call(ModelResultRelease, :prototype_codes, [])
      assert length(codes) == 13
      refute :prototype_authority_refused in ModelResultRelease.withheld_reasons()

      assert_constraint!("model_result_releases_disposition", ["'released_unverified'"])

      assert_constraint!("model_result_releases_reason", [
        "'owner_prototype_unverified'",
        "'prototype_authority_refused'"
      ])

      assert_constraint!("model_result_releases_pair", [
        "'released_unverified'",
        "'owner_prototype_unverified'",
        "'prototype_authority_refused'"
      ])
    end
  end

  ## 6. sources (d237_06)

  describe "6. sources" do
    test "the source and provider value sets and d237_06 is applied" do
      for resource <- [SdrAgent.Sales.Account, SdrAgent.Sales.Lead] do
        assert :dossier in Ash.Resource.Info.attribute(resource, :source).constraints[:one_of]
      end

      provider = Ash.Resource.Info.attribute(SdrAgent.Research.ResearchArtifact, :provider)
      assert :public_dossier in provider.constraints[:one_of]
      assert Enum.any?(applied_migrations(), &match?({_, "d237_06_sources"}, &1))
    end
  end

  ## 7. dossier tables (d237_07)

  describe "7. dossier tables" do
    test "both tables exist, append-only, with their keys, CHECKs and payload foreign keys" do
      assert_table!("dossier_entries")
      assert_table!("dossier_sources")

      assert index_def("dossier_entries_unique_dossier_row_index") =~
               "(tenant_id, dossier_sha256, row_id)"

      assert index_def("dossier_sources_unique_entry_source_index") =~ "(entry_id, source_id)"

      for {name, fragments} <- [
            {"dossier_entries_email_kind", ["'personal_work'"]},
            {"dossier_entries_contact_classification", ["'unverified'"]},
            {"dossier_entries_contact_confidence", ["'high'", "'medium'", "'low'"]},
            {"dossier_entries_row_id", ["[a-z0-9]"]},
            {"dossier_sources_source_type", ["'company_site'", "'directory'"]},
            {"dossier_sources_https", ["https://"]},
            {"dossier_entries_claims_sha256_payload_fkey",
             ["(tenant_id, claims_sha256)", "payloads"]},
            {"dossier_entries_notes_sha256_payload_fkey",
             ["(tenant_id, notes_sha256)", "payloads"]},
            {"dossier_sources_content_sha256_payload_fkey",
             ["(tenant_id, content_sha256)", "payloads"]}
          ] do
        assert_constraint!(name, fragments)
      end

      assert triggers("dossier_entries") ==
               ~w(dossier_entries_guard_row dossier_entries_guard_truncate)

      assert triggers("dossier_sources") ==
               ~w(dossier_sources_guard_row dossier_sources_guard_truncate)
    end
  end

  ## 8. migration order

  test "8. the seven d237 migrations are applied last, in the IF-2 order" do
    names = applied_migrations() |> Enum.sort() |> Enum.map(&elem(&1, 1))

    assert Enum.take(names, -7) == ~w(d237_01_users d237_02_actor_types
             d237_03_prototype_database_bindings d237_04_prototype_delegations
             d237_05_release_decisions d237_06_sources d237_07_dossier)
  end
end
