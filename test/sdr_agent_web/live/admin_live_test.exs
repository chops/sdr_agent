defmodule SdrAgentWeb.AdminLiveTest do
  @moduledoc """
  S10b Admin / provider status (ADM only): the configured model provider and
  integrations (names only, never credentials), the daily model-call budget
  and per-run limits, today's send quota and the operators. Reviewers and
  auditors are sent back to the dashboard.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Test.ResolveHarness
  alias SdrAgent.Test.StatusHarness

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

      # C2-02c 2b: with no coordinator the status is unavailable; the
      # server and its attestation are unknown, not positively absent.
      {:ok, view, _html} = live(admin, ~p"/admin")
      assert has_element?(view, "#model-provider", "ClaudeCLI")

      assert has_element?(
               view,
               "#effective-provider[data-effective='none']",
               "status_unavailable"
             )

      assert has_element?(view, "#provider-server[data-status='unknown']")
      assert has_element?(view, "#model-attestation[data-status='unknown']")

      tree!(command_args: [@fake, "model_drift"])

      {:ok, view, _html} = live(admin, ~p"/admin")
      assert has_element?(view, "#model-alias", "opus")
      assert has_element?(view, "#model-id", "claude-opus-5-5")
      assert has_element?(view, "#reviewed-cli-version", "2.1.294")
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

      # A coordinator that positively runs no server: not running. (Last:
      # it retries its boot.)
      StatusHarness.stop_tree!()
      no_server_tree!()
      {:ok, view, _html} = live(admin, ~p"/admin")

      assert has_element?(
               view,
               "#effective-provider[data-effective='none']",
               "provider_not_running"
             )

      assert has_element?(view, "#provider-server[data-status='not_running']")
      assert has_element?(view, "#model-attestation[data-status='not_running']")
    end

    test "R0-02: ClaudeCLI shows the pinned CLI path it launches, without running it",
         %{conn: conn} do
      bin = SdrAgent.Test.PinnedCLI.store_path!()
      put_env!(:model_provider, SdrAgent.AI.ModelProvider.ClaudeCLI)
      put_env!(SdrAgent.AI.ModelProvider.ClaudeCLI, executable: bin)

      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
      assert has_element?(view, "#pinned-cli-path", bin)
    end

    # R0-05 GREEN migration (contract section 1): the configured and
    # effective profile lines became the desired, running and accepting
    # lines. The Fake has no desired profile; it runs and accepts on its
    # in-process profile, with no refusal.
    test "R0-05: the Fake shows its profile as running and accepting, with no refusal",
         %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")

      refute has_element?(view, "#desired-profile")
      assert has_element?(view, "#running-profile[data-profile='fake']", "fake")
      assert has_element?(view, "#accepting-calls[data-accepting='yes']", "yes, on fake")
      refute has_element?(view, "#accepting-calls[data-refusal]")
      refute has_element?(view, "#provider-refusal")
    end

    # R0-05 GREEN migration (contract section 1): `#configured-profile`
    # became `#desired-profile` (the coordinator's confirmed desired
    # profile, unknown without one) and `#effective-profile` became
    # `#running-profile` and `#accepting-calls`.
    test "R0-05: a refused ClaudeCLI shows its profile, no effective profile and the reason",
         %{conn: conn} do
      bin = SdrAgent.Test.PinnedCLI.store_path!()
      put_env!(:model_provider, SdrAgent.AI.ModelProvider.ClaudeCLI)
      put_env!(SdrAgent.AI.ModelProvider.ClaudeCLI, executable: bin)
      admin = sign_in(conn, :admin)

      # C2-02c 2b: with no coordinator the profile is unknown, never the
      # registry default, and the reason is the unavailable status.
      {:ok, view, _html} = live(admin, ~p"/admin")
      assert has_element?(view, "#desired-profile[data-profile='unknown']", "unknown")
      refute has_element?(view, "#desired-profile", "claude_cli_opus")
      assert has_element?(view, "#running-profile[data-profile='unknown']")

      assert has_element?(
               view,
               "#accepting-calls[data-accepting='no'][data-refusal='status_unavailable']"
             )

      assert has_element?(
               view,
               "#provider-refusal[data-refusal='status_unavailable']",
               "status is unavailable"
             )

      # A coordinator that positively runs no server: refused, at its
      # confirmed desired (default) profile.
      no_server_tree!()
      {:ok, view, _html} = live(admin, ~p"/admin")

      assert has_element?(
               view,
               "#desired-profile[data-profile='claude_cli_opus'][data-source='default']",
               "(default)"
             )

      assert has_element?(view, "#running-profile[data-profile='none']")

      assert has_element?(
               view,
               "#accepting-calls[data-accepting='no'][data-refusal='provider_not_running']"
             )

      assert has_element?(
               view,
               "#provider-refusal[data-refusal='provider_not_running']",
               "no supervised ClaudeCLI server"
             )

      assert has_element?(view, "#pinned-cli-path", bin)
      assert has_element?(view, "#pinned-cli-version", "Claude Code 2.1.294")
    end

    test "R0-02: the Fake shows no pinned CLI", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
      refute has_element?(view, "#pinned-cli-path")
    end
  end

  test "the provider card refreshes when a call commits (attestation drift is seen live)",
       %{conn: conn} = ctx do
    # R0-07 slice B: real calls are admitted only with a promoted tuple.
    SdrAgent.AdmissionFixtures.admit_tuples!()

    # C2-02c: the card samples the coordinator and its bound server.
    tree!(
      command_args: [Path.expand("../../support/fake_claude_cli.exs", __DIR__), "model_drift"]
    )

    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    assert has_element?(view, "#model-attestation[data-status='not_applicable']")

    put_env!(:model_provider, SdrAgent.AI.ModelProvider.ClaudeCLI)
    # C9: the real-model call is charged to a grant.
    SdrAgent.AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
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

  # C2-02c: the provider card is the coordinator's row plus its bound
  # server's sample, so ClaudeCLI cases run the profile tree (the fake CLI
  # under the test launcher, launches admitted; `server` adds ClaudeCLI
  # options), released.
  defp tree!(server) do
    ResolveHarness.lease_cleanup!()

    StatusHarness.tree!(
      server: [launch_admission: &SdrAgent.Test.LaunchAdmission.admitted/3] ++ server
    )

    ResolveHarness.await_status!(&(&1.hold == :released))
    ResolveHarness.drain!()
  end

  # The profile tree whose every start fails before the server's init
  # returns: the coordinator positively binds no server.
  defp no_server_tree! do
    ResolveHarness.lease_cleanup!()
    StatusHarness.tree!(server: [timeout: 1])

    ResolveHarness.await!(
      fn ->
        match?(
          %{observed_profile: :none, desired_profile: %{profile_id: _}},
          SdrAgent.AI.ModelProvider.Runtime.status()
        )
      end,
      10_000,
      "fixture: the coordinator never bound no server"
    )
  end
end
