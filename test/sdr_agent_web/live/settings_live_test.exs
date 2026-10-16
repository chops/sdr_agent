defmodule SdrAgentWeb.SettingsLiveTest do
  @moduledoc """
  C4-01b (`docs/product/c4/readiness.md`, section 5 tests 29, 30 and the
  settings-page part of 31; C4-R1, C4-R2, C4-R3, C4-R10, C4-R11, C4-R14;
  OQ-6; section 6): the settings page at `/settings` in the operator live
  session.

    * Test 29, the admin's staged editor, after the C9-05 grant editor
      (`SdrAgentWeb.AdminLive`, `SdrAgentWeb.GrantForm`): an edit form, an
      in-page review step and a confirmation; only the confirmation calls
      `SdrAgent.Agents.create_settings_revision/2`, as the signed-in user,
      with the revision number the admin saw when the form was opened; a
      stale save shows a reload prompt; domain refusals are shown next to
      their fields; a forged confirmation without a held review does
      nothing; a demoted, disabled or signed-out admin never reaches the
      domain.
    * Test 30, the read-only view per the field policy: reviewers read
      settings text, read-only (OQ-6); an auditor's view records an
      AuditAccess through `SdrAgentWeb.AuditedView` and fails closed;
      signed-out visitors are redirected to sign-in.
    * Test 31 (page part): values, built-in defaults and their versions,
      validation ranges, sources, "not yet enforced" labels, the per-field
      raise confirmation, tenant-day limits and the safeguard list
      (`SdrAgent.Agents.RunSettings.Safeguards`), and the admin page's link.

  RED: `/settings` is not routed (`SdrAgentWeb.SettingsLiveHelpers`
  asserts the route after the fixtures), and the admin page has no link.
  All content is synthetic (reserved `example.test` hosts).
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.SettingsFixtures,
    only: [
      content: 1,
      content: 2,
      int_max: 0,
      latest_number: 2,
      limit_defaults: 0,
      limit_minimums: 0,
      save!: 3,
      save_offering!: 1
    ]

  import SdrAgentWeb.SettingsLiveHelpers

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.AuditCase
  alias SdrAgent.Outreach.Compliance
  alias SdrAgent.Test.SecretShapes

  @moduletag :c4_01b

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]
  @link "https://book.example.test/demo/intro"

  defp first_line(text), do: text |> String.split("\n") |> hd()

  defp forged_confirm(view) do
    forged = %{
      "kind" => "booking_link",
      "expected_number" => "0",
      "settings_content" => %{"url" => "https://forged.example.test/x"},
      "confirm_raised" => []
    }

    render_submit(view, "confirm_settings", forged)
    render_click(view, "confirm_settings", forged)
  end

  describe "test 29: the admin's staged editor" do
    test "a booking link is saved through review and confirmation, audited",
         %{conn: conn} = ctx do
      view = open_settings(conn, :admin)

      for kind <- @kinds do
        assert has_element?(view, "#edit-#{kind}"), "C4-01b: no edit control for #{kind}"
      end

      refute has_element?(view, "#settings-form")

      edit(view, :booking_link)
      assert has_element?(view, "#settings-form[data-kind='booking_link']")

      review(view, %{url: @link, note: "First booking link"})

      assert has_element?(view, "#settings-review", @link), "C4-01b: no review step"
      assert has_element?(view, "#settings-review", "revision 1")
      assert has_element?(view, "#settings-confirm #confirm-settings")
      # Nothing is saved before the confirmation.
      assert latest_number(ctx.tenant.id, :booking_link) == 0,
             "C4-01b: the review step saved before the confirmation"

      assert revision_events(ctx.tenant) == 0

      confirm(view)

      saved = revision(ctx.admin, :booking_link, 1)
      assert saved, "C4-01b: the confirmation saved nothing"
      assert saved.booking_link.url == @link
      assert saved.note == "First booking link"
      assert saved.supersedes_id == nil
      assert saved.created_by_id == ctx.admin.id

      admin_id = ctx.admin.id
      events = events_of_type(ctx.tenant, "settings.revision.created")
      assert match?([%{actor_id: ^admin_id}], events)

      refute has_element?(view, "#settings-review")
      refute has_element?(view, "#settings-form")

      assert has_element?(
               view,
               "#settings-booking_link-source[data-source='revision']",
               "revision 1"
             )

      assert has_element?(view, "#settings-booking_link-value", @link)
    end

    test "an edit is saved against the revision seen and supersedes it", %{conn: conn} = ctx do
      first = save!(:writing_guide, %{text: "Guide revision one."}, ctx.admin)
      view = conn |> open_settings(:admin) |> edit(:writing_guide)

      assert has_element?(
               view,
               "#settings-form textarea[name='settings_content[text]']",
               "Guide revision one."
             )

      review(view, %{text: "Guide revision two."})
      assert has_element?(view, "#settings-review", "revision 2")
      assert latest_number(ctx.tenant.id, :writing_guide) == 1

      confirm(view)

      second = revision(ctx.admin, :writing_guide, 2)
      assert second, "C4-01b: the edit was not saved as revision 2"
      assert second.supersedes_id == first.id
      assert second.writing_guide.text == "Guide revision two."

      assert has_element?(
               view,
               "#settings-writing_guide-source[data-source='revision']",
               "revision 2"
             )
    end

    test "a stale save is refused with a reload prompt and nothing is written",
         %{conn: conn} = ctx do
      save!(:writing_guide, %{text: "Guide revision one."}, ctx.admin)
      view = conn |> open_settings(:admin) |> edit(:writing_guide)

      # Another admin saves while the form is open (before the review).
      other = AuditCase.human(:admin, ctx.tenant)
      second = save!(:writing_guide, %{text: "Another admin's guide."}, other)

      review(view, %{text: "My guide."})
      confirm(view)

      assert has_element?(view, "#settings-stale", "revision 2"),
             "C4-01b: a stale save showed no reload prompt naming the latest revision"

      assert has_element?(view, "#settings-stale #reload-settings")
      assert latest_number(ctx.tenant.id, :writing_guide) == 2
      assert revision(ctx.admin, :writing_guide, 2).writing_guide.text == "Another admin's guide."
      assert revision_events(ctx.tenant) == 2

      view |> element("#reload-settings") |> render_click()

      refute has_element?(view, "#settings-stale")

      assert has_element?(
               view,
               "#settings-form textarea[name='settings_content[text]']",
               "Another admin's guide."
             )

      review(view, %{text: "My guide."})
      confirm(view)

      third = revision(ctx.admin, :writing_guide, 3)
      assert third, "C4-01b: the save after the reload was not revision 3"
      assert third.supersedes_id == second.id
      assert third.writing_guide.text == "My guide."
    end

    test "a first save raced by another admin is stale against revision 1", %{conn: conn} = ctx do
      view = conn |> open_settings(:admin) |> edit(:booking_link)
      other = AuditCase.human(:admin, ctx.tenant)
      save!(:booking_link, %{url: "https://book.example.test/other"}, other)

      review(view, %{url: @link})
      confirm(view)

      assert has_element?(view, "#settings-stale", "revision 1"),
             "C4-01b: a raced first save showed no reload prompt"

      assert latest_number(ctx.tenant.id, :booking_link) == 1

      assert revision(ctx.admin, :booking_link, 1).booking_link.url ==
               "https://book.example.test/other"
    end

    test "domain refusals are shown next to their fields, the input is kept, nothing is written",
         %{conn: conn} = ctx do
      view = conn |> open_settings(:admin) |> edit(:booking_link)
      review(view, %{url: "http://book.example.test/demo/intro"})
      confirm(view)

      assert has_element?(view, "#settings-error-url"),
             "C4-01b: the booking link refusal is not shown next to the url"

      refute has_element?(view, "#settings-review")

      assert has_element?(
               view,
               "#settings-form input[name='settings_content[url]'][value='http://book.example.test/demo/intro']"
             )

      assert latest_number(ctx.tenant.id, :booking_link) == 0

      # A secret-shaped guide: the refusal names the field, never the value.
      secret = SecretShapes.provider_key()
      edit(view, :writing_guide)
      review(view, %{text: "Plain guide. " <> secret})
      confirm(view)

      assert has_element?(view, "#settings-error-text"),
             "C4-01b: the guide refusal is not shown next to the text"

      refute view |> element("#settings-error-text") |> render() =~ secret
      assert latest_number(ctx.tenant.id, :writing_guide) == 0

      # Limits: below a minimum, and not a whole number.
      edit(view, :operational_limits)
      review(view, %{research_max_source_chars: "100", run_max_tool_calls: "four"})
      confirm(view)

      assert has_element?(view, "#settings-error-research_max_source_chars"),
             "C4-01b: the out-of-range limit is not shown next to its input"

      assert has_element?(view, "#settings-error-run_max_tool_calls"),
             "C4-01b: the non-integer limit is not shown next to its input"

      assert has_element?(
               view,
               "#settings-form input[name='settings_content[research_max_source_chars]'][value='100']"
             )

      assert latest_number(ctx.tenant.id, :operational_limits) == 0
      assert revision_events(ctx.tenant) == 0
    end

    test "a forged confirmation without a held review does nothing; only the review is saved",
         %{conn: conn} = ctx do
      view = open_settings(conn, :admin)

      forged_confirm(view)

      assert latest_number(ctx.tenant.id, :booking_link) == 0,
             "C4-01b: a forged confirmation without a review saved"

      edit(view, :booking_link)
      forged_confirm(view)

      assert latest_number(ctx.tenant.id, :booking_link) == 0,
             "C4-01b: a forged confirmation during the edit step saved"

      review(view, %{url: @link})

      assert latest_number(ctx.tenant.id, :booking_link) == 0,
             "C4-01b: the review step saved before the confirmation"

      # Even with forged params, the confirmation saves exactly the held review.
      forged_confirm(view)

      saved = revision(ctx.admin, :booking_link, 1)
      assert saved, "C4-01b: the confirmation of a held review saved nothing"
      assert saved.booking_link.url == @link
      assert latest_number(ctx.tenant.id, :booking_link) == 1
      assert revision_events(ctx.tenant) == 1
    end

    test "malformed events neither crash the page nor write", %{conn: conn} = ctx do
      view = conn |> open_settings(:admin) |> edit(:offering_profile)

      render_change(view, "change_settings", %{"settings_content" => "x"})
      render_submit(view, "review_settings", %{"settings_content" => "x"})
      render_submit(view, "review_settings", %{})

      render_submit(view, "review_settings", %{
        "settings_content" => %{"name" => %{"x" => "y"}, "items" => "x", "colour" => "blue"}
      })

      render_submit(view, "review_settings", %{
        "settings_content" => %{"items" => %{"0" => "x", "one" => ["y"]}}
      })

      render_click(view, "edit_settings", %{"kind" => "not_a_kind"})
      render_click(view, "edit_settings", %{"kind" => %{"x" => 1}})
      render_click(view, "edit_settings", %{})
      render_submit(view, "confirm_settings", %{"confirm_raised" => "x"})
      render_submit(view, "confirm_settings", %{"confirm_raised" => ["not_a_limit"]})

      assert has_element?(view, "#settings-offering_profile")
      refute has_element?(view, "#settings-review")
      assert revision_events(ctx.tenant) == 0

      for kind <- @kinds, do: assert(latest_number(ctx.tenant.id, kind) == 0)
    end
  end

  describe "test 29: a changed operator never reaches the domain" do
    # A review held by the signed-in admin; another admin remains, so the
    # signed-in one can be demoted or disabled.
    defp staged(ctx) do
      view = ctx.conn |> open_settings(:admin) |> edit(:booking_link) |> review(%{url: @link})
      Map.merge(ctx, %{view: view, other: AuditCase.human(:admin, ctx.tenant)})
    end

    test "an admin demoted while connected cannot save", ctx do
      ctx = staged(ctx)
      {:ok, _demoted} = Accounts.change_role(ctx.admin, :reviewer, actor: ctx.other)

      result = confirm(ctx.view)

      assert latest_number(ctx.tenant.id, :booking_link) == 0,
             "C4-01b: a demoted admin's confirmation saved"

      assert denials_of(ctx, ctx.admin) == [],
             "C4-01b: the demoted admin's confirmation reached the domain"

      unless redirected_to?(result, "/") do
        refute has_element?(ctx.view, "#settings-review")
        refute has_element?(ctx.view, "#edit-booking_link")
      end
    end

    test "an admin disabled while connected is signed out before the domain is called", ctx do
      ctx = staged(ctx)
      {:ok, _disabled} = Accounts.change_status(ctx.admin, :disabled, actor: ctx.other)

      result = confirm(ctx.view)

      assert redirected_to?(result, "/sign-in"),
             "C4-01b: a disabled admin was not signed out: #{inspect(result, limit: 4)}"

      assert latest_number(ctx.tenant.id, :booking_link) == 0
      assert denials_of(ctx, ctx.admin) == []
    end

    test "an admin whose sessions were revoked is signed out before the domain is called",
         ctx do
      ctx = staged(ctx)
      password = String.duplicate("a", 12) <> "-reset-0"

      {:ok, _reset} =
        Accounts.set_password(ctx.admin, %{password: password, password_confirmation: password},
          actor: ctx.other
        )

      result = confirm(ctx.view)

      assert redirected_to?(result, "/sign-in"),
             "C4-01b: a revoked session was not signed out: #{inspect(result, limit: 4)}"

      assert latest_number(ctx.tenant.id, :booking_link) == 0
    end
  end

  describe "test 30: the read-only view and the audited auditor view" do
    test "a reviewer reads the settings text, read-only (OQ-6)", %{conn: conn} = ctx do
      save_offering!(ctx.admin)
      save!(:booking_link, %{url: @link}, ctx.admin)
      save!(:writing_guide, %{text: "Reviewer-visible guide."}, ctx.admin)
      reviewer = user!(ctx, :reviewer)

      view = open_settings(conn, :reviewer)

      assert has_element?(view, "#settings-writing_guide-value", "Reviewer-visible guide.")
      assert has_element?(view, "#settings-offering_profile-value", "Example Widgets Scheduler")

      assert has_element?(
               view,
               "#settings-offering_profile-value",
               "Syncs synthetic team calendars."
             )

      assert has_element?(view, "#settings-booking_link-value", @link)

      for kind <- @kinds do
        refute has_element?(view, "#edit-#{kind}"), "C4-01b: a reviewer can edit #{kind}"
      end

      render_click(view, "edit_settings", %{"kind" => "writing_guide"})
      refute has_element?(view, "#settings-form"), "C4-01b: a reviewer opened the edit form"

      render_submit(view, "review_settings", %{"settings_content" => %{"text" => "Forged."}})
      forged_confirm(view)

      assert latest_number(ctx.tenant.id, :writing_guide) == 1
      assert latest_number(ctx.tenant.id, :booking_link) == 1
      assert denials_of(ctx, reviewer) == [], "C4-01b: a reviewer's event reached the domain"
      assert accesses_of(ctx, reviewer) == []
    end

    test "an auditor's view is recorded as an AuditAccess naming the revisions shown",
         %{conn: conn} = ctx do
      offering = save_offering!(ctx.admin)
      guide = save!(:writing_guide, %{text: "Auditor-visible guide."}, ctx.admin)
      auditor = user!(ctx, :auditor)

      view = open_settings(conn, :auditor)

      accesses = accesses_of(ctx, auditor)

      assert match?(
               [
                 %{access_kind: :record_view, target_resource: "SdrAgent.Agents.SettingsRevision"}
               ],
               accesses
             ),
             "C4-01b: the auditor's settings view was not recorded once: " <>
               inspect(accesses, limit: 4)

      [access] = accesses

      assert MapSet.new(String.split(access.target_ref, ",")) ==
               MapSet.new([offering.id, guide.id])

      assert has_element?(view, "#settings-writing_guide-value", "Auditor-visible guide.")

      for kind <- @kinds do
        refute has_element?(view, "#edit-#{kind}"), "C4-01b: an auditor can edit #{kind}"
      end
    end

    test "an auditor's view fails closed when the access cannot be recorded",
         %{conn: conn} = ctx do
      save!(:writing_guide, %{text: "Withheld guide text."}, ctx.admin)
      conn = sign_in(conn, :auditor)
      refuse_access_inserts!()

      result = try_settings(conn)

      assert match?({:ok, _view, _html}, result),
             "C4-01b: the page crashed instead of failing closed"

      {:ok, view, html} = result

      assert has_element?(view, "#withheld"), "C4-01b: the unrecorded auditor view was served"
      refute html =~ "Withheld guide text."
      refute render(view) =~ "Withheld guide text."
      refute has_element?(view, "#settings-writing_guide-value")
    end

    test "a signed-out visitor is redirected to sign-in", %{conn: conn} do
      result = try_settings(conn)

      assert redirected_to?(result, "/sign-in"),
             "C4-01b: /settings was served without a signed-in operator: " <>
               inspect(result, limit: 4)
    end
  end

  describe "test 31: what the settings page shows" do
    test "unset settings and built-in defaults are labelled with their source and version",
         %{conn: conn} do
      view = open_settings(conn, :reviewer)

      for kind <- [:offering_profile, :booking_link] do
        assert has_element?(view, "#settings-#{kind}-source[data-source='absent']", "not set"),
               "C4-01b: #{kind} is not labelled as not set"
      end

      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        %{version: version} = CodeDefaults.current(kind)

        assert has_element?(
                 view,
                 "#settings-#{kind}-source[data-source='code_default']",
                 "built-in default version #{version}"
               ),
               "C4-01b: #{kind} is not labelled as its built-in default"

        assert has_element?(view, "#settings-#{kind}-source", "not yet reviewed by you")
      end

      guide = CodeDefaults.current(:writing_guide).content.text
      brief = CodeDefaults.current(:research_brief).content.guidance
      assert has_element?(view, "#settings-writing_guide-value", first_line(guide))
      assert has_element?(view, "#settings-research_brief-value", first_line(brief))
    end

    test "a saved setting is labelled with its revision number", %{conn: conn} = ctx do
      save!(:writing_guide, %{text: "Guide revision one."}, ctx.admin)
      save!(:writing_guide, %{text: "Guide revision two."}, ctx.admin)

      view = open_settings(conn, :admin)

      assert has_element?(
               view,
               "#settings-writing_guide-source[data-source='revision']",
               "revision 2"
             ),
             "C4-01b: the saved guide is not labelled with its revision"

      refute has_element?(view, "#settings-writing_guide-source", "not yet reviewed by you")
      assert has_element?(view, "#settings-writing_guide-value", "Guide revision two.")
      refute has_element?(view, "#settings-writing_guide-value", "Guide revision one.")
    end

    test "every limit shows its value, built-in default, validation range and enforcement",
         %{conn: conn} = ctx do
      view = open_settings(conn, :admin)
      defaults = limit_defaults()
      minimums = limit_minimums()
      rules = Safeguards.limit_rules()

      for {field, _rule} <- rules do
        selector =
          "#limit-#{field}[data-value='#{defaults[field]}'][data-default='#{defaults[field]}']" <>
            "[data-min='#{minimums[field]}'][data-max='#{int_max()}']"

        assert has_element?(view, selector),
               "C4-01b: limit #{field} does not show its value, default and range"

        assert has_element?(view, "#limit-#{field}-range", ~r/2,?147,?483,?647/),
               "C4-01b: limit #{field} does not show its validation range"
      end

      # Section 3.3 at this tree: only the three run_* limits are enforced.
      enforced = for {field, %{enforced_by: by}} <- rules, by, do: field
      assert enforced == [:run_max_model_calls, :run_max_tool_calls, :run_max_tokens]

      for {field, _rule} <- rules do
        if field in enforced do
          refute has_element?(view, "#limit-#{field}", "not yet enforced"),
                 "C4-01b: enforced limit #{field} is labelled not yet enforced"
        else
          assert has_element?(view, "#limit-#{field}", "not yet enforced"),
                 "C4-01b: limit #{field} is not labelled not yet enforced"
        end
      end

      lowered = content(:operational_limits, %{run_max_tool_calls: 50})
      save!(:operational_limits, lowered, ctx.admin)
      view = open_settings(conn, :admin)

      assert has_element?(view, "#limit-run_max_tool_calls[data-value='50'][data-default='60']")

      assert has_element?(
               view,
               "#settings-operational_limits-source[data-source='revision']",
               "revision 1"
             )
    end

    test "tenant-day limits are shown read-only", %{conn: conn} do
      view = open_settings(conn, :admin)

      assert has_element?(view, "#tenant-limits", "#{Agents.daily_model_call_limit()}"),
             "C4-01b: the daily model-call limit is not shown"

      assert has_element?(view, "#tenant-limits", "#{Compliance.daily_send_cap()}")
      refute has_element?(view, "#tenant-limits input")
    end

    test "the fixed safeguards are listed read-only with their reasons", %{conn: conn} do
      view = open_settings(conn, :reviewer)

      for entry <- Safeguards.entries() do
        assert has_element?(view, "#safeguards li", entry.name),
               "C4-01b: safeguard #{entry.name} is not listed"

        assert has_element?(view, "#safeguards li", entry.reason)
      end

      refute has_element?(view, "#safeguards input")
      refute has_element?(view, "#safeguards button")
    end

    test "a raise is confirmed per field, naming old, new, default and the budgets that bound it",
         %{conn: conn} = ctx do
      view = conn |> open_settings(:admin) |> edit(:operational_limits)
      review(view, %{run_max_model_calls: "30", run_max_tool_calls: "50"})

      assert has_element?(
               view,
               "#raise-run_max_model_calls[data-from='20'][data-to='30'][data-default='20']"
             ),
             "C4-01b: the review does not ask to confirm the raise"

      assert has_element?(
               view,
               "#raise-run_max_model_calls",
               "#{Agents.daily_model_call_limit()}"
             )

      assert has_element?(view, "#raise-run_max_model_calls", ~r/grant/i)
      # A lowering needs no confirmation.
      refute has_element?(view, "#raise-run_max_tool_calls")

      assert has_element?(
               view,
               "#settings-confirm input[type='checkbox'][name='confirm_raised[]']" <>
                 "[value='run_max_model_calls']"
             )

      refute has_element?(view, "#settings-confirm input[value='run_max_tool_calls']")

      # Not ticked: refused next to the confirmation, nothing written.
      confirm(view, [])

      assert has_element?(view, "#settings-error-confirm_raised"),
             "C4-01b: an unconfirmed raise was not refused visibly"

      refute has_element?(view, "#settings-review")
      assert latest_number(ctx.tenant.id, :operational_limits) == 0

      assert has_element?(
               view,
               "#settings-form input[name='settings_content[run_max_model_calls]'][value='30']"
             )

      review(view, %{run_max_model_calls: "30", run_max_tool_calls: "50"})
      confirm(view, [:run_max_model_calls])

      saved = revision(ctx.admin, :operational_limits, 1)
      assert saved, "C4-01b: the confirmed raise was not saved"
      assert saved.raised_fields == [:run_max_model_calls]
      assert saved.operational_limits.run_max_model_calls == 30
      assert saved.operational_limits.run_max_tool_calls == 50
      assert has_element?(view, "#limit-run_max_model_calls[data-value='30'][data-default='20']")
    end

    test "the research brief and offering forms carry their structured fields",
         %{conn: conn} = ctx do
      view = conn |> open_settings(:admin) |> edit(:research_brief)
      review(view, %{guidance: "Look for synthetic scheduling needs.", depth: "standard"})

      assert latest_number(ctx.tenant.id, :research_brief) == 0,
             "C4-01b: the review step saved before the confirmation"

      confirm(view)

      brief = revision(ctx.admin, :research_brief, 1)
      assert brief, "C4-01b: the brief was not saved"
      assert brief.research_brief.depth == :standard

      edit(view, :offering_profile)

      review(view, %{
        name: "Example Widgets Scheduler",
        summary: "A synthetic scheduling product.",
        audience: "Synthetic operations teams.",
        items: %{"0" => %{id: "calendar_sync", kind: "feature", text: "Syncs calendars."}}
      })

      assert has_element?(view, "#settings-review", "calendar_sync")
      assert latest_number(ctx.tenant.id, :offering_profile) == 0
      confirm(view)

      offering = revision(ctx.admin, :offering_profile, 1)
      assert offering, "C4-01b: the offering was not saved"

      assert Enum.map(offering.offering_profile.items, &{&1.id, &1.kind, &1.text}) == [
               {"calendar_sync", :feature, "Syncs calendars."}
             ]

      assert content(:offering_profile).name == offering.offering_profile.name
    end

    test "the admin page links to the settings page", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")

      assert has_element?(view, "a[href='/settings']"),
             "C4-01b: /admin does not link to /settings"
    end
  end
end
