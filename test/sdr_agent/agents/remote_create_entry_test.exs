defmodule SdrAgent.Agents.RemoteCreateEntryTest do
  @moduledoc """
  S-B2 RED addendum A (Codex 2026-10-31 B2 GO, correlation
  m_1793429567352697084_19d14d30): regression coverage of the single
  RemoteModelCall create entry. The helper fix already exists, so these
  tests are regression coverage, not fresh RED evidence.

  Contract specified here:

  - `SdrAgent.Agents.RemoteCalls.create_for_reservation/2` is not exported
    (the removed direct helper; no export-name prefix rule);
  - `SdrAgent.Agents.Changes.CreateRemoteCall.with_reservation/1` with no
    `:reserve` inside creates no RemoteModelCall, even when its body
    attempts the create with the bound reservation reference: invocation,
    call and AuditEvent counts are unchanged;
  - after a local-transport reservation, a `RemoteModelCall :create` for
    that invocation under the generic RemoteCalls scope (the test seam) is
    `Ash.Error.Forbidden`, and invocation, call and AuditEvent counts are
    unchanged.

  Synthetic data only; no model, no CLI, no network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.Changes.CreateRemoteCall
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.RemoteCalls
  alias SdrAgent.RemoteCallFixtures, as: F

  require Ash.Query

  # The reservation scope's process key (CreateRemoteCall's @key).
  @reservation_key :sdr_agent_remote_reservation_scope

  setup do
    fx = F.world!()
    %{fx: fx}
  end

  defp invocations(fx) do
    ModelInvocation
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  defp counts(fx), do: {invocations(fx), F.count(F.call_resource()), F.event_count(fx)}

  defp call_attrs(invocation) do
    %{
      model_invocation_id: invocation.id,
      request_sha256: invocation.request_sha256,
      profile_id: invocation.profile_id,
      model_id: invocation.model_id,
      claim_deadline: DateTime.add(invocation.reserved_at, 120, :second)
    }
  end

  defp create_call(fx, invocation, context) do
    F.safely(fn ->
      F.loaded!(F.call_resource())
      |> Ash.Changeset.for_create(:create, call_attrs(invocation),
        actor: fx.agent,
        context: context
      )
      |> Ash.create()
    end)
  end

  test "RemoteCalls.create_for_reservation/2 is not exported" do
    F.loaded!(RemoteCalls)

    refute function_exported?(RemoteCalls, :create_for_reservation, 2),
           "the removed direct helper RemoteCalls.create_for_reservation/2 is exported"
  end

  test "with_reservation/1 with no :reserve inside creates no RemoteModelCall", %{fx: fx} do
    F.remote!(:local)
    invocation = F.reserve!(fx)
    F.remote!()
    before = counts(fx)

    result =
      CreateRemoteCall.with_reservation(fn ->
        Repo.transaction(fn ->
          bound = Process.get(@reservation_key)
          assert is_map(bound), "prerequisite: with_reservation binds no scope: #{inspect(bound)}"
          create_call(fx, invocation, %{@reservation_key => bound.ref})
        end)
      end)

    refute match?({:ok, {:ok, _}}, result),
           "a RemoteModelCall was created without a :reserve: #{inspect(result)}"

    assert counts(fx) == before,
           "with_reservation without a :reserve changed {invocations, calls, events}"
  end

  test "a local-transport reservation cannot gain a RemoteModelCall under the generic RemoteCalls scope",
       %{fx: fx} do
    F.remote!(:local)
    invocation = F.reserve!(fx)
    assert F.call_of(invocation.id) == nil, "prerequisite: the local reservation created a call"
    F.remote!()
    before = counts(fx)

    result = F.with_scope(fn context -> create_call(fx, invocation, context) end)

    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "RemoteModelCall :create under the generic scope: #{inspect(result)}"

    assert counts(fx) == before,
           "the generic-scope create changed {invocations, calls, events}"

    assert F.call_of(invocation.id) == nil
  end
end
