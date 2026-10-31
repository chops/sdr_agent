defmodule SdrAgent.Agents.RemoteTenancyTest do
  @moduledoc """
  S-B2 RED item 5 (entity/plan r2 6f0de674 relationships; Codex review
  2bddc465 must_fix 2; PASS ed0835d1): tenant-scoped composites.

  Contract specified here:

  - every new tenant-owned row has `tenant_id`, and the tenant-scoped
    composite foreign keys exist: MacWorker (binding_id, tenant_id) →
    prototype_database_bindings (id, tenant_id); RemoteModelCall
    (model_invocation_id, tenant_id) → model_invocations (id, tenant_id) and
    (worker_id, tenant_id) → MacWorker (id, tenant_id); ClaimNonce
    (worker_id, tenant_id) and (call_id, tenant_id); RemoteCallResult and
    RemoteCallReceipt (call_id, tenant_id) → RemoteModelCall (id, tenant_id);
  - a row of this tenant that references another tenant's parent (planted
    with triggers disabled, since the tenant table is a singleton) is a
    `foreign_key_violation` of that composite key;
  - a worker of tenant A cannot claim or complete a tenant-B call planted
    with a raw insert: the claim returns A's own call, and the planted call
    is never claimed, locked, written or given a receipt.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  defp composite?(table, cols, ref) do
    want = Enum.sort(cols)

    Enum.any?(F.foreign_keys(table), fn {c, r, rc} ->
      c == want and r == ref and rc == Enum.sort(["id", "tenant_id"])
    end)
  end

  defp assert_composite_violation!(result, table, column, label) do
    error = F.assert_pg!(result, :foreign_key_violation, label)
    name = error.postgres[:constraint]
    assert is_binary(name), "#{label}: no constraint name in #{inspect(error)}"

    assert F.constraint_columns(table, name) == Enum.sort([column, "tenant_id"]),
           "#{label}: violated #{name}, not the (#{column}, tenant_id) composite"
  end

  # A claimed call, its nonce, an accepted result and its receipt.
  defp claimed_and_completed!(fx) do
    %{worker: worker, token: token} = F.enrol!(fx)
    invocation = F.reserve!(fx)
    nonce = F.nonce()
    launch = F.claim!(token, nonce)

    assert F.kind(F.complete(token, nonce, launch.call_id, launch.request_sha256, F.transcript())) ==
             :accepted

    %{worker: worker, token: token, invocation: invocation, nonce: nonce, launch: launch}
  end

  # Another tenant's copy of the row of `resource` matching `where`.
  defp plant_foreign!(resource, where, params, set) do
    assert :ok == F.copy_insert(resource, where, params, set, replica: true),
           "prerequisite: planting a foreign #{inspect(resource)}"
  end

  describe "the database" do
    test "every new table carries the tenant-scoped composite foreign keys" do
      worker = F.table(F.worker_resource())
      call = F.table(F.call_resource())
      nonce = F.table(F.nonce_resource())
      result = F.table(F.result_resource())
      receipt = F.table(F.receipt_resource())

      for {table, cols, ref} <- [
            {worker, ["binding_id", "tenant_id"], "prototype_database_bindings"},
            {call, ["model_invocation_id", "tenant_id"], "model_invocations"},
            {call, ["tenant_id", "worker_id"], worker},
            {nonce, ["tenant_id", "worker_id"], worker},
            {nonce, ["call_id", "tenant_id"], call},
            {result, ["call_id", "tenant_id"], call},
            {receipt, ["call_id", "tenant_id"], call}
          ] do
        assert composite?(table, cols, ref),
               "#{table}: no (#{Enum.join(cols, ", ")}) → #{ref} (id, tenant_id) foreign key; " <>
                 "found #{inspect(F.foreign_keys(table))}"
      end
    end

    test "rows referencing another tenant's parent are composite foreign_key_violations",
         %{fx: fx} do
      life = claimed_and_completed!(fx)
      foreign_tenant = F.dump(Ecto.UUID.generate())
      foreign_worker = Ecto.UUID.generate()
      foreign_call = Ecto.UUID.generate()

      plant_foreign!(F.worker_resource(), "id = $1", [F.dump(life.worker.id)], [
        {"id", F.dump(foreign_worker)},
        {"tenant_id", foreign_tenant},
        {"status", "disabled"},
        {"token_sha256", :crypto.strong_rand_bytes(32)}
      ])

      plant_foreign!(F.call_resource(), "id = $1", [F.dump(life.launch.call_id)], [
        {"id", F.dump(foreign_call)},
        {"tenant_id", foreign_tenant},
        {"model_invocation_id", F.dump(Ecto.UUID.generate())},
        {"worker_id", nil},
        {"state", "pending"}
      ])

      call_table = F.table(F.call_resource())
      nonce_table = F.table(F.nonce_resource())
      result_table = F.table(F.result_resource())
      receipt_table = F.table(F.receipt_resource())
      [receipt] = F.receipts(life.launch.call_id)

      # A call of this tenant (for an invocation that has no call) naming the
      # foreign worker.
      F.remote!(:local)
      local = F.reserve!(fx)
      F.remote!(:remote)

      assert_composite_violation!(
        F.copy_insert(F.call_resource(), "id = $1", [F.dump(life.launch.call_id)], [
          {"id", F.dump(Ecto.UUID.generate())},
          {"model_invocation_id", F.dump(local.id)},
          {"worker_id", F.dump(foreign_worker)},
          {"state", "pending"}
        ]),
        call_table,
        "worker_id",
        "call → foreign worker"
      )

      # A nonce of this tenant naming the foreign worker, then the foreign call.
      nonce_where = "claim_nonce = $1"

      assert_composite_violation!(
        F.copy_insert(F.nonce_resource(), nonce_where, [life.nonce], [
          {"worker_id", F.dump(foreign_worker)},
          {"claim_nonce", F.nonce()}
        ]),
        nonce_table,
        "worker_id",
        "nonce → foreign worker"
      )

      assert_composite_violation!(
        F.copy_insert(F.nonce_resource(), nonce_where, [life.nonce], [
          {"call_id", F.dump(foreign_call)},
          {"claim_nonce", F.nonce()}
        ]),
        nonce_table,
        "call_id",
        "nonce → foreign call"
      )

      assert_composite_violation!(
        F.copy_insert(F.result_resource(), "call_id = $1", [F.dump(life.launch.call_id)], [
          {"call_id", F.dump(foreign_call)}
        ]),
        result_table,
        "call_id",
        "result → foreign call"
      )

      assert_composite_violation!(
        F.copy_insert(F.receipt_resource(), "id = $1", [receipt["id"]], [
          {"id", F.dump(Ecto.UUID.generate())},
          {"call_id", F.dump(foreign_call)}
        ]),
        receipt_table,
        "call_id",
        "receipt → foreign call"
      )

      # A worker of this tenant naming a binding id that is not this tenant's.
      assert_composite_violation!(
        F.copy_insert(F.worker_resource(), "id = $1", [F.dump(life.worker.id)], [
          {"id", F.dump(Ecto.UUID.generate())},
          {"binding_id", F.dump(Ecto.UUID.generate())},
          {"status", "disabled"},
          {"token_sha256", :crypto.strong_rand_bytes(32)}
        ]),
        F.table(F.worker_resource()),
        "binding_id",
        "worker → binding of no tenant row"
      )
    end
  end

  describe "the actions" do
    test "a tenant-A worker never claims or completes a planted tenant-B call", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      own = F.reserve!(fx)
      own_call = F.call_of(own.id)
      assert own_call, "no RemoteModelCall for the reservation"
      planted = Ecto.UUID.generate()

      # Tenant B's call is pending and due first (the earliest claim deadline).
      plant_foreign!(F.call_resource(), "id = $1", [own_call["id"]], [
        {"id", F.dump(planted)},
        {"tenant_id", F.dump(Ecto.UUID.generate())},
        {"model_invocation_id", F.dump(Ecto.UUID.generate())}
      ])

      tamper!(
        ~s[UPDATE "#{F.table(F.call_resource())}" SET claim_deadline = claim_deadline - interval '60 seconds' WHERE id = $1],
        [F.dump(planted)]
      )

      before = {F.call_row(planted), F.xmax(F.call_resource(), planted)}
      nonce = F.nonce()
      launch = F.claim!(token, nonce)
      assert launch.call_id == F.load(own_call["id"]), "the claim did not return A's own call"

      assert F.kind(F.complete(token, nonce, planted, launch.request_sha256, F.transcript())) ==
               :refused_mismatch

      assert F.receipts(planted) == [], "the tenant-B call got a receipt"

      assert {F.call_row(planted), F.xmax(F.call_resource(), planted)} == before,
             "the tenant-B call was claimed, locked or written"

      assert F.call_row(launch.call_id)["state"] == "claimed"
    end
  end
end
