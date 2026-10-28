defmodule SdrAgent.Prototype.PayloadScopeTest do
  @moduledoc """
  `Payload :store_prototype_input` and `SdrAgent.Audit.Checks.PrototypeInputScope`
  (interfaces r6 "Operator payload and content paths", must-fix R4), over
  the real `bind/1`:

  - allow: the operator stores, for each approved purpose, exactly the
    bytes whose sha256 its scope carries;
  - deny, with nothing written: bytes outside the scope's sha256s, no
    scope, a scope of another tenant or delegation, an unapproved purpose;
    a non-operator (admin, kernel, seeder, a forged operator id, nil) with
    a scope; the real operator on a live mismatch and in ordinary runtime;
    the operator on plain `:store`;
  - `context/1` builds only well-formed scopes.

  The forged scopes below are test-only adversarial inputs built under the
  check's private key. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Checks.PrototypeInputScope
  alias SdrAgent.Audit.Payload

  @marker :sdr_prototype_input_scope

  defp sha(bytes), do: :crypto.hash(:sha256, bytes)

  defp count_payloads do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM payloads", [])
    n
  end

  defp scope(fx, purpose, contents) do
    PrototypeInputScope.context(%{
      tenant_id: fx.tenant.id,
      delegation_id: fx.actor.id,
      purpose: purpose,
      sha256s: Enum.map(contents, &sha/1)
    })
  end

  defp store(action \\ :store_prototype_input, content, actor, context) do
    Payload
    |> Ash.Changeset.for_create(action, %{content: content, content_type: "application/json"},
      actor: actor,
      context: context
    )
    |> Ash.create()
  end

  defp forbidden!(name, result) do
    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "#{name}: expected Forbidden, got #{inspect(result)}"
  end

  test "allow: the operator stores the exact bytes of each approved purpose's scope" do
    fx = bound!()

    for purpose <- PrototypeInputScope.purposes() do
      content = ~s({"synthetic":"#{purpose}"})
      result = store(content, fx.actor, scope(fx, purpose, [content]))
      assert match?({:ok, %Payload{}}, result), "#{purpose}: #{inspect(result)}"
      {:ok, payload} = result
      assert payload.sha256 == sha(content)
    end
  end

  test "deny: bytes outside the scope, no scope, another tenant or delegation, an unapproved purpose" do
    fx = bound!()
    content = ~s({"synthetic":"in-scope"})
    other = ~s({"synthetic":"out-of-scope"})
    base = scope(fx, :dossier_claims, [content])
    forged = fn changes -> %{@marker => Map.merge(base[@marker], changes)} end
    before = count_payloads()

    cases = [
      outside_sha256s: {other, base},
      no_scope: {content, %{}},
      other_tenant: {content, forged.(%{tenant_id: Ecto.UUID.generate()})},
      other_delegation: {content, forged.(%{delegation_id: Ecto.UUID.generate()})},
      unapproved_purpose: {content, forged.(%{purpose: :other})}
    ]

    for {name, {bytes, context}} <- cases do
      forbidden!(name, store(bytes, fx.actor, context))
    end

    assert count_payloads() == before
  end

  test "deny: a non-operator carrying a scope" do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)
    content = ~s({"synthetic":"forged-scope"})
    context = scope(fx, :dossier_claims, [content])
    before = count_payloads()

    actors = [
      admin: admin,
      kernel: system_actor(:kernel, fx.tenant),
      seeder: system_actor(:seeder, fx.tenant),
      forged_operator: %Actor{
        type: :prototype_operator,
        id: Ecto.UUID.generate(),
        tenant_id: fx.tenant.id
      },
      nil: nil
    ]

    for {name, actor} <- actors do
      forbidden!(name, store(content, actor, context))
    end

    assert count_payloads() == before
  end

  test "deny: the real operator on a live mismatch and in ordinary runtime" do
    fx = bound!()
    content = ~s({"synthetic":"live-check"})
    context = scope(fx, :seed_provenance, [content])
    before = count_payloads()

    enter!(%{snapshot: %{fx.snapshot | database_oid: fx.snapshot.database_oid + 1}})
    forbidden!(:live_mismatch, store(content, fx.actor, context))

    assert PrototypeFixtures.leave_runtime() == :ok
    forbidden!(:ordinary_runtime, store(content, fx.actor, context))

    assert count_payloads() == before
  end

  test "deny: the operator on plain :store" do
    fx = bound!()
    content = ~s({"synthetic":"plain-store"})

    forbidden!(
      :plain_store,
      store(:store, content, fx.actor, scope(fx, :dossier_notes, [content]))
    )
  end

  test "deny: a forged scope with a malformed hash list or shape never raises and never passes" do
    fx = bound!()
    content = ~s({"synthetic":"forged-shape"})
    good = sha(content)
    base = %{tenant_id: fx.tenant.id, delegation_id: fx.actor.id, purpose: :dossier_claims}
    before = count_payloads()

    forged = [
      mixed_members: Map.put(base, :sha256s, [good, "not-32-bytes"]),
      non_binary_member: Map.put(base, :sha256s, [good, 42]),
      empty_list: Map.put(base, :sha256s, []),
      not_a_list: Map.put(base, :sha256s, good),
      missing_key: base,
      not_a_map: [good],
      improper_list: Map.put(base, :sha256s, [good | :bad_tail])
    ]

    for {name, scope} <- forged do
      forbidden!(name, store(content, fx.actor, %{@marker => scope}))
    end

    assert count_payloads() == before
  end

  test "context/1 builds only well-formed scopes" do
    fx = bound!()

    for bad <- [
          %{purpose: :other},
          %{sha256s: []},
          %{sha256s: ["not-32-bytes"]},
          %{tenant_id: nil}
        ] do
      input =
        Map.merge(
          %{
            tenant_id: fx.tenant.id,
            delegation_id: fx.actor.id,
            purpose: :dossier_claims,
            sha256s: [sha("x")]
          },
          bad
        )

      assert_raise ArgumentError, fn -> PrototypeInputScope.context(input) end
    end
  end
end
