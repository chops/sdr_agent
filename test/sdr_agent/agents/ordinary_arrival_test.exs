defmodule SdrAgent.Agents.OrdinaryArrivalTest do
  @moduledoc """
  L2 E3 cutover arrival and the workshop reserve (contract stage 3 steps 3–5
  as corrected; plan `notes/features/l2-e3-ordinary-calls.org` RED items 4–6),
  through the ordinary facade path on a pinned, non-test-launcher server (the
  fake CLI as its command; the real launch admission):

  - no grant at all → `:no_eligible_grant`;
  - a run whose origin maps to an unfunded bucket (`:reply` → `:b5`) →
    `:no_allocation`, no launch;
  - the funded bucket (`:assignment` → `:b1`) outside its window →
    `:no_allocation`; inside it, the call reserves and launches once;
  - the workshop reserve is unusable before `available_from` unless
    released; two open allocations for one bucket → `:ambiguous_allocation`.

  Each refusal is the committed reservation receipt, with the invocation
  rolled back and no CLI launch. No real model is called.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Clock
  alias SdrAgent.Test.PinnedCLI

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @start ~U[2026-11-01 15:00:00.000000Z]

  setup do
    AdmissionFixtures.admit_tuples!()
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    dump = Path.join(System.tmp_dir!(), "sdr-e3-arrival-#{System.unique_integer([:positive])}")
    on_exit(fn -> (dump <> ".*") |> Path.wildcard() |> Enum.each(&File.rm/1) end)

    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "env_dump", dump, "0"],
        executable: PinnedCLI.inject_identity!(),
        # Launch admission reads this test's frozen clock (test-seam option).
        clock_from: self(),
        timeout: 30_000
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    %{tenant: tenant, admin: admin, server: server, dump: dump}
  end

  defp launches(ctx), do: length(Path.wildcard(ctx.dump <> ".*"))

  defp run!(ctx, origin), do: AgentsFixtures.running_run(ctx.tenant, usage_origin: origin)

  defp call(ctx, %{run: run, agent: agent}, key) do
    audit =
      key
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    AdmissionFixtures.admitting(fn ->
      ModelProvider.complete(
        %{
          id: key,
          run: run,
          actor: agent,
          operation: "model.complete",
          prompt: "Qualify the fixture lead (#{key})",
          schema: @schema,
          audit: audit
        },
        provider: ClaudeCLI,
        provider_options: [server: ctx.server]
      )
    end)
  end

  defp invocations(%{run: run, agent: agent}) do
    {:ok, rows} = Agents.list_model_invocations(run.id, actor: agent)
    rows
  end

  # The G-DEMO shape: the first window funds exactly [:b1] for 60 minutes.
  defp demo_grant!(ctx, allocations) do
    AgentsFixtures.grant!(
      ctx.tenant,
      %{
        name: "G-DEMO",
        total_attempts: 200,
        per_utc_day_attempts: 30,
        starts_at: @start,
        expires_at: ~U[2026-11-07 06:59:00.000000Z],
        allocations: allocations
      },
      ctx.admin
    )
  end

  defp first_window,
    do: %{
      key: :b1,
      applies_to: [:b1],
      attempts: 5,
      available_from: @start,
      available_until: DateTime.add(@start, 60, :minute)
    }

  defp workshop,
    do: %{
      key: :workshop,
      applies_to: [:b1],
      attempts: 30,
      available_from: ~U[2026-11-06 07:00:00.000000Z]
    }

  defp assert_reservation_refused(result, reason, run, ctx) do
    assert match?({:error, %Refused{stage: :reservation, reason: ^reason}}, result),
           "E3: the ordinary call reaches reservation and is refused with " <>
             "#{inspect(reason)}; got #{inspect(result, limit: 6)}"

    assert invocations(run) == [], "the refused reservation is rolled back"
    assert launches(ctx) == 0, "no CLI was launched"
  end

  test "with no grant, a healthy ordinary call is :no_eligible_grant", ctx do
    Clock.freeze(DateTime.add(@start, 5, :minute))
    run = run!(ctx, :assignment)
    assert_reservation_refused(call(ctx, run, "a-no-grant"), :no_eligible_grant, run, ctx)
  end

  test "a reply-origin run (bucket :b5) arriving in the window is :no_allocation", ctx do
    assert UsageBucket.bucket(:reply, :reply_classification) == :b5
    assert UsageBucket.bucket(:reply, :qualification) == :b5
    demo_grant!(ctx, [first_window()])
    Clock.freeze(DateTime.add(@start, 5, :minute))
    run = run!(ctx, :reply)
    assert_reservation_refused(call(ctx, run, "a-reply"), :no_allocation, run, ctx)
  end

  test "the funded bucket outside its window is :no_allocation; inside, it launches once",
       ctx do
    assert UsageBucket.bucket(:assignment, :qualification) == :b1
    demo_grant!(ctx, [first_window()])

    Clock.freeze(DateTime.add(@start, 61, :minute))
    late = run!(ctx, :assignment)
    assert_reservation_refused(call(ctx, late, "a-late"), :no_allocation, late, ctx)

    Clock.freeze(DateTime.add(@start, 5, :minute))
    planned = run!(ctx, :assignment)
    result = call(ctx, planned, "a-planned")

    refute match?({:error, %Refused{}}, result),
           "E3: the planned run is admitted: #{inspect(result, limit: 6)}"

    assert [row] = invocations(planned)
    assert row.sent_at != nil, "E3: the planned call was sent"
    assert launches(ctx) == 1, "exactly one CLI launch"
  end

  describe "the workshop reserve" do
    test "is unusable before available_from, usable once released", ctx do
      grant = demo_grant!(ctx, [workshop()])
      Clock.freeze(~U[2026-11-05 20:00:00.000000Z])
      early = run!(ctx, :assignment)
      assert_reservation_refused(call(ctx, early, "w-early"), :no_allocation, early, ctx)

      {:ok, _} =
        Agents.release_allocation(grant, %{expected_revision: grant.revision, key: :workshop},
          actor: ctx.admin
        )

      released = run!(ctx, :assignment)
      result = call(ctx, released, "w-released")

      refute match?({:error, %Refused{}}, result),
             "E3: a released reserve admits: #{inspect(result, limit: 6)}"

      assert [%{sent_at: %DateTime{}}] = invocations(released)
    end

    test "overlapping an open allocation for the same bucket is :ambiguous_allocation", ctx do
      demo_grant!(ctx, [
        %{first_window() | available_until: ~U[2026-11-07 06:59:00.000000Z]},
        workshop()
      ])

      Clock.freeze(~U[2026-11-06 08:00:00.000000Z])
      run = run!(ctx, :assignment)
      assert_reservation_refused(call(ctx, run, "w-both"), :ambiguous_allocation, run, ctx)
    end
  end
end
