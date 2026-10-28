defmodule SdrAgent.Prototype.PayloadReadScopeTest do
  @moduledoc """
  The two scoped D-237 Payload reads, over the real `bind/1`:

  - `:read_dossier_source_content` with `SdrAgent.Audit.Checks.DossierSourceScope`
    (supplement 1 r2 §6a): the agent runtime of the binding's tenant reads a
    hash its scope carries, in the live binding, and a `payload_view`
    access is recorded under its own identity with purpose
    `d237_dossier_source`; refused for a hash outside the scope, no scope,
    another tenant, another actor type, a live mismatch and ordinary
    runtime.
  - `:read_prototype_review_content` with `SdrAgent.Audit.Checks.PrototypeReviewScope`
    (interfaces r6 R4): the operator reads the receipt hash its scope
    carries, and a `payload_view` access is recorded under the operator's
    identity (type `prototype_operator`, the delegation id) with purpose
    `d237_prototype_review`; refused for another hash, no scope, another
    tenant or delegation, a non-operator, a live mismatch and ordinary
    runtime.

  Payloads are stored by the seeder; the scopes are built with `context/1`,
  and forged ones are test-only adversarial inputs under the private keys.
  Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Checks.DossierSourceScope
  alias SdrAgent.Audit.Checks.PrototypeReviewScope
  alias SdrAgent.Audit.Payload

  defp stored!(fx, content) do
    {:ok, payload} =
      SdrAgent.Audit.put_payload(content, "text/plain", actor: system_actor(:seeder, fx.tenant))

    payload.sha256
  end

  defp read(action, sha256, actor, context) do
    Payload
    |> Ash.ActionInput.for_action(action, %{sha256: sha256}, actor: actor, context: context)
    |> Ash.run_action()
  end

  defp accesses(actor_id, purpose) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_accesses WHERE actor_id = $1 AND purpose = $2",
        [actor_id, purpose]
      )

    n
  end

  defp forbidden!(name, result) do
    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "#{name}: expected Forbidden, got #{inspect(result)}"
  end

  defp source_scope(fx, sha256s, overrides \\ %{}) do
    DossierSourceScope.context(
      Map.merge(
        %{
          tenant_id: fx.tenant.id,
          agent_run_id: Ecto.UUID.generate(),
          lead_id: Ecto.UUID.generate(),
          entry_id: Ecto.UUID.generate(),
          sha256s: sha256s
        },
        overrides
      )
    )
  end

  defp review_scope(fx, sha256s),
    do:
      PrototypeReviewScope.context(%{
        tenant_id: fx.tenant.id,
        delegation_id: fx.actor.id,
        sha256s: sha256s
      })

  describe ":read_dossier_source_content" do
    test "allow: the agent runtime reads a source of its scope; payload_view under its identity" do
      fx = bound!()
      sha = stored!(fx, "Synthetic company page for acme1.test.")
      agent = Actor.system(:agent_runtime, fx.tenant.id)

      result = read(:read_dossier_source_content, sha, agent, source_scope(fx, [sha]))

      assert result == {:ok, "Synthetic company page for acme1.test."},
             "read: #{inspect(result)}"

      assert accesses(agent.id, "d237_dossier_source") == 1
    end

    test "deny: another hash, no scope, another tenant, another actor type, a live mismatch, ordinary runtime" do
      fx = bound!()
      sha = stored!(fx, "Synthetic in-scope page.")
      other = stored!(fx, "Synthetic out-of-scope page.")
      agent = Actor.system(:agent_runtime, fx.tenant.id)
      scope = source_scope(fx, [sha])

      forbidden!(:outside, read(:read_dossier_source_content, other, agent, scope))
      forbidden!(:no_scope, read(:read_dossier_source_content, sha, agent, %{}))

      forbidden!(
        :other_tenant,
        read(
          :read_dossier_source_content,
          sha,
          agent,
          source_scope(fx, [sha], %{tenant_id: Ecto.UUID.generate()})
        )
      )

      forbidden!(:operator, read(:read_dossier_source_content, sha, fx.actor, scope))

      forbidden!(
        :reconciler,
        read(:read_dossier_source_content, sha, system_actor(:reconciler, fx.tenant), scope)
      )

      enter!(%{snapshot: %{fx.snapshot | database_oid: fx.snapshot.database_oid + 1}})
      forbidden!(:live_mismatch, read(:read_dossier_source_content, sha, agent, scope))

      assert PrototypeFixtures.leave_runtime() == :ok
      forbidden!(:ordinary_runtime, read(:read_dossier_source_content, sha, agent, scope))
    end
  end

  describe ":read_prototype_review_content" do
    test "allow: the operator reads its receipt hash; payload_view under the operator's identity" do
      fx = bound!()
      sha = stored!(fx, "Synthetic rendered draft for review.")

      result = read(:read_prototype_review_content, sha, fx.actor, review_scope(fx, [sha]))
      assert result == {:ok, "Synthetic rendered draft for review."}, "read: #{inspect(result)}"

      %{rows: rows} =
        Repo.query!(
          "SELECT actor_type, actor_id FROM audit_accesses WHERE purpose = $1",
          ["d237_prototype_review"]
        )

      assert rows == [["prototype_operator", fx.actor.id]]
    end

    test "deny: another hash, no scope, another tenant or delegation, a non-operator, a live mismatch, ordinary runtime" do
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      enter!(fx)
      sha = stored!(fx, "Synthetic rendered receipt.")
      other = stored!(fx, "Synthetic other payload.")
      scope = review_scope(fx, [sha])
      marker = :sdr_prototype_review_scope
      forged = fn changes -> %{marker => Map.merge(scope[marker], changes)} end

      forbidden!(:outside, read(:read_prototype_review_content, other, fx.actor, scope))
      forbidden!(:no_scope, read(:read_prototype_review_content, sha, fx.actor, %{}))

      forbidden!(
        :other_tenant,
        read(
          :read_prototype_review_content,
          sha,
          fx.actor,
          forged.(%{tenant_id: Ecto.UUID.generate()})
        )
      )

      forbidden!(
        :other_delegation,
        read(
          :read_prototype_review_content,
          sha,
          fx.actor,
          forged.(%{delegation_id: Ecto.UUID.generate()})
        )
      )

      for {name, actor} <- [
            admin: admin,
            agent_runtime: system_actor(:agent_runtime, fx.tenant),
            forged_operator: %Actor{
              type: :prototype_operator,
              id: Ecto.UUID.generate(),
              tenant_id: fx.tenant.id
            }
          ] do
        forbidden!(name, read(:read_prototype_review_content, sha, actor, scope))
      end

      enter!(%{snapshot: %{fx.snapshot | database_oid: fx.snapshot.database_oid + 1}})
      forbidden!(:live_mismatch, read(:read_prototype_review_content, sha, fx.actor, scope))

      assert PrototypeFixtures.leave_runtime() == :ok
      forbidden!(:ordinary_runtime, read(:read_prototype_review_content, sha, fx.actor, scope))
    end
  end
end
