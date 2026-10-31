defmodule SdrAgent.Agents.RemoteImmutabilityTest do
  @moduledoc """
  S-B2 RED item 8 (entity/plan r2 6f0de674 invariants; r4 R1
  "Immutability"): database triggers on every new table.

  Contract specified here:

  - RemoteModelCall: an UPDATE of a row in a terminal state (completed,
    expired_unknown) is refused; an UPDATE of a non-terminal row is not
    refused by the trigger; DELETE and TRUNCATE are refused;
  - ClaimNonce, RemoteCallResult and RemoteCallReceipt: UPDATE, DELETE and
    TRUNCATE are refused (insert-only);
  - MacWorker (active → disabled is terminal): an UPDATE of a disabled row,
    DELETE and TRUNCATE are refused.

  Refusals are Postgres `restrict_violation` errors (the
  `SdrAgent.Audit.SQL` trigger convention), and the row is unchanged.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Clock
  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  # A completed call (nonce, result, receipt), an expired_unknown call and a
  # pending call; the worker is then disabled.
  defp rows!(fx) do
    %{worker: worker, token: token} = F.enrol!(fx)
    t0 = F.instant()
    Clock.freeze(t0)
    F.reserve!(fx)
    F.reserve!(fx)
    F.reserve!(fx)
    n1 = F.nonce()
    done = F.claim!(token, n1)

    assert F.kind(F.complete(token, n1, done.call_id, done.request_sha256, F.transcript())) ==
             :accepted

    n2 = F.nonce()
    expired = F.claim!(token, n2)
    Clock.freeze(DateTime.add(t0, 600, :second))

    assert F.kind(F.complete(token, n2, expired.call_id, expired.request_sha256, F.transcript())) ==
             :late

    disabled = F.disable!(fx, worker)

    %{
      worker: disabled,
      done: done.call_id,
      expired: expired.call_id,
      pending: hd(F.call_ids_in("pending"))
    }
  end

  defp refused!(sql, params, label) do
    F.assert_pg!(raw_error(sql, params), :restrict_violation, label)
  end

  defp snapshot(resource), do: Enum.sort(F.rows(resource))

  test "RemoteModelCall: a terminal row cannot be updated; DELETE and TRUNCATE are refused",
       %{fx: fx} do
    life = rows!(fx)
    t = F.table(F.call_resource())
    before = snapshot(F.call_resource())

    for id <- [life.done, life.expired] do
      refused!(
        ~s[UPDATE "#{t}" SET claimed_at = claimed_at WHERE id = $1],
        [F.dump(id)],
        "UPDATE terminal #{id}"
      )

      refused!(
        ~s[UPDATE "#{t}" SET state = 'pending' WHERE id = $1],
        [F.dump(id)],
        "reopen #{id}"
      )
    end

    refused!(~s[DELETE FROM "#{t}" WHERE id = $1], [F.dump(life.pending)], "DELETE")
    refused!(~s[TRUNCATE "#{t}" CASCADE], [], "TRUNCATE")
    assert snapshot(F.call_resource()) == before

    # A non-terminal row is not refused by the trigger (positive control).
    result =
      raw_error(~s[UPDATE "#{t}" SET claim_deadline = claim_deadline WHERE id = $1], [
        F.dump(life.pending)
      ])

    assert match?({:error, {:unexpected_success, _}}, result),
           "a pending call's no-op UPDATE was refused: #{inspect(result)}"
  end

  test "ClaimNonce, RemoteCallResult and RemoteCallReceipt refuse UPDATE, DELETE and TRUNCATE",
       %{fx: fx} do
    rows!(fx)

    for {resource, column} <- [
          {F.nonce_resource(), "claim_nonce"},
          {F.result_resource(), "byte_size"},
          {F.receipt_resource(), "position"}
        ] do
      t = F.table(resource)
      before = snapshot(resource)
      assert before != [], "prerequisite: #{t} rows"

      for sql <- [
            ~s[UPDATE "#{t}" SET "#{column}" = "#{column}"],
            ~s[DELETE FROM "#{t}"],
            ~s[TRUNCATE "#{t}" CASCADE]
          ] do
        refused!(sql, [], sql)
      end

      assert snapshot(resource) == before, "#{t} changed"
    end
  end

  test "MacWorker: a disabled row cannot be updated; DELETE and TRUNCATE are refused",
       %{fx: fx} do
    life = rows!(fx)
    t = F.table(F.worker_resource())
    before = snapshot(F.worker_resource())
    id = F.dump(life.worker.id)

    refused!(~s[UPDATE "#{t}" SET status = 'active' WHERE id = $1], [id], "re-activate")
    refused!(~s[DELETE FROM "#{t}" WHERE id = $1], [id], "DELETE")
    refused!(~s[TRUNCATE "#{t}" CASCADE], [], "TRUNCATE")
    assert snapshot(F.worker_resource()) == before
  end
end
