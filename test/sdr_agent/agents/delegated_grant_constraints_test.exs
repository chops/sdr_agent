defmodule SdrAgent.Agents.DelegatedGrantConstraintsTest do
  @moduledoc """
  C2* S2 RED-1 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §6 and
  §7 row 2, Codex plan/entity PASS `aa42492e` with its binding OQ rulings;
  ADR-0004 agent-environment item 9; design draft r4 §7 item 2; T-S5 and
  AC7): the database itself holds every grant to exactly the two accepted
  provenance shapes, whatever the application does.

    * `owner_form`: both user ids set and both delegated fields NULL;
    * `delegated`: no creator, the authorization id and its digest set,
      and an updater only on a revoked row.

  The rule is the `model_call_grants_provenance` CHECK in its
  TRUE-or-reject form (`COALESCE(…, false)`). With it: `provisioning` is
  NOT NULL, defaults to `owner_form` and is `owner_form | delegated`
  (`model_call_grants_provisioning`); the digest is 64 lowercase hex
  characters (`model_call_grants_delegated_sha256`); and one grant exists
  per `(tenant_id, delegated_authorization_id)` whatever its status (the
  partial unique index `model_call_grants_unique_delegated_authorization_index`,
  `WHERE delegated_authorization_id IS NOT NULL`). Different authorization
  ids in one tenant are not a database conflict (OQ8: that refusal is the
  action's plain read).

  Rows are written with raw SQL, each refusal in its own savepoint
  (`raw_error/2`) and pinned to its SQLSTATE and the §6 constraint name.
  Every negative case is otherwise valid, and each rule has a positive
  control. A foreign tenant's row is written with triggers (so also the
  foreign keys) disabled by `SET LOCAL` in a savepoint, since the tenant
  table holds one tenant: an SQL-level CHECK and index fixture on the
  disposable sandbox, not an application write route. CHECKs and the unique
  index still apply to it, as a same-tenant control shows, and the role is
  shown back at `origin`, with the tenant foreign key applying again, after
  both the refused and the accepted write.

  Audit continuity (Codex F1, OQ15): grants and allocations stay outside
  the audited record-hash set, so the new columns raise no
  `record_hash_mismatch`. The controls pin that premise; they do not claim
  that grant row hashes are verified. The down migration and the
  before/after verifier comparison are proved only on the separately
  reviewed external route (OQ15, OQ16); no test here runs DDL.

  RED: the three columns do not exist and both user ids are NOT NULL.
  Each structural test fails on an explicit `c2star-s2:` column guard
  after its fixtures; the three controls pass now and after GREEN.
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Clock

  @moduletag :c2star_s2

  @table "model_call_grants"
  @new_columns ["provisioning", "delegated_authorization_id", "delegated_authorization_sha256"]
  @provenance "model_call_grants_provenance"
  @provisioning "model_call_grants_provisioning"
  @digest_check "model_call_grants_delegated_sha256"
  @index "model_call_grants_unique_delegated_authorization_index"
  @user_fks ["model_call_grants_created_by_id_fkey", "model_call_grants_updated_by_id_fkey"]

  @now ~U[2026-10-28 12:00:00.000000Z]
  @starts ~U[2026-10-27 00:00:00.000000Z]
  @expires ~U[2026-10-31 00:00:00.000000Z]

  setup do
    Clock.freeze(@now)
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## Guards and catalog reads

  defp column_exists?(column) do
    SQL.query!(
      Repo,
      "SELECT count(*) FROM information_schema.columns " <>
        "WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
      [@table, column]
    ).rows == [[1]]
  end

  defp require_columns! do
    for column <- @new_columns do
      assert column_exists?(column), "c2star-s2: column #{@table}.#{column} is missing"
    end
  end

  defp constraint_def!(name) do
    rows =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conrelid = to_regclass($1::text) AND conname::text = $2",
        [@table, name]
      ).rows

    assert match?([[_]], rows), "c2star-s2: constraint #{name} on #{@table} is missing"
    [[definition]] = rows
    definition
  end

  # The quoted values of an `IN (...)` CHECK, as Postgres renders it.
  defp check_values!(name) do
    ~r/'([^']*)'::text/
    |> Regex.scan(constraint_def!(name), capture: :all_but_first)
    |> List.flatten()
    |> Enum.sort()
  end

  defp one_of!(attribute_name) do
    attribute = Info.attribute(ModelCallGrant, attribute_name)
    assert attribute, "c2star-s2: ModelCallGrant has no #{inspect(attribute_name)} attribute"

    attribute.constraints
    |> Keyword.get(:one_of, [])
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  ## Raw rows

  defp u(id), do: Ecto.UUID.dump!(id)
  defp rand_hex(bytes), do: hex(:crypto.strong_rand_bytes(bytes))
  defp authorization_id, do: "s2-fixture-#{System.unique_integer([:positive])}"

  defp row(ctx, shape, overrides \\ []) do
    base =
      [
        id: u(Ash.UUIDv7.generate()),
        tenant_id: u(ctx.tenant.id),
        name: "c2star-s2 constraint fixture",
        purpose: "Synthetic raw row for the delegated-grant constraints",
        status: "active",
        profile_ids: ["claude_cli_opus"],
        total_attempts: 6,
        per_utc_day_attempts: 4,
        starts_at: @starts,
        expires_at: @expires,
        revision: 1,
        revoked_at: nil,
        trace_id: rand_hex(16),
        span_id: rand_hex(8),
        inserted_at: @now,
        updated_at: @now
      ] ++ provenance(ctx, shape)

    Enum.reduce(overrides, base, fn {key, value}, acc -> Keyword.replace!(acc, key, value) end)
  end

  defp provenance(ctx, :owner_form) do
    [
      provisioning: "owner_form",
      created_by_id: u(ctx.admin.id),
      updated_by_id: u(ctx.admin.id),
      delegated_authorization_id: nil,
      delegated_authorization_sha256: nil
    ]
  end

  defp provenance(_ctx, :delegated) do
    [
      provisioning: "delegated",
      created_by_id: nil,
      updated_by_id: nil,
      delegated_authorization_id: authorization_id(),
      delegated_authorization_sha256: rand_hex(32)
    ]
  end

  defp revoked(overrides \\ []),
    do: [status: "revoked", revoked_at: @now, revision: 2] ++ overrides

  defp insert_sql(columns) do
    names = Keyword.keys(columns)
    assert names == Enum.uniq(names), "fixture bug: duplicate INSERT columns #{inspect(names)}"
    placeholders = Enum.map_join(1..length(names)//1, ", ", &"$#{&1}")

    {"INSERT INTO #{@table} (#{Enum.join(names, ", ")}) VALUES (#{placeholders})",
     Keyword.values(columns)}
  end

  defp update_sql(id, sets) do
    {assignments, params} =
      sets
      |> Enum.with_index(2)
      |> Enum.map(fn {{column, value}, i} -> {"#{column} = $#{i}", value} end)
      |> Enum.unzip()

    {"UPDATE #{@table} SET #{Enum.join(assignments, ", ")} WHERE id = $1", [id | params]}
  end

  # A refused write, in its own savepoint.
  defp attempt(row) do
    {sql, params} = insert_sql(row)
    raw_error(sql, params)
  end

  defp attempt_update(id, sets) do
    {sql, params} = update_sql(id, sets)
    raw_error(sql, params)
  end

  defp assert_one_row(result, label) do
    assert match?({:ok, %{num_rows: 1}}, result),
           "c2star-s2: #{label}: positive control refused: " <>
             inspect(result, limit: 6, printable_limit: 300)
  end

  defp insert!(row, label) do
    {sql, params} = insert_sql(row)
    assert_one_row(SQL.query(Repo, sql, params), label)
  end

  defp update!(id, sets, label) do
    {sql, params} = update_sql(id, sets)
    assert_one_row(SQL.query(Repo, sql, params), label)
  end

  # An insert with triggers (and so foreign keys) disabled by SET LOCAL only
  # (never a session or global setting), in a savepoint: a refusal rolls the
  # savepoint back with the setting, a success sets origin before release.
  # CHECKs and unique indexes still apply.
  defp attempt_foreign(row) do
    {sql, params} = insert_sql(row)

    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])
      Repo |> SQL.query(sql, params) |> finish_foreign()
    end)
  end

  defp finish_foreign({:ok, result}) do
    SQL.query!(Repo, "SET LOCAL session_replication_role = origin", [])
    result
  end

  defp finish_foreign({:error, error}), do: Repo.rollback(error)

  # The replication role the next ordinary statement runs under.
  defp replication_role, do: SQL.query!(Repo, "SHOW session_replication_role", []).rows

  defp refusal({:error, %Postgrex.Error{postgres: %{code: code} = postgres}}),
    do: {code, Map.get(postgres, :constraint)}

  defp refusal(result), do: {:not_refused, result}

  defp assert_refused(result, code, constraint, label) do
    got = refusal(result)

    assert got == {code, constraint},
           "c2star-s2: #{label}: expected #{inspect(code)} #{constraint}, got " <>
             inspect(got, limit: 6, printable_limit: 300)
  end

  defp stored(id, columns) do
    SQL.query!(Repo, "SELECT #{Enum.join(columns, ", ")} FROM #{@table} WHERE id = $1", [id]).rows
  end

  ## Owner-form grants through the domain API

  defp owner_grant!(ctx) do
    attrs = %{
      name: "c2star-s2 owner-form control",
      purpose: "Synthetic owner-form grant for the continuity controls",
      profile_ids: [:claude_cli_opus],
      total_attempts: 2,
      starts_at: @starts,
      expires_at: @expires,
      allocations: [
        %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_opus, attempts: 2}
      ]
    }

    result = Agents.create_grant(attrs, actor: ctx.admin)

    assert match?({:ok, %{id: _}}, result),
           "c2star-s2: the owner-form create_grant control failed: #{inspect(result)}"

    elem(result, 1)
  end

  defp current_record_hash(ctx, grant) do
    result = Ash.get(ModelCallGrant, grant.id, AuditKernel.opts(ctx.tenant.id))
    assert match?({:ok, %{id: _}}, result), "c2star-s2: kernel read failed: #{inspect(result)}"
    result |> elem(1) |> RecordHash.hex()
  end

  ## T-S5: refused inserts

  describe "T-S5: refused inserts" do
    test "an owner_form row has both users and no delegated field", ctx do
      cases = [
        {"no created_by", row(ctx, :owner_form, created_by_id: nil)},
        {"no updated_by", row(ctx, :owner_form, updated_by_id: nil)},
        {"no users", row(ctx, :owner_form, created_by_id: nil, updated_by_id: nil)},
        {"a delegated id", row(ctx, :owner_form, delegated_authorization_id: authorization_id())},
        {"a delegated digest",
         row(ctx, :owner_form, delegated_authorization_sha256: rand_hex(32))},
        {"both delegated fields",
         row(ctx, :owner_form,
           delegated_authorization_id: authorization_id(),
           delegated_authorization_sha256: rand_hex(32)
         )},
        {"a delegated id on a revoked row",
         row(ctx, :owner_form, revoked(delegated_authorization_id: authorization_id()))}
      ]

      require_columns!()
      insert!(row(ctx, :owner_form), "an owner_form row")

      for {label, candidate} <- cases do
        assert_refused(
          attempt(candidate),
          :check_violation,
          @provenance,
          "owner_form with #{label}"
        )
      end
    end

    test "a delegated row has no creator, names its authorization and digest, no active updater",
         ctx do
      admin = u(ctx.admin.id)

      cases = [
        {"a creator", row(ctx, :delegated, created_by_id: admin)},
        {"a creator on a revoked row",
         row(ctx, :delegated, revoked(created_by_id: admin, updated_by_id: admin))},
        {"no authorization id", row(ctx, :delegated, delegated_authorization_id: nil)},
        {"no digest", row(ctx, :delegated, delegated_authorization_sha256: nil)},
        {"neither id nor digest",
         row(ctx, :delegated,
           delegated_authorization_id: nil,
           delegated_authorization_sha256: nil
         )},
        {"an updater on an active row", row(ctx, :delegated, updated_by_id: admin)}
      ]

      require_columns!()
      insert!(row(ctx, :delegated), "an active delegated row")

      for {label, candidate} <- cases do
        assert_refused(
          attempt(candidate),
          :check_violation,
          @provenance,
          "delegated with #{label}"
        )
      end
    end

    test "provisioning is NOT NULL and one of owner_form | delegated", ctx do
      bad =
        for value <- ["other", "Delegated", "OWNER_FORM", ""],
            shape <- [:owner_form, :delegated],
            do: {value, row(ctx, shape, provisioning: value)}

      null = row(ctx, :owner_form, provisioning: nil)

      require_columns!()

      for {value, candidate} <- bad do
        got = refusal(attempt(candidate))

        # Postgres applies CHECKs in name order, so the provenance CHECK
        # (which also needs a known value) may report first; the
        # provisioning CHECK's own list is pinned under "AC7: definitions".
        assert got in [{:check_violation, @provenance}, {:check_violation, @provisioning}],
               "c2star-s2: provisioning #{inspect(value)}: expected a check_violation, got " <>
                 inspect(got, limit: 6, printable_limit: 300)
      end

      result = attempt(null)

      assert match?(
               {:error,
                %Postgrex.Error{postgres: %{code: :not_null_violation, column: "provisioning"}}},
               result
             ),
             "c2star-s2: a NULL provisioning must be a not_null_violation: " <>
               inspect(result, limit: 6, printable_limit: 300)
    end

    test "the authorization digest is 64 lowercase hex characters", ctx do
      good = hex(digest("c2star-s2 fixture digest"))
      assert String.upcase(good) != good, "fixture bug: the digest needs a hex letter"

      cases = [
        {"uppercase", String.upcase(good)},
        {"63 characters", String.slice(good, 0, 63)},
        {"65 characters", good <> "0"},
        {"a non-hex character", "g" <> String.slice(good, 1, 63)},
        {"a leading space", " " <> String.slice(good, 1, 63)}
      ]

      rows =
        for {label, value} <- cases,
            do: {label, row(ctx, :delegated, delegated_authorization_sha256: value)}

      require_columns!()
      insert!(row(ctx, :delegated, delegated_authorization_sha256: good), "a hex-64 digest")

      for {label, candidate} <- rows do
        assert_refused(
          attempt(candidate),
          :check_violation,
          @digest_check,
          "a digest with #{label}"
        )
      end
    end

    test "one delegated grant per (tenant, authorization id), whatever its status", ctx do
      held = authorization_id()
      revoked_held = authorization_id()

      first = row(ctx, :delegated, delegated_authorization_id: held)
      again_active = row(ctx, :delegated, delegated_authorization_id: held)
      again_revoked = row(ctx, :delegated, revoked(delegated_authorization_id: held))
      first_revoked = row(ctx, :delegated, revoked(delegated_authorization_id: revoked_held))
      after_revoke = row(ctx, :delegated, delegated_authorization_id: revoked_held)

      require_columns!()

      insert!(first, "the first grant of an authorization")

      assert_refused(
        attempt(again_active),
        :unique_violation,
        @index,
        "a second active grant (another digest) under one authorization"
      )

      assert_refused(
        attempt(again_revoked),
        :unique_violation,
        @index,
        "a second, revoked grant under one authorization"
      )

      insert!(first_revoked, "a revoked grant of another authorization")

      assert_refused(
        attempt(after_revoke),
        :unique_violation,
        @index,
        "a new grant after the authorization's grant was revoked"
      )
    end
  end

  ## T-S5: accepted inserts

  describe "T-S5: accepted inserts" do
    test "a revoked delegated row may carry the revoking admin, or none (PRV)", ctx do
      by_admin = row(ctx, :delegated, revoked(updated_by_id: u(ctx.admin.id)))
      by_provisioner = row(ctx, :delegated, revoked())

      require_columns!()

      insert!(by_admin, "a delegated row revoked by an admin")
      insert!(by_provisioner, "a delegated row revoked by the provisioner")
    end

    test "one tenant holds two owner_form rows and delegated rows of different authorizations",
         ctx do
      rows = [
        {"an owner_form row", row(ctx, :owner_form)},
        {"a second owner_form row", row(ctx, :owner_form)},
        {"a delegated row", row(ctx, :delegated)},
        {"a delegated row of another authorization", row(ctx, :delegated)}
      ]

      require_columns!()

      for {label, candidate} <- rows, do: insert!(candidate, label)
    end

    test "the same authorization id in two tenants", ctx do
      held = authorization_id()
      own = row(ctx, :delegated, delegated_authorization_id: held)
      same_tenant = row(ctx, :delegated, delegated_authorization_id: held)

      foreign =
        row(ctx, :delegated,
          tenant_id: u(Ash.UUIDv7.generate()),
          delegated_authorization_id: held
        )

      orphan = row(ctx, :delegated, tenant_id: u(Ash.UUIDv7.generate()))

      require_columns!()
      insert!(own, "the authorization's grant in this tenant")
      assert replication_role() == [["origin"]], "precondition: the session starts at origin"

      assert_refused(
        attempt_foreign(same_tenant),
        :unique_violation,
        @index,
        "control: a same-tenant duplicate written with triggers disabled"
      )

      assert replication_role() == [["origin"]],
             "c2star-s2: the role must be origin again after the rolled-back savepoint"

      assert_one_row(attempt_foreign(foreign), "the same authorization id in another tenant")

      assert replication_role() == [["origin"]],
             "c2star-s2: the role must be origin again after the released savepoint"

      # The next ordinary write runs with triggers on: the tenant foreign key
      # refuses a row of an unknown tenant.
      assert_refused(
        attempt(orphan),
        :foreign_key_violation,
        "model_call_grants_tenant_id_fkey",
        "an ordinary write after the foreign-tenant fixture"
      )
    end
  end

  ## T-S5: updates

  describe "T-S5: updates" do
    test "an active delegated row gains no updater; revocation may record the admin, once", ctx do
      admin = u(ctx.admin.id)
      active = row(ctx, :delegated)
      id = Keyword.fetch!(active, :id)

      require_columns!()
      insert!(active, "an active delegated row")

      assert_refused(
        attempt_update(id, updated_by_id: admin),
        :check_violation,
        @provenance,
        "an updater on an active delegated row"
      )

      update!(
        id,
        [status: "revoked", revoked_at: @now, revision: 2, updated_by_id: admin],
        "an admin revocation of a delegated row"
      )

      assert_refused(
        attempt_update(id, status: "active"),
        :check_violation,
        @provenance,
        "an admin-revoked delegated row returning to active"
      )
    end

    test "provenance cannot be relabelled or emptied", ctx do
      admin = u(ctx.admin.id)
      delegated = row(ctx, :delegated)
      owner = row(ctx, :owner_form)
      delegated_id = Keyword.fetch!(delegated, :id)
      owner_id = Keyword.fetch!(owner, :id)

      cases = [
        {"delegated relabelled owner_form", delegated_id, [provisioning: "owner_form"]},
        {"delegated relabelled owner_form with users", delegated_id,
         [provisioning: "owner_form", created_by_id: admin, updated_by_id: admin]},
        {"owner_form relabelled delegated", owner_id,
         [
           provisioning: "delegated",
           delegated_authorization_id: authorization_id(),
           delegated_authorization_sha256: rand_hex(32)
         ]},
        {"owner_form losing its creator", owner_id, [created_by_id: nil]},
        {"owner_form losing its updater", owner_id, [updated_by_id: nil]},
        {"delegated losing its digest", delegated_id, [delegated_authorization_sha256: nil]}
      ]

      require_columns!()
      insert!(delegated, "a delegated row")
      insert!(owner, "an owner_form row")

      for {label, id, sets} <- cases do
        assert_refused(attempt_update(id, sets), :check_violation, @provenance, label)
      end
    end
  end

  ## AC7: definitions

  describe "AC7: definitions" do
    test "the provisioning CHECK lists exactly the Ash attribute's one_of values" do
      require_columns!()

      assert one_of!(:provisioning) == ["delegated", "owner_form"]
      assert check_values!(@provisioning) == one_of!(:provisioning)
    end

    test "control: the status CHECK lists exactly the Ash attribute's one_of values" do
      assert one_of!(:status) == ["active", "revoked"]
      assert check_values!("model_call_grants_status") == one_of!(:status)
    end

    test "the provenance CHECK is TRUE-or-reject; the unique index is partial on the id" do
      require_columns!()

      provenance = constraint_def!(@provenance)

      assert provenance =~ ~r/\ACHECK \(COALESCE\(/ and provenance =~ ~r/, false\)\)\z/,
             "c2star-s2: #{@provenance} is not COALESCE(..., false): #{provenance}"

      rows =
        SQL.query!(
          Repo,
          "SELECT pg_get_indexdef(i.indexrelid), i.indisunique FROM pg_index i " <>
            "WHERE i.indexrelid = to_regclass($1::text) AND i.indrelid = to_regclass($2::text)",
          [@index, @table]
        ).rows

      assert match?([[_, true]], rows), "c2star-s2: unique index #{@index} is missing"
      [[definition, true]] = rows

      assert definition =~ "(tenant_id, delegated_authorization_id)" and
               definition =~ "WHERE (delegated_authorization_id IS NOT NULL)",
             "c2star-s2: #{@index} is not (tenant_id, delegated_authorization_id) " <>
               "WHERE delegated_authorization_id IS NOT NULL: #{definition}"
    end

    test "created_by_id and updated_by_id are nullable; their foreign keys are unchanged" do
      require_columns!()

      nullable =
        SQL.query!(
          Repo,
          "SELECT column_name::text, is_nullable::text FROM information_schema.columns " <>
            "WHERE table_schema = 'public' AND table_name = $1 " <>
            "AND column_name::text = ANY($2::text[]) ORDER BY column_name",
          [@table, ["created_by_id", "updated_by_id"]]
        ).rows

      assert nullable == [["created_by_id", "YES"], ["updated_by_id", "YES"]],
             "c2star-s2: the user ids must be nullable: #{inspect(nullable)}"

      foreign_keys =
        SQL.query!(
          Repo,
          "SELECT conname::text, pg_get_constraintdef(oid) FROM pg_constraint " <>
            "WHERE conrelid = to_regclass($1::text) AND contype = 'f' " <>
            "AND confrelid = to_regclass('public.users') AND confdeltype = 'r' " <>
            "AND conname::text = ANY($2::text[]) ORDER BY conname",
          [@table, @user_fks]
        ).rows

      assert Enum.map(foreign_keys, &hd/1) == @user_fks,
             "c2star-s2: the user foreign keys changed: #{inspect(foreign_keys)}"

      for {[_name, definition], column} <-
            Enum.zip(foreign_keys, ["created_by_id", "updated_by_id"]) do
        assert definition =~ "FOREIGN KEY (#{column})" and definition =~ "ON DELETE RESTRICT",
               "c2star-s2: #{column}'s foreign key changed: #{definition}"
      end
    end
  end

  ## AC7: owner-form rows

  describe "AC7: owner-form rows" do
    test "a row written without the new columns, as every existing row was, is owner_form", ctx do
      legacy =
        ctx
        |> row(:owner_form)
        |> Keyword.drop([
          :provisioning,
          :delegated_authorization_id,
          :delegated_authorization_sha256
        ])

      id = Keyword.fetch!(legacy, :id)

      require_columns!()
      insert!(legacy, "a row without the new columns")

      assert stored(id, @new_columns) == [["owner_form", nil, nil]]
    end

    test "an owner-form grant from the domain API is stored owner_form, both users, no delegation",
         ctx do
      grant = owner_grant!(ctx)

      require_columns!()

      assert stored(u(grant.id), @new_columns ++ ["created_by_id", "updated_by_id"]) == [
               ["owner_form", nil, nil, u(ctx.admin.id), u(ctx.admin.id)]
             ]
    end
  end

  ## AC7: audit continuity (Codex F1)

  describe "AC7: audit continuity (Codex F1, OQ15)" do
    test "control: grants and allocations are not in the audited record-hash set" do
      for module <- [ModelCallGrant, ModelCallAllocation] do
        assert Code.ensure_loaded?(module)

        refute function_exported?(module, :__sdr_audited__, 0),
               "c2star-s2: #{inspect(module)} joined the audited set; revisit F1 (OQ15)"
      end
    end

    test "control: a grant row changed after its event raises no record issue; the chain verifies",
         ctx do
      grant = owner_grant!(ctx)
      assert [event] = events_of_type(ctx.tenant, "model.grant.created")
      recorded = event.payload["record_sha256"]
      assert is_binary(recorded), "c2star-s2: the grant event carries no record_sha256"

      # Every column added to an existing row changes its canonical map in
      # the same way: the stored row no longer hashes to its event.
      SQL.query!(Repo, "UPDATE #{@table} SET name = $2 WHERE id = $1", [
        u(grant.id),
        "c2star-s2 changed after its event"
      ])

      assert current_record_hash(ctx, grant) != recorded

      result = Audit.verify_chain(actor: system_actor(:auditor_cli, ctx.tenant))

      assert match?({:ok, %{valid?: true, issues: []}}, result),
             "c2star-s2: the chain must verify with no grant record issue: " <>
               inspect(result, limit: 8, printable_limit: 300)
    end
  end
end
