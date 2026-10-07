defmodule SdrAgent.Accounts.BootstrapAdminTest do
  @moduledoc """
  S2 User: "users are created only by ADM create_user or the bootstrap task
  for the first admin". The kernel (KRN) bootstrap works in every
  environment, but only while the tenant has no users, and never records
  the password (PR #9 review, blocker 1).
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User

  setup do
    %{tenant: bootstrap!()}
  end

  @password "first-admin-password-0123"

  defp attrs(password, email \\ "first.admin@example.test") do
    %{
      email: email,
      display_name: "First Admin",
      password: password,
      password_confirmation: password
    }
  end

  test "creates the first admin as the kernel; the password appears in no event or log", ctx do
    password = @password

    log =
      capture_log([level: :debug], fn ->
        send(self(), {:result, Accounts.bootstrap_admin(attrs(password))})
      end)

    assert_received {:result, {:ok, admin}}
    assert {admin.role, admin.status, admin.tenant_id} == {:admin, :active, ctx.tenant.id}

    assert [event] = events_of_type(ctx.tenant, "user.created")
    assert event.actor_type == :kernel
    assert event.action == "bootstrap_admin"
    assert event.subject_id == admin.id

    for event <- events(ctx.tenant) do
      refute event.canonical_bytes =~ password
      refute event.canonical_bytes =~ admin.hashed_password
    end

    refute log =~ password
    assert {:ok, _} = Accounts.sign_in("first.admin@example.test", password)
  end

  test "refuses once the tenant has any user", ctx do
    {:ok, _} = Accounts.bootstrap_admin(attrs(@password))

    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.bootstrap_admin(attrs(@password <> "-2", "second@example.test"))

    assert length(events_of_type(ctx.tenant, "user.created")) == 1
  end

  test "refuses when a non-admin user already exists", ctx do
    _reviewer = new_human(:reviewer, ctx.tenant)

    assert {:error, %Ash.Error.Invalid{}} = Accounts.bootstrap_admin(attrs(@password))

    {:ok, users} = Accounts.list_users(actor: system_actor(:seeder, ctx.tenant))
    refute Enum.any?(users, &(&1.role == :admin))
  end

  test "only a kernel request may run the bootstrap action", ctx do
    password = @password

    for actor <- [
          system_actor(:seeder, ctx.tenant),
          system_actor(:kernel, ctx.tenant),
          system_actor(:agent_runtime, ctx.tenant),
          nil
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Changeset.for_create(:bootstrap_admin, attrs(password), actor: actor)
               |> Ash.create(),
             inspect(actor)
    end

    assert events_of_type(ctx.tenant, "user.created") == []
  end

  test "the first admin's password has at least 16 characters", ctx do
    assert {:error, %Ash.Error.Invalid{}} = Accounts.bootstrap_admin(attrs("fifteen-chars-x"))
    assert events_of_type(ctx.tenant, "user.created") == []
    assert {:ok, _} = Accounts.bootstrap_admin(attrs("sixteen-chars-xy"))
  end
end
