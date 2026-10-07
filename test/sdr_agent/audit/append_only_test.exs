defmodule SdrAgent.Audit.AppendOnlyTest do
  @moduledoc false
  use SdrAgent.AuditCase, async: false

  alias Ecto.Adapters.SQL

  # S2 "Append-only / immutable resources" created through S11.
  @append_only ~w(tenants payloads audit_events provenance_snapshots audit_accesses
                  retention_markers decisions audit_anchors anchor_sink_receipts)
  @terminal_immutable ~w(model_invocations tool_invocations)
  @s11_terminal_immutable ~w(audit_exports)
  @lifecycle_immutable ~w(audit_signing_keys)

  test "every append-only table carries its UPDATE/DELETE and TRUNCATE triggers" do
    for table <-
          @append_only ++ @terminal_immutable ++ @s11_terminal_immutable ++ @lifecycle_immutable do
      %{rows: rows} =
        SQL.query!(
          SdrAgent.Repo,
          """
          SELECT tgname FROM pg_trigger
           WHERE tgrelid = $1::text::regclass AND NOT tgisinternal AND tgenabled = 'O'
          """,
          [table]
        )

      names = List.flatten(rows)
      assert "#{table}_guard_row" in names, "#{table} lacks its row trigger: #{inspect(names)}"
      assert "#{table}_guard_truncate" in names, "#{table} lacks its truncate trigger"
    end
  end

  test "signing key identity and public material are database-immutable" do
    tenant = bootstrap!()
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      SdrAgent.Audit.register_signing_key(%{key_id: "immutable-key", public_key: public_key},
        actor: system_actor(:kernel, tenant)
      )

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             raw_error("UPDATE audit_signing_keys SET key_id = 'changed' WHERE id = $1", [
               Ecto.UUID.dump!(key.id)
             ])

    assert message =~ "immutable key material"
  end

  test "revoking a rotated key cannot rewrite its retirement instant" do
    tenant = bootstrap!()
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      SdrAgent.Audit.register_signing_key(%{key_id: "retirement-key", public_key: public},
        actor: system_actor(:kernel, tenant)
      )

    admin = human(:admin, tenant)
    {:ok, rotated} = SdrAgent.Audit.rotate_signing_key(key.id, actor: admin)

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             raw_error(
               "UPDATE audit_signing_keys SET status = 'revoked', revoked_at = now(), revocation_reason = 'test', retired_at = retired_at + interval '1 second' WHERE id = $1",
               [Ecto.UUID.dump!(key.id)]
             )

    assert message =~ "retirement instant is immutable"
    {:ok, revoked} = SdrAgent.Audit.revoke_signing_key(key.id, "test revocation", actor: admin)
    assert revoked.retired_at == rotated.retired_at
  end

  describe "raw SQL against append-only tables" do
    setup do
      tenant = bootstrap!()
      kernel = system_actor(:kernel, tenant)
      {:ok, _payload} = SdrAgent.Audit.put_payload("body", "text/plain", actor: kernel)
      {:ok, _} = SdrAgent.Audit.verify_chain(actor: human(:admin, tenant))

      {:ok, _} =
        SdrAgent.Audit.set_retention_marker(retention_attrs(), actor: human(:admin, tenant))

      %{tenant: tenant}
    end

    test "UPDATE is rejected" do
      for {table, column} <- [
            {"tenants", "name"},
            {"payloads", "content_type"},
            {"audit_events", "event_type"},
            {"provenance_snapshots", "git_sha"},
            {"audit_accesses", "purpose"},
            {"retention_markers", "reason"}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
                 raw_error("UPDATE #{table} SET #{column} = 'x'")

        assert message =~ "append-only", "#{table}: #{message}"
      end
    end

    test "DELETE is rejected" do
      for table <-
            ~w(tenants payloads audit_events provenance_snapshots audit_accesses retention_markers) do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
                 raw_error("DELETE FROM #{table}")

        assert message =~ "append-only", "#{table}: #{message}"
      end
    end

    test "TRUNCATE is rejected" do
      for table <- @append_only do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
                 raw_error("TRUNCATE #{table} CASCADE")

        assert message =~ "append-only", "#{table}: #{message}"
      end
    end
  end

  describe "terminal-immutable invocations" do
    setup do
      tenant = bootstrap!()
      %{run: run, agent: agent} = SdrAgent.AgentsFixtures.running_run(tenant)

      {:ok, invocation} =
        SdrAgent.Agents.reserve_model_invocation(
          run,
          SdrAgent.AgentsFixtures.model_attrs("mi-ao"),
          actor: agent
        )

      {:ok, _tool} =
        SdrAgent.Agents.start_tool_invocation(
          run,
          %{action_module: "A", action_version: "1", input: "{}", idempotency_key: "t-ao"},
          actor: agent
        )

      %{tenant: tenant, invocation: invocation, agent: agent, run: run}
    end

    test "immutable columns cannot change even while the invocation is open", ctx do
      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw_error("UPDATE model_invocations SET model_id = 'other' WHERE id = $1", [
                 Ecto.UUID.dump!(ctx.invocation.id)
               ])

      assert message =~ "immutable"
    end

    test "a terminal invocation cannot be updated at all", ctx do
      {:ok, sent} = SdrAgent.Agents.mark_model_invocation_sent(ctx.invocation, actor: ctx.agent)

      {:ok, _done} =
        SdrAgent.Agents.complete_model_invocation(sent, SdrAgent.AgentsFixtures.completion(),
          actor: ctx.agent
        )

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw_error("UPDATE model_invocations SET latency_ms = 1 WHERE id = $1", [
                 Ecto.UUID.dump!(ctx.invocation.id)
               ])

      assert message =~ "terminal"
    end

    test "invocations cannot be deleted", ctx do
      for table <- @terminal_immutable do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
                 raw_error("DELETE FROM #{table}")

        assert message =~ "append-only" or message =~ "cannot be deleted"
      end

      _ = ctx
    end
  end

  defp retention_attrs do
    %{
      target_resource: "SdrAgent.Audit.Payload",
      target_ref: "abc",
      retention_class: :synthetic_demo,
      legal_hold: false,
      reason: "demo"
    }
  end
end
