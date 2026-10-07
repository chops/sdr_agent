defmodule SdrAgentWeb.OperatorCase do
  @moduledoc """
  Test case for the operator console (S10 LiveViews): the deterministic demo
  data set seeded as in `SdrAgent.SDRCase` (clock frozen one day after the
  fixture epoch), plus a browser connection signed in as one of the seeded
  operators (`:admin`, `:reviewer`, `:auditor`) through the real password
  strategy, so the LiveView session resolves the user exactly as in the app.
  """
  use ExUnit.CaseTemplate

  import Phoenix.ConnTest

  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed

  using do
    quote do
      @endpoint SdrAgentWeb.Endpoint

      use SdrAgentWeb, :verified_routes
      use Oban.Testing, repo: SdrAgent.Repo

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn
      import SdrAgent.AuditCase, only: [events: 1, events_of_type: 2, hex: 1]
      import SdrAgent.OutreachFixtures
      import SdrAgent.SDRCase, only: [assign!: 2, drain!: 0, fixture_lead!: 2]
      import SdrAgentWeb.OperatorCase
    end
  end

  setup tags do
    SdrAgent.DataCase.setup_sandbox(tags)
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    on_exit(&Clock.unfreeze/0)
    {:ok, _counts} = Seed.run()
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()

    {:ok, tenant} =
      Ash.get(SdrAgent.Audit.Tenant, tenant_id, SdrAgent.Audit.Kernel.opts(tenant_id))

    seeder = Actor.system(:seeder, tenant.id, "test")
    [admin | _] = Fixtures.users()
    {:ok, admin} = Accounts.get_user(admin.id, actor: seeder)

    %{
      conn: build_conn(),
      tenant: tenant,
      admin: admin,
      agent: Actor.system(:agent_runtime, tenant.id),
      aud: Actor.system(:auditor_cli, tenant.id),
      campaign_id: Fixtures.campaign().id
    }
  end

  @doc "`conn` signed in as the seeded operator with `role` (real password sign-in)."
  def sign_in(conn, role) do
    fixture = Enum.find(Fixtures.users(), &(&1.role == role))
    {:ok, user} = Accounts.sign_in(fixture.email, fixture.password)

    conn
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @doc "The seeded operator with `role`, read as ADM."
  def user!(ctx, role) do
    fixture = Enum.find(Fixtures.users(), &(&1.role == role))
    {:ok, user} = Accounts.get_user(fixture.id, actor: ctx.admin)
    user
  end

  @doc "AuditAccess rows recorded for `user`, oldest first (read as ADM)."
  def accesses_of(ctx, user) do
    {:ok, accesses} = SdrAgent.Audit.list_accesses(actor: ctx.admin)
    Enum.filter(accesses, &(&1.actor_id == user.id))
  end

  @doc "`authz.denied` events recorded for `user`."
  def denials_of(ctx, user) do
    ctx.tenant
    |> SdrAgent.AuditCase.events()
    |> Enum.filter(&(&1.event_type == "authz.denied" and &1.actor_id == user.id))
  end
end
