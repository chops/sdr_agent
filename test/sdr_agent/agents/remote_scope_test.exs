defmodule SdrAgent.Agents.RemoteScopeTest do
  @moduledoc """
  S-B2 RED item 6 (entity/plan r2 6f0de674 Policy/Actor; Codex review
  2bddc465 must_fix 3; PASS ed0835d1 read-scope clarification).

  Contract specified here:

  - every action of the five new resources authorizes only with the
    domain-private RemoteCalls scope
    (`SdrAgent.Agents.Checks.RemoteCallsScope`): a direct Ash create,
    update, destroy, generic action or read by `%SdrAgent.Actor{type:
    :mac_worker}` (id and tenant equal to a real worker's) without that
    scope is denied (Forbidden, or a read that returns nothing);
  - RemoteCallResult has no external or unscoped read: admin, reviewer,
    auditor and auditor_cli reads return nothing or are Forbidden;
  - the scope has no public grant: it is process- and transaction-bound,
    entered in tests only through the test-seam-only
    `SdrAgent.Agents.RemoteCalls.__with_scope_for_test__/1`; a context
    captured inside it and reused after it returns, used from another
    process while it is open, or hand-built with a fresh ref is denied for
    a read and for the internal `:touch_last_seen` write;
  - the domain-private metadata read in the RemoteCalls scope returns the
    digest, size and ids, and its transcript field stays forbidden
    (`%Ash.ForbiddenField{}`) in S-B2;
  - the `:mac_worker` actor type grants nothing: it cannot reserve a model
    call, assign a lead or read runs.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  defp completed!(fx) do
    %{worker: worker, token: token} = F.enrol!(fx)
    F.reserve!(fx)
    nonce = F.nonce()
    launch = F.claim!(token, nonce)
    bytes = F.transcript("scope")

    assert F.kind(F.complete(token, nonce, launch.call_id, launch.request_sha256, bytes)) ==
             :accepted

    mac = struct(Actor, type: :mac_worker, id: worker.id, tenant_id: fx.tenant.id)

    # Loaded here, in the test process and before any seam opens, so a
    # Task's authority check needs no database connection.
    worker_row = Ash.get!(F.loaded!(F.worker_resource()), worker.id, authorize?: false)
    %{worker: worker, worker_row: worker_row, launch: launch, bytes: bytes, mac: mac}
  end

  defp any_row!(resource) do
    rows = Ash.read!(resource, authorize?: false)
    assert rows != [], "prerequisite: a #{inspect(resource)} row"
    hd(rows)
  end

  defp hidden?(result),
    do: result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)

  test "every action of each new resource is denied to a :mac_worker actor without the scope",
       %{fx: fx} do
    life = completed!(fx)

    for resource <- F.resources(),
        action <- Ash.Resource.Info.actions(F.loaded!(resource)) do
      label = "#{inspect(resource)}.#{action.name} (#{action.type})"

      case action.type do
        :read ->
          result = F.safely(fn -> Ash.read(resource, action: action.name, actor: life.mac) end)
          assert hidden?(result), "#{label}: read by :mac_worker: #{inspect(result)}"

        type when type in [:create, :action] ->
          refute Ash.can?({resource, action.name}, life.mac) == true, "#{label} allowed"

        type when type in [:update, :destroy] ->
          refute Ash.can?({any_row!(resource), action.name}, life.mac) == true, "#{label} allowed"
      end
    end
  end

  test "RemoteCallResult reads are denied to admin, reviewer, auditor and auditor_cli",
       %{fx: fx} do
    life = completed!(fx)
    result_resource = F.loaded!(F.result_resource())

    actors = [
      {:admin, human(:admin, fx.tenant)},
      {:reviewer, human(:reviewer, fx.tenant)},
      {:auditor, human(:auditor, fx.tenant)},
      {:auditor_cli, system_actor(:auditor_cli, fx.tenant)},
      {:mac_worker, life.mac}
    ]

    for {name, actor} <- actors,
        action <- Ash.Resource.Info.actions(result_resource),
        action.type == :read do
      result = F.safely(fn -> Ash.read(result_resource, action: action.name, actor: actor) end)
      assert hidden?(result), "#{name} #{action.name}: #{inspect(result)}"
    end
  end

  test "the scoped metadata read gives the digest, size and ids; the transcript stays forbidden",
       %{fx: fx} do
    life = completed!(fx)
    digest = :crypto.hash(:sha256, life.bytes)

    rows = F.with_scope(fn context -> scoped_rows(life, context) end)
    assert is_list(rows) and rows != [], "no scoped read returned the result: #{inspect(rows)}"

    for row <- rows do
      assert row.call_id == life.launch.call_id
      assert row.tenant_id == fx.tenant.id
      assert row.transcript_sha256 == digest
      assert row.byte_size == byte_size(life.bytes)

      assert match?(%Ash.ForbiddenField{}, row.transcript),
             "the transcript field is readable in the scope: #{inspect(row.transcript)}"
    end
  end

  ## The scope is process- and transaction-bound (no public grant)

  # Every row any read action of RemoteCallResult returns with `context`.
  defp scoped_rows(life, context) do
    result_resource = F.loaded!(F.result_resource())

    for action <- Ash.Resource.Info.actions(result_resource),
        action.type == :read,
        {:ok, rows} <- [
          F.safely(fn ->
            Ash.read(result_resource, action: action.name, actor: life.mac, context: context)
          end)
        ],
        row <- rows,
        do: row
  end

  # Every read action of RemoteCallResult with `context` is denied.
  defp assert_read_denied!(life, context, label) do
    result_resource = F.loaded!(F.result_resource())

    for action <- Ash.Resource.Info.actions(result_resource), action.type == :read do
      result =
        F.safely(fn ->
          Ash.read(result_resource, action: action.name, actor: life.mac, context: context)
        end)

      assert hidden?(result), "#{label}: #{action.name} read: #{inspect(result)}"
    end
  end

  defp touch(life, context) do
    worker = Ash.get!(F.loaded!(F.worker_resource()), life.worker.id, authorize?: false)

    F.safely(fn ->
      worker
      |> Ash.Changeset.for_update(:touch_last_seen, %{}, actor: life.mac, context: context)
      |> Ash.update()
    end)
  end

  # The internal :touch_last_seen write with `context` is Forbidden and writes nothing.
  defp assert_write_denied!(life, context, label) do
    before = F.rows(F.worker_resource(), "id = $1", [F.dump(life.worker.id)])
    result = touch(life, context)

    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "#{label}: :touch_last_seen: #{inspect(result)}"

    assert F.rows(F.worker_resource(), "id = $1", [F.dump(life.worker.id)]) == before,
           "#{label}: the worker row changed"
  end

  # Policy-only checks (no query), safe from a process without the connection.
  defp can_read?(life, context) do
    result_resource = F.loaded!(F.result_resource())

    # A query subject never strict-passes `Ash.can?/3` under
    # run_queries?: false (it reports :maybe), so ask for the altered query
    # and count only a pass that added no policy filter.
    Enum.any?(Ash.Resource.Info.actions(result_resource), fn action ->
      action.type == :read and
        (
          query =
            Ash.Query.for_read(result_resource, action.name, %{},
              actor: life.mac,
              context: context
            )

          case Ash.can(query, life.mac,
                 run_queries?: false,
                 maybe_is: false,
                 alter_source?: true
               ) do
            {:ok, true, %Ash.Query{filter: filter}} -> filter == query.filter
            _ -> false
          end
        )
    end)
  end

  defp can_touch?(life, context) do
    changeset =
      Ash.Changeset.for_update(life.worker_row, :touch_last_seen, %{},
        actor: life.mac,
        context: context
      )

    Ash.can?(changeset, life.mac, run_queries?: false, maybe_is: false) == true
  end

  test "a context captured inside with_scope and reused after it returns is denied", %{fx: fx} do
    life = completed!(fx)

    captured =
      F.with_scope(fn context ->
        assert scoped_rows(life, context) != [], "control: the open scope reads the result"
        context
      end)

    assert is_map(captured),
           "with_scope did not return the captured context: #{inspect(captured)}"

    assert_read_denied!(life, captured, "after with_scope")
    assert_write_denied!(life, captured, "after with_scope")
  end

  test "the captured context used from another process is denied while the seam is open",
       %{fx: fx} do
    life = completed!(fx)

    outcome =
      F.with_scope(fn context ->
        control = {can_read?(life, context), can_touch?(life, context)}

        other =
          fn -> {can_read?(life, context), can_touch?(life, context)} end
          |> Task.async()
          |> Task.yield(10_000)

        {control, other}
      end)

    assert match?({{true, true}, {:ok, _}}, outcome),
           "control: the owning process is allowed in the open seam: #{inspect(outcome)}"

    {_control, {:ok, other}} = outcome
    assert other == {false, false}, "another process used the captured scope: #{inspect(other)}"
  end

  test "a hand-built context with the same keys and a fresh ref is denied", %{fx: fx} do
    life = completed!(fx)

    {captured, inside} =
      F.with_scope(fn context ->
        forged = F.fresh_refs(context)
        {context, {can_read?(life, forged), can_touch?(life, forged)}}
      end)

    assert is_map(captured) and F.has_ref?(captured),
           "the scope context carries no reference: #{inspect(captured)}"

    forged = F.fresh_refs(captured)
    assert Map.keys(forged) == Map.keys(captured) and forged != captured

    assert inside == {false, false}, "a forged context passed inside the open seam"
    assert_read_denied!(life, forged, "forged")
    assert_write_denied!(life, forged, "forged")
  end

  test "the :mac_worker actor type cannot reserve, assign or read runs", %{fx: fx} do
    life = completed!(fx)

    reserve =
      F.safely(fn ->
        Agents.reserve_model_invocation(fx.run, SdrAgent.PrototypeGateFixtures.call_attrs(),
          actor: life.mac
        )
      end)

    assert match?({:error, %Ash.Error.Forbidden{}}, reserve), "reserve: #{inspect(reserve)}"

    lead = %SdrAgent.Sales.Lead{id: Ecto.UUID.generate(), tenant_id: fx.tenant.id}

    assign =
      F.safely(fn ->
        SdrAgent.SDR.assign_lead(lead, campaign_id: Ecto.UUID.generate(), actor: life.mac)
      end)

    assert match?({:error, %Ash.Error.Forbidden{}}, assign), "assign: #{inspect(assign)}"

    runs = F.safely(fn -> Ash.read(AgentRun, actor: life.mac) end)
    assert hidden?(runs), "read runs: #{inspect(runs)}"
  end
end
