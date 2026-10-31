defmodule SdrAgent.Agents.RemoteReservationTest do
  @moduledoc """
  S-B2 RED item 1 (entity/plan r2 6f0de674; plan P1; Codex PASS ed0835d1):
  the reservation creates the RemoteModelCall.

  Contract specified here:

  - under the trusted transport `:remote` (`Application` config
    `:sdr_agent, :model_transport`; never caller input; default local),
    `Agents.reserve_model_invocation/3` inserts exactly one
    `SdrAgent.Agents.RemoteModelCall` in the reservation's own transaction:
    state pending, the invocation's `request_sha256`, `profile_id` and
    `model_id`, `claim_deadline = reserved_at + 120 s`, no worker, no
    `claimed_at`, no `result_deadline`, the invocation's tenant;
  - an injected failure of the call insert (after the invocation insert)
    rolls back both rows;
  - transport `:local` creates no call;
  - under `:remote` a prompt over 262144 bytes, or a schema whose encoding
    is over 262144 bytes, is refused before admission: no invocation and
    no charge;
  - a later expiry never refunds the charge.

  Synthetic data only; no model, no CLI.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Clock
  alias SdrAgent.RemoteCallFixtures, as: F

  require Ash.Query

  @cap 262_144

  setup do
    fx = F.world!()
    %{fx: fx}
  end

  defp invocations(fx) do
    ModelInvocation
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  defp charged(fx) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^fx.grant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  defp inject_call_insert_failure! do
    table = F.table(F.call_resource())

    Repo.query!(
      """
      CREATE FUNCTION pg_temp.sdr_test_remote_call_fault() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'sb2 injected remote call insert failure';
      END $$ LANGUAGE plpgsql
      """,
      []
    )

    Repo.query!(
      "CREATE TRIGGER sdr_test_remote_call_fault BEFORE INSERT ON \"#{table}\" " <>
        "FOR EACH ROW EXECUTE FUNCTION pg_temp.sdr_test_remote_call_fault()",
      []
    )
  end

  describe "under :remote" do
    test "one pending RemoteModelCall is created with the invocation's digest, profile, model and claim deadline",
         %{fx: fx} do
      F.remote!()
      F.loaded!(F.call_resource())
      t0 = F.instant()
      Clock.freeze(t0)
      invocation = F.reserve!(fx)

      assert F.count(F.call_resource()) == 1, "exactly one RemoteModelCall per reservation"
      call = F.call_of(invocation.id)
      assert call, "no RemoteModelCall for the reserved invocation"

      assert call["state"] == "pending"
      assert F.load(call["tenant_id"]) == fx.tenant.id
      assert call["request_sha256"] == invocation.request_sha256
      assert call["profile_id"] == Atom.to_string(invocation.profile_id)
      assert call["model_id"] == invocation.model_id
      assert F.ts(call["claim_deadline"]) == DateTime.add(invocation.reserved_at, 120, :second)
      assert F.ts(call["claim_deadline"]) == DateTime.add(t0, 120, :second)
      assert call["worker_id"] == nil
      assert call["claimed_at"] == nil
      assert call["result_deadline"] == nil
    end

    test "an injected failure of the call insert rolls back the invocation too", %{fx: fx} do
      F.remote!()
      inject_call_insert_failure!()
      before = {invocations(fx), charged(fx)}

      result = F.reserve(fx)
      refute match?({:ok, _}, result), "the reservation committed without its call"
      assert {invocations(fx), charged(fx)} == before, "the invocation survived the call failure"
      assert F.count(F.call_resource()) == 0
    end

    test "a prompt over 262144 bytes is refused before admission with no charge", %{fx: fx} do
      F.remote!()
      before = {invocations(fx), charged(fx)}
      prompt = String.duplicate("p", @cap + 1)

      result = F.reserve(fx, %{request: F.request(prompt, F.schema())})
      refute match?({:ok, _}, result), "an over-cap prompt was reserved: #{inspect(result)}"
      assert match?({:error, _}, result), "expected a refusal, got #{inspect(result)}"
      assert {invocations(fx), charged(fx)} == before, "the over-cap prompt was charged"
    end

    test "a schema whose encoding is over 262144 bytes is refused before admission with no charge",
         %{fx: fx} do
      F.remote!()
      before = {invocations(fx), charged(fx)}
      schema = %{"type" => "object", "description" => String.duplicate("s", @cap + 1)}
      assert byte_size(Jason.encode!(schema)) > @cap

      result = F.reserve(fx, %{request: F.request(F.prompt(), schema)})
      refute match?({:ok, _}, result), "an over-cap schema was reserved: #{inspect(result)}"
      assert match?({:error, _}, result), "expected a refusal, got #{inspect(result)}"
      assert {invocations(fx), charged(fx)} == before, "the over-cap schema was charged"
    end

    test "the charge taken at reserve is never refunded by a later expiry", %{fx: fx} do
      F.remote!()
      %{token: token} = F.enrol!(fx)
      t0 = F.instant()
      Clock.freeze(t0)
      invocation = F.reserve!(fx)
      charged_after_reserve = charged(fx)
      assert charged_after_reserve >= 1

      nonce = F.nonce()
      Clock.freeze(DateTime.add(t0, 5, :second))
      launch = F.claim!(token, nonce)

      # The completion arrives at the result deadline: the call expires unknown.
      Clock.freeze(DateTime.add(t0, 5 + 600, :second))

      assert F.kind(
               F.complete(token, nonce, launch.call_id, launch.request_sha256, F.transcript())
             ) ==
               :late

      assert F.call_row(launch.call_id)["state"] == "expired_unknown"
      assert charged(fx) == charged_after_reserve, "the expiry refunded the charge"
      assert F.invocation(invocation.id).grant_id == fx.grant.id
    end
  end

  describe "under :local" do
    test "the reservation creates no RemoteModelCall", %{fx: fx} do
      F.remote!(:local)
      F.loaded!(F.call_resource())
      F.reserve!(fx)
      assert F.count(F.call_resource()) == 0
    end
  end
end
