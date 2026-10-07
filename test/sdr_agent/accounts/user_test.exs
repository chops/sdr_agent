defmodule SdrAgent.Accounts.UserTest do
  @moduledoc """
  S2 row User (delta in S5): admin-only user management, roles and status,
  the last-active-admin invariant, password changes (auditors never change
  their own), password sign-in with audited outcomes, and field-restricted
  reads.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User
  alias SdrAgent.Audit

  @password "new-password-5678"

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      auditor: human(:auditor, tenant)
    }
  end

  defp user_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        email: "new.operator@example.test",
        display_name: "New Operator",
        role: :reviewer,
        password: @password,
        password_confirmation: @password
      },
      overrides
    )
  end

  defp new_password(overrides \\ %{}) do
    Map.merge(%{password: @password, password_confirmation: @password}, overrides)
  end

  defp denials(tenant), do: events_of_type(tenant, "authz.denied")

  defp session_valid?(token), do: match?({:ok, _, _}, AshAuthentication.Jwt.verify(token, User))

  describe "create_user" do
    test "ADM creates a user with a hashed password in its tenant; the event omits the hash",
         ctx do
      {:ok, user} = Accounts.create_user(user_attrs(), actor: ctx.admin)

      assert user.role == :reviewer
      assert user.status == :active
      assert user.display_name == "New Operator"
      assert user.tenant_id == ctx.tenant.id
      assert to_string(user.email) == "new.operator@example.test"
      assert Bcrypt.verify_pass(@password, user.hashed_password)

      [event] =
        Enum.filter(events_of_type(ctx.tenant, "user.created"), &(&1.subject_id == user.id))

      assert event.actor_id == ctx.admin.id
      assert event.actor_role == :admin
      refute Map.has_key?(event.payload["changes"], "hashed_password")
      assert "hashed_password" in event.payload["redacted"]
      refute event.canonical_bytes =~ user.hashed_password
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: ctx.admin)
    end

    test "rejects a duplicate email, an unknown role and a mismatched confirmation", ctx do
      {:ok, _} = Accounts.create_user(user_attrs(), actor: ctx.admin)

      for attrs <- [
            %{email: "NEW.Operator@example.test"},
            %{email: "x@example.test", role: :owner},
            %{email: "y@example.test", password_confirmation: "other-password-1"},
            %{email: "z@example.test", password: "short", password_confirmation: "short"}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Accounts.create_user(user_attrs(attrs), actor: ctx.admin),
               inspect(attrs)
      end
    end

    test "REV, AUR, system and anonymous callers are denied, each denial audited", ctx do
      actors = [ctx.reviewer, ctx.auditor, system_actor(:agent_runtime, ctx.tenant), nil]

      for {actor, n} <- Enum.with_index(actors, 1) do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.create_user(user_attrs(%{email: "u#{n}@example.test"}), actor: actor)

        assert length(denials(ctx.tenant)) == n
      end
    end

    test "public registration, password reset and confirmation do not exist" do
      strategy = AshAuthentication.Info.strategy!(User, :password)
      refute strategy.registration_enabled?
      refute strategy.resettable
      refute strategy.sign_in_tokens_enabled?
      refute Ash.Resource.Info.action(User, :register_with_password)
      refute Ash.Resource.Info.action(User, :request_password_reset_token)

      creates =
        User
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&(&1.type == :create))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert creates == [:create_user, :seed]
      refute Ash.Resource.Info.actions(User) |> Enum.any?(&(&1.type == :destroy))
    end

    test "the seeder creates users only where seeding is allowed", ctx do
      seeder = system_actor(:seeder, ctx.tenant)
      previous = Application.get_env(:sdr_agent, :seeding_allowed?)
      Application.put_env(:sdr_agent, :seeding_allowed?, false)

      try do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.seed_user(Map.put(user_attrs(), :id, Ecto.UUID.generate()),
                   actor: seeder
                 )
      after
        Application.put_env(:sdr_agent, :seeding_allowed?, previous)
      end

      id = Ecto.UUID.generate()
      assert {:ok, %{id: ^id}} = Accounts.seed_user(Map.put(user_attrs(), :id, id), actor: seeder)
    end
  end

  describe "roles and status" do
    test "ADM changes a role and a status; both are audited", ctx do
      {:ok, user} = Accounts.create_user(user_attrs(), actor: ctx.admin)
      {:ok, user} = Accounts.change_role(user, :auditor, actor: ctx.admin)
      assert user.role == :auditor
      {:ok, user} = Accounts.change_status(user, :disabled, actor: ctx.admin)
      assert user.status == :disabled

      assert [role_event] = events_of_type(ctx.tenant, "user.role_changed")
      assert role_event.payload["changes"]["role"] == "auditor"
      assert [status_event] = events_of_type(ctx.tenant, "user.status_changed")
      assert status_event.payload["changes"]["status"] == "disabled"
    end

    test "the last active admin cannot be demoted or disabled", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.change_role(ctx.admin, :reviewer, actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.change_status(ctx.admin, :disabled, actor: ctx.admin)

      # A disabled admin does not count.
      dormant = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_status(dormant, :disabled, actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.change_role(ctx.admin, :reviewer, actor: ctx.admin)

      second = new_human(:admin, ctx.tenant)
      assert {:ok, demoted} = Accounts.change_role(ctx.admin, :reviewer, actor: second)
      assert demoted.role == :reviewer

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.change_status(second, :disabled, actor: second)
    end

    test "REV and AUR cannot change roles or status; each attempt is audited", ctx do
      for {actor, n} <- Enum.with_index([ctx.reviewer, ctx.auditor], 1) do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.change_role(ctx.reviewer, :admin, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.change_status(ctx.admin, :disabled, actor: actor)

        assert length(denials(ctx.tenant)) == 2 * n
      end
    end

    test "a disabled user cannot sign in and its sessions end", ctx do
      {:ok, user} = Accounts.create_user(user_attrs(), actor: ctx.admin)
      {:ok, signed_in} = Accounts.sign_in("new.operator@example.test", @password)
      token = signed_in.__metadata__.token
      assert session_valid?(token)

      {:ok, _} = Accounts.change_status(user, :disabled, actor: ctx.admin)

      assert {:error, _} = Accounts.sign_in("new.operator@example.test", @password)
      refute session_valid?(token)

      assert {:error, _} =
               AshAuthentication.subject_to_user(AshAuthentication.user_to_subject(user), User)
    end
  end

  describe "passwords" do
    test "ADM and REV change their own password with the current one; sessions end", ctx do
      for user <- [ctx.admin, ctx.reviewer] do
        {:ok, signed_in} = Accounts.sign_in(to_string(user.email), test_password())
        token = signed_in.__metadata__.token

        # AshAuthentication refuses a wrong current password as an authentication failure.
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.change_password(
                   user,
                   Map.put(new_password(), :current_password, "wrong-password-0"),
                   actor: user
                 )

        {:ok, changed} =
          Accounts.change_password(
            user,
            Map.put(new_password(), :current_password, test_password()),
            actor: user
          )

        assert Bcrypt.verify_pass(@password, changed.hashed_password)
        refute session_valid?(token)
        assert {:ok, _} = Accounts.sign_in(to_string(user.email), @password)
      end

      events = events_of_type(ctx.tenant, "user.password_changed")
      assert Enum.map(events, & &1.actor_id) == [ctx.admin.id, ctx.reviewer.id]
      assert Enum.all?(events, &(not Map.has_key?(&1.payload["changes"], "hashed_password")))
    end

    test "change_password applies only to the actor's own user", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.change_password(
                 ctx.reviewer,
                 Map.put(new_password(), :current_password, test_password()),
                 actor: ctx.admin
               )
    end

    test "AUR cannot change its own password, through the domain or the AshAuthentication action",
         ctx do
      attrs = Map.put(new_password(), :current_password, test_password())

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.change_password(ctx.auditor, attrs, actor: ctx.auditor)

      assert [_] = denials(ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.auditor
               |> Ash.Changeset.for_update(:change_password, attrs, actor: ctx.auditor)
               |> Ash.update()

      assert {:ok, _} = Accounts.sign_in(to_string(ctx.auditor.email), test_password())
      assert events_of_type(ctx.tenant, "user.password_changed") == []
    end

    test "ADM sets another user's password (incl. an auditor's); REV and self cannot", ctx do
      {:ok, signed_in} = Accounts.sign_in(to_string(ctx.auditor.email), test_password())
      {:ok, _} = Accounts.set_password(ctx.auditor, new_password(), actor: ctx.admin)
      refute session_valid?(signed_in.__metadata__.token)
      assert {:ok, _} = Accounts.sign_in(to_string(ctx.auditor.email), @password)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.set_password(ctx.auditor, new_password(), actor: ctx.reviewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.set_password(ctx.admin, new_password(), actor: ctx.admin)

      assert [event] = events_of_type(ctx.tenant, "user.password_changed")
      assert event.actor_id == ctx.admin.id
      assert event.subject_id == ctx.auditor.id
    end
  end

  describe "sign-in audit" do
    test "a successful sign-in returns a session token and is recorded", ctx do
      {:ok, user} = Accounts.sign_in(to_string(ctx.reviewer.email), test_password())
      assert user.id == ctx.reviewer.id
      assert session_valid?(user.__metadata__.token)

      assert [event] = events_of_type(ctx.tenant, "auth.sign_in.succeeded")
      assert event.actor_type == :user
      assert event.actor_id == ctx.reviewer.id
      assert event.category == :auth
    end

    test "failed sign-ins are recorded anonymously with only the email's sha256", ctx do
      email = to_string(ctx.reviewer.email)
      assert {:error, _} = Accounts.sign_in(email, "wrong-password-0")
      assert {:error, _} = Accounts.sign_in("Nobody@Example.test", test_password())

      assert [first, second] = events_of_type(ctx.tenant, "auth.sign_in.failed")
      assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []

      for event <- [first, second] do
        assert event.actor_type == :anonymous
        assert event.actor_id == nil
        assert event.category == :auth
        refute event.canonical_bytes =~ "xample.test"
        refute event.canonical_bytes =~ "wrong-password-0"
        refute event.canonical_bytes =~ test_password()
      end

      assert first.payload["email_sha256"] == hex(:crypto.hash(:sha256, String.downcase(email)))
      assert second.payload["email_sha256"] == hex(:crypto.hash(:sha256, "nobody@example.test"))
    end

    test "signing out is recorded with the user as actor", ctx do
      assert {:ok, _} = Accounts.record_signed_out(ctx.reviewer)
      assert [event] = events_of_type(ctx.tenant, "auth.signed_out")
      assert event.actor_id == ctx.reviewer.id
    end
  end

  describe "reading users" do
    test "each user reads itself; ADM reads all; REV reads no one else", ctx do
      assert {:ok, me} = Accounts.get_user(ctx.reviewer.id, actor: ctx.reviewer)
      assert me.email == ctx.reviewer.email
      assert {:error, _} = Accounts.get_user(ctx.admin.id, actor: ctx.reviewer)

      assert {:ok, all} = Accounts.list_users(actor: ctx.admin)
      assert length(all) == 3

      assert {:ok, [only]} = Accounts.list_users(actor: ctx.reviewer)
      assert only.id == ctx.reviewer.id
      assert {:ok, []} = Accounts.list_users(actor: nil)
    end

    test "AUR reads other users' display name and role only", ctx do
      {:ok, users} = Accounts.list_users(actor: ctx.auditor)
      assert length(users) == 3

      other = Enum.find(users, &(&1.id == ctx.admin.id))
      assert other.display_name == ctx.admin.display_name
      assert other.role == :admin

      for field <- [:email, :status, :tenant_id] do
        assert %Ash.ForbiddenField{} = Map.get(other, field), "#{field} must be hidden"
      end

      own = Enum.find(users, &(&1.id == ctx.auditor.id))
      assert own.email == ctx.auditor.email

      # The hash is a private AshAuthentication attribute: never loaded for operators.
      assert Enum.all?(users, &match?(%Ash.NotLoaded{}, &1.hashed_password))
      {:ok, admin_view} = Accounts.list_users(actor: ctx.admin)
      assert Enum.all?(admin_view, &match?(%Ash.NotLoaded{}, &1.hashed_password))
    end
  end
end
