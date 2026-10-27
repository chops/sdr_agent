defmodule SdrAgent.Agents.ReleaseStatusTest do
  @moduledoc """
  C2* slice S4 RED-1, `SdrAgent.Agents.release_status/2` (plan r2 §4.3, §7
  T-S1, OQ3; ADR-0005 C2* item 13): the one read-only label read of the
  run view.

      release_status([invocation_id], actor: actor) ::
        {:ok, %{invocation_id => :demo_exception | :other}} | {:error, term()}

  Actor authorization first: (1) the ModelInvocation read AS THE ACTOR
  (policy `actor_present`, tenant-scoped, `select [:id]`); then (2) one
  kernel read of ModelResultRelease for exactly the ids (1) returned,
  selecting only the invocation id and disposition. Only the atom map
  escapes: no row, reason, basis or kernel field.

    * Admin, reviewer and auditor get every readable id: `:demo_exception`
      for a demo-exception release, `:other` for released, withheld, no
      release or a Fake call.
    * An id the actor cannot read (another tenant's, or none) is absent.
    * A tenantless operator gets `{:ok, %{}}`; no actor gets `{:error, _}`.

  RED report labels: every test fails on its guard at this head
  (structural: `release_status/2` is absent). The "with a demo-exception
  release" describe needs S3's H2 harness (`SdrAgent.DemoDraftFixtures`
  "S3 dependency"); until that resolves at the rebased base it fails on
  the RED dependency message instead.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.DemoDraftFixtures
  import SdrAgent.OutreachFixtures, only: [operator!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.InboxFixtures

  @output_columns ~w(parsed_output validation_errors refusal error usage)

  describe "without a demo-exception release" do
    setup ctx do
      base = ctx |> lead_base!() |> env!(:ordinary)
      run = run!(base)
      released = invocation!(base, run, :released)
      withheld = invocation!(base, run, :withheld)
      undecided = invocation!(base, run, {:none, :qualification})
      fake = invocation!(base, run, :fake)
      foreign = invocation!(base, run, :fake)
      move_to_foreign_tenant!(:model_invocations, foreign.invocation.id)
      readable = Enum.map([released, withheld, undecided, fake], & &1.invocation.id)
      unreadable = [foreign.invocation.id, Ash.UUIDv7.generate()]

      %{readable: readable, unreadable: unreadable, ids: readable ++ unreadable}
    end

    test "T-S1 admin, reviewer and auditor: :other for released, withheld, undecided and Fake; others absent",
         ctx do
      expected = Map.new(ctx.readable, &{&1, :other})

      for role <- [:admin, :reviewer, :auditor] do
        assert release_status(ctx.ids, operator!(ctx, role)) == {:ok, expected}, "#{role}"
      end
    end

    test "T-S1 an operator of another tenant and a tenantless operator get an empty map", ctx do
      reviewer = operator!(ctx, :reviewer)

      for actor <- [%{reviewer | tenant_id: Ash.UUIDv7.generate()}, %{reviewer | tenant_id: nil}] do
        assert release_status(ctx.ids, actor) == {:ok, %{}}, inspect(actor.tenant_id)
      end
    end

    test "T-S1 no actor is an error, never a map", ctx do
      assert match?({:error, _}, release_status(ctx.ids, nil))
    end

    test "T-S1 the actor's read comes first; the kernel release read names only the ids it returned",
         ctx do
      assert_implemented!()
      args = [ctx.ids, [actor: operator!(ctx, :reviewer)]]

      {result, queries} =
        InboxFixtures.trace_queries(fn -> apply(Agents, :release_status, args) end)

      assert match?({:ok, %{}}, result)
      tables = Enum.map(queries, fn {sql, _} -> table(sql) end)
      assert tables == ["model_invocations", "model_result_releases"], inspect(queries)
      [{_, invocation_params}, {_, release_params}] = queries
      dumped = Enum.map(ctx.unreadable, &Ecto.UUID.dump!/1)

      refute Enum.any?(dumped, &(&1 in List.flatten(release_params))),
             "the release read never names an id the actor could not read"

      assert Enum.any?(dumped, &(&1 in List.flatten(invocation_params))),
             "the actor's read is the one that is asked about every id"

      for {sql, _} <- queries, column <- @output_columns do
        refute sql =~ ~s(."#{column}"), "no output column is selected: #{sql}"
      end
    end
  end

  describe "with a demo-exception release (S3 H2)" do
    setup ctx do
      base = ctx |> lead_base!() |> env!(:demo)
      run = run!(base)
      demo = invocation!(base, run, {:demo, :qualification})
      released = invocation!(base, run, :released)
      %{demo: demo, released: released}
    end

    test "T-S1 admin, reviewer and auditor read :demo_exception for the demo release only", ctx do
      ids = [ctx.demo.invocation.id, ctx.released.invocation.id]

      expected = %{
        ctx.demo.invocation.id => :demo_exception,
        ctx.released.invocation.id => :other
      }

      for role <- [:admin, :reviewer, :auditor] do
        assert release_status(ids, operator!(ctx, role)) == {:ok, expected}, "#{role}"
      end
    end

    test "T-S1 only atoms escape: no release row, reason, basis or kernel field", ctx do
      ids = [ctx.demo.invocation.id, ctx.released.invocation.id]
      result = release_status(ids, operator!(ctx, :auditor))

      assert match?({:ok, %{}}, result)
      {:ok, map} = result
      assert Enum.sort(Map.keys(map)) == Enum.sort(ids)
      assert Enum.all?(Map.values(map), &(&1 in [:demo_exception, :other])), inspect(map)
    end
  end

  defp assert_implemented! do
    assert Code.ensure_loaded?(Agents) and function_exported?(Agents, :release_status, 2),
           "C2* S4: SdrAgent.Agents.release_status/2 is not implemented"
  end

  defp release_status(ids, actor) do
    assert_implemented!()

    try do
      invoke(Agents, :release_status, [ids, [actor: actor]])
    rescue
      error -> {:raised, error}
    end
  end

  defp invoke(module, fun, args), do: apply(module, fun, args)

  defp table(sql) do
    case Regex.run(~r/\bFROM "([a-z_]+)"/, sql, capture: :all_but_first) do
      [table] -> table
      _ -> {:no_table, sql}
    end
  end
end
