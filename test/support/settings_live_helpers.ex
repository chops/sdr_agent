defmodule SdrAgentWeb.SettingsLiveHelpers do
  @moduledoc """
  Helpers for the C4-01b LiveView tests (`docs/product/c4/readiness.md`,
  section 5 tests 23 (LiveView part), 29, 30 and 31): the settings page at
  `/settings` (`SdrAgentWeb.SettingsLive`) and the run page's settings
  summary.

  The page is reached only through `open_settings/2` or `try_settings/1`,
  which first assert that `/settings` is routed to `SdrAgentWeb.SettingsLive`,
  so on a tree without C4-01b each test fails on an explicit `C4-01b: ...`
  assertion after its fixtures, never on a crash of the router.

  The page interface these tests rely on (chosen by the RED where the packet
  is silent; see each test module):

    * `#edit-<kind>` (`phx-click="edit_settings"`, `phx-value-kind`) opens
      the one edit form `#settings-form`, whose params live under
      `settings_content` (packet section 3.6) and whose submit is the
      review step (`#settings-review`);
    * `confirm_settings` (the `#settings-confirm` form, submit button
      `#confirm-settings`, raise checkboxes `confirm_raised[]`) saves the
      review the socket holds, and only that;
    * a stale save shows `#settings-stale` with `#reload-settings`;
      a refusal shows `#settings-error-<field>` next to the input.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest
  import SdrAgentWeb.OperatorCase, only: [sign_in: 2]

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias SdrAgent.Repo

  @endpoint SdrAgentWeb.Endpoint
  @live SdrAgentWeb.SettingsLive

  @doc "The settings LiveView module (C4-01b)."
  def settings_live, do: @live

  @doc "Asserts that `GET /settings` is a LiveView route to `SdrAgentWeb.SettingsLive`."
  def assert_settings_route! do
    info = Phoenix.Router.route_info(SdrAgentWeb.Router, "GET", "/settings", "localhost")

    assert match?(%{phoenix_live_view: {@live, _action, _opts, _session}}, info),
           "C4-01b: /settings is not routed to #{inspect(@live)}"

    assert Code.ensure_loaded?(@live), "C4-01b: #{inspect(@live)} is not compiled"
    :ok
  end

  @doc """
  `live/2` on `/settings` with `conn` (route asserted first); returns the
  raw result (`{:ok, view, html}` or `{:error, redirect}`).
  """
  def try_settings(conn) do
    assert_settings_route!()
    live(conn, "/settings")
  end

  @doc "`/settings` signed in as the seeded operator with `role`; asserts it is served."
  def open_settings(conn \\ build_conn(), role) do
    result = conn |> sign_in(role) |> try_settings()

    assert match?({:ok, _view, _html}, result),
           "C4-01b: /settings was not served to #{role}: #{inspect(result, limit: 6)}"

    {:ok, view, _html} = result
    view
  end

  @doc "Opens the edit form of `kind` (`#edit-<kind>`)."
  def edit(view, kind) do
    view |> element("#edit-#{kind}") |> render_click()
    view
  end

  @doc "Sends a change of the edit form (params under `settings_content`)."
  def change(view, params) do
    view |> form("#settings-form", settings_content: params) |> render_change()
    view
  end

  @doc "Submits the edit form for review (params under `settings_content`)."
  def review(view, params) do
    view |> form("#settings-form", settings_content: params) |> render_submit()
    view
  end

  @doc """
  Sends `confirm_settings` with the ticked raise confirmations. The page acts
  only on the review its socket holds; the event params carry nothing but
  the admin's ticks (`confirm_raised`).
  """
  def confirm(view, raised \\ []) do
    render_submit(view, "confirm_settings", %{"confirm_raised" => Enum.map(raised, &to_string/1)})
  end

  @doc "The number of `settings.revision.created` events of `tenant`."
  def revision_events(tenant),
    do: tenant |> SdrAgent.AuditCase.events_of_type("settings.revision.created") |> length()

  @doc "The revision of `kind` numbered `number`, read as `actor`; nil when none."
  def revision(actor, kind, number) do
    SdrAgent.Agents.SettingsRevision
    |> Ash.Query.filter(kind == ^kind and number == ^number)
    |> Ash.read_one!(actor: actor)
  end

  @doc """
  Makes every AuditAccess insert fail inside the test's sandbox transaction
  (the S12b technique), so an audited view must fail closed.
  """
  def refuse_access_inserts! do
    SQL.query!(Repo, """
    CREATE FUNCTION c4_01b_refuse_access() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'access store unavailable'; END; $$
    """)

    SQL.query!(
      Repo,
      "CREATE TRIGGER c4_01b_refuse_access BEFORE INSERT ON audit_accesses " <>
        "FOR EACH ROW EXECUTE FUNCTION c4_01b_refuse_access()"
    )

    :ok
  end

  @doc "Whether `result` is a LiveView redirect to `to`."
  def redirected_to?({:error, {kind, %{to: to}}}, to) when kind in [:redirect, :live_redirect],
    do: true

  def redirected_to?(_result, _to), do: false
end
