defmodule SdrAgent.Audit.PayloadTest do
  @moduledoc false
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      kernel: system_actor(:kernel, tenant),
      agent: system_actor(:agent_runtime, tenant)
    }
  end

  test "stores content addressed by sha256 and deduplicates", ctx do
    {:ok, first} = Audit.put_payload("full model response", "application/json", actor: ctx.agent)

    {:ok, second} =
      Audit.put_payload("full model response", "application/json", actor: ctx.kernel)

    assert first.sha256 == :crypto.hash(:sha256, "full model response")
    assert first.byte_size == byte_size("full model response")
    assert first.tenant_id == ctx.tenant.id
    assert second.sha256 == first.sha256
    assert second.inserted_at == first.inserted_at
    assert first.trace_id =~ ~r/^[0-9a-f]{32}$/

    {:ok, payloads} = Audit.list_payloads(actor: human(:admin, ctx.tenant))
    assert Enum.count(payloads, &(&1.sha256 == first.sha256)) == 1
  end

  test "payload creation appends no event (referencing events carry the hash)", ctx do
    before = length(events(ctx.tenant))
    {:ok, _} = Audit.put_payload("x", "text/plain", actor: ctx.agent)
    assert length(events(ctx.tenant)) == before
  end

  test "content is never truncated", ctx do
    big = String.duplicate("synthetic ", 50_000)
    {:ok, payload} = Audit.put_payload(big, "text/plain", actor: ctx.agent)

    {:ok, content} =
      Audit.read_content(payload.sha256, actor: human(:admin, ctx.tenant), purpose: "check")

    assert content == big
  end

  test "human operators and AUD cannot store payloads", ctx do
    for actor <- [
          human(:admin, ctx.tenant),
          human(:reviewer, ctx.tenant),
          system_actor(:auditor_cli, ctx.tenant)
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = Audit.put_payload("x", "text/plain", actor: actor)
    end
  end

  test "metadata reads hide the content field", ctx do
    {:ok, payload} =
      Audit.put_payload("secret-ish synthetic body", "text/plain", actor: ctx.agent)

    {:ok, [read]} = Audit.list_payloads(actor: human(:auditor, ctx.tenant))
    assert read.sha256 == payload.sha256
    assert %Ash.ForbiddenField{} = read.content
  end

  describe "read_content" do
    setup ctx do
      {:ok, payload} =
        Audit.put_payload("model request body", "application/json", actor: ctx.agent)

      %{payload: payload}
    end

    test "returns content and appends one AuditAccess with its event", ctx do
      for role <- [:admin, :reviewer, :auditor] do
        actor = human(role, ctx.tenant)

        assert {:ok, "model request body"} =
                 Audit.read_content(ctx.payload.sha256, actor: actor, purpose: "review")
      end

      assert {:ok, "model request body"} =
               Audit.read_content(ctx.payload.sha256,
                 actor: system_actor(:auditor_cli, ctx.tenant),
                 purpose: "export"
               )

      {:ok, accesses} = Audit.list_accesses(actor: human(:auditor, ctx.tenant))
      views = Enum.filter(accesses, &(&1.access_kind == :payload_view))
      assert length(views) == 4
      assert Enum.all?(views, &(&1.target_ref == hex(ctx.payload.sha256)))

      access_events = events_of_type(ctx.tenant, "audit.access.payload_view")
      assert length(access_events) == 4

      assert Enum.sort(Enum.map(views, & &1.audit_event_id)) ==
               Enum.sort(Enum.map(access_events, & &1.id))

      assert Enum.all?(access_events, &(&1.category == :access))
    end

    test "a system actor without read rights is denied and the denial is audited", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Audit.read_content(ctx.payload.sha256, actor: ctx.agent, purpose: "x")

      assert [denied] = events_of_type(ctx.tenant, "authz.denied")
      assert denied.actor_type == :agent_runtime
      assert denied.authorization.decision == :denied
      assert denied.payload["action"] == "read_content"
      assert events_of_type(ctx.tenant, "audit.access.payload_view") == []
    end

    test "an unknown payload returns an error and records no access", ctx do
      assert {:error, _} =
               Audit.read_content(digest("missing"),
                 actor: human(:admin, ctx.tenant),
                 purpose: "x"
               )

      assert events_of_type(ctx.tenant, "audit.access.payload_view") == []
    end
  end
end
