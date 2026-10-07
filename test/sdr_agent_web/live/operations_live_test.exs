defmodule SdrAgentWeb.OperationsLiveTest do
  @moduledoc """
  S10b Runs/Operations: the attention queue with acknowledge and resolve
  (note required; ADM, REV), the operations list with cancel (ADM), agent
  runs linking to the run view, and the run view (decisions, model and tool
  invocations, payload and Tempo trace links). The auditor is read-only and
  every view it opens is recorded.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Operations

  defp open_failure!(ctx) do
    lead = fixture_lead!(ctx, "02")

    {:ok, failure} =
      Operations.open_failure(
        %{
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: lead.id,
          class: :provider_error,
          severity: :warning,
          message: "fixture search timed out"
        },
        actor: ctx.agent
      )

    failure
  end

  describe "attention" do
    test "a reviewer acknowledges and then resolves a failure with a note", %{conn: conn} = ctx do
      failure = open_failure!(ctx)
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/operations")

      assert has_element?(view, "#failures-#{failure.id} [data-status='open']")
      view |> element("#acknowledge-#{failure.id}") |> render_click()
      assert has_element?(view, "#failures-#{failure.id} [data-status='acknowledged']")

      view
      |> form("#resolve-#{failure.id}", resolve: %{resolution_note: "Retried by hand"})
      |> render_submit()

      refute has_element?(view, "#failures-#{failure.id}")
      {:ok, resolved} = Operations.get_failure(failure.id, actor: ctx.admin)
      assert {resolved.status, resolved.resolution_note} == {:resolved, "Retried by hand"}
    end

    test "resolving without a note is refused and explained", %{conn: conn} = ctx do
      failure = open_failure!(ctx)
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/operations")

      view |> form("#resolve-#{failure.id}", resolve: %{resolution_note: ""}) |> render_submit()

      assert has_element?(view, "#flash-error")
      {:ok, still} = Operations.get_failure(failure.id, actor: ctx.admin)
      assert still.status == :open
    end

    test "the auditor's acknowledge and resolve events are refused and audited",
         %{conn: conn} = ctx do
      failure = open_failure!(ctx)
      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/operations")

      refute has_element?(view, "#acknowledge-#{failure.id}")
      render_click(view, "acknowledge", %{"id" => failure.id})

      render_submit(view, "resolve", %{
        "id" => failure.id,
        "resolve" => %{"resolution_note" => "x"}
      })

      {:ok, still} = Operations.get_failure(failure.id, actor: ctx.admin)
      assert still.status == :open
      assert length(denials_of(ctx, auditor)) == 2
    end
  end

  describe "operations and runs" do
    setup ctx do
      Map.merge(ctx, assign!(ctx, "01"))
    end

    test "lists the agent run and its operation", %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/operations")

      assert has_element?(view, "#operations-#{ctx.operation.id} [data-status='enqueued']")
      assert has_element?(view, "#runs-#{ctx.run.id} a[href='/runs/#{ctx.run.id}']")
    end

    test "an admin cancels an enqueued operation; a reviewer is not offered it",
         %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/operations")
      refute has_element?(view, "#cancel-operation-#{ctx.operation.id}")

      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/operations")
      view |> element("#cancel-operation-#{ctx.operation.id}") |> render_click()

      assert has_element?(view, "#operations-#{ctx.operation.id} [data-status='cancelled']")
    end

    test "a reviewer's forged cancel is refused by the domain", %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/operations")
      render_click(view, "cancel_operation", %{"id" => ctx.operation.id})

      assert has_element?(view, "#flash-error")
      {:ok, operation} = Operations.get_operation(ctx.operation.id, actor: ctx.admin)
      assert operation.status == :enqueued
    end

    test "an auditor's operations view is recorded", %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, _view, _html} = conn |> sign_in(:auditor) |> live(~p"/operations")

      assert [%{access_kind: :record_view, target_resource: "Operations"}] =
               accesses_of(ctx, auditor)
    end
  end

  describe "run view" do
    setup ctx do
      assigned = assign!(ctx, "01")
      %{success: 1} = drain!()
      Map.merge(ctx, assigned)
    end

    test "reconstructs the run: decisions, model and tool invocations, trace link",
         %{conn: conn, run: run} = ctx do
      {:ok, decisions} = SdrAgent.Agents.list_decisions(run.id, actor: ctx.admin)
      {:ok, [invocation | _]} = SdrAgent.Agents.list_model_invocations(run.id, actor: ctx.admin)
      {:ok, [tool | _]} = SdrAgent.Agents.list_tool_invocations(run.id, actor: ctx.admin)

      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/runs/#{run.id}")

      assert has_element?(view, "#run-header [data-status='succeeded']")
      for decision <- decisions, do: assert(has_element?(view, "#decision-#{decision.id}"))
      assert has_element?(view, "#model-invocation-#{invocation.id}")

      assert has_element?(
               view,
               "#model-invocation-#{invocation.id} a[href='/audit/payloads/#{hex(invocation.request_sha256)}']"
             )

      assert has_element?(view, "#tool-invocation-#{tool.id}")
      assert has_element?(view, "#run-header a[data-trace-id='#{run.trace_id}']")
    end

    test "an auditor's run view is recorded with the run id", %{conn: conn, run: run} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, _view, _html} = conn |> sign_in(:auditor) |> live(~p"/runs/#{run.id}")

      assert [%{target_resource: "SdrAgent.Agents.AgentRun", target_ref: ref}] =
               accesses_of(ctx, auditor)

      assert ref == run.id
    end
  end
end
