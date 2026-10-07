defmodule SdrAgent.Operations.AttentionTest do
  @moduledoc """
  S2 "Operator attention": every condition that needs a human opens a
  Failure *in the same transaction* as the state change that causes it
  (AgentRun → failed, budget_exhausted or system-cancelled; Lead → blocked;
  a drifted Claude CLI attestation), and clearing the condition resolves it.
  Atomicity is proven by making the Failure insert fail inside the
  transaction (a temporary trigger in the test sandbox): the causing state
  change must roll back with it.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  @fake_cli Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      agent: system_actor(:agent_runtime, tenant)
    }
  end

  # Makes every INSERT into `failures` raise, inside this test's sandbox
  # transaction only (rolled back with it).
  defp break_failure_inserts! do
    Repo.query!("""
    CREATE FUNCTION pg_temp.s7_reject_failure() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RAISE EXCEPTION 's7 test: failure insert rejected'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER s7_reject_failure BEFORE INSERT ON failures
    FOR EACH ROW EXECUTE FUNCTION pg_temp.s7_reject_failure()
    """)
  end

  defp attention(ctx) do
    {:ok, failures} = Operations.list_attention(actor: ctx.admin)
    failures
  end

  describe "AgentRun" do
    test "the operation and attention links are foreign keys", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)

      assert {:error, _} =
               Repo.query(
                 "UPDATE agent_runs SET attention_failure_id = $1 WHERE id = $2",
                 [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(run.id)]
               )
    end

    test "failed opens a critical run_stopped Failure in the same transaction", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      {:ok, failed} =
        Agents.fail_run(run, %{status_reason: :provider_error, failure_reason: "provider down"},
          actor: agent
        )

      assert [failure] = attention(ctx)
      assert failed.attention_failure_id == failure.id
      assert failure.class == :run_stopped
      assert failure.severity == :critical
      assert failure.subject_resource == "SdrAgent.Agents.AgentRun"
      assert failure.subject_id == run.id
      assert failure.message =~ "provider_error"
      assert [_] = events_of_type(ctx.tenant, "operations.failure.opened")
    end

    test "budget exhaustion opens a budget_exhausted Failure", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      {:ok, exhausted} =
        Agents.exhaust_run_budget(run, %{status_reason: :daily_budget}, actor: agent)

      assert [failure] = attention(ctx)
      assert exhausted.attention_failure_id == failure.id
      assert failure.class == :budget_exhausted
      assert failure.message =~ "daily_budget"
    end

    test "a system cancel opens a Failure; an operator cancel does not", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      {:ok, cancelled} = Agents.cancel_run(run, actor: agent, attrs: %{status_reason: :crash})
      assert [failure] = attention(ctx)
      assert cancelled.attention_failure_id == failure.id

      %{run: other} = AgentsFixtures.running_run(ctx.tenant)
      {:ok, by_operator} = Agents.cancel_run(other, actor: ctx.reviewer)
      assert by_operator.attention_failure_id == nil
      assert [^failure] = attention(ctx)
    end

    test "if the Failure cannot be written the run does not fail", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      break_failure_inserts!()

      assert {:error, _} =
               Agents.fail_run(run, %{status_reason: :crash, failure_reason: "boom"},
                 actor: agent
               )

      {:ok, reloaded} = Agents.get_run(run.id, actor: agent)
      assert reloaded.status == :running
      assert reloaded.attention_failure_id == nil
      assert events_of_type(ctx.tenant, "agents.run.failed") == []
    end

    test "an operator retry resolves the retried run's Failure", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      {:ok, failed} = Agents.fail_run(run, %{status_reason: :crash}, actor: agent)

      {:ok, retry} = Agents.retry_run(failed, actor: ctx.admin)
      assert retry.retry_of_id == failed.id
      assert attention(ctx) == []

      {:ok, failure} = Operations.get_failure(failed.attention_failure_id, actor: ctx.admin)
      assert failure.status == :resolved
      assert failure.resolved_by_type == :user
      assert failure.resolved_by_id == ctx.admin.id
      assert failure.resolution_note =~ retry.id
    end
  end

  describe "Lead → blocked" do
    test "blocking opens its Failure atomically; retry resolves it", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "blocked")

      {:ok, blocked} =
        Sales.update(
          lead,
          :block,
          %{decision_id: decision.id, status_reason: "no usable evidence"},
          actor: ctx.agent
        )

      assert [failure] = attention(ctx)
      assert failure.subject_resource == "SdrAgent.Sales.Lead"
      assert failure.subject_id == blocked.id
      assert failure.class == :run_stopped
      assert failure.severity == :warning
      assert failure.message =~ "no usable evidence"

      {:ok, retried} = Sales.update(blocked, :retry, %{}, actor: ctx.admin)
      assert retried.status == :assigned
      assert attention(ctx) == []
      {:ok, resolved} = Operations.get_failure(failure.id, actor: ctx.admin)
      assert resolved.status == :resolved
      assert resolved.resolved_by_id == ctx.admin.id
    end

    test "the caller may name the failure class", ctx do
      lead = F.lead_in!(ctx.tenant, :qualifying)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "blocked")

      {:ok, _} =
        Sales.update(
          lead,
          :block,
          %{
            decision_id: decision.id,
            status_reason: "qualification rejected",
            failure_class: :validation_error
          },
          actor: ctx.agent
        )

      assert [%{class: :validation_error}] = attention(ctx)
    end

    test "if the Failure cannot be written the lead is not blocked", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "blocked")
      break_failure_inserts!()

      assert {:error, _} =
               Sales.update(lead, :block, %{decision_id: decision.id, status_reason: "x"},
                 actor: ctx.agent
               )

      {:ok, reloaded} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
      assert reloaded.status == :researching
      assert events_of_type(ctx.tenant, "sales.lead.blocked") == []
    end
  end

  describe "Claude CLI attestation drift" do
    test "a drifted attestation fails the invocation and opens a critical Failure", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      {:ok, server} =
        ClaudeCLI.start_link(
          command: System.find_executable("elixir"),
          command_args: [@fake_cli, "version_drift"]
        )

      request = %{
        id: "drift-1",
        run: run,
        actor: agent,
        operation: "model.complete",
        prompt: "qualify",
        schema: Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}),
        audit:
          "drift-1"
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
      }

      assert {:error, :version_attestation_drift} =
               ModelProvider.complete(request,
                 provider: ClaudeCLI,
                 provider_options: [server: server]
               )

      {:ok, [invocation]} = Agents.list_model_invocations(run.id, actor: agent)
      assert invocation.status == :failed
      assert [failure] = attention(ctx)
      assert failure.class == :provider_error
      assert failure.severity == :critical
      assert failure.subject_resource == "SdrAgent.Agents.ModelInvocation"
      assert failure.subject_id == invocation.id
      assert failure.message =~ "version_attestation_drift"
    end

    test "an ordinary provider error opens no attention Failure", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      request = %{
        id: "plain-error",
        run: run,
        actor: agent,
        operation: "model.complete",
        prompt: "qualify",
        schema: Zoi.object(%{answer: Zoi.string()}),
        audit:
          Map.take(AgentsFixtures.model_attrs("x"), [
            :purpose,
            :prompt_template_id,
            :prompt_template_version,
            :prompt_template_sha256,
            :output_schema_id,
            :output_schema_version,
            :output_schema_sha256
          ])
      }

      assert {:error, :claude_cli_error} =
               ModelProvider.complete(request, provider: __MODULE__.ErrorProvider)

      assert attention(ctx) == []
    end
  end

  defmodule ErrorProvider do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.Fake

    def prepare(request, opts), do: Fake.prepare(request, opts)
    def complete(_request, _opts), do: {:error, :claude_cli_error}
  end
end
