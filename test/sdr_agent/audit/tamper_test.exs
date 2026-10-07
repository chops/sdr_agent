defmodule SdrAgent.Audit.TamperTest do
  @moduledoc false
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical

  setup do
    tenant = bootstrap!()
    kernel = system_actor(:kernel, tenant)

    for n <- 1..4 do
      {:ok, _} =
        Audit.append(
          %{
            event_type: "test.event",
            category: :system,
            subject_resource: "Test",
            subject_id: "s-#{n}",
            action: "test",
            payload: %{n: n}
          },
          actor: kernel
        )
    end

    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  defp verify(ctx) do
    {:ok, report} = Audit.verify_chain(actor: ctx.admin)
    report
  end

  defp issue_types(report), do: report.issues |> Enum.map(& &1.type) |> Enum.uniq()

  test "an edited column no longer matches the hashed canonical bytes", ctx do
    tamper!(
      "UPDATE audit_events SET payload = '{\"n\": 99}' WHERE tenant_id = $1 AND sequence = 4",
      [Ecto.UUID.dump!(ctx.tenant.id)]
    )

    report = verify(ctx)
    refute report.valid?
    assert %{type: :row_mismatch, sequence: 4} = Enum.find(report.issues, &(&1.sequence == 4))
  end

  test "an edited actor column is detected", ctx do
    tamper!(
      "UPDATE audit_events SET actor_id = 'someone-else' WHERE tenant_id = $1 AND sequence = 3",
      [Ecto.UUID.dump!(ctx.tenant.id)]
    )

    assert :row_mismatch in issue_types(verify(ctx))
  end

  test "edited canonical bytes break the event hash", ctx do
    tamper!(
      "UPDATE audit_events SET canonical_bytes = canonical_bytes || ' '::bytea WHERE tenant_id = $1 AND sequence = 5",
      [Ecto.UUID.dump!(ctx.tenant.id)]
    )

    report = verify(ctx)

    assert %{type: :event_hash_mismatch, sequence: 5} =
             Enum.find(report.issues, &(&1.sequence == 5))
  end

  test "a deleted event leaves a sequence gap", ctx do
    tamper!("DELETE FROM audit_events WHERE tenant_id = $1 AND sequence = 4", [
      Ecto.UUID.dump!(ctx.tenant.id)
    ])

    report = verify(ctx)
    refute report.valid?
    assert :sequence_gap in issue_types(report)
  end

  test "a consistently re-hashed event breaks the next event's prev_hash", ctx do
    [row] =
      tamper!(
        "SELECT canonical_bytes FROM audit_events WHERE tenant_id = $1 AND sequence = 4",
        [Ecto.UUID.dump!(ctx.tenant.id)]
      ).rows

    [bytes] = row
    forged = bytes |> Jason.decode!() |> put_in(["payload", "n"], 1000)
    forged_bytes = Canonical.encode!(forged)

    tamper!(
      """
      UPDATE audit_events
         SET canonical_bytes = $2, event_hash = $3, payload = $4
       WHERE tenant_id = $1 AND sequence = 4
      """,
      [
        Ecto.UUID.dump!(ctx.tenant.id),
        forged_bytes,
        :crypto.hash(:sha256, forged_bytes),
        forged["payload"]
      ]
    )

    report = verify(ctx)
    refute report.valid?

    assert %{type: :prev_hash_mismatch, sequence: 5} =
             Enum.find(report.issues, &(&1.sequence == 5))
  end

  test "a chain head that diverges from the newest event is detected", ctx do
    tamper!("UPDATE audit_chain_heads SET last_event_hash = $2 WHERE tenant_id = $1", [
      Ecto.UUID.dump!(ctx.tenant.id),
      digest("forged head")
    ])

    assert :head_mismatch in issue_types(verify(ctx))
  end

  test "edited payload content no longer matches its sha256", ctx do
    {:ok, payload} =
      Audit.put_payload("original body", "text/plain", actor: system_actor(:kernel, ctx.tenant))

    tamper!("UPDATE payloads SET content = 'forged body' WHERE sha256 = $1", [payload.sha256])

    report = verify(ctx)

    assert %{type: :payload_hash_mismatch} =
             Enum.find(report.issues, &(&1.type == :payload_hash_mismatch))
  end

  test "an audited domain row edited outside the application is detected", ctx do
    {:ok, definition} =
      SdrAgent.Agents.register_definition(
        %{name: "SDRAgent", version: 1, module: "SdrAgent.SDRAgent", definition: %{"a" => 1}},
        actor: system_actor(:kernel, ctx.tenant)
      )

    tamper!("UPDATE agent_definitions SET module = 'Evil' WHERE id = $1", [
      Ecto.UUID.dump!(definition.id)
    ])

    report = verify(ctx)

    assert %{type: :record_hash_mismatch, subject_id: subject_id} =
             Enum.find(report.issues, &(&1.type == :record_hash_mismatch))

    assert subject_id == definition.id
  end

  test "an untampered chain stays valid after verification is itself audited", ctx do
    assert verify(ctx).valid?
    assert verify(ctx).valid?
  end
end
