defmodule SdrAgent.Audit.KernelTest do
  use SdrAgent.AuditCase, async: false

  require OpenTelemetry.Tracer

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical

  @zero_hash <<0::256>>

  describe "bootstrap" do
    test "creates the singleton tenant with a genesis event and provenance" do
      tenant = bootstrap!()

      assert tenant.slug == "demo"
      assert tenant.singleton == true

      [genesis, provenance] = events(tenant)
      assert genesis.sequence == 1
      assert genesis.event_type == "tenant.created"
      assert genesis.prev_hash == @zero_hash
      assert genesis.subject_id == tenant.id
      assert genesis.actor_type == :kernel

      assert provenance.sequence == 2
      assert provenance.event_type == "system.provenance.recorded"
      assert provenance.prev_hash == genesis.event_hash
      assert provenance.provenance_snapshot_id == genesis.provenance_snapshot_id
      assert provenance.subject_id == genesis.provenance_snapshot_id

      # Read by the auditor CLI: creating a real operator would append an event.
      {:ok, head} = Audit.get_chain_head(actor: system_actor(:auditor_cli, tenant))
      assert head.last_sequence == 2
      assert head.last_event_hash == provenance.event_hash
    end

    test "is idempotent" do
      tenant = bootstrap!()
      assert {:ok, again} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
      assert again.id == tenant.id
      assert length(events(tenant)) == 2
    end

    test "records a provenance snapshot of the build and runtime" do
      tenant = bootstrap!()
      [genesis | _] = events(tenant)

      {:ok, snapshot} =
        Audit.get_provenance_snapshot(genesis.provenance_snapshot_id,
          actor: human(:auditor, tenant)
        )

      assert snapshot.git_sha =~ ~r/^([0-9a-f]{40}|unknown)$/
      assert is_boolean(snapshot.git_dirty)
      assert byte_size(snapshot.mix_lock_sha256) == 32
      assert byte_size(snapshot.config_sha256) == 32
      assert snapshot.otp_release == to_string(:erlang.system_info(:otp_release))
      assert snapshot.elixir_version == System.version()
      assert snapshot.canonicalization_version == Canonical.version()
      assert snapshot.schema_version =~ ~r/^\d{14}$/
      assert byte_size(snapshot.snapshot_sha256) == 32
    end
  end

  describe "append" do
    setup do
      tenant = bootstrap!()
      %{tenant: tenant, kernel: system_actor(:kernel, tenant)}
    end

    test "chains events with gap-free sequence and sha256 over canonical bytes", ctx do
      {:ok, first} = Audit.append(event("test.first"), actor: ctx.kernel)
      {:ok, second} = Audit.append(event("test.second"), actor: ctx.kernel)

      assert first.sequence == 3
      assert second.sequence == 4
      assert second.prev_hash == first.event_hash
      assert first.event_hash == :crypto.hash(:sha256, first.canonical_bytes)
      assert first.hash_algorithm == "sha256"
      assert first.canonicalization_version == Canonical.version()

      decoded = Jason.decode!(first.canonical_bytes)
      assert decoded["sequence"] == 3
      assert decoded["prev_hash"] == hex(first.prev_hash)
      assert decoded["event_type"] == "test.first"
      assert decoded["payload"] == %{"n" => 1}
    end

    test "records actor, authorization, clock source, versions and causation", ctx do
      admin = human(:admin, ctx.tenant)
      correlation = Ecto.UUID.generate()

      {:ok, ev} =
        Audit.append(
          Map.merge(event("test.actor"), %{
            correlation_id: correlation,
            idempotency_key: "k-1",
            attempt: 2,
            version_refs: %{policy_rules: %{"suppression" => "1"}}
          }),
          actor: admin
        )

      assert ev.actor_type == :user
      assert ev.actor_id == admin.id
      assert ev.actor_role == :admin
      assert ev.authorization.decision == :authorized
      assert ev.authorization.policy_version == Audit.policy_version()
      assert ev.clock_source == :system_utc
      assert ev.correlation_id == correlation
      assert ev.idempotency_key == "k-1"
      assert ev.attempt == 2
      assert ev.version_refs["policy_rules"] == %{"suppression" => "1"}
      assert is_binary(ev.version_refs["config_sha256"])
      assert ev.version_refs["schema_version"] =~ ~r/^\d{14}$/
      assert ev.tenant_id == ctx.tenant.id
    end

    test "uses the injectable clock", ctx do
      fixed = ~U[2026-10-06 09:30:00.123456Z]
      SdrAgent.Clock.freeze(fixed)
      on_exit(&SdrAgent.Clock.unfreeze/0)

      {:ok, ev} = Audit.append(event("test.clock"), actor: ctx.kernel)
      assert ev.occurred_at == fixed
      assert ev.clock_source == :test_fixed
    end

    test "records the trace and span ids of the current span", ctx do
      OpenTelemetry.Tracer.with_span "test.parent" do
        span_ctx = OpenTelemetry.Tracer.current_span_ctx()
        {:ok, ev} = Audit.append(event("test.traced"), actor: ctx.kernel)

        assert ev.trace_id == :otel_span.hex_trace_id(span_ctx)
        assert ev.span_id == :otel_span.hex_span_id(span_ctx)
      end
    end

    test "opens a span when none is active", ctx do
      refute :otel_span.is_valid(OpenTelemetry.Tracer.current_span_ctx())

      {:ok, ev} = Audit.append(event("test.untraced"), actor: ctx.kernel)

      assert ev.trace_id =~ ~r/^[0-9a-f]{32}$/
      assert ev.span_id =~ ~r/^[0-9a-f]{16}$/
      refute ev.trace_id == String.duplicate("0", 32)
      refute ev.span_id == String.duplicate("0", 16)
    end

    test "records an anonymous actor when none is given", ctx do
      {:ok, ev} = Audit.append(event("test.anonymous"), actor: nil)
      assert ev.actor_type == :anonymous
      assert ev.actor_id == nil
      assert ev.tenant_id == ctx.tenant.id
    end

    test "joins the caller's transaction: rollback removes the event and keeps the head", ctx do
      {:ok, before} = Audit.get_chain_head(actor: human(:admin, ctx.tenant))

      assert {:error, :boom} =
               Audit.transaction(fn ->
                 {:ok, _} = Audit.append(event("test.rolled_back"), actor: ctx.kernel)
                 SdrAgent.Repo.rollback(:boom)
               end)

      {:ok, head} = Audit.get_chain_head(actor: human(:admin, ctx.tenant))
      assert head.last_sequence == before.last_sequence
      assert head.last_event_hash == before.last_event_hash
      assert events_of_type(ctx.tenant, "test.rolled_back") == []

      {:ok, next} = Audit.append(event("test.after_rollback"), actor: ctx.kernel)
      assert next.sequence == before.last_sequence + 1
    end

    test "verifies a clean chain", ctx do
      admin = human(:admin, ctx.tenant)
      for n <- 1..5, do: {:ok, _} = Audit.append(event("test.n#{n}"), actor: ctx.kernel)

      assert {:ok, report} = Audit.verify_chain(actor: admin)
      assert report.valid?
      assert report.issues == []
      # genesis, provenance, the admin's user.created, five appends
      assert report.last_sequence == 8
    end
  end

  defp event(type) do
    %{
      event_type: type,
      category: :system,
      subject_resource: "Test",
      subject_id: "subject-1",
      action: "test",
      payload: %{n: 1}
    }
  end
end
