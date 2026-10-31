defmodule SdrAgentWeb.HostedOwnerConsoleTest do
  @moduledoc """
  S-B5 owner console RED: no inherited reviewer buttons, separate assignment,
  honest unavailable panels, explicit worker control and escaped diagnostic
  transcript display. All rows/transcripts are synthetic; no model or CLI.
  """
  use SdrAgentWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SdrAgent.AuditCase, only: [human: 2]
  import SdrAgent.PrototypeCase, only: [call: 3]

  alias SdrAgent.AgentsFixtures
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.Repo
  alias SdrAgentWeb.Scope

  @bytes "PRIVATE_UI_TRANSCRIPT<script>alert('never executable')</script>"

  setup tags do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    lead = SdrAgent.SalesFixtures.lead!(ctx.fx.tenant)
    SdrAgent.SalesFixtures.active_campaign!(ctx.fx.tenant)
    assert {:ok, auditor_token, _} = AshAuthentication.Jwt.token_for_user(ctx.fx.auditor)

    remote =
      if tags[:transcript] do
        :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
        definition = AgentsFixtures.definition!(ctx.fx.tenant)
        agent = SdrAgent.Actor.system(:agent_runtime, ctx.fx.tenant.id)
        fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
        SdrAgent.AdmissionFixtures.admit_tuples!()
        grant = AgentsFixtures.grant!(fx.tenant, %{}, admin)
        run = run_for_lead!(fx, lead.id)
        fx = Map.merge(fx, %{grant: grant, run: run})
        F.remote!()
        %{token: token} = F.enrol!(fx)
        F.reserve!(fx)
        nonce = F.nonce()
        launch = F.claim!(token, nonce)

        assert F.kind(F.complete(token, nonce, launch.call_id, launch.request_sha256, @bytes)) ==
                 :accepted

        %{
          run: run,
          call_id: launch.call_id,
          other_run: if(tags[:foreign_transcript], do: run_for_lead!(fx, lead.id))
        }
      else
        %{}
      end

    enrolled = H.enrol!(ctx)
    signed = H.consume!(enrolled.enrollment_token)
    H.enter!(ctx)

    Map.merge(
      ctx,
      Map.merge(remote, %{
        admin: admin,
        lead: lead,
        enrolled: enrolled,
        token: signed.__metadata__.token,
        auditor_token: auditor_token
      })
    )
  end

  defp signed_conn(conn, token), do: init_test_session(conn, %{"user_token" => token})

  # Gate fixtures intentionally use an unpersisted lead id. A real console
  # view loads that relationship, so build its run against the persisted lead.
  defp run_for_lead!(fx, lead_id) do
    key = "owner-ui-#{Ecto.UUID.generate()}"

    assert {:ok, operation} =
             SdrAgent.Operations.create_operation(
               %{
                 kind: :research_lead,
                 queue: :research,
                 subject_resource: "SdrAgent.Sales.Lead",
                 subject_id: lead_id,
                 idempotency_key: key,
                 correlation_id: Ecto.UUID.generate(),
                 max_attempts: 1
               },
               actor: fx.agent
             )

    assert {:ok, operation} = SdrAgent.Operations.start_operation(operation, actor: fx.agent)

    attrs =
      fx.definition
      |> AgentsFixtures.run_attrs()
      |> Map.merge(%{lead_id: lead_id, operation_id: operation.id})

    assert {:ok, run} = SdrAgent.Agents.create_run(attrs, actor: fx.agent)
    assert {:ok, run} = SdrAgent.Agents.start_run(run, actor: fx.agent)
    run
  end

  defp accesses do
    Repo.query!(
      "SELECT count(*) FROM audit_accesses WHERE target_resource='SdrAgent.Agents.RemoteCallResult'",
      []
    ).rows
  end

  test "owner presentation has no inherited reviewer/admin powers, but keeps assignment", ctx do
    scope = Scope.for_user(ctx.enrolled.user)
    refute Scope.reviewer?(scope)
    refute Scope.admin?(scope)
    assert call(Scope, :assigner?, [scope])
    assert call(Scope, :hosted_owner?, [scope])
    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.enrolled.user)
    refute call(Scope, :assigner?, [scope])
    refute Scope.reviewer?(scope)
    assert :ok = PrototypeFixtures.leave_runtime()
    assert Scope.reviewer?(Scope.for_user(ctx.admin))
    assert Scope.admin?(Scope.for_user(ctx.admin))
  end

  test "dashboard serves allowed pipeline data and labels attention unavailable, not zero", ctx do
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/")
    assert has_element?(view, "#pipeline")
    assert has_element?(view, "#stat-attention-unavailable", "Unavailable")
    refute has_element?(view, "#stat-attention [data-value]", "0")
  end

  test "operations shows allowed runs and worker controls without false empty forbidden panels",
       ctx do
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/operations")
    assert has_element?(view, "#agent-runs")
    assert has_element?(view, "#mac-worker-controls")
    assert has_element?(view, "#operations-unavailable", "Unavailable")
    assert has_element?(view, "#attention-unavailable", "Unavailable")
    refute has_element?(view, "#failures-empty")
    refute has_element?(view, "#operations-empty")
  end

  test "owner can enrol, pause, resume and disable a worker without a model call", ctx do
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/operations")
    assert has_element?(view, "#worker-enrol")
    before = Repo.query!("SELECT count(*) FROM model_invocations", []).rows
    view |> form("#worker-enrol", worker: F.pins()) |> render_submit()
    assert has_element?(view, "#worker-token")
    assert {:ok, [worker]} = SdrAgent.Operations.list_mac_workers(actor: ctx.enrolled.user)
    token_text = view |> element("#worker-token") |> render()
    assert token_text =~ ~r/[A-Za-z0-9_-]{40,}/
    view |> element("#dismiss-worker-token") |> render_click()
    refute has_element?(view, "#worker-token")
    view |> element("#worker-pause-#{worker.id}") |> render_click()
    assert has_element?(view, "#worker-resume-#{worker.id}")
    view |> element("#worker-resume-#{worker.id}") |> render_click()
    assert has_element?(view, "#worker-pause-#{worker.id}")
    view |> element("#worker-disable-#{worker.id}") |> render_click()
    refute has_element?(view, "#worker-pause-#{worker.id}")
    refute has_element?(view, "#worker-resume-#{worker.id}")
    assert Repo.query!("SELECT count(*) FROM model_invocations", []).rows == before
  end

  test "owner lead page offers assignment separately from reviewer actions", ctx do
    scope = Scope.for_user(ctx.enrolled.user)
    assert call(Scope, :assigner?, [scope])
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/leads/#{ctx.lead.id}")
    assert has_element?(view, "#assign-lead")
  end

  test "a refused second enrollment clears the one-time token", ctx do
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/operations")
    view |> form("#worker-enrol", worker: F.pins()) |> render_submit()
    assert has_element?(view, "#worker-token")
    view |> form("#worker-enrol", worker: F.pins()) |> render_submit()
    refute has_element?(view, "#worker-token")
    assert has_element?(view, "#flash-error")
    assert {:ok, [_]} = SdrAgent.Operations.list_mac_workers(actor: ctx.enrolled.user)
  end

  test "enrollment event and successful metadata refresh preserve the one-time token", ctx do
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/operations")
    view |> form("#worker-enrol", worker: F.pins()) |> render_submit()
    assert has_element?(view, "#worker-token")
    token_html = view |> element("#worker-token") |> render()
    assert {:ok, [worker]} = SdrAgent.Operations.list_mac_workers(actor: ctx.enrolled.user)

    # Sandbox transactions do not commit: publish the same content-free
    # event the real commit relay sends, through the real PubSub path.
    :ok =
      SdrAgent.LiveEvents.broadcast(%{
        tenant_id: ctx.fx.tenant.id,
        sequence: 0,
        category: "domain_change",
        event_type: "mac_worker.enrolled",
        subject_resource: "SdrAgent.Operations.MacWorker",
        subject_id: worker.id,
        agent_run_id: nil
      })

    assert has_element?(view, "#worker-token"), "enrollment event erased the one-time token"
    assert view |> element("#worker-token") |> render() == token_html
    send(view.pid, :live_refresh)
    assert has_element?(view, "#worker-token"), "successful refresh erased the one-time token"
    assert view |> element("#worker-token") |> render() == token_html
    assert has_element?(view, "#mac-worker-controls")
  end

  test "owner disable signs out the token-bearing view instead of refreshing it", ctx do
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.token) |> live("/operations")
    view |> form("#worker-enrol", worker: F.pins()) |> render_submit()
    assert has_element?(view, "#worker-token")

    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.enrolled.user)
    send(view.pid, :live_refresh)
    assert_redirect(view, "/sign-in", 1_000)

    conn = ctx.conn |> signed_conn(ctx.token) |> get("/operations")
    assert redirected_to(conn) == "/sign-in"
    refute conn.resp_body =~ "worker-token"
  end

  test "bound auditor sees no worker controls and forged enrolment is refused", ctx do
    assert function_exported?(Scope, :hosted_owner?, 1), "missing owner presentation boundary"
    {:ok, view, _} = ctx.conn |> signed_conn(ctx.auditor_token) |> live("/operations")
    refute has_element?(view, "#mac-worker-controls")
    render_submit(view, "enrol_worker", %{"worker" => F.pins()})
    assert has_element?(view, "#flash-error")
    assert {:ok, []} = SdrAgent.Operations.list_mac_workers(actor: ctx.enrolled.user)
  end

  @tag :transcript
  test "run transcript stays explicit, escaped and clears on refresh without another disclosure",
       ctx do
    {:ok, view, html} = ctx.conn |> signed_conn(ctx.token) |> live("/runs/#{ctx.run.id}")
    assert has_element?(view, "#run-header"), render(view)
    assert has_element?(view, "#signals-unavailable", "Unavailable")
    assert has_element?(view, "#show-remote-transcript-#{ctx.call_id}")
    refute html =~ "PRIVATE_UI_TRANSCRIPT"
    assert accesses() == [[0]]
    view |> element("#show-remote-transcript-#{ctx.call_id}") |> render_click()
    assert has_element?(view, "#remote-transcript-content", @bytes)
    refute render(view) =~ "<script>alert"
    assert accesses() == [[1]]
    send(view.pid, :live_refresh)
    refute render(view) =~ "PRIVATE_UI_TRANSCRIPT"
    assert accesses() == [[1]]
  end

  @tag :transcript
  @tag :foreign_transcript
  test "owner cannot request a transcript from another run in the same tenant", ctx do
    assert function_exported?(Scope, :hosted_owner?, 1), "missing owner presentation boundary"
    assert ctx.other_run.id != ctx.run.id
    assert ctx.other_run.tenant_id == ctx.run.tenant_id

    {:ok, view, html} =
      ctx.conn |> signed_conn(ctx.token) |> live("/runs/#{ctx.other_run.id}")

    assert has_element?(view, "#run-header"), render(view)
    refute html =~ "PRIVATE_UI_TRANSCRIPT"
    refute has_element?(view, "#show-remote-transcript-#{ctx.call_id}")
    assert accesses() == [[0]]
    render_click(view, "show_remote_transcript", %{"id" => ctx.call_id})
    refute render(view) =~ "PRIVATE_UI_TRANSCRIPT"
    assert has_element?(view, "#flash-error")
    assert accesses() == [[0]]
  end

  @tag :transcript
  test "a forged auditor transcript event never displays bytes", ctx do
    assert function_exported?(Scope, :hosted_owner?, 1), "missing owner presentation boundary"
    {:ok, view, html} = ctx.conn |> signed_conn(ctx.auditor_token) |> live("/runs/#{ctx.run.id}")
    refute html =~ "PRIVATE_UI_TRANSCRIPT"
    render_click(view, "show_remote_transcript", %{"id" => ctx.call_id})
    refute render(view) =~ "PRIVATE_UI_TRANSCRIPT"
    assert has_element?(view, "#flash-error")
    assert accesses() == [[0]]
  end

  @tag :transcript
  test "console HTTP responses forbid caching and referrer disclosure", ctx do
    conn = ctx.conn |> signed_conn(ctx.token) |> get("/runs/#{ctx.run.id}")
    assert html_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end
end
