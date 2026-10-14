defmodule SdrAgent.Inbox.SessionTest do
  @moduledoc "C1-02 current human session scope, role changes and auditor coalescing."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [operator!: 2, drafted!: 1]

  alias SdrAgent.Accounts
  alias SdrAgent.Audit

  test "nil, malformed session and system actor cannot read Home", ctx do
    failure!(ctx)

    for invalid <- [nil, %{}, %{"user_token" => "forged"}, ctx.agent, ctx.admin] do
      assert {:error, :forbidden} = refresh(invalid)
    end
  end

  test "a signed and stored non-user-purpose token is not a Home session", ctx do
    failure!(ctx)

    assert {:ok, token, _claims} =
             AshAuthentication.Jwt.token_for_user(ctx.admin, %{}, purpose: :password_reset)

    assert {:error, :forbidden} = refresh(token)
  end

  test "a valid JWT whose jti is revoked cannot read Home", ctx do
    failure!(ctx)
    token = session!(ctx.admin)
    assert :ok = AshAuthentication.TokenResource.Actions.revoke(SdrAgent.Accounts.Token, token)
    assert {:error, :forbidden} = refresh(token)
  end

  test "a modified signature on a real stored token is forbidden", ctx do
    failure!(ctx)
    token = session!(ctx.admin)
    [header, claims, signature] = String.split(token, ".")
    <<first, rest::binary>> = signature
    replacement = if first == ?a, do: ?b, else: ?a
    forged = Enum.join([header, claims, <<replacement, rest::binary>>], ".")
    assert {:error, :forbidden} = refresh(forged)
  end

  test "disabled user loses all rows and totals on the next refresh", ctx do
    failure!(ctx)
    reviewer = operator!(ctx, :reviewer)
    session = session!(reviewer)

    assert {:ok, %{items: [_]}} = refresh(session)
    assert {:ok, _} = Accounts.change_status(reviewer, :disabled, actor: ctx.admin)
    assert {:error, :forbidden} = refresh(session)
  end

  test "revoked stored token cannot reuse an old actor or page", ctx do
    failure!(ctx)
    reviewer = operator!(ctx, :reviewer)
    session = session!(reviewer)

    assert {:ok, %{items: [_]}} = refresh(session)
    password = "replacement-synthetic-password"

    assert {:ok, _} =
             Accounts.set_password(
               reviewer,
               %{password: password, password_confirmation: password},
               actor: ctx.admin
             )

    assert {:error, :forbidden} = refresh(session)
  end

  test "another user cannot replay a cursor even in the same tenant", ctx do
    for _ <- 1..3, do: failure!(ctx)
    admin_session = session!(ctx.admin)
    reviewer_session = session!(operator!(ctx, :reviewer))

    assert {:ok, page} = refresh(admin_session, limit: 1)
    assert {:error, :invalid_input} = refresh(reviewer_session, cursor: page.next_cursor)
  end

  test "caller cannot override resolved actor or tenant through options", ctx do
    failure!(ctx)
    session = session!(ctx.admin)

    for opts <- [[actor: ctx.admin], [tenant_id: ctx.tenant.id], [tenant: ctx.tenant]] do
      assert {:error, :invalid_input} = refresh(session, opts)
    end
  end

  test "auditor reference is byte-stable for equal views and bounded at 50 shown ids", ctx do
    for _ <- 1..53, do: failure!(ctx)
    session = session!(operator!(ctx, :auditor))

    assert {:ok, first} = refresh(session)
    assert {:ok, second} = refresh(session)
    assert Enum.map(first.items, & &1.id) == Enum.map(second.items, & &1.id)
    assert {:ok, [a, b]} = Audit.list_accesses(actor: ctx.admin)
    assert a.target_ref == b.target_ref
    assert byte_size(a.target_ref) <= 12_000
    assert String.starts_with?(a.target_ref, ~s({"version":))
    assert length(Jason.decode!(a.target_ref)["shown"]) == 50
  end

  test "a demoted reviewer receives read-only capabilities from the stored role", ctx do
    %{draft: draft} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)
    session = session!(reviewer)

    assert {:ok, first} = refresh(session)

    assert Enum.any?(
             item!(first, draft).actions,
             &(&1.action_id == :approve_capture and &1.availability == :enabled)
           )

    assert {:ok, _} = Accounts.change_role(reviewer, :auditor, actor: ctx.admin)
    assert {:ok, second} = refresh(session)

    assert Enum.all?(
             item!(second, draft).actions,
             &(&1.action_id == :inspect or &1.availability == :blocked)
           )
  end

  test "ordinary admin and reviewer metadata refreshes append no AuditAccess", ctx do
    failure!(ctx)
    sessions = for user <- [ctx.admin, operator!(ctx, :reviewer)], do: session!(user)
    before = events_of_type(ctx.tenant, "audit.access.record_view")

    for session <- sessions, do: assert({:ok, _} = refresh(session))
    assert events_of_type(ctx.tenant, "audit.access.record_view") == before
  end

  test "auditor refresh audits only actually-shown ids plus closed metric scope/window", ctx do
    failures = for _ <- 1..53, do: failure!(ctx)
    auditor = operator!(ctx, :auditor)
    session = session!(auditor)

    assert {:ok, page} = refresh(session, limit: 2)
    assert total!(page, :live_failures) == 53
    assert {:ok, [access]} = Audit.list_accesses(actor: ctx.admin)
    assert access.access_kind == :record_view
    assert access.target_resource == "SdrAgent.Inbox"
    assert {:ok, ref} = Jason.decode(access.target_ref)
    refute Map.has_key?(ref, "tenant_id")
    refute Map.has_key?(ref, "actor_id")
    assert access.actor_id == auditor.id
    assert access.tenant_id == ctx.tenant.id
    assert byte_size(access.target_ref) <= 12_000
    assert length(ref["shown"]) == 2

    assert Enum.sort(Enum.map(ref["shown"], & &1["id"])) ==
             Enum.sort(Enum.map(page.items, & &1.subject_ref.id))

    assert Enum.sort(Enum.map(ref["metrics"], & &1["metric"])) ==
             ~w(live_failures local_captures_this_week pending_email_drafts)

    hidden = Enum.map(failures, & &1.id) -- Enum.map(page.items, & &1.subject_ref.id)
    refute Enum.any?(hidden, &String.contains?(access.target_ref, &1))
    assert length(events_of_type(ctx.tenant, "audit.access.record_view")) == 1
  end
end
