defmodule SdrAgent.Agents.ModelCallAdmissionTest do
  @moduledoc """
  C9-02/03 (R0 readiness packet, G5-R0): every real-model (ClaudeCLI)
  reservation is charged, inside the reservation transaction, to exactly one
  allocation of one owner-created grant, selected by the trusted usage
  bucket of `(run.usage_origin, purpose)`. The new ledger columns are
  written by `:reserve` only and immutable afterwards; rows written before
  R0 (generation 1) keep their lifecycle. A refusal rolls the reservation
  back and is then committed on its own as one deduplicated
  `budget_exhausted` Failure and a `model.reservation.refused` event.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure

  @now ~U[2026-10-20 12:00:00.000000Z]
  @starts ~U[2026-10-12 00:00:00.000000Z]
  @expires ~U[2026-11-06 00:00:00.000000Z]
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})

  setup do
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  defp grant!(ctx, overrides \\ %{}) do
    AgentsFixtures.grant!(
      ctx.tenant,
      Map.merge(
        %{
          total_attempts: 10,
          starts_at: @starts,
          expires_at: @expires,
          allocations: [%{key: :b1, applies_to: [:b1], attempts: 10}]
        },
        overrides
      )
    )
  end

  defp run!(ctx, origin \\ :assignment) do
    AgentsFixtures.running_run(ctx.tenant, usage_origin: origin)
  end

  defp attrs(key, overrides \\ %{}) do
    key
    |> AgentsFixtures.claude_attrs()
    |> Map.put(:request, ~s({"request":"#{key}"}))
    |> Map.merge(overrides)
  end

  defp reserve(%{run: run, agent: agent}, key, overrides \\ %{}) do
    Agents.reserve_model_invocation(run, attrs(key, overrides), actor: agent)
  end

  defp invocations(%{run: run, agent: agent}) do
    {:ok, invocations} = Agents.list_model_invocations(run.id, actor: agent)
    invocations
  end

  defp consumed(grant) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.count!(authorize?: false)
  end

  defp refusal_failures(ctx) do
    Failure
    |> Ash.Query.filter(
      class == :budget_exhausted and subject_resource == "SdrAgent.Agents.AgentRun"
    )
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))
  end

  defp stored_payload?(ctx, content) do
    {:ok, payloads} = Audit.list_payloads(actor: system_actor(:auditor_cli, ctx.tenant))
    Enum.any?(payloads, &(&1.sha256 == :crypto.hash(:sha256, content)))
  end

  defp reload_run(%{run: run, agent: agent}) do
    {:ok, run} = Agents.get_run(run.id, actor: agent)
    run
  end

  describe "an admitted ClaudeCLI reservation" do
    test "is charged to the one eligible allocation, written on the row", ctx do
      grant = grant!(ctx)
      [allocation] = grant.allocations
      run = run!(ctx)

      assert {:ok, invocation} = reserve(run, "ok-1")
      assert [stored] = invocations(run)
      assert stored.id == invocation.id
      assert stored.ledger_generation == 2
      assert stored.profile_id == :claude_cli_opus
      assert stored.grant_id == grant.id
      assert stored.allocation_id == allocation.id
      assert consumed(grant) == 1
    end

    test "a caller cannot choose the grant, allocation or generation", ctx do
      grant = grant!(ctx)

      other =
        grant!(ctx, %{name: "G-OTHER", allocations: [%{key: :b5, applies_to: [:b5], attempts: 1}]})

      run = run!(ctx)

      assert {:ok, invocation} =
               reserve(run, "forged", %{
                 grant_id: other.id,
                 allocation_id: hd(other.allocations).id,
                 ledger_generation: 1
               })

      assert invocation.grant_id == grant.id
      assert invocation.allocation_id == hd(grant.allocations).id
      assert invocation.ledger_generation == 2
    end

    test "a referral's outreach proposal is charged to b5, its research to b1", ctx do
      grant =
        grant!(ctx, %{
          allocations: [
            %{key: :b1, applies_to: [:b1], attempts: 5},
            %{key: :b5, applies_to: [:b5], attempts: 5}
          ]
        })

      by_key = Map.new(grant.allocations, &{&1.key, &1.id})
      run = run!(ctx, :referral)

      assert {:ok, research} = reserve(run, "ref-1")
      assert {:ok, draft} = reserve(run, "ref-2", %{purpose: :outreach_proposal})
      assert research.allocation_id == by_key.b1
      assert draft.allocation_id == by_key.b5
    end

    test "Fake invocations record their profile and need no grant", ctx do
      run = run!(ctx)

      assert {:ok, invocation} =
               Agents.reserve_model_invocation(run.run, AgentsFixtures.model_attrs("fake-1"),
                 actor: run.agent
               )

      assert invocation.provider == :fake
      assert invocation.profile_id == :fake
      assert invocation.ledger_generation == 2
      assert invocation.grant_id == nil
      assert invocation.allocation_id == nil
    end

    test "a ClaudeCLI reservation without a reviewed real profile is invalid", ctx do
      grant!(ctx)
      run = run!(ctx)

      for profile <- [nil, :fake] do
        assert {:error, %Ash.Error.Invalid{}} =
                 reserve(run, "profile-#{inspect(profile)}", %{profile_id: profile})
      end

      assert invocations(run) == []
    end

    test "a duplicate idempotency key consumes once", ctx do
      grant = grant!(ctx)
      run = run!(ctx)

      assert {:ok, _} = reserve(run, "dup")
      assert {:error, %Ash.Error.Invalid{}} = reserve(run, "dup")
      assert consumed(grant) == 1
      assert reload_run(run).budget.model_calls_reserved == 1
      assert refusal_failures(ctx) == []
    end
  end

  describe "grant eligibility" do
    test "at starts_at and until just before expires_at", ctx do
      grant!(ctx)
      run = run!(ctx)

      Clock.freeze(DateTime.add(@starts, -1, :microsecond))
      assert {:error, :no_eligible_grant} = reserve(run, "early")
      Clock.freeze(@starts)
      assert {:ok, _} = reserve(run, "at-start")
      Clock.freeze(DateTime.add(@expires, -1, :microsecond))
      assert {:ok, _} = reserve(run, "last-moment")
      Clock.freeze(@expires)
      assert {:error, :no_eligible_grant} = reserve(run, "expired")
    end

    test "a revoked grant admits nothing", ctx do
      grant = grant!(ctx)
      {:ok, _} = Agents.revoke_grant(grant, %{expected_revision: 1}, actor: ctx.admin)
      run = run!(ctx)

      assert {:error, :no_eligible_grant} = reserve(run, "revoked")
    end

    test "a profile outside the grant's profiles admits nothing", ctx do
      grant!(ctx, %{profile_ids: [:claude_cli_sonnet]})
      run = run!(ctx)

      assert {:error, :no_eligible_grant} = reserve(run, "opus")
      assert {:ok, _} = reserve(run, "sonnet", %{profile_id: :claude_cli_sonnet})
    end

    test "an allocation restricted to another profile is not used", ctx do
      grant!(ctx, %{
        allocations: [%{key: :b1, applies_to: [:b1], profile_id: :claude_cli_sonnet, attempts: 3}]
      })

      run = run!(ctx)

      assert {:error, :no_allocation} = reserve(run, "opus")
      assert {:ok, _} = reserve(run, "sonnet", %{profile_id: :claude_cli_sonnet})
    end

    test "an allocation that does not fund the bucket is not used", ctx do
      grant!(ctx)
      run = run!(ctx, :reply)

      assert {:error, :no_allocation} = reserve(run, "reply")
    end

    test "the workshop reserve is unavailable before its time and available after release",
         ctx do
      workshop = ~U[2026-11-01 00:00:00.000000Z]

      grant =
        grant!(ctx, %{
          allocations: [
            %{key: :workshop, applies_to: [:b1], attempts: 2, available_from: workshop}
          ]
        })

      run = run!(ctx)

      assert {:error, :no_allocation} = reserve(run, "before")

      {:ok, _} =
        Agents.release_allocation(grant, %{expected_revision: 1, key: :workshop},
          actor: ctx.admin
        )

      assert {:ok, _} = reserve(run, "released")
    end

    test "an allocation window opens at available_from and closes at available_until", ctx do
      from = ~U[2026-10-27 00:00:00.000000Z]
      until = ~U[2026-10-30 00:00:00.000000Z]

      grant!(ctx, %{
        allocations: [
          %{
            key: :rehearsal,
            applies_to: [:b1],
            attempts: 5,
            available_from: from,
            available_until: until
          }
        ]
      })

      run = run!(ctx)

      Clock.freeze(DateTime.add(from, -1, :microsecond))
      assert {:error, :no_allocation} = reserve(run, "w-early")
      Clock.freeze(from)
      assert {:ok, _} = reserve(run, "w-open")
      Clock.freeze(until)
      assert {:error, :no_allocation} = reserve(run, "w-closed")
    end

    test "two matching allocations are ambiguous", ctx do
      grant!(ctx, %{
        allocations: [
          %{key: :b1, applies_to: [:b1], attempts: 3},
          %{key: :daily_use, applies_to: [:b1, :b2], attempts: 3}
        ]
      })

      run = run!(ctx)

      assert {:error, :ambiguous_allocation} = reserve(run, "ambiguous")
    end

    test "allocations of two grants matching at once are ambiguous", ctx do
      grant!(ctx)
      grant!(ctx, %{name: "G-SECOND"})
      run = run!(ctx)

      assert {:error, :ambiguous_allocation} = reserve(run, "two-grants")
    end

    test "a run without a usage origin (created before R0) is refused", ctx do
      grant!(ctx)
      run = run!(ctx)
      legacy_run!(run.run)

      assert {:error, :no_usage_origin} = reserve(run, "legacy-run")
      assert invocations(run) == []
    end

    test "an actor of another tenant charges nothing", ctx do
      grant = grant!(ctx)
      run = run!(ctx)
      foreign = system_actor(:agent_runtime, %{id: Ecto.UUID.generate()})

      assert {:error, _} =
               Agents.reserve_model_invocation(run.run, attrs("foreign"), actor: foreign)

      assert consumed(grant) == 0
      assert invocations(run) == []
    end
  end

  describe "room" do
    test "the allocation's attempts", ctx do
      grant = grant!(ctx, %{allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]})
      run = run!(ctx)

      assert {:ok, _} = reserve(run, "a-1")
      assert {:error, {:budget_exhausted, :allocation}} = reserve(run, "a-2")
      assert consumed(grant) == 1
    end

    test "the grant total, even when an allocation still has attempts", ctx do
      grant =
        grant!(ctx, %{
          total_attempts: 3,
          allocations: [
            %{key: :b1, applies_to: [:b1], attempts: 2},
            %{key: :b5, applies_to: [:b5], attempts: 1}
          ]
        })

      assignment = run!(ctx)
      reply = run!(ctx, :reply)
      assert {:ok, _} = reserve(assignment, "g-1")
      assert {:ok, _} = reserve(assignment, "g-2")

      # Lowering below what is consumed is allowed; it only stops new reservations.
      {:ok, grant} =
        Agents.update_grant_terms(
          grant,
          %{expected_revision: 1, allocations: [%{key: :b1, attempts: 1}]},
          actor: ctx.admin
        )

      {:ok, _grant} =
        Agents.update_grant_terms(grant, %{expected_revision: grant.revision, total_attempts: 2},
          actor: ctx.admin
        )

      assert {:error, {:budget_exhausted, :grant}} = reserve(reply, "g-3")
    end

    test "the grant's UTC day limit, renewed at midnight UTC", ctx do
      grant!(ctx, %{per_utc_day_attempts: 2})
      run = run!(ctx)

      Clock.freeze(~U[2026-10-20 23:59:59.999999Z])
      assert {:ok, _} = reserve(run, "day-1")
      assert {:ok, _} = reserve(run, "day-2")
      assert {:error, {:budget_exhausted, :grant_day}} = reserve(run, "day-3")

      Clock.freeze(~U[2026-10-21 00:00:00.000000Z])
      assert {:ok, _} = reserve(run, "day-4")
    end
  end

  describe "a refused reservation" do
    test "writes no payload, invocation or counter, and one Failure and event", ctx do
      run = run!(ctx)
      before = reload_run(run).budget

      assert {:error, :no_eligible_grant} = reserve(run, "refused-1")

      assert invocations(run) == []
      assert reload_run(run).budget == before
      refute stored_payload?(ctx, ~s({"request":"refused-1"}))
      assert events_of_type(ctx.tenant, "model.invocation.reserved") == []
      assert events_of_type(ctx.tenant, "agents.run.model_call_reserved") == []

      assert [failure] = refusal_failures(ctx)
      assert failure.status == :open
      assert failure.subject_id == run.run.id
      assert failure.severity == :critical
      assert failure.message =~ "no_eligible_grant"
      assert failure.detail_sha256 != nil

      assert [event] = events_of_type(ctx.tenant, "model.reservation.refused")
      assert event.agent_run_id == run.run.id
      assert event.actor_type == :agent_runtime
      assert event.payload["reason"] == "no_eligible_grant"
      assert event.payload["failure_id"] == failure.id
      assert event.payload["profile_id"] == "claude_cli_opus"
      assert event.payload["bucket"] == "b1"
      refute Map.has_key?(event.payload, "request")
    end

    test "a repeated refusal adds no second Failure", ctx do
      run = run!(ctx)

      assert {:error, :no_eligible_grant} = reserve(run, "again-1")
      assert {:error, :no_eligible_grant} = reserve(run, "again-2")

      assert [failure] = refusal_failures(ctx)
      events = events_of_type(ctx.tenant, "model.reservation.refused")
      assert length(events) == 2
      assert Enum.all?(events, &(&1.payload["failure_id"] == failure.id))
      assert Enum.map(events, & &1.payload["deduplicated"]) == [false, true]
    end

    test "a different reason, grant or run opens its own Failure", ctx do
      grant = grant!(ctx, %{allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]})
      run = run!(ctx)
      other_run = run!(ctx)

      assert {:ok, _} = reserve(run, "r-1")
      assert {:error, {:budget_exhausted, :allocation}} = reserve(run, "r-2")
      assert {:error, {:budget_exhausted, :allocation}} = reserve(other_run, "r-3")

      {:ok, _} = Agents.revoke_grant(grant, %{expected_revision: 1}, actor: ctx.admin)
      assert {:error, :no_eligible_grant} = reserve(run, "r-4")

      assert length(refusal_failures(ctx)) == 3
    end

    test "a resolved refusal Failure is not reused", ctx do
      run = run!(ctx)
      assert {:error, :no_eligible_grant} = reserve(run, "res-1")
      [failure] = refusal_failures(ctx)

      {:ok, _} =
        SdrAgent.Operations.resolve_failure(failure, %{resolution_note: "grant created"},
          actor: ctx.admin
        )

      assert {:error, :no_eligible_grant} = reserve(run, "res-2")
      assert length(refusal_failures(ctx)) == 2
    end

    test "the facade refuses before the provider runs", ctx do
      run = run!(ctx)

      assert {:error, :no_eligible_grant} =
               ModelProvider.complete(request(run, "facade-refused"),
                 provider: __MODULE__.MustNotRun
               )

      assert invocations(run) == []
      assert [_] = refusal_failures(ctx)
    end

    test "the facade charges an admitted call through the provider", ctx do
      grant = grant!(ctx)
      run = run!(ctx)

      assert {:ok, result} =
               ModelProvider.complete(request(run, "facade-ok"),
                 provider: __MODULE__.ClaudeShaped
               )

      assert result.invocation.status == :completed
      assert result.invocation.grant_id == grant.id
      assert result.invocation.profile_id == :claude_cli_opus
    end
  end

  describe "ledger generations (migration cutover)" do
    test "generation-1 ClaudeCLI rows keep their lifecycle", ctx do
      grant!(ctx)
      run = run!(ctx)
      {:ok, reserved} = reserve(run, "legacy-reserved")
      {:ok, to_send} = reserve(run, "legacy-sent")
      legacy!(reserved)
      legacy!(to_send)

      [reserved, to_send] =
        Enum.map([reserved, to_send], &Ash.get!(ModelInvocation, &1.id, authorize?: false))

      assert {reserved.ledger_generation, reserved.grant_id} == {1, nil}

      assert {:ok, failed} =
               Agents.fail_model_invocation(reserved, %{error: %{"kind" => "legacy"}},
                 actor: run.agent
               )

      assert failed.status == :failed

      assert {:ok, sent} = Agents.mark_model_invocation_sent(to_send, actor: run.agent)
      assert {:ok, unknown} = Agents.mark_model_invocation_unknown(sent, actor: run.agent)
      assert unknown.status == :unknown
      assert unknown.ledger_generation == 1
    end

    test "a new generation-2 ClaudeCLI row without profile, grant or allocation is rejected",
         ctx do
      grant!(ctx)
      run = run!(ctx)
      {:ok, invocation} = reserve(run, "template")

      for column <- ~w(profile_id grant_id allocation_id) do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 insert_copy(invocation, "#{column} = NULL")
      end

      # The same row as generation 1 (written before R0) is allowed.
      assert {:error, :inserted} =
               insert_copy(
                 invocation,
                 "ledger_generation = 1, profile_id = NULL, grant_id = NULL, allocation_id = NULL"
               )
    end

    test "the allocation must belong to the recorded grant", ctx do
      grant!(ctx)

      other =
        grant!(ctx, %{name: "G-OTHER", allocations: [%{key: :b5, applies_to: [:b5], attempts: 1}]})

      run = run!(ctx)
      {:ok, invocation} = reserve(run, "fk-template")

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert_copy(invocation, "allocation_id = $1", [
                 Ecto.UUID.dump!(hd(other.allocations).id)
               ])
    end

    test "the new columns cannot change after reserve", ctx do
      grant = grant!(ctx)

      other =
        grant!(ctx, %{name: "G-OTHER", allocations: [%{key: :b5, applies_to: [:b5], attempts: 1}]})

      run = run!(ctx)
      {:ok, invocation} = reserve(run, "immutable")
      id = Ecto.UUID.dump!(invocation.id)

      changes = [
        {"ledger_generation = 1", []},
        {"profile_id = 'claude_cli_sonnet'", []},
        {"grant_id = $2", [Ecto.UUID.dump!(other.id)]},
        {"allocation_id = NULL", []}
      ]

      for {set, params} <- changes do
        assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
                 raw_error("UPDATE model_invocations SET #{set} WHERE id = $1", [id | params])
      end

      stored = Ash.get!(ModelInvocation, invocation.id, authorize?: false)
      assert {stored.ledger_generation, stored.grant_id} == {2, grant.id}

      # No lifecycle action accepts them either.
      for action <- [:mark_sent, :fail] do
        assert {:error, %Ash.Error.Invalid{}} =
                 invocation
                 |> Ash.Changeset.for_update(
                   action,
                   %{grant_id: other.id, error: %{"kind" => "x"}},
                   actor: run.agent
                 )
                 |> Ash.update()
      end
    end
  end

  # Simulates a run created before R0 (the migration leaves usage_origin null).
  defp legacy_run!(run) do
    tamper!("UPDATE agent_runs SET usage_origin = NULL WHERE id = $1", [Ecto.UUID.dump!(run.id)])
  end

  # Simulates an invocation written before R0 (generation 1, no grant).
  defp legacy!(invocation) do
    tamper!(
      "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
        "allocation_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(invocation.id)]
    )
  end

  # Inserts a copy of `invocation` with `set` applied (a fresh id, sequence
  # and idempotency key), in a rolled-back transaction; returns the
  # Postgres error, or `{:error, :inserted}` when the insert succeeded.
  defp insert_copy(invocation, set, params \\ []) do
    Repo.transaction(fn ->
      query = &Ecto.Adapters.SQL.query(Repo, &1, &2)

      with {:ok, _} <-
             query.(
               "CREATE TEMP TABLE invocation_copy ON COMMIT DROP AS " <>
                 "SELECT * FROM model_invocations WHERE id = $1",
               [Ecto.UUID.dump!(invocation.id)]
             ),
           {:ok, _} <-
             query.(
               "UPDATE invocation_copy SET id = gen_random_uuid(), sequence_in_run = 999, " <>
                 "idempotency_key = 'copy-' || gen_random_uuid(), #{set}",
               params
             ),
           {:ok, _} <- query.("INSERT INTO model_invocations SELECT * FROM invocation_copy", []) do
        Repo.rollback(:inserted)
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp request(%{run: run, agent: agent}, id) do
    audit =
      id
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

    %{
      id: id,
      run: run,
      actor: agent,
      operation: "model.complete",
      prompt: "Qualify the fixture lead",
      schema: @schema,
      audit: audit
    }
  end

  defmodule MustNotRun do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, ClaudeCLI.provenance()}
    def complete(_request, _opts), do: raise("the provider must not be invoked")
  end

  defmodule ClaudeShaped do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, ClaudeCLI.provenance()}

    def complete(request, _opts) do
      output = %{answer: "qualified", score: 7}

      {:ok,
       %{
         output: output,
         provider: :claude_cli,
         model: "claude-opus-5-5",
         request_id: request.id,
         raw_response: Jason.encode!(%{output: output}),
         usage: %{input_tokens: 1, output_tokens: 1, plan_calls: 1}
       }}
    end
  end
end
