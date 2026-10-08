defmodule SdrAgentWeb.AdminLiveTest do
  @moduledoc """
  S10b Admin / provider status (ADM only): the configured model provider and
  integrations (names only, never credentials), the daily model-call budget
  and per-run limits, today's send quota and the operators. Reviewers and
  auditors are sent back to the dashboard.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Fixtures

  test "the admin sees provider, budgets, delivery and operators", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")

    assert has_element?(view, "#model-provider", "Fake")
    assert has_element?(view, "#daily-budget [data-used]")
    assert has_element?(view, "#delivery-adapter", "CaptureAdapter")

    for user <- Fixtures.users() do
      assert has_element?(view, "#users-#{user.id} [data-role='#{user.role}']")
    end
  end

  describe "Q0.1 model provider status" do
    @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

    test "the Fake shows its fixture model and needs no attestation", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")

      assert has_element?(view, "#model-provider", "Fake")
      assert has_element?(view, "#effective-provider[data-effective='Fake']")
      assert has_element?(view, "#model-id", "fake-qualifier")
      assert has_element?(view, "#model-attestation[data-status='not_applicable']")
    end

    test "ClaudeCLI shows alias, resolved id, reviewed version and the last attestation",
         %{conn: conn} do
      put_env!(:model_provider, SdrAgent.AI.ModelProvider.ClaudeCLI)
      admin = sign_in(conn, :admin)

      {:ok, view, _html} = live(admin, ~p"/admin")
      assert has_element?(view, "#model-provider", "ClaudeCLI")

      assert has_element?(
               view,
               "#effective-provider[data-effective='none']",
               "provider_not_running"
             )

      assert has_element?(view, "#provider-server[data-status='not_running']")
      assert has_element?(view, "#model-attestation[data-status='not_running']")

      start_supervised!(
        {SdrAgent.AI.ModelProvider.ClaudeCLI,
         name: SdrAgent.AI.ModelProvider.ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         command_args: [@fake, "model_drift"]}
      )

      {:ok, view, _html} = live(admin, ~p"/admin")
      assert has_element?(view, "#model-alias", "opus")
      assert has_element?(view, "#model-id", "claude-opus-5-5")
      assert has_element?(view, "#reviewed-cli-version", "2.1.291")
      assert has_element?(view, "#provider-server[data-status='running']")
      assert has_element?(view, "#effective-provider[data-effective='ClaudeCLI']")
      assert has_element?(view, "#model-attestation[data-status='pending']", "first call")

      assert {:error, :model_attestation_drift} =
               SdrAgent.AI.ModelProvider.ClaudeCLI.complete(
                 %{
                   prompt: "qualify",
                   schema: Zoi.object(%{answer: Zoi.string()}),
                   witness: %{
                     model_invocation_id: Ash.UUIDv7.generate(),
                     traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
                   }
                 },
                 []
               )

      {:ok, view, _html} = live(admin, ~p"/admin")

      assert has_element?(
               view,
               "#model-attestation[data-status='drift']",
               "model_attestation_drift"
             )
    end
  end

  test "the provider card refreshes when a call commits (attestation drift is seen live)",
       %{conn: conn} = ctx do
    start_supervised!(
      {SdrAgent.AI.ModelProvider.ClaudeCLI,
       name: SdrAgent.AI.ModelProvider.ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       command_args: [Path.expand("../../support/fake_claude_cli.exs", __DIR__), "model_drift"]}
    )

    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    assert has_element?(view, "#model-attestation[data-status='not_applicable']")

    put_env!(:model_provider, SdrAgent.AI.ModelProvider.ClaudeCLI)
    assign!(ctx, "01")
    drain!()

    # The sandbox never commits: deliver what LiveEvents.Relay sends after a
    # commit (as in SdrAgentWeb.LiveRefreshTest).
    SdrAgent.LiveEvents.broadcast(%{
      tenant_id: ctx.tenant.id,
      sequence: 0,
      event_type: "test.committed",
      category: "domain_change",
      subject_resource: nil,
      subject_id: nil,
      agent_run_id: nil
    })

    assert has_element?(view, "#model-provider", "ClaudeCLI")

    assert has_element?(
             view,
             "#model-attestation[data-status='drift']",
             "model_attestation_drift"
           )
  end

  test "no credential or password material is rendered", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    html = render(view)

    refute html =~ "$2b$"
    refute html =~ "hashed_password"

    for user <- Fixtures.users(), do: refute(html =~ user.password)
  end

  for role <- [:reviewer, :auditor] do
    test "#{role} is redirected away from admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> sign_in(unquote(role)) |> live(~p"/admin")
    end
  end

  test "only the admin's navigation shows Admin", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/")
    assert has_element?(view, "#nav-admin[href='/admin']")

    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")
    refute has_element?(view, "#nav-admin")
  end
end
