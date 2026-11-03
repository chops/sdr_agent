defmodule SdrAgentWeb.OwnerIntakeLiveTest do
  @moduledoc """
  RED (notes/features/owner-prospect-intake.org; ADR-0026): the owner-only
  "Add prospect" panel on the existing /leads page. It previews through
  `SdrAgent.Prototype.OwnerIntake.preview/2` (kept in server assigns, never
  accepted from the client) and saves through `commit/3`. It discloses that
  the prospect is owner-supplied and not independently verified, and that
  correction is not supported in this version. Refusals render fixed
  messages that never echo submitted values. Saving never assigns, runs a
  model or creates an operation.

  Synthetic `.test` values only; no model, CLI or network.
  """
  use SdrAgentWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Repo

  @sentinel_excerpt "SENTINEL-EXCERPT-7f3a builds warehouse robots."
  @sentinel_email "sentinel-7f3a@acme-intake.test"

  setup do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    signed = H.consume!(enrolled.enrollment_token)
    assert {:ok, auditor_token, _} = AshAuthentication.Jwt.token_for_user(ctx.fx.auditor)
    H.enter!(ctx)

    Map.merge(ctx, %{
      enrolled: enrolled,
      user: signed,
      token: signed.__metadata__.token,
      auditor_token: auditor_token
    })
  end

  defp signed_conn(conn, token), do: init_test_session(conn, %{"user_token" => token})

  defp open(ctx, token \\ nil) do
    {:ok, view, _html} = ctx.conn |> signed_conn(token || ctx.token) |> live("/leads")
    view
  end

  defp form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "company_name" => "Acme Intake",
        "domain" => "ACME-Intake.test",
        "website_url" => "https://www.acme-intake.test/",
        "first_name" => "Avery",
        "last_name" => "Intake",
        "title" => "VP Operations",
        "email" => "Avery@Acme-Intake.test",
        "sources" => %{
          "0" => %{
            "url" => "https://www.acme-intake.test/",
            "source_type" => "company_site",
            "retrieved_on" => "2026-10-30",
            "excerpt" => "Acme Intake builds warehouse robots."
          }
        }
      },
      overrides
    )
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  defp counts, do: Enum.map(~w(leads contacts accounts operations model_invocations), &count/1)

  defp open_panel(view) do
    assert has_element?(view, "#add-prospect"), "no Add prospect control on /leads"
    view |> element("#add-prospect") |> render_click()
    view
  end

  defp preview(view, params) do
    view |> form("#owner-intake-form", intake: params) |> render_submit()
    view
  end

  test "the owner sees Add prospect with the unverified and no-correction disclosures", ctx do
    view = ctx |> open() |> open_panel()
    assert has_element?(view, "#owner-intake-form")
    assert has_element?(view, "#intake-unverified", "not independently verified")
    assert has_element?(view, "#intake-correction-unsupported")
  end

  test "a non-owner sees no panel, and its forged events change nothing", ctx do
    view = open(ctx, ctx.auditor_token)
    refute has_element?(view, "#add-prospect")
    refute has_element?(view, "#owner-intake-form")
    before = counts()

    assert function_exported?(SdrAgentWeb.LeadLive.Index, :handle_event, 3),
           "LeadLive.Index handles no events"

    render_hook(view, "intake_preview", %{"intake" => form_params()})
    render_hook(view, "intake_commit", %{})
    refute has_element?(view, "#intake-preview")
    assert counts() == before
  end

  test "preview shows the normalized prospect and writes nothing", ctx do
    before = counts()
    view = ctx |> open() |> open_panel() |> preview(form_params())
    assert has_element?(view, "#intake-preview")
    assert has_element?(view, "#intake-preview-mode", "New company")
    assert has_element?(view, "#intake-preview-domain", "acme-intake.test")
    assert has_element?(view, "#intake-preview-email", "avery@acme-intake.test")
    assert has_element?(view, "#intake-preview [data-source-key='s1']")
    assert has_element?(view, "#intake-preview #intake-unverified")
    assert counts() == before
  end

  test "saving creates the lead and opens it, with no assignment, operation or model call",
       ctx do
    [leads, contacts, accounts, operations, invocations] = counts()
    view = ctx |> open() |> open_panel() |> preview(form_params())
    view |> element("#intake-commit") |> render_click()
    {path, _flash} = assert_redirect(view)
    assert [_, lead_id] = Regex.run(~r"^/leads/([0-9a-f-]{36})\z", path)
    assert counts() == [leads + 1, contacts + 1, accounts + 1, operations, invocations]
    {:ok, lead} = Ash.get(SdrAgent.Sales.Lead, lead_id, H.kernel(ctx))
    assert lead.status == :new
  end

  test "save without a server-side preview is refused; a client preview is ignored", ctx do
    view = ctx |> open() |> open_panel()
    before = counts()

    render_hook(view, "intake_commit", %{
      "preview" => %{"mode" => "create", "submission_sha256" => String.duplicate("0", 64)}
    })

    assert has_element?(view, "#intake-error", "Preview the prospect")
    assert counts() == before
  end

  test "a non-ASCII domain is refused with a fixed message that echoes nothing", ctx do
    view = ctx |> open() |> open_panel()
    before = counts()
    view = preview(view, form_params(%{"domain" => "exämple-intake.test"}))
    assert has_element?(view, "#intake-error")
    refute render(element(view, "#intake-error")) =~ "exämple"
    refute has_element?(view, "#intake-preview")
    assert counts() == before
  end

  test "a website without a matching company_site source is refused", ctx do
    source = %{
      "url" => "https://www.acme-intake.test/team",
      "source_type" => "company_site",
      "retrieved_on" => "2026-10-30",
      "excerpt" => "Avery Intake leads operations."
    }

    view = ctx |> open() |> open_panel() |> preview(form_params(%{"sources" => %{"0" => source}}))
    assert has_element?(view, "#intake-error", "company website")
    refute has_element?(view, "#intake-preview")
  end

  test "saving the same prospect again opens the existing lead without new rows", ctx do
    view = ctx |> open() |> open_panel() |> preview(form_params())
    view |> element("#intake-commit") |> render_click()
    {first, _} = assert_redirect(view)
    before = counts()
    again = ctx |> open() |> open_panel() |> preview(form_params())
    assert has_element?(again, "#intake-preview-mode", "Already added")
    again |> element("#intake-commit") |> render_click()
    {second, _} = assert_redirect(again)
    assert second == first
    assert counts() == before
  end

  test "an owner disabled after preview cannot save", ctx do
    view = ctx |> open() |> open_panel() |> preview(form_params())
    before = counts()
    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.user)
    render_hook(view, "intake_commit", %{})
    assert counts() == before
  end

  test "submitted excerpt and email never reach the log", ctx do
    params =
      form_params(%{
        "email" => @sentinel_email,
        "sources" => %{
          "0" => %{
            "url" => "https://www.acme-intake.test/",
            "source_type" => "company_site",
            "retrieved_on" => "2026-10-30",
            "excerpt" => @sentinel_excerpt
          }
        }
      })

    log =
      capture_log(fn ->
        view = ctx |> open() |> open_panel() |> preview(params)
        view |> element("#intake-commit") |> render_click()
        assert_redirect(view)
      end)

    refute log =~ "SENTINEL-EXCERPT-7f3a"
    refute log =~ "sentinel-7f3a"
  end
end
