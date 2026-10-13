defmodule SdrAgent.Agents.ReleasePrelockedTest do
  @moduledoc """
  R0-07 slice A round 5, contract (d), slice-A half (packet section 5.2;
  PASS clarification 4): the private, transaction-scoped prelocked
  decision context `SdrAgent.Agents.ReleaseDecision.Prelocked`.

  The finalizer (R0-07 slice C; stood in for here) takes every dependent
  lock before the chain head, then decides inside `Prelocked.run/2`. The
  context is accepted only in its own process and transaction, while
  registered, and when tenant, invocation, link and receipt all equal the
  registered bindings. A hand-built, mismatched, leaked or stale context is
  refused with no row and no event. The prelocked path requests no lock
  after the head; standalone decide locks invocation then link `FOR SHARE`
  before the head and never takes the no-lock path. Slice C adds the
  whole-finalization order regression.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations

  @locks ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    invocation = AgentsFixtures.claude_completed!(run, agent, "pl-1")
    other = AgentsFixtures.claude_completed!(run, agent, "pl-2")

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: rec,
      invocation: invocation,
      link: AgentsFixtures.reconciled_link!(invocation, rec),
      other: other,
      other_link: AgentsFixtures.reconciled_link!(other, rec)
    }
  end

  defp released(invocation, link),
    do: %{
      model_invocation_id: invocation.id,
      disposition: :released,
      reason: :reconciled,
      wire_witness_link_id: link.id
    }

  defp bindings(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: ctx.tenant.id,
        model_invocation_id: ctx.invocation.id,
        wire_witness_link_id: ctx.link.id,
        receipt_id: nil
      },
      Map.new(overrides)
    )
  end

  defp lock!(resource, id, tenant_id, mode) do
    {:ok, %{}} =
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(mode)
      |> Ash.read_one()
  end

  # A finalizer stand-in: dependent locks, then the head, then `fun`.
  defp finalize(ctx, fun) do
    Audit.transaction(fn ->
      lock!(ModelInvocation, ctx.invocation.id, ctx.tenant.id, "FOR SHARE")
      lock!(WireWitnessLink, ctx.link.id, ctx.tenant.id, "FOR SHARE")
      {:ok, _head} = Kernel.lock_head(ctx.tenant.id)

      case fun.() do
        {:ok, value} -> value
        {:error, error} -> Repo.rollback(error)
        other -> other
      end
    end)
  end

  defp nothing_written(ctx) do
    {:ok, rows} = Agents.list_result_releases(actor: system_actor(:auditor_cli, ctx.tenant))
    assert rows == []
    assert Enum.filter(events(ctx.tenant), &(&1.event_type =~ "model.result.")) == []
  end

  # Every SQL statement this process sends while `fun` runs.
  defp capture(fun) do
    handler = "pl-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if self() == me, do: send(me, {:sql, meta.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(acc) do
    receive do
      {:sql, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp head?(sql), do: sql =~ "audit_chain_heads" and sql =~ @locks
  defp lock?(sql), do: sql =~ @locks

  defp first_index(queries, predicate),
    do: Enum.find_index(queries, predicate) || flunk("missing: #{inspect(queries)}")

  describe "the prelocked path" do
    test "a registered, matching context decides with no lock after the head", ctx do
      {result, queries} =
        capture(fn ->
          finalize(ctx, fn ->
            Prelocked.run(bindings(ctx), fn prelocked ->
              Agents.decide_result_release(released(ctx.invocation, ctx.link),
                actor: ctx.agent,
                prelocked: prelocked
              )
            end)
          end)
        end)

      assert {:ok, %{disposition: :released}} = result
      head = first_index(queries, &head?/1)

      after_head = Enum.drop(queries, head + 1)
      assert Enum.reject(Enum.filter(after_head, &lock?/1), &head?/1) == [], inspect(after_head)
    end

    test "the receipt must be this invocation's reconciliation cause", ctx do
      {:ok, cause} =
        Operations.open_failure(
          %{
            subject_resource: "SdrAgent.Agents.ModelInvocation",
            subject_id: ctx.invocation.id,
            class: :reconciliation_required,
            severity: :warning,
            message: "wire witness test: model invocation needs operator review",
            retryable: false
          },
          actor: ctx.rec
        )

      {:ok, foreign} =
        Operations.open_failure(
          %{
            subject_resource: "SdrAgent.Agents.ModelInvocation",
            subject_id: ctx.other.id,
            class: :reconciliation_required,
            severity: :warning,
            message: "wire witness test: model invocation needs operator review",
            retryable: false
          },
          actor: ctx.rec
        )

      attrs = %{
        model_invocation_id: ctx.invocation.id,
        disposition: :withheld,
        reason: :witness_timeout
      }

      decide = fn receipt ->
        finalize(ctx, fn ->
          Prelocked.run(bindings(ctx, receipt_id: receipt, wire_witness_link_id: nil), fn pl ->
            Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: pl)
          end)
        end)
      end

      for receipt <- [foreign.id, Ecto.UUID.generate()] do
        assert {:error, _} = decide.(receipt)
      end

      nothing_written(ctx)
      assert {:ok, %{disposition: :withheld}} = decide.(cause.id)
    end
  end

  describe "refused contexts (no row, no event)" do
    test "a hand-built context is refused", ctx do
      forged =
        struct(Prelocked, Map.merge(bindings(ctx), %{ref: make_ref(), xact_id: "1"}))

      # Inside the finalizer's transaction a refused action rolls it back.
      assert {:error, _} =
               finalize(ctx, fn ->
                 Agents.decide_result_release(released(ctx.invocation, ctx.link),
                   actor: ctx.agent,
                   prelocked: forged
                 )
               end)

      nothing_written(ctx)
    end

    test "a context is refused for another invocation, link or tenant", ctx do
      for {label, attrs, overrides} <- [
            {"other invocation", released(ctx.other, ctx.other_link), %{}},
            {"other link", released(ctx.invocation, ctx.other_link), %{}},
            {"other tenant", released(ctx.invocation, ctx.link),
             %{tenant_id: Ecto.UUID.generate()}}
          ] do
        result =
          finalize(ctx, fn ->
            Prelocked.run(bindings(ctx, overrides), fn pl ->
              Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: pl)
            end)
          end)

        assert {:error, _} = result, label
      end

      nothing_written(ctx)
    end

    test "a tampered copy of a registered context is refused", ctx do
      result =
        finalize(ctx, fn ->
          Prelocked.run(bindings(ctx), fn pl ->
            tampered = %{
              pl
              | model_invocation_id: ctx.other.id,
                wire_witness_link_id: ctx.other_link.id
            }

            Agents.decide_result_release(released(ctx.other, ctx.other_link),
              actor: ctx.agent,
              prelocked: tampered
            )
          end)
        end)

      assert {:error, _} = result
      nothing_written(ctx)
    end

    test "a context leaked out of its scope or transaction is refused", ctx do
      {:ok, leaked} =
        Audit.transaction(fn -> Prelocked.run(bindings(ctx), fn pl -> pl end) end)

      # After its transaction, and inside a later one.
      assert {:error, _} =
               Agents.decide_result_release(released(ctx.invocation, ctx.link),
                 actor: ctx.agent,
                 prelocked: leaked
               )

      assert {:error, _} =
               finalize(ctx, fn ->
                 Agents.decide_result_release(released(ctx.invocation, ctx.link),
                   actor: ctx.agent,
                   prelocked: leaked
                 )
               end)

      # Leaked out of its scope within the same transaction.
      assert {:error, _} =
               finalize(ctx, fn ->
                 pl = Prelocked.run(bindings(ctx), fn pl -> pl end)

                 Agents.decide_result_release(released(ctx.invocation, ctx.link),
                   actor: ctx.agent,
                   prelocked: pl
                 )
               end)

      nothing_written(ctx)
    end

    test "a context cannot be established outside a transaction", ctx do
      assert {:error, :not_in_transaction} = Prelocked.run(bindings(ctx), fn pl -> pl end)
    end

    test "a context is refused in another process", ctx do
      result =
        finalize(ctx, fn ->
          Prelocked.run(bindings(ctx), fn pl ->
            {:ok, Task.await(Task.async(fn -> Prelocked.verify(pl) end))}
          end)
        end)

      assert {:ok, {:error, _}} = result
    end
  end

  test "standalone decide locks invocation, then link, before the head; nothing after", ctx do
    {result, queries} =
      capture(fn ->
        Agents.decide_result_release(released(ctx.invocation, ctx.link), actor: ctx.agent)
      end)

    assert {:ok, %{disposition: :released}} = result
    invocation = first_index(queries, &(&1 =~ ~s("model_invocations") and &1 =~ "FOR SHARE"))
    link = first_index(queries, &(&1 =~ ~s("wire_witness_links") and &1 =~ "FOR SHARE"))
    head = first_index(queries, &head?/1)

    assert invocation < link and link < head, inspect(queries)
    after_head = Enum.drop(queries, head + 1)
    assert Enum.reject(Enum.filter(after_head, &lock?/1), &head?/1) == [], inspect(after_head)
  end
end
