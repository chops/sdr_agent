defmodule SdrAgent.Audit.ReconciliationContentTest do
  @moduledoc """
  Supplementary Payload ruling S1–S3: the narrow `:read_reconciliation_content`
  action. Only REC, inside an Agents-built scope that names exactly one
  invocation's request/response hashes in the actor's tenant, may read; the
  purpose is fixed; a `payload_view` AuditAccess with REC's real identity is
  appended before content is returned and the read fails closed when it
  cannot be. The generic `read_content`/`read` policies are unchanged.
  """
  use SdrAgent.AuditCase, async: false

  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Checks.ReconciliationScope

  setup do
    assert function_exported?(Audit, :read_reconciliation_content, 2),
           "S12b: Audit.read_reconciliation_content/2 is not implemented"

    assert function_exported?(Agents, :read_reconciliation_payloads, 2),
           "S12b: Agents.read_reconciliation_payloads/2 is not implemented"

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
      scope: scope(tenant.id, invocation)
    }
  end

  defp scope(tenant_id, invocation) do
    ReconciliationScope.context(%{
      tenant_id: tenant_id,
      model_invocation_id: invocation.id,
      sha256s: [invocation.request_sha256, invocation.response_sha256]
    })
  end

  defp purpose(invocation), do: "wire_witness_reconciliation:#{invocation.id}"

  defp views(tenant), do: events_of_type(tenant, "audit.access.payload_view")

  test "Agents reads both bodies of one invocation for REC, each audited", ctx do
    request = AgentsFixtures.model_attrs("x").request
    response = AgentsFixtures.completion().response

    assert {:ok, %{request: ^request, response: ^response}} =
             Agents.read_reconciliation_payloads(ctx.invocation, actor: ctx.rec)

    assert [_, _] = views = views(ctx.tenant)
    assert Enum.all?(views, &(&1.actor_type == :reconciler))
    assert Enum.all?(views, &(&1.payload["purpose"] == purpose(ctx.invocation)))

    assert Enum.sort(Enum.map(views, & &1.subject_id)) ==
             Enum.sort([hex(ctx.invocation.request_sha256), hex(ctx.invocation.response_sha256)])

    {:ok, accesses} = Audit.list_accesses(actor: human(:auditor, ctx.tenant))
    rec_views = Enum.filter(accesses, &(&1.actor_type == :reconciler))
    assert length(rec_views) == 2
    assert Enum.all?(rec_views, &(&1.purpose == purpose(ctx.invocation)))
  end

  test "REC reads an in-scope hash through the Audit action", ctx do
    assert {:ok, content} =
             Audit.read_reconciliation_content(ctx.invocation.request_sha256,
               actor: ctx.rec,
               scope: ctx.scope
             )

    assert content == AgentsFixtures.model_attrs("x").request
    assert [view] = views(ctx.tenant)
    assert view.payload["purpose"] == purpose(ctx.invocation)
  end

  test "a hash outside the invocation's scope is refused and audited", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Audit.read_reconciliation_content(ctx.unrelated.sha256,
               actor: ctx.rec,
               scope: ctx.scope
             )

    assert views(ctx.tenant) == []
    assert [denied] = events_of_type(ctx.tenant, "authz.denied")
    assert denied.payload["action"] == "read_reconciliation_content"
  end

  test "a scope for another tenant is refused", ctx do
    foreign = scope(Ecto.UUID.generate(), ctx.invocation)

    assert {:error, %Ash.Error.Forbidden{}} =
             Audit.read_reconciliation_content(ctx.invocation.request_sha256,
               actor: ctx.rec,
               scope: foreign
             )

    assert views(ctx.tenant) == []
  end

  test "without the Agents scope REC is refused", ctx do
    for scope <- [nil, %{}, %{sdr_reconciliation_scope: true}] do
      assert match?(
               {:error, %Ash.Error.Forbidden{}},
               Audit.read_reconciliation_content(ctx.invocation.request_sha256,
                 actor: ctx.rec,
                 scope: scope
               )
             ),
             inspect(scope)
    end

    assert views(ctx.tenant) == []
  end

  test "every other system actor and every human is refused, even in scope", ctx do
    others =
      Enum.map(SdrAgent.Actor.types() -- [:reconciler], &system_actor(&1, ctx.tenant)) ++
        Enum.map([:admin, :reviewer, :auditor], &human(&1, ctx.tenant)) ++ [nil]

    for actor <- others do
      assert match?(
               {:error, %Ash.Error.Forbidden{}},
               Audit.read_reconciliation_content(ctx.invocation.request_sha256,
                 actor: actor,
                 scope: ctx.scope
               )
             ),
             inspect(actor)

      assert match?(
               {:error, %Ash.Error.Forbidden{}},
               Agents.read_reconciliation_payloads(ctx.invocation, actor: actor)
             ),
             inspect(actor)
    end

    assert views(ctx.tenant) == []
  end

  test "the generic read_content policy is unchanged: REC still cannot use it", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Audit.read_content(ctx.invocation.request_sha256, actor: ctx.rec, purpose: "x")
  end

  test "no content is returned when the access record cannot be appended", ctx do
    SQL.query!(Repo, """
    CREATE FUNCTION s12b_refuse_access() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'access store unavailable'; END; $$
    """)

    SQL.query!(
      Repo,
      "CREATE TRIGGER s12b_refuse_access BEFORE INSERT ON audit_accesses " <>
        "FOR EACH ROW EXECUTE FUNCTION s12b_refuse_access()"
    )

    before = length(events(ctx.tenant))

    assert {:error, _} =
             Audit.read_reconciliation_content(ctx.invocation.request_sha256,
               actor: ctx.rec,
               scope: ctx.scope
             )

    assert {:error, _} = Agents.read_reconciliation_payloads(ctx.invocation, actor: ctx.rec)
    assert length(events(ctx.tenant)) == before
  end
end
