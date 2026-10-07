defmodule SdrAgent.Audit.PolicyTest do
  @moduledoc """
  Auditor contract and denial-audit contract for the S3 resources: every
  guarded action and every mutation attempted by an auditor (AUR) is denied
  with exactly one committed `authz.denied` event.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Audit

  setup do
    tenant = bootstrap!()
    %{run: run} = AgentsFixtures.running_run(tenant)
    {:ok, payload} = Audit.put_payload("body", "text/plain", actor: system_actor(:kernel, tenant))
    %{tenant: tenant, run: run, payload: payload, auditor: human(:auditor, tenant)}
  end

  defp marker_attrs(ref) do
    %{
      target_resource: "SdrAgent.Audit.Payload",
      target_ref: ref,
      retention_class: :synthetic_demo,
      legal_hold: true,
      reason: "litigation hold drill"
    }
  end

  defp denials(tenant), do: events_of_type(tenant, "authz.denied")

  describe "auditor (AUR) is denied every mutation, each audited once" do
    test "for every S3 mutation path", ctx do
      definition = AgentsFixtures.definition!(ctx.tenant)
      aur = ctx.auditor

      attempts = [
        {"set_retention_marker",
         fn -> Audit.set_retention_marker(marker_attrs("r1"), actor: aur) end},
        {"put_payload", fn -> Audit.put_payload("x", "text/plain", actor: aur) end},
        {"register_definition",
         fn ->
           Agents.register_definition(%{name: "X", version: 1, module: "X", definition: %{}},
             actor: aur
           )
         end},
        {"retire_definition", fn -> Agents.retire_definition(definition, actor: aur) end},
        {"create_run",
         fn -> Agents.create_run(AgentsFixtures.run_attrs(definition), actor: aur) end},
        {"cancel_run", fn -> Agents.cancel_run(ctx.run, actor: aur) end},
        {"retry_run", fn -> Agents.retry_run(ctx.run, actor: aur) end},
        {"set_run_phase", fn -> Agents.set_run_phase(ctx.run, :qualify, actor: aur) end},
        {"record_decision",
         fn ->
           Agents.record_decision(
             %{
               agent_run_id: ctx.run.id,
               kind: :phase_transition,
               mode: :deterministic,
               rule_id: "phase",
               rule_version: "1",
               subject_resource: "SdrAgent.Agents.AgentRun",
               subject_id: ctx.run.id,
               inputs: %{},
               outcome: "qualify"
             },
             actor: aur
           )
         end},
        {"reserve_model_invocation",
         fn ->
           Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("aur"), actor: aur)
         end},
        {"start_tool_invocation",
         fn ->
           Agents.start_tool_invocation(
             ctx.run,
             %{action_module: "A", action_version: "1", input: "{}", idempotency_key: "aur-t"},
             actor: aur
           )
         end}
      ]

      for {{label, attempt}, index} <- Enum.with_index(attempts, 1) do
        assert {:error, %Ash.Error.Forbidden{}} = attempt.(), label

        assert length(denials(ctx.tenant)) == index,
               "#{label} must append exactly one authz.denied"
      end

      for denied <- denials(ctx.tenant) do
        assert denied.actor_type == :user
        assert denied.actor_role == :auditor
        assert denied.actor_id == aur.id
        assert denied.category == :auth
        assert denied.authorization.decision == :denied
        assert byte_size(denied.subject_id || "") <= 64
      end
    end

    test "but may read the ledger, payload metadata and accesses", ctx do
      assert {:ok, [_ | _]} = Audit.list_events(actor: ctx.auditor)
      assert {:ok, [_]} = Audit.list_payloads(actor: ctx.auditor)
      assert {:ok, _} = Audit.list_accesses(actor: ctx.auditor)
      assert {:ok, _} = Audit.get_chain_head(actor: ctx.auditor)
      assert denials(ctx.tenant) == []
    end
  end

  describe "verify_chain" do
    test "ADM, AUR and AUD verify; each verification appends one AuditAccess", ctx do
      for actor <- [
            human(:admin, ctx.tenant),
            ctx.auditor,
            system_actor(:auditor_cli, ctx.tenant)
          ] do
        assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: actor)
      end

      {:ok, accesses} = Audit.list_accesses(actor: ctx.auditor)
      assert Enum.count(accesses, &(&1.access_kind == :chain_verify)) == 3
      assert length(events_of_type(ctx.tenant, "audit.access.chain_verify")) == 3
    end

    test "REV and system actors are denied, each with one authz.denied", ctx do
      for {actor, n} <-
            Enum.with_index(
              [human(:reviewer, ctx.tenant), system_actor(:agent_runtime, ctx.tenant)],
              1
            ) do
        assert {:error, %Ash.Error.Forbidden{}} = Audit.verify_chain(actor: actor)
        assert length(denials(ctx.tenant)) == n
      end

      assert events_of_type(ctx.tenant, "audit.access.chain_verify") == []
    end

    test "an anonymous caller is denied and recorded as anonymous", ctx do
      assert {:error, %Ash.Error.Forbidden{}} = Audit.verify_chain(actor: nil)
      assert [denied] = denials(ctx.tenant)
      assert denied.actor_type == :anonymous
      assert denied.actor_id == nil
    end
  end

  describe "ledger access" do
    test "nobody reads the ledger anonymously; REV may read the timeline", ctx do
      assert {:error, %Ash.Error.Forbidden{}} = Audit.list_events(actor: nil)
      assert {:ok, [_ | _]} = Audit.list_events(actor: human(:reviewer, ctx.tenant))

      assert {:error, %Ash.Error.Forbidden{}} =
               Audit.list_accesses(actor: human(:reviewer, ctx.tenant))
    end

    test "the ledger exposes no public create, update or destroy", _ctx do
      actions = Ash.Resource.Info.actions(SdrAgent.Audit.AuditEvent)
      refute Enum.any?(actions, &(&1.type in [:update, :destroy]))
      assert Enum.map(Enum.filter(actions, &(&1.type == :create)), & &1.name) == [:append]
    end

    test "appending directly through Ash without kernel context is forbidden", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               SdrAgent.Audit.AuditEvent
               |> Ash.Changeset.for_create(:append, %{event_type: "forged"},
                 actor: human(:admin, ctx.tenant)
               )
               |> Ash.create()
    end
  end

  describe "retention markers" do
    test "ADM sets a marker; corrections must supersede the current marker", ctx do
      admin = human(:admin, ctx.tenant)
      {:ok, first} = Audit.set_retention_marker(marker_attrs("ref-1"), actor: admin)
      assert first.supersedes_id == nil
      assert [_] = events_of_type(ctx.tenant, "retention.marker.set")

      assert {:error, %Ash.Error.Invalid{}} =
               Audit.set_retention_marker(marker_attrs("ref-1"), actor: admin)

      {:ok, second} =
        Audit.set_retention_marker(
          Map.merge(marker_attrs("ref-1"), %{legal_hold: false, supersedes_id: first.id}),
          actor: admin
        )

      assert second.supersedes_id == first.id

      assert {:error, %Ash.Error.Invalid{}} =
               Audit.set_retention_marker(
                 Map.merge(marker_attrs("ref-1"), %{supersedes_id: first.id}),
                 actor: admin
               )

      {:ok, current} =
        Audit.current_retention_marker("SdrAgent.Audit.Payload", "ref-1", actor: admin)

      assert current.id == second.id
    end

    test "REV and system actors cannot set markers", ctx do
      for actor <- [human(:reviewer, ctx.tenant), system_actor(:agent_runtime, ctx.tenant)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Audit.set_retention_marker(marker_attrs("x"), actor: actor)
      end

      assert denials(ctx.tenant) == []
    end
  end

  describe "guarded calls inside a transaction" do
    test "denials are appended after the outermost Audit.transaction, even on rollback", ctx do
      assert {:error, :rolled_back} =
               Audit.transaction(fn ->
                 assert {:error, %Ash.Error.Forbidden{}} =
                          Audit.verify_chain(actor: human(:reviewer, ctx.tenant))

                 assert denials(ctx.tenant) == []
                 SdrAgent.Repo.rollback(:rolled_back)
               end)

      assert [_] = denials(ctx.tenant)
    end

    test "guarded calls refuse to run inside a foreign transaction", ctx do
      assert_raise ArgumentError, ~r/Audit.transaction/, fn ->
        SdrAgent.Repo.transaction(fn -> Audit.verify_chain(actor: human(:admin, ctx.tenant)) end)
      end
    end
  end
end
