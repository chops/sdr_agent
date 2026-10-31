defmodule SdrAgent.Agents.RemoteClaimTest do
  @moduledoc """
  S-B2 RED item 2 (entity/plan r2 6f0de674 "Contracts" claim; r4a C2;
  Codex PASS ed0835d1): `SdrAgent.Agents.RemoteCalls.claim(token, nonce,
  pins)`.

  Contract specified here:

  - a happy claim moves the call pending → claimed (worker, `claimed_at`,
    `result_deadline = claimed_at + 600 s`), the invocation reserved → sent
    (only inside the claim), inserts the ClaimNonce bound to the call, and
    returns the domain launch: call_id, profile_id, model_id,
    request_sha256, prompt, schema, result_deadline;
  - a same-nonce replay while claimed returns the same launch and acquires
    no new work; a nonce bound to a terminal call returns
    `{:ok, :none, state}`; a nonce that found no call returns `:none`
    forever, even once a pending call exists;
  - one claimed call per worker: a second nonce returns `:none` while one
    is claimed; the partial UNIQUE(worker_id) WHERE state = 'claimed' is
    present and enforced;
  - a past claim_deadline is not claimable;
  - a disabled worker, paused intake, a bad token, and a pin mismatch
    each refuse with no state change and no nonce;
  - a launch_check refusal rolls the claim back (the call is not claimed
    and no nonce is bound to it);
  - `Agents.admit_launch/3` on an invocation that has a RemoteModelCall
    returns `{:error, :remote_transport}` and writes nothing.

  Owner-run worker writes are made in ordinary runtime. Synthetic only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Clock
  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  defp nonce_rows(nonce), do: F.rows(F.nonce_resource(), "claim_nonce = $1", [nonce])

  defp sent_events(fx, invocation),
    do: F.subject_count(fx, "model.invocation.sent", invocation.id)

  defp assert_refused_nothing_written(result, fx, invocation, nonce, label) do
    refute match?({:ok, %{call_id: _}}, result), "#{label}: a launch was returned"
    assert match?({:error, _}, result), "#{label}: expected a refusal, got #{inspect(result)}"
    call = F.call_of(invocation.id)
    assert call, "#{label}: no RemoteModelCall for the invocation"
    assert call["state"] == "pending", "#{label}: the call changed"
    assert call["worker_id"] == nil
    assert nonce_rows(nonce) == [], "#{label}: a nonce was written"
    assert F.invocation(invocation.id).status == :reserved
    assert sent_events(fx, invocation) == 0
  end

  describe "a happy claim" do
    test "claims the call, sends the invocation, binds the nonce and returns the launch",
         %{fx: fx} do
      %{worker: worker, token: token} = F.enrol!(fx)
      t0 = F.instant()
      Clock.freeze(t0)
      invocation = F.reserve!(fx)
      t1 = DateTime.add(t0, 7, :second)
      Clock.freeze(t1)
      nonce = F.nonce()

      result = F.claim(token, nonce)
      assert match?({:ok, %{call_id: _}}, result), "claim: #{inspect(result)}"
      {:ok, launch} = result

      call = F.call_of(invocation.id)
      assert launch.call_id == F.load(call["id"])
      assert call["state"] == "claimed"
      assert F.load(call["worker_id"]) == worker.id
      assert F.ts(call["claimed_at"]) == t1
      assert F.ts(call["result_deadline"]) == DateTime.add(t1, 600, :second)

      assert launch.profile_id in [:claude_cli_opus, "claude_cli_opus"]
      assert launch.model_id == invocation.model_id
      assert launch.request_sha256 == invocation.request_sha256
      assert launch.prompt == F.prompt()
      assert launch.schema == F.schema()
      assert F.ts(launch.result_deadline) == DateTime.add(t1, 600, :second)

      sent = F.invocation(invocation.id)
      assert sent.status == :sent
      assert sent_events(fx, invocation) == 1

      assert [row] = nonce_rows(nonce)
      assert F.load(row["call_id"]) == launch.call_id
      assert F.load(row["worker_id"]) == worker.id
      assert F.load(row["tenant_id"]) == fx.tenant.id
    end
  end

  describe "nonce idempotency (C2)" do
    test "a same-nonce replay while claimed returns the same launch and acquires no new work",
         %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      first = F.reserve!(fx)
      second = F.reserve!(fx)
      nonce = F.nonce()
      launch = F.claim!(token, nonce)

      assert F.claim(token, nonce) == {:ok, launch}
      assert F.call_ids_in("claimed") == [launch.call_id], "the replay acquired new work"
      assert length(F.call_ids_in("pending")) == 1
      assert length(nonce_rows(nonce)) == 1
      assert sent_events(fx, first) + sent_events(fx, second) == 1
    end

    test "a nonce bound to a terminal call returns {:ok, :none, state}", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      F.reserve!(fx)
      F.reserve!(fx)
      nonce = F.nonce()
      launch = F.claim!(token, nonce)

      assert F.kind(
               F.complete(token, nonce, launch.call_id, launch.request_sha256, F.transcript())
             ) ==
               :accepted

      result = F.claim(token, nonce)

      assert match?({:ok, :none, state} when state in [:completed, "completed"], result),
             "terminal nonce replay: #{inspect(result)}"

      assert length(F.call_ids_in("pending")) == 1, "a terminal nonce acquired new work"
      assert F.call_ids_in("claimed") == []
    end

    test "a nonce that found no call returns :none forever", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      spent = F.nonce()
      assert F.claim(token, spent) == {:ok, :none}
      assert [row] = nonce_rows(spent)
      assert row["call_id"] == nil

      invocation = F.reserve!(fx)
      assert F.claim(token, spent) == {:ok, :none}
      assert F.call_of(invocation.id)["state"] == "pending"
      assert length(nonce_rows(spent)) == 1

      assert %{call_id: _} = F.claim!(token, F.nonce())
    end
  end

  describe "one claimed call per worker" do
    test "a second nonce returns :none while one call is claimed", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      F.reserve!(fx)
      F.reserve!(fx)
      launch = F.claim!(token, F.nonce())

      assert F.claim(token, F.nonce()) == {:ok, :none}
      assert F.call_ids_in("claimed") == [launch.call_id]
      assert length(F.call_ids_in("pending")) == 1
    end

    test "the partial unique index on worker_id WHERE state = 'claimed' is present and enforced",
         %{fx: fx} do
      %{worker: worker, token: token} = F.enrol!(fx)
      F.reserve!(fx)
      F.reserve!(fx)
      F.claim!(token, F.nonce())
      [pending] = F.call_ids_in("pending")
      table = F.table(F.call_resource())

      partial =
        Enum.filter(F.unique_indexes(table), fn {cols, pred} ->
          cols == ["worker_id"] and is_binary(pred) and pred =~ "claimed"
        end)

      assert partial != [], "indexes: #{inspect(F.unique_indexes(table))}"

      result =
        F.replica_error(
          ~s[UPDATE "#{table}" SET state = 'claimed', worker_id = $1 WHERE id = $2],
          [F.dump(worker.id), F.dump(pending)]
        )

      F.assert_pg!(result, :unique_violation, "a second claimed call for one worker")
    end
  end

  describe "refusals write nothing" do
    test "a past claim_deadline is not claimable", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      t0 = F.instant()
      Clock.freeze(t0)
      invocation = F.reserve!(fx)
      Clock.freeze(DateTime.add(t0, 120, :second))

      assert F.claim(token, F.nonce()) == {:ok, :none}
      assert F.call_of(invocation.id)["state"] == "pending"
      assert F.invocation(invocation.id).status == :reserved
    end

    test "a disabled worker is refused", %{fx: fx} do
      %{worker: worker, token: token} = F.enrol!(fx)
      F.disable!(fx, worker)
      invocation = F.reserve!(fx)
      nonce = F.nonce()
      assert_refused_nothing_written(F.claim(token, nonce), fx, invocation, nonce, "disabled")
    end

    test "paused intake is refused", %{fx: fx} do
      %{worker: worker, token: token} = F.enrol!(fx)
      F.set_intake!(fx, worker, :paused)
      invocation = F.reserve!(fx)
      nonce = F.nonce()
      assert_refused_nothing_written(F.claim(token, nonce), fx, invocation, nonce, "paused")
    end

    test "a bad token is refused", %{fx: fx} do
      F.enrol!(fx)
      invocation = F.reserve!(fx)
      nonce = F.nonce()
      bad = :crypto.strong_rand_bytes(32)
      assert_refused_nothing_written(F.claim(bad, nonce), fx, invocation, nonce, "bad token")
    end

    test "a pin mismatch is refused", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      invocation = F.reserve!(fx)
      nonce = F.nonce()
      pins = Map.put(F.pins(), "executable_sha256", F.hex(:crypto.hash(:sha256, "other")))
      assert_refused_nothing_written(F.claim(token, nonce, pins), fx, invocation, nonce, "pins")
    end

    test "a launch_check refusal rolls the claim back", %{fx: fx} do
      %{token: token} = F.enrol!(fx)
      invocation = F.reserve!(fx)
      # The promoted tuple is withdrawn after reservation: launch_check refuses.
      AdmissionFixtures.put_entries!([])
      nonce = F.nonce()

      result = F.claim(token, nonce)

      refute match?({:ok, %{call_id: _}}, result),
             "a refused launch was returned: #{inspect(result)}"

      call = F.call_of(invocation.id)
      assert call, "no RemoteModelCall for the invocation"
      refute call["state"] == "claimed", "the refused launch claimed the call"
      assert call["worker_id"] == nil

      assert Enum.all?(nonce_rows(nonce), &(&1["call_id"] == nil)),
             "a nonce was bound to the refused call"

      refute F.invocation(invocation.id).status == :sent
      assert sent_events(fx, invocation) == 0
    end
  end

  describe "the local launch path" do
    test "admit_launch on a remote invocation returns :remote_transport and writes nothing",
         %{fx: fx} do
      invocation = F.reserve!(fx)
      assert F.call_of(invocation.id), "no RemoteModelCall for the remote invocation"
      before = F.event_count(fx)

      result = Agents.admit_launch(invocation.id, invocation.profile_id, actor: fx.agent)
      assert result == {:error, :remote_transport}, "admit_launch: #{inspect(result)}"

      assert F.invocation(invocation.id).status == :reserved
      assert F.call_of(invocation.id)["state"] == "pending"
      assert F.event_count(fx) == before, "the refusal wrote an event"
    end
  end
end
