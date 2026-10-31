defmodule SdrAgent.Prototype.HostedOwnerAtomicTest do
  @moduledoc "S-B5a RED: rollback coupling and cross-binding activation constraints, synthetic only."
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.HostedOwnerFixtures, as: H

  @owner SdrAgent.Operations.HostedOwner

  setup do
    H.activated!()
  end

  test "owner audit failure rolls back user, owner, token and chain head", ctx do
    loaded!(@owner)
    before = state(ctx)
    inject!("audit_events", "NEW.event_type = 'operations.hosted_owner.enrolled'")

    result =
      safely(fn ->
        call(SdrAgent.Operations, :enrol_hosted_owner, [
          %{email: "rollback@example.test", display_name: "Rollback"},
          H.console(ctx)
        ])
      end)

    refute match?({:ok, _}, result)
    assert state(ctx) == before
  end

  test "failed user-disable audit preserves active owner and valid session", ctx do
    %{owner: owner, enrollment_token: link} = H.enrol!(ctx)
    signed = H.consume!(link)
    before = state(ctx)
    inject!("audit_events", "NEW.event_type = 'user.status_changed'")
    result = safely(fn -> H.disable(ctx, owner.id) end)
    refute match?({:ok, _}, result)
    assert state(ctx) == before
    assert {:ok, %{status: :active}} = Ash.get(@owner, owner.id, H.kernel(ctx))
    assert {:ok, _} = Accounts.current_operator(signed.__metadata__.token)
  end

  test "failed normal-session insert rolls back single-use link consumption", ctx do
    %{enrollment_token: link} = H.enrol!(ctx)
    inject!("tokens", "NEW.purpose = 'user'")
    result = safely(fn -> H.consume(link) end)
    refute match?({:ok, _}, result)
    Repo.query!("DROP TRIGGER sdr_test_hosted_owner_fault ON tokens", [])
    assert {:ok, _} = H.consume(link)
    assert {:error, _} = H.consume(link)
  end

  test "the database refuses another binding's relocation even with valid owner tenant and user",
       ctx do
    %{owner: owner} = H.enrol!(ctx)
    table = AshPostgres.DataLayer.Info.table(@owner)
    foreign_relocation = Ecto.UUID.generate()
    foreign_binding = Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        # Isolated fault fixture: plant an orphan relocation with FK triggers
        # suspended ONLY for that insert. Then restore triggers before testing
        # the HostedOwner FK itself. The entire transaction is rolled back.
        Repo.query!("SET LOCAL session_replication_role = replica", [])

        Repo.query!(
          """
          INSERT INTO prototype_relocations
          SELECT (jsonb_populate_record(NULL::prototype_relocations,
            to_jsonb(r) || jsonb_build_object('id', $1::text, 'binding_id', $2::text))).*
          FROM prototype_relocations r WHERE r.id = $3
          """,
          [foreign_relocation, foreign_binding, Ecto.UUID.dump!(ctx.relocation.id)]
        )

        Repo.query!("SET LOCAL session_replication_role = origin", [])

        outcome =
          Repo.query(
            """
            INSERT INTO "#{table}"
            SELECT (jsonb_populate_record(NULL::"#{table}", to_jsonb(o) ||
              jsonb_build_object('id', gen_random_uuid(), 'user_id', $2::text,
                'relocation_id', $3::text, 'status', 'disabled', 'disabled_at', now()))).*
            FROM "#{table}" o WHERE o.id = $1
            """,
            [Ecto.UUID.dump!(owner.id), ctx.fx.auditor.id, foreign_relocation]
          )

        case outcome do
          {:error, error} -> Repo.rollback(error)
          {:ok, inserted} -> Repo.rollback({:unexpected_success, inserted})
        end
      end)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: name}}} =
             result

    assert name == "hosted_owners_relocation_id_fkey"
    assert scalar("SELECT count(*) FROM prototype_relocations", []) == 1
  end

  defp inject!(table, condition) do
    Repo.query!(
      """
      CREATE FUNCTION pg_temp.sdr_test_hosted_owner_fault() RETURNS trigger AS $$
      BEGIN
        IF #{condition} THEN RAISE EXCEPTION 'synthetic hosted owner fault'; END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """,
      []
    )

    Repo.query!(
      "CREATE TRIGGER sdr_test_hosted_owner_fault BEFORE INSERT ON \"#{table}\" " <>
        "FOR EACH ROW EXECUTE FUNCTION pg_temp.sdr_test_hosted_owner_fault()",
      []
    )
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  end

  defp state(ctx) do
    table = AshPostgres.DataLayer.Info.table(@owner)

    %{rows: [head]} =
      Repo.query!(
        "SELECT last_sequence, last_event_hash FROM audit_chain_heads WHERE tenant_id = $1",
        [Ecto.UUID.dump!(ctx.fx.tenant.id)]
      )

    {scalar("SELECT count(*) FROM users", []), scalar("SELECT count(*) FROM \"#{table}\"", []),
     scalar("SELECT count(*) FROM tokens", []), head}
  end

  defp scalar(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end
end
