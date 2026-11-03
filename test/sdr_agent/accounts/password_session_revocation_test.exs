defmodule SdrAgent.Accounts.PasswordSessionRevocationTest do
  @moduledoc """
  Security-patch controls for the existing password revocation contract:
  all old target sessions end, unrelated sessions survive, and a refused
  password change does not revoke anything. Uses real Accounts actions.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts

  @new_password "synthetic-new-password-5678"

  setup do
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant), reviewer: human(:reviewer, tenant)}
  end

  test "own password change ends every prior session but not another user's", ctx do
    old_sessions = sessions!(ctx.reviewer)
    [other] = sessions!(ctx.admin, 1)

    assert {:ok, _} =
             Accounts.change_password(
               ctx.reviewer,
               Map.put(password_attrs(), :current_password, test_password()),
               actor: ctx.reviewer
             )

    assert_revoked(old_sessions)
    assert {:ok, %{id: id}} = Accounts.current_operator(other)
    assert id == ctx.admin.id
    assert_new_password(ctx.reviewer)
    assert [event] = events_of_type(ctx.tenant, "user.password_changed")
    assert event.subject_id == ctx.reviewer.id
  end

  test "admin password set ends every target session but keeps the admin signed in", ctx do
    old_sessions = sessions!(ctx.reviewer)
    [admin_session] = sessions!(ctx.admin, 1)

    assert {:ok, _} =
             Accounts.set_password(ctx.reviewer, password_attrs(), actor: ctx.admin)

    assert_revoked(old_sessions)
    assert {:ok, %{id: id}} = Accounts.current_operator(admin_session)
    assert id == ctx.admin.id
    assert_new_password(ctx.reviewer)
    assert [event] = events_of_type(ctx.tenant, "user.password_changed")
    assert event.subject_id == ctx.reviewer.id
  end

  test "a non-password update leaves both of the user's sessions valid", ctx do
    sessions = sessions!(ctx.reviewer)

    assert {:ok, _} = Accounts.change_role(ctx.reviewer, :auditor, actor: ctx.admin)

    for token <- sessions do
      assert {:ok, %{id: id, role: :auditor}} = Accounts.current_operator(token)
      assert id == ctx.reviewer.id
    end

    assert events_of_type(ctx.tenant, "user.password_changed") == []
  end

  test "a wrong current password preserves all sessions and existing credentials", ctx do
    sessions = sessions!(ctx.reviewer)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.change_password(
               ctx.reviewer,
               Map.put(password_attrs(), :current_password, "wrong-synthetic-password"),
               actor: ctx.reviewer
             )

    for token <- sessions do
      assert {:ok, %{id: id}} = Accounts.current_operator(token)
      assert id == ctx.reviewer.id
    end

    assert {:ok, _} = Accounts.sign_in(to_string(ctx.reviewer.email), test_password())
    assert {:error, _} = Accounts.sign_in(to_string(ctx.reviewer.email), @new_password)
    assert events_of_type(ctx.tenant, "user.password_changed") == []
  end

  defp sessions!(user, count \\ 2) do
    for _ <- 1..count do
      assert {:ok, signed} = Accounts.sign_in(to_string(user.email), test_password())
      token = signed.__metadata__.token
      assert {:ok, %{id: id}} = Accounts.current_operator(token)
      assert id == user.id
      token
    end
  end

  defp assert_revoked(tokens) do
    for token <- tokens, do: assert(:error == Accounts.current_operator(token))
  end

  defp assert_new_password(user) do
    assert {:error, _} = Accounts.sign_in(to_string(user.email), test_password())
    assert {:ok, signed} = Accounts.sign_in(to_string(user.email), @new_password)
    assert {:ok, %{id: id}} = Accounts.current_operator(signed.__metadata__.token)
    assert id == user.id
  end

  defp password_attrs,
    do: %{password: @new_password, password_confirmation: @new_password}
end
