defmodule SdrAgent.Agents.RemoteCompleteTest do
  @moduledoc """
  S-B2 RED item 3 (entity/plan r2 6f0de674 "Contracts" complete; r4a C3;
  Codex PASS ed0835d1): `SdrAgent.Agents.RemoteCalls.complete(token,
  nonce, call_id, request_digest, transcript)`.

  Contract specified here:

  - accepted: one RemoteCallResult (the bytes, `transcript_sha256` computed
    on the server, `byte_size`), the call claimed → completed and an
    `:accepted` receipt;
  - after completion, the same bytes are `:duplicate_same` and different
    bytes are `:conflict` (the domain-private scoped digest comparison);
    the first result and the state never change;
  - now ≥ result_deadline: claimed → expired_unknown with a `:late`
    receipt and no result; a completion on an expired call is `:late` only;
  - a disabled worker still authenticates: `:refused_disabled` on its
    claimed call (state unchanged) while its claim and heartbeat are refused;
  - a wrong request_digest, or a foreign call_id (another call, another
    tenant's included), is `:refused_mismatch` on the NONCE's call only;
    the foreign call gets no receipt and its row is neither locked nor
    written; the first result, the call and the charge are unchanged;
  - an unknown nonce, or a nonce spent with no call, is refused with no
    receipt;
  - a transcript over 2097152 bytes is refused with no receipt;
  - receipt positions are 1..n, gap-free, and UNIQUE(call_id, position)
    is present and enforced.

  Synthetic data only; no model, no CLI.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Clock
  alias SdrAgent.RemoteCallFixtures, as: F

  require Ash.Query

  @max 2_097_152

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  # The new contract (MacWorker, reservation call, claim) in the test body.
  defp claimed!(%{fx: fx}) do
    %{worker: worker, token: token} = F.enrol!(fx)
    t0 = F.instant()
    Clock.freeze(t0)
    invocation = F.reserve!(fx)
    t1 = DateTime.add(t0, 3, :second)
    Clock.freeze(t1)
    nonce = F.nonce()
    launch = F.claim!(token, nonce)

    %{
      fx: fx,
      worker: worker,
      token: token,
      invocation: invocation,
      nonce: nonce,
      launch: launch,
      t1: t1
    }
  end

  defp complete(ctx, bytes, overrides \\ []) do
    F.complete(
      Keyword.get(overrides, :token, ctx.token),
      Keyword.get(overrides, :nonce, ctx.nonce),
      Keyword.get(overrides, :call_id, ctx.launch.call_id),
      Keyword.get(overrides, :digest, ctx.launch.request_sha256),
      bytes
    )
  end

  defp results(call_id), do: F.rows(F.result_resource(), "call_id = $1", [F.dump(call_id)])

  defp kinds(call_id), do: Enum.map(F.receipts(call_id), & &1["kind"])

  defp charged(fx) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^fx.grant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  defp accepted!(ctx, bytes \\ F.transcript()) do
    assert F.kind(complete(ctx, bytes)) == :accepted
    assert [result] = results(ctx.launch.call_id)
    result
  end

  describe "accepted" do
    test "stores the result with the server digest, completes the call and appends :accepted",
         ctx do
      ctx = claimed!(ctx)
      bytes = F.transcript()
      assert F.kind(complete(ctx, bytes)) == :accepted

      assert [result] = results(ctx.launch.call_id)
      assert result["transcript"] == bytes
      assert result["transcript_sha256"] == :crypto.hash(:sha256, bytes)
      assert result["byte_size"] == byte_size(bytes)
      assert F.load(result["tenant_id"]) == ctx.fx.tenant.id

      assert F.call_row(ctx.launch.call_id)["state"] == "completed"
      assert [receipt] = F.receipts(ctx.launch.call_id)
      assert receipt["kind"] == "accepted"
      assert receipt["transcript_sha256"] == :crypto.hash(:sha256, bytes)
      assert receipt["position"] == 1
    end
  end

  describe "after completion" do
    test "the same bytes are :duplicate_same and change nothing", ctx do
      ctx = claimed!(ctx)
      bytes = F.transcript()
      first = accepted!(ctx, bytes)

      assert F.kind(complete(ctx, bytes)) == :duplicate_same
      assert results(ctx.launch.call_id) == [first]
      assert F.call_row(ctx.launch.call_id)["state"] == "completed"
      assert kinds(ctx.launch.call_id) == ["accepted", "duplicate_same"]
    end

    test "different bytes are :conflict and the first result is unchanged", ctx do
      ctx = claimed!(ctx)
      first = accepted!(ctx, F.transcript("first"))

      assert F.kind(complete(ctx, F.transcript("second"))) == :conflict
      assert results(ctx.launch.call_id) == [first]
      assert F.call_row(ctx.launch.call_id)["state"] == "completed"
      assert kinds(ctx.launch.call_id) == ["accepted", "conflict"]

      [_, conflict] = F.receipts(ctx.launch.call_id)
      assert conflict["transcript_sha256"] == :crypto.hash(:sha256, F.transcript("second"))
    end
  end

  describe "the result deadline" do
    test "now >= result_deadline expires the call unknown with a :late receipt and no result",
         ctx do
      ctx = claimed!(ctx)
      Clock.freeze(DateTime.add(ctx.t1, 600, :second))

      assert F.kind(complete(ctx, F.transcript())) == :late
      assert F.call_row(ctx.launch.call_id)["state"] == "expired_unknown"
      assert results(ctx.launch.call_id) == []
      assert kinds(ctx.launch.call_id) == ["late"]
    end

    test "a completion on an expired call appends :late only", ctx do
      ctx = claimed!(ctx)
      Clock.freeze(DateTime.add(ctx.t1, 600, :second))
      assert F.kind(complete(ctx, F.transcript())) == :late
      Clock.freeze(DateTime.add(ctx.t1, 601, :second))

      assert F.kind(complete(ctx, F.transcript())) == :late
      assert F.call_row(ctx.launch.call_id)["state"] == "expired_unknown"
      assert results(ctx.launch.call_id) == []
      assert kinds(ctx.launch.call_id) == ["late", "late"]
    end
  end

  describe "a disabled worker" do
    test "authenticates for complete (:refused_disabled, state unchanged); claim and heartbeat are refused",
         ctx do
      ctx = claimed!(ctx)
      F.disable!(ctx.fx, ctx.worker)

      assert F.kind(complete(ctx, F.transcript())) == :refused_disabled
      assert F.call_row(ctx.launch.call_id)["state"] == "claimed"
      assert results(ctx.launch.call_id) == []
      assert kinds(ctx.launch.call_id) == ["refused_disabled"]

      claim = F.claim(ctx.token, F.nonce())
      assert match?({:error, _}, claim), "a disabled worker claimed: #{inspect(claim)}"
      heartbeat = F.heartbeat(ctx.token)

      assert match?({:error, _}, heartbeat),
             "a disabled worker's heartbeat: #{inspect(heartbeat)}"
    end
  end

  describe "mismatch" do
    test "a wrong request_digest is :refused_mismatch on the nonce's call before acceptance",
         ctx do
      ctx = claimed!(ctx)
      wrong = F.other_digest(ctx.launch.request_sha256)

      assert F.kind(complete(ctx, F.transcript(), digest: wrong)) == :refused_mismatch
      assert F.call_row(ctx.launch.call_id)["state"] == "claimed"
      assert results(ctx.launch.call_id) == []
      assert kinds(ctx.launch.call_id) == ["refused_mismatch"]
    end

    test "a wrong request_digest after acceptance leaves the first result, call and charge unchanged",
         ctx do
      ctx = claimed!(ctx)
      first = accepted!(ctx)
      call = F.call_row(ctx.launch.call_id)
      charge = charged(ctx.fx)
      wrong = F.other_digest(ctx.launch.request_sha256)

      assert F.kind(complete(ctx, F.transcript("x"), digest: wrong)) == :refused_mismatch
      assert results(ctx.launch.call_id) == [first]
      assert F.call_row(ctx.launch.call_id) == call
      assert charged(ctx.fx) == charge
      assert kinds(ctx.launch.call_id) == ["accepted", "refused_mismatch"]
    end

    test "a foreign call_id is :refused_mismatch on the nonce's call; the foreign rows are untouched",
         ctx do
      ctx = claimed!(ctx)
      other = F.reserve!(ctx.fx)
      same_tenant = F.load(F.call_of(other.id)["id"])
      foreign_tenant = Ecto.UUID.generate()

      assert :ok ==
               F.copy_insert(
                 F.call_resource(),
                 "id = $1",
                 [F.dump(same_tenant)],
                 [
                   {"id", F.dump(foreign_tenant)},
                   {"tenant_id", F.dump(Ecto.UUID.generate())},
                   {"model_invocation_id", F.dump(Ecto.UUID.generate())}
                 ],
                 replica: true
               )

      charge = charged(ctx.fx)

      for foreign <- [same_tenant, foreign_tenant] do
        before = {F.call_row(foreign), F.xmax(F.call_resource(), foreign)}

        assert F.kind(complete(ctx, F.transcript(), call_id: foreign)) == :refused_mismatch,
               "foreign #{foreign}"

        assert F.receipts(foreign) == [], "the foreign call #{foreign} got a receipt"

        assert {F.call_row(foreign), F.xmax(F.call_resource(), foreign)} == before,
               "the foreign call #{foreign} was locked or written"
      end

      assert kinds(ctx.launch.call_id) == ["refused_mismatch", "refused_mismatch"]
      assert F.call_row(ctx.launch.call_id)["state"] == "claimed"
      assert results(ctx.launch.call_id) == []
      assert charged(ctx.fx) == charge
    end
  end

  describe "refused with no receipt" do
    test "an unknown nonce is refused with no receipt", ctx do
      ctx = claimed!(ctx)
      result = complete(ctx, F.transcript(), nonce: F.nonce())
      assert match?({:error, _}, result), "unknown nonce: #{inspect(result)}"
      refute F.kind(result) in [:accepted, :refused_mismatch]
      assert F.count(F.receipt_resource()) == 0
      assert F.call_row(ctx.launch.call_id)["state"] == "claimed"
    end

    test "a nonce spent with no call is refused with no receipt", ctx do
      ctx = claimed!(ctx)
      spent = F.nonce()
      assert F.claim(ctx.token, spent) == {:ok, :none}

      result = complete(ctx, F.transcript(), nonce: spent)
      assert match?({:error, _}, result), "null-call nonce: #{inspect(result)}"
      refute F.kind(result) in [:accepted, :refused_mismatch]
      assert F.count(F.receipt_resource()) == 0
    end

    test "a transcript over 2097152 bytes is refused with no receipt", ctx do
      ctx = claimed!(ctx)
      result = complete(ctx, :binary.copy("t", @max + 1))
      assert match?({:error, _}, result), "over-cap transcript: #{inspect(result)}"
      refute F.kind(result) in [:accepted, :refused_mismatch]
      assert F.count(F.receipt_resource()) == 0
      assert results(ctx.launch.call_id) == []
      assert F.call_row(ctx.launch.call_id)["state"] == "claimed"
    end
  end

  describe "receipt positions" do
    test "are 1..n, gap-free, under UNIQUE(call_id, position)", ctx do
      ctx = claimed!(ctx)
      wrong = F.other_digest(ctx.launch.request_sha256)
      assert F.kind(complete(ctx, F.transcript(), digest: wrong)) == :refused_mismatch
      accepted!(ctx, F.transcript("p"))
      assert F.kind(complete(ctx, F.transcript("p"))) == :duplicate_same
      assert F.kind(complete(ctx, F.transcript("q"))) == :conflict

      positions = Enum.map(F.receipts(ctx.launch.call_id), & &1["position"])
      assert positions == [1, 2, 3, 4]

      table = F.table(F.receipt_resource())

      assert Enum.any?(F.unique_indexes(table), fn {cols, pred} ->
               cols == ["call_id", "position"] and pred == nil
             end),
             "indexes: #{inspect(F.unique_indexes(table))}"

      [first | _] = F.receipts(ctx.launch.call_id)

      result =
        F.copy_insert(F.receipt_resource(), "id = $1", [first["id"]], [
          {"id", F.dump(Ecto.UUID.generate())}
        ])

      F.assert_pg!(result, :unique_violation, "a duplicate (call_id, position)")
    end
  end
end
