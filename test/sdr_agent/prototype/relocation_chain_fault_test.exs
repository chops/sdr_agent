defmodule SdrAgent.Prototype.RelocationChainFaultTest do
  @moduledoc """
  S-B1 RED r4 (Codex hold review 004447Z Pick1): a live-read fault at the
  relocation-chain reads, through a DISTINCT test-build seam label
  `:relocation_chain` of `SdrAgent.Prototype.Authority.TestSeam`, never
  hidden inside `:binding_read`.

  Contract specified here:

  - a nonempty chain is read in two statements: one on
    `prototype_relocations` and one on `prototype_relocation_events`. The
    seam names each read with its own raw label under the logical
    `:relocation_chain` label: `{:relocation_chain, :relocations}` and
    `{:relocation_chain, :events}`, accepted by `with_live_fault/3` and
    `live_fault_hits/1` and carried as the `d237_live_fault` telemetry tag
    of an injected `:abort`; the seam stays test-build-only and keeps S1's
    semantics (one claim per scope; `:returned_error` replaces the read's
    result, `:raise` raises in its place, `:abort` runs one tagged real
    `SELECT 1 / 0`, then the real read);
  - `check_live/0` fails closed on a synthetic fault at either read:
    `{:error, :binding_mismatch}`, with no SQL at the faulted read;
  - a reservation (`Agents.reserve_model_invocation/3`, the fence after
    `Kernel.lock_head/1`) fails closed on `:returned_error`, `:raise` and
    `:abort` at either read: no invocation, no charge, no reservation
    counter change and no `model.invocation.reserved` event; its
    transaction rolls back; after an `:abort` no business statement
    (INSERT, UPDATE, DELETE) runs between the tagged fault and the
    rollback; the connection then recovers and an unarmed reservation
    succeeds.

  The chain is one relocation with `planned` only (unfenced; spending is
  allowed without a fault). Chain writes are owner-run (the `:relocation`
  kernel marker) in ordinary runtime. Synthetic `.test` data only; no
  model call.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Prototype.Authority.TestSeam
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeGateFixtures, as: G

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @reads [:relocations, :events]
  @kinds [:returned_error, :raise, :abort]
  @sources %{relocations: "prototype_relocations", events: "prototype_relocation_events"}
  @refusal_types ["operations.failure.opened", "model.reservation.refused"]

  setup do
    fx = G.prototype!()
    run = G.run!(fx)
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    ctx = %{fx: fx, run: run, original: original, destination: destination}
    planned!(ctx)
    ctx
  end

  ## The chain (owner-run, ordinary runtime, then back in prototype runtime)

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  defp planned!(ctx) do
    loaded!(@relocation)
    loaded!(@event)
    assert PrototypeFixtures.leave_runtime() == :ok
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok

    created =
      @relocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          binding_id: ctx.fx.binding.id,
          relocation_seq: 1,
          from_identity: ctx.original,
          to_identity: ctx.destination
        },
        owner(ctx.fx)
      )
      |> Ash.create()

    assert match?({:ok, %{id: _}}, created),
           "prerequisite: relocation create: #{inspect(created)}"

    {:ok, relocation} = created

    appended =
      @event
      |> Ash.Changeset.for_create(
        :append,
        %{relocation_id: relocation.id, kind: :planned},
        owner(ctx.fx)
      )
      |> Ash.create()

    assert match?({:ok, %{id: _}}, appended), "prerequisite: append planned: #{inspect(appended)}"
    G.enter!(ctx.fx)
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
  end

  ## The seam, guarded: the `:relocation_chain` labels are absent before GREEN

  defp stage(read), do: {:relocation_chain, read}

  defp seam!(read) do
    loaded!(TestSeam)

    for {fun, arity} <- [with_live_fault: 3, live_fault_hits: 1] do
      assert function_exported?(TestSeam, fun, arity),
             "#{inspect(TestSeam)}.#{fun}/#{arity} is not exported"
    end

    try do
      Function.capture(TestSeam, :live_fault_hits, 1).(stage(read))
    rescue
      FunctionClauseError ->
        flunk("the live-fault seam has no #{inspect(stage(read))} label")
    end
  end

  defp fault(read, kind, fun) do
    seam!(read)

    Function.capture(TestSeam, :with_live_fault, 3).(stage(read), kind, fn ->
      result = fun.()
      {result, hits(read)}
    end)
  end

  defp hits(read), do: Function.capture(TestSeam, :live_fault_hits, 1).(stage(read))

  ## Statements (Repo telemetry of this process; closed labels only)

  defp kind("begin", _source, _options), do: :begin
  defp kind("commit", _source, _options), do: :commit
  defp kind("rollback", _source, _options), do: :rollback

  defp kind(query, source, options) do
    cond do
      Keyword.has_key?(options, :d237_live_fault) ->
        {:fault, options[:d237_live_fault], Repo.in_transaction?()}

      source == @sources.relocations ->
        {:read, :relocations}

      source == @sources.events ->
        {:read, :events}

      true ->
        {:other, verb(query)}
    end
  end

  defp verb(query) do
    case query
         |> String.trim_leading()
         |> String.split(" ", parts: 2)
         |> hd()
         |> String.upcase() do
      "SELECT" -> :select
      "INSERT" -> :insert
      "UPDATE" -> :update
      "DELETE" -> :delete
      _other -> :other
    end
  end

  defp code({:ok, _}), do: :ok
  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp code(_other), do: :error

  @doc false
  def handle_result(_event, _measurements, metadata, test) do
    if self() == test do
      options = Map.get(metadata, :options) || []
      row = {kind(metadata.query, metadata.source, options), code(metadata.result)}
      send(test, {:sb1_fault_query, row})
    end
  end

  defp raw(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:sdr_agent, :repo, :query], &__MODULE__.handle_result/4, self())

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(rows) do
    receive do
      {:sb1_fault_query, row} -> drain([row | rows])
    after
      0 -> Enum.reverse(rows)
    end
  end

  defp business?({{:other, verb}, _code}), do: verb in [:insert, :update, :delete]
  defp business?(_row), do: false

  # After the one tagged fault (inside a transaction): no business statement
  # before the first rollback, and a rollback follows.
  defp aborted_then_rolled_back!(rows, read) do
    tagged = stage(read)
    faults = Enum.filter(rows, &match?({{:fault, _, _}, _}, &1))
    assert faults == [{{:fault, tagged, true}, :division_by_zero}], "faults: #{inspect(faults)}"
    {_pre, [_fault | post]} = Enum.split_while(rows, &(not match?({{:fault, _, _}, _}, &1)))
    {before_rollback, rest} = Enum.split_while(post, &(elem(&1, 0) != :rollback))
    assert match?([{:rollback, :ok} | _], rest), "no rollback after the fault: #{inspect(post)}"

    writes = Enum.filter(before_rollback, &business?/1)
    assert writes == [], "business statements after the fault: #{inspect(writes)}"
  end

  # The events read follows a successful relocations read.
  defp earlier_reads!(rows, :events),
    do: assert({{:read, :relocations}, :ok} in rows, "the relocations read did not run")

  defp earlier_reads!(_rows, :relocations), do: :ok

  # `:abort` is the one tagged fault then no business statement before the
  # rollback; a synthetic kind runs no tagged fault.
  defp fault_trace!(rows, read, :abort), do: aborted_then_rolled_back!(rows, read)

  defp fault_trace!(rows, _read, _synthetic),
    do: refute(Enum.any?(rows, &match?({{:fault, _, _}, _}, &1)), "a tagged fault ran")

  # The first transaction of the call (the reservation's own) rolls back.
  defp first_transaction_rolled_back!(rows) do
    {_outside, from_begin} = Enum.split_while(rows, &(elem(&1, 0) != :begin))
    assert match?([{:begin, :ok} | _], from_begin), "no transaction: #{inspect(rows)}"

    ending =
      Enum.find(from_begin, &(elem(&1, 0) in [:commit, :rollback]))

    assert ending == {:rollback, :ok}, "the reservation's transaction ended #{inspect(ending)}"
  end

  ## State

  defp state(ctx) do
    run = Ash.get!(AgentRun, ctx.run.id, authorize?: false)

    %{
      invocations: G.invocations(ctx.fx),
      charged: G.charged(ctx.fx),
      reserved_calls: run.budget.model_calls_reserved,
      events: ctx.fx.tenant |> events() |> Enum.map(& &1.id)
    }
  end

  defp new_types(ctx, before) do
    ctx.fx.tenant
    |> events()
    |> Enum.reject(&(&1.id in before.events))
    |> Enum.map(& &1.event_type)
  end

  defp unspent!(ctx, before, label) do
    now = state(ctx)

    assert {now.invocations, now.charged, now.reserved_calls} ==
             {before.invocations, before.charged, before.reserved_calls},
           "#{label}: an invocation, charge or reservation was written"

    types = new_types(ctx, before)
    refute "model.invocation.reserved" in types, "#{label}: reserved event appended"
    assert types -- @refusal_types == [], "#{label}: events appended: #{inspect(types)}"
  end

  ## Controls (no fault)

  describe "no fault" do
    test "check_live/0 on a nonempty chain reads both chain tables, successfully", _ctx do
      {result, rows} = raw(&SdrAgent.Prototype.check_live/0)
      assert result == :ok, "check_live: #{inspect(result)}"
      reads = for {{:read, read}, code} <- rows, do: {read, code}
      assert {:relocations, :ok} in reads, "no relocations read: #{inspect(rows)}"
      assert {:events, :ok} in reads, "no relocation events read: #{inspect(rows)}"
    end

    test "a reservation on the unfenced nonempty chain succeeds", ctx do
      result = G.reserve(ctx.fx, ctx.run)
      assert match?({:ok, %ModelInvocation{}}, result), "reserve: #{inspect(result)}"
    end

    test "the :relocation_chain labels count no hit with no scope", _ctx do
      for read <- @reads do
        assert seam!(read) == 0, "#{inspect(stage(read))} counted a hit with no scope"
      end
    end
  end

  ## check_live/0: synthetic faults fail closed, with no SQL at the faulted read

  describe "check_live/0 under a chain-read fault" do
    for read <- @reads, kind <- [:returned_error, :raise] do
      test "#{read}/#{kind}: binding_mismatch, the faulted read never runs", _ctx do
        read = unquote(read)

        {{result, hits}, rows} =
          raw(fn -> fault(read, unquote(kind), &SdrAgent.Prototype.check_live/0) end)

        assert {result, hits} == {{:error, :binding_mismatch}, 1},
               "check_live: #{inspect({result, hits})}"

        refute Enum.any?(rows, &match?({{:read, ^read}, _}, &1)), "the faulted #{read} read ran"
        refute Enum.any?(rows, &match?({{:fault, _, _}, _}, &1)), "a tagged fault ran"

        earlier_reads!(rows, read)

        assert SdrAgent.Prototype.check_live() == :ok, "#{read}/#{unquote(kind)}: scope outlived"
      end
    end
  end

  ## The reservation: every kind at either read fails closed and rolls back

  describe "a reservation under a chain-read fault" do
    for read <- @reads, kind <- @kinds do
      test "#{read}/#{kind}: no invocation, no charge, rolled back", ctx do
        read = unquote(read)
        kind = unquote(kind)
        before = state(ctx)

        {{result, hits}, rows} =
          raw(fn -> fault(read, kind, fn -> G.reserve(ctx.fx, ctx.run) end) end)

        assert hits == 1, "#{read}/#{kind}: the fault did not fire (hits #{hits})"
        refute match?({:ok, _}, result), "#{read}/#{kind}: reserved: #{inspect(result)}"
        unspent!(ctx, before, "#{read}/#{kind}")
        first_transaction_rolled_back!(rows)

        fault_trace!(rows, read, kind)

        # Recovery: the connection is usable and an unarmed reservation spends.
        assert match?({:ok, _}, Repo.query("SELECT 1", [])), "the connection did not recover"
        again = G.reserve(ctx.fx, ctx.run)

        assert match?({:ok, %ModelInvocation{}}, again),
               "#{read}/#{kind}: the next reservation: #{inspect(again)}"
      end
    end
  end
end
