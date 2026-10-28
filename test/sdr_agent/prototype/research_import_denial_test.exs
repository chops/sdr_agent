defmodule SdrAgent.Prototype.ResearchImportDenialTest do
  @moduledoc """
  The denial audit of the D-237 Research import names (Codex ca4624a1
  section B), over the real `bind/1`:

  - a refused `SdrAgent.Research.record_dossier_entry/2` or
    `record_dossier_source/2` by a recognized actor of the binding's
    tenant (an admin, an auditor, an agent runtime, a forged operator) is
    `Forbidden` and appends exactly ONE `authz.denied`, through the audit
    guard's deferred mechanism. It records the import action (`import` on
    the dossier resource) and the actor, and echoes none of the input;
  - missing or non-actor input, and an actor of a tenant with no
    initialized audit chain, keep the fixed early `Forbidden` with no
    append and no raise (no audit destination from unvalidated input);
  - malformed input stays `Forbidden` (the precheck runs before any
    changeset), never `Invalid`;
  - the operator's call (the precheck passes) appends no denial and writes
    nothing while S3's body is pending, and the direct `:import` action
    still writes nothing.

  S3 owns the per-row `SdrAgent.Audit.transaction/1` and its mid-row
  rollback proof. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Research
  alias SdrAgent.Research.DossierEntry
  alias SdrAgent.Research.DossierSource

  @names [record_dossier_entry: DossierEntry, record_dossier_source: DossierSource]
  @sentinel "SENTINEL-import-input-acme9.test"

  defp sensitive_attrs,
    do: %{"company" => @sentinel, "notes" => @sentinel, @sentinel => @sentinel}

  defp all_events do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM audit_events", [])
    n
  end

  defp rows do
    %{rows: [[entries]]} = Repo.query!("SELECT count(*) FROM dossier_entries", [])
    %{rows: [[sources]]} = Repo.query!("SELECT count(*) FROM dossier_sources", [])
    {entries, sources}
  end

  defp denials(tenant), do: events_of_type(tenant, "authz.denied")

  defp forbidden!(label, result) do
    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "#{label}: expected Forbidden, got #{inspect(result)}"
  end

  test "a refused import by a recognized actor appends exactly one authz.denied, echoing no input" do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    auditor = human(:auditor, fx.tenant)
    enter!(fx)

    forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: fx.tenant.id}

    # {actor, the kernel's recorded {actor_type, actor_id}}
    actors = [
      admin: {admin, {:user, admin.id}},
      auditor: {auditor, {:user, auditor.id}},
      agent_runtime:
        {Actor.system(:agent_runtime, fx.tenant.id), {:agent_runtime, "agent_runtime"}},
      forged_operator: {forged, {:prototype_operator, forged.id}}
    ]

    rows_before = rows()

    for {name, resource} <- @names, {actor_name, {actor, recorded}} <- actors do
      label = "#{name} by #{actor_name}"
      before = denials(fx.tenant)
      forbidden!(label, apply(Research, name, [sensitive_attrs(), [actor: actor]]))

      new = denials(fx.tenant) -- before
      assert length(new) == 1, "#{label}: expected exactly one authz.denied, got #{length(new)}"
      [denied] = new

      assert {denied.subject_resource, denied.action, denied.tenant_id} ==
               {inspect(resource), "import", fx.tenant.id},
             "#{label}: denial metadata #{inspect({denied.subject_resource, denied.action})}"

      assert {denied.actor_type, denied.actor_id} == recorded,
             "#{label}: denial actor #{inspect({denied.actor_type, denied.actor_id})}"

      refute inspect(denied) =~ @sentinel, "#{label}: the denial echoes the input"
    end

    assert rows() == rows_before
  end

  test "an ordinary-runtime refusal is audited the same way" do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)

    for {name, resource} <- @names do
      before = denials(fx.tenant)
      forbidden!("#{name} in ordinary runtime", apply(Research, name, [%{}, [actor: admin]]))
      new = denials(fx.tenant) -- before
      assert length(new) == 1, "#{name}: expected exactly one authz.denied, got #{length(new)}"
      assert hd(new).subject_resource == inspect(resource)
    end
  end

  test "missing or non-actor input, and an uninitialized tenant, keep the early Forbidden with no append" do
    fx = bound!()
    events_before = all_events()

    inputs = [
      nil_actor: [actor: nil],
      no_actor_option: [],
      plain_map: [actor: %{tenant_id: fx.tenant.id, role: :admin}],
      string: [actor: "admin"],
      uninitialized_tenant: [actor: Actor.system(:agent_runtime, Ecto.UUID.generate())]
    ]

    for {name, _resource} <- @names, {input_name, opts} <- inputs do
      forbidden!("#{name} with #{input_name}", apply(Research, name, [sensitive_attrs(), opts]))
    end

    assert all_events() == events_before, "a missing or untrusted actor produced an audit append"
  end

  test "a malformed actor envelope of a real tenant is a plain Forbidden: no append, no raise" do
    fx = bound!()
    tid = fx.tenant.id
    user = &struct(SdrAgent.Accounts.User, Map.put(&1, :tenant_id, tid))
    events_before = all_events()

    envelopes = [
      unknown_actor_type: %Actor{type: :not_a_type, id: "x", tenant_id: tid},
      map_actor_id: %Actor{type: :agent_runtime, id: %{bad: :id}, tenant_id: tid},
      invalid_utf8_actor_id: %Actor{type: :agent_runtime, id: <<0xFF, 0xFE>>, tenant_id: tid},
      user_id_not_uuid: user.(%{id: "not-a-uuid", role: :admin}),
      user_nil_id: user.(%{id: nil, role: :admin}),
      user_map_id: user.(%{id: %{bad: :id}, role: :admin}),
      user_unknown_role: user.(%{id: Ecto.UUID.generate(), role: :not_a_role}),
      user_role_not_auditable: user.(%{id: Ecto.UUID.generate(), role: :agent_operator})
    ]

    for {name, _resource} <- @names, {envelope_name, actor} <- envelopes do
      label = "#{name} with #{envelope_name}"

      result =
        try do
          apply(Research, name, [sensitive_attrs(), [actor: actor]])
        rescue
          error -> {:raised, error.__struct__}
        end

      forbidden!(label, result)
      refute inspect(result) =~ @sentinel, "#{label}: the refusal echoes the input"
    end

    assert all_events() == events_before, "a malformed actor envelope produced an audit append"
  end

  test "a system actor id the audit store cannot hold is a plain Forbidden: no append, no raise" do
    fx = bound!()
    tid = fx.tenant.id
    events_before = all_events()

    # NUL is valid UTF-8 but PostgreSQL text and jsonb cannot store it
    # (Codex 67ff29f5 R1a, RED); the empty and 129-byte ids are coverage of
    # the stated 1..128-byte bound.
    ids = [
      nul_only: <<0>>,
      embedded_nul: "agent" <> <<0>> <> "runtime",
      empty: "",
      over_128_bytes: String.duplicate("a", 129)
    ]

    for {name, _resource} <- @names, {id_name, id} <- ids do
      label = "#{name} with #{id_name}"
      actor = %Actor{type: :agent_runtime, id: id, tenant_id: tid}

      result =
        try do
          apply(Research, name, [sensitive_attrs(), [actor: actor]])
        rescue
          error -> {:raised, error.__struct__}
        end

      forbidden!(label, result)
      refute inspect(result) =~ @sentinel, "#{label}: the refusal echoes the input"
    end

    assert all_events() == events_before, "an unstorable actor id produced an audit append"
  end

  test "malformed input stays Forbidden before any changeset" do
    fx = bound!()
    agent = Actor.system(:agent_runtime, fx.tenant.id)

    for {name, _resource} <- @names,
        attrs <- [%{"bad" => <<0xFF, 0xFE>>}, %{id: :not_a_uuid, tenant_id: 42}] do
      forbidden!("#{name} with malformed input", apply(Research, name, [attrs, [actor: agent]]))
    end
  end

  test "the operator's pending import appends no denial, and the direct action writes nothing" do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)
    rows_before = rows()
    denials_before = denials(fx.tenant)

    for {name, _resource} <- @names do
      result = apply(Research, name, [%{}, [actor: fx.actor]])
      assert match?({:error, _}, result), "#{name} by the operator: #{inspect(result)}"
      refute match?({:error, %Ash.Error.Forbidden{}}, result), "#{name}: operator was forbidden"
    end

    assert denials(fx.tenant) == denials_before, "the operator's pending import was audited"

    for {_name, resource} <- @names do
      direct =
        resource
        |> Ash.Changeset.for_create(:import, %{}, actor: admin)
        |> Ash.create()

      assert match?({:error, _}, direct),
             "direct #{inspect(resource)} :import: #{inspect(direct)}"
    end

    assert rows() == rows_before
  end
end
