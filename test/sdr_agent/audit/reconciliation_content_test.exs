defmodule SdrAgent.Audit.ReconciliationContentTest do
  @moduledoc """
  Supplementary Payload ruling S1–S3: the narrow `:read_reconciliation_content`
  action. Only REC may read, and only from inside the Agents-owned path
  (`SdrAgent.Agents.read_reconciliation_payloads/2`), which re-reads the
  authoritative invocation in the actor's tenant and attaches the private
  scope (QualificationContext-style: no public function accepts a caller
  scope) naming exactly that invocation's two payload hashes. The purpose is
  fixed; a `payload_view` AuditAccess with REC's real identity is appended
  before content is returned and the read fails closed when it cannot be.
  The generic `read_content`/`read` policies are unchanged.
  """
  use SdrAgent.AuditCase, async: false

  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Checks.ReconciliationScope
  alias SdrAgent.Audit.Payload

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    attrs = AgentsFixtures.model_attrs("rec-read") |> Map.put(:provider, :claude_cli)
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: agent)

    {:ok, unrelated} = Audit.put_payload("unrelated body", "text/plain", actor: agent)

    %{
      tenant: tenant,
      agent: agent,
      rec: system_actor(:reconciler, tenant),
      invocation: invocation,
      unrelated: unrelated,
      request: AgentsFixtures.model_attrs("x").request,
      response: AgentsFixtures.completion().response
    }
  end

  defp purpose(invocation), do: "wire_witness_reconciliation:#{invocation.id}"
  defp views(tenant), do: events_of_type(tenant, "audit.access.payload_view")

  describe "Agents.read_reconciliation_payloads/2" do
    test "REC reads both bodies of its invocation; each read is one REC access", ctx do
      assert {:ok, %{request: request, response: response}} =
               read_payloads(ctx.invocation, actor: ctx.rec)

      assert {request, response} == {ctx.request, ctx.response}

      assert [_, _] = views = views(ctx.tenant)
      assert Enum.all?(views, &(&1.actor_type == :reconciler and &1.actor_id == "reconciler"))
      assert Enum.all?(views, &(&1.payload["purpose"] == purpose(ctx.invocation)))

      assert Enum.sort(Enum.map(views, & &1.subject_id)) ==
               Enum.sort([
                 hex(ctx.invocation.request_sha256),
                 hex(ctx.invocation.response_sha256)
               ])

      {:ok, accesses} = Audit.list_accesses(actor: human(:auditor, ctx.tenant))
      rec_views = Enum.filter(accesses, &(&1.actor_type == :reconciler))
      assert length(rec_views) == 2
      assert Enum.all?(rec_views, &(&1.purpose == purpose(ctx.invocation)))
    end

    test "re-reads the parent: caller-supplied hashes and purposes are ignored", ctx do
      forged = %{
        ctx.invocation
        | request_sha256: ctx.unrelated.sha256,
          response_sha256: ctx.unrelated.sha256
      }

      assert {:ok, %{request: request, response: response}} =
               read_payloads(forged, actor: ctx.rec, purpose: "operator curiosity")

      assert {request, response} == {ctx.request, ctx.response}
      refute Enum.any?(views(ctx.tenant), &(&1.subject_id == hex(ctx.unrelated.sha256)))
      assert Enum.all?(views(ctx.tenant), &(&1.payload["purpose"] == purpose(ctx.invocation)))
    end

    test "an actor of another tenant cannot read this tenant's invocation", ctx do
      foreign_rec = system_actor(:reconciler, %{id: Ecto.UUID.generate()})

      for target <- [ctx.invocation, ctx.invocation.id] do
        assert {:error, %Ash.Error.Query.NotFound{}} = read_payloads(target, actor: foreign_rec)
      end

      assert views(ctx.tenant) == []
    end

    test "every other system actor and every human is refused; denials are audited", ctx do
      others =
        Enum.map(SdrAgent.Actor.types() -- [:reconciler], &system_actor(&1, ctx.tenant)) ++
          Enum.map([:admin, :reviewer, :auditor], &human(&1, ctx.tenant))

      for actor <- others do
        assert match?(
                 {:error, %Ash.Error.Forbidden{}},
                 read_payloads(ctx.invocation, actor: actor)
               ),
               inspect(actor)
      end

      assert views(ctx.tenant) == []
      denied = events_of_type(ctx.tenant, "authz.denied")
      assert length(denied) == length(others)
      assert Enum.all?(denied, &(&1.payload["action"] == "read_reconciliation_payloads"))
    end

    test "no content is returned when the access record cannot be appended", ctx do
      refuse_access_inserts!()
      before = length(events(ctx.tenant))
      assert {:error, _access_failure} = read_payloads(ctx.invocation, actor: ctx.rec)
      assert length(events(ctx.tenant)) == before
    end
  end

  describe "Payload :read_reconciliation_content policy" do
    test "REC inside the scope reads; the purpose is fixed by the scope", ctx do
      assert {:ok, content} =
               run_scoped(ctx.invocation.request_sha256, ctx.rec, scope(ctx.tenant.id, ctx))

      assert content == ctx.request
      assert [view] = views(ctx.tenant)
      assert view.payload["purpose"] == purpose(ctx.invocation)
    end

    test "a hash outside the scope is refused without an access", ctx do
      assert match?(
               {:error, %Ash.Error.Forbidden{}},
               run_scoped(ctx.unrelated.sha256, ctx.rec, scope(ctx.tenant.id, ctx))
             )

      assert views(ctx.tenant) == []
    end

    test "a scope naming another tenant is refused", ctx do
      assert match?(
               {:error, %Ash.Error.Forbidden{}},
               run_scoped(
                 ctx.invocation.request_sha256,
                 ctx.rec,
                 scope(Ecto.UUID.generate(), ctx)
               )
             )

      assert views(ctx.tenant) == []
    end

    test "without the private scope REC is refused", ctx do
      for context <- [%{}, %{sdr_reconciliation_scope: true}, %{sdr_reconciliation_scope: %{}}] do
        assert match?(
                 {:error, %Ash.Error.Forbidden{}},
                 run_scoped(ctx.invocation.request_sha256, ctx.rec, context)
               ),
               inspect(context)
      end

      assert views(ctx.tenant) == []
    end

    test "every other actor is refused even inside the scope", ctx do
      others =
        Enum.map(SdrAgent.Actor.types() -- [:reconciler], &system_actor(&1, ctx.tenant)) ++
          Enum.map([:admin, :reviewer, :auditor], &human(&1, ctx.tenant)) ++ [nil]

      for actor <- others do
        assert match?(
                 {:error, %Ash.Error.Forbidden{}},
                 run_scoped(ctx.invocation.request_sha256, actor, scope(ctx.tenant.id, ctx))
               ),
               inspect(actor)
      end

      assert views(ctx.tenant) == []
    end

    test "regression: the generic read_content policy still refuses REC", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Audit.read_content(ctx.invocation.request_sha256, actor: ctx.rec, purpose: "x")
    end
  end

  ## Calls

  defp read_payloads(invocation, opts), do: Agents.read_reconciliation_payloads(invocation, opts)

  # Runs the Payload action directly with an explicit context, as only the
  # Agents path does in production; used to test the policy boundary.
  defp run_scoped(sha256, actor, context) do
    Payload
    |> Ash.ActionInput.for_action(:read_reconciliation_content, %{sha256: sha256},
      actor: actor,
      context: context
    )
    |> Ash.run_action()
  end

  defp scope(tenant_id, ctx) do
    ReconciliationScope.context(%{
      tenant_id: tenant_id,
      model_invocation_id: ctx.invocation.id,
      sha256s: [ctx.invocation.request_sha256, ctx.invocation.response_sha256]
    })
  end

  defp refuse_access_inserts! do
    SQL.query!(Repo, """
    CREATE FUNCTION s12b_refuse_access() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'access store unavailable'; END; $$
    """)

    SQL.query!(
      Repo,
      "CREATE TRIGGER s12b_refuse_access BEFORE INSERT ON audit_accesses " <>
        "FOR EACH ROW EXECUTE FUNCTION s12b_refuse_access()"
    )
  end
end
