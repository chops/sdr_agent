defmodule SdrAgent.Agents.ResultGateWaitTest do
  @moduledoc """
  R0-07 slice C, REQ-07-4 "The wait" (packet section 2, step 2): after a
  call is validated and stored, the gate reconciles that invocation
  in-process (`ResultGate.await/3`), polling `Witness.reconcile/2` with
  `gate:` until the outcome settles or a bounded deadline passes. No lock
  or transaction of its own is held while it waits (it refuses to start
  inside one). The bound defaults to 120 s and configuration may only lower
  it.

  Settled: reconciled, mismatch, an unreadable or unconfigured store, or
  any other final classification. Pending (keep waiting): no exchange yet,
  an open exchange, an incomplete capture.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)
    root = GateFixtures.root!()
    config = Application.get_env(:sdr_agent, ResultGate)

    on_exit(fn ->
      File.rm_rf!(root)

      if config,
        do: Application.put_env(:sdr_agent, ResultGate, config),
        else: Application.delete_env(:sdr_agent, ResultGate)
    end)

    Application.put_env(:sdr_agent, ResultGate, wait_ms: 400, poll_ms: 25)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      operation: operation,
      root: root,
      gate: %{run_id: run.id, operation_id: operation.id}
    }
  end

  defp await(ctx, invocation, opts \\ []),
    do: ResultGate.await(invocation, ctx.gate, [store_root: ctx.root] ++ opts)

  describe "the bound" do
    test "defaults to 120 s; configuration may only lower it" do
      Application.delete_env(:sdr_agent, ResultGate)
      assert ResultGate.wait_ms() == 120_000

      for {configured, effective} <- [{500, 500}, {120_000, 120_000}, {999_999, 120_000}] do
        Application.put_env(:sdr_agent, ResultGate, wait_ms: configured)
        assert ResultGate.wait_ms() == effective, inspect(configured)
      end

      for bad <- [0, -1, "10", nil] do
        Application.put_env(:sdr_agent, ResultGate, wait_ms: bad)
        assert ResultGate.wait_ms() == 120_000, inspect(bad)
      end
    end
  end

  describe "settled outcomes return at once" do
    test "a reconciled exchange", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")

      assert {:ok, %{status: :reconciled, link_id: link_id, cause_id: nil}} =
               await(ctx, invocation, methods: [:propagated_id])

      assert is_binary(link_id)
    end

    test "a mismatch, with its gate cause", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
      assert {:ok, %{status: :mismatch, cause_id: cause_id}} = await(ctx, invocation)
      assert is_binary(cause_id)
    end

    test "an unconfigured store", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")

      assert {:ok, %{status: :skipped}} =
               ResultGate.await(invocation, ctx.gate, store_root: nil)
    end
  end

  describe "pending outcomes" do
    test "a missing exchange waits for the bound, then times out with its receipt", ctx do
      invocation = GateFixtures.call_model!(ctx, "none")
      started = System.monotonic_time(:millisecond)

      assert {:timeout, %{status: :unwitnessed, cause_id: cause_id}} = await(ctx, invocation)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 400 and elapsed < 4_000, inspect(elapsed)
      assert is_binary(cause_id)
    end

    test "a capture that appears during the wait settles it before the bound", ctx do
      Application.put_env(:sdr_agent, ResultGate, wait_ms: 10_000, poll_ms: 25)
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
      records = Path.join([ctx.root, "witnesses", invocation.id])
      held = Path.join(ctx.root, "held-" <> invocation.id)
      File.rename!(records, held)

      Task.start(fn ->
        Process.sleep(200)
        File.rename!(held, records)
      end)

      started = System.monotonic_time(:millisecond)
      assert {:ok, %{status: :mismatch}} = await(ctx, invocation)
      assert System.monotonic_time(:millisecond) - started < 10_000
    end
  end

  test "the wait refuses to start inside a transaction (no lock held while waiting)", ctx do
    invocation = GateFixtures.call_model!(ctx, "none")

    assert {:ok, {:error, :in_transaction}} =
             Repo.transaction(fn -> await(ctx, invocation) end)
  end

  test "the gate must be the invocation's own", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")
    %{run: other} = AgentsFixtures.operated_run(ctx.tenant)

    assert {:error, :invalid_gate} =
             ResultGate.await(invocation, %{ctx.gate | run_id: other.id}, store_root: ctx.root)
  end
end
