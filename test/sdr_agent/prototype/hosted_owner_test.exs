defmodule SdrAgent.Prototype.HostedOwnerTest do
  @moduledoc "S-B5a RED: synthetic owner enrollment, exact authority, revocation and audit coupling."
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Prototype.Checks.OperatorAction

  @owner SdrAgent.Operations.HostedOwner

  setup do
    H.activated!()
  end

  test "enrollment creates a same-tenant reviewer bound to the live activation", ctx do
    enrolled = H.enrol!(ctx)
    assert enrolled.owner.tenant_id == ctx.fx.tenant.id
    assert enrolled.owner.binding_id == ctx.fx.binding.id
    assert enrolled.owner.relocation_id == ctx.relocation.id
    assert enrolled.owner.user_id == enrolled.user.id
    assert enrolled.owner.status == :active
    assert enrolled.owner.disabled_at == nil
    assert enrolled.user.role == :reviewer
    assert enrolled.user.status == :active
    refute enrolled.user.id in [ctx.fx.anchor.id, ctx.fx.auditor.id]
    refute Map.has_key?(enrolled, :password)
  end

  test "one active owner per binding; second enrollment creates no extra user", ctx do
    _first = H.enrol!(ctx)
    before = user_count()

    assert {:error, _} =
             call(SdrAgent.Operations, :enrol_hosted_owner, [
               %{email: "second@example.test", display_name: "Second"},
               H.console(ctx)
             ])

    assert user_count() == before
    assert owner_count() == 1
  end

  test "a source or third identity cannot enroll an owner", ctx do
    loaded!(@owner)
    assert :ok = PrototypeFixtures.put_live_identity(ctx.source)

    assert {:error, _} =
             call(SdrAgent.Operations, :enrol_hosted_owner, [
               %{email: "source@example.test", display_name: "Source"},
               H.console(ctx)
             ])

    assert owner_count() == 0
    assert user_count() == 2
  end

  test "ordinary reviewer and auditor cannot enroll even carrying a console marker", ctx do
    loaded!(@owner)

    for actor <- [ctx.fx.auditor, ctx.fx.actor] do
      opts = Keyword.put(H.console(ctx), :actor, actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               call(SdrAgent.Operations, :enrol_hosted_owner, [
                 %{email: "denied@example.test", display_name: "Denied"},
                 opts
               ])
    end

    assert owner_count() == 0
  end

  test "direct User enrollment action is forbidden outside the Operations scope", ctx do
    assert Ash.Resource.Info.action(User, :create_hosted_owner), "missing scoped User action"

    for opts <- [H.console(ctx), [actor: ctx.fx.auditor], [actor: ctx.fx.actor]] do
      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Changeset.for_create(
                 :create_hosted_owner,
                 %{email: "direct@example.test", display_name: "Direct"},
                 opts
               )
               |> Ash.create()
    end
  end

  test "hosted reviewer gets only review_read and assign, never console powers", ctx do
    %{user: user} = H.enrol!(ctx)
    H.enter!(ctx)
    assert H.hosted?(user)

    for action <- [:review_read, :assign] do
      assert OperatorAction.match?(user, %{}, action: action)
    end

    for action <- OperatorAction.actions() -- [:review_read, :assign] do
      refute OperatorAction.match?(user, %{}, action: action)
    end

    refute H.hosted?(ctx.fx.auditor)
    refute H.hosted?(ctx.fx.anchor)
    refute H.hosted?(Actor.system(:kernel, ctx.fx.tenant.id))
    forged = %{user | id: Ecto.UUID.generate()}
    refute H.hosted?(forged)
  end

  test "console disable revokes every session and the enrollment link atomically", ctx do
    %{owner: owner, user: user, enrollment_token: link} = H.enrol!(ctx)
    signed = H.consume!(link)
    token = signed.__metadata__.token
    assert {:ok, _} = Accounts.current_operator(token)
    assert {:ok, %{status: :disabled, disabled_at: %DateTime{}}} = H.disable(ctx, owner.id)
    assert :error = Accounts.current_operator(token)
    assert {:error, _} = H.consume(link)
    fresh = Accounts.get_user(user.id, H.kernel(ctx)) |> elem(1)
    assert fresh.status == :disabled
  end

  test "owner may disable only itself and stale actor immediately loses authority", ctx do
    %{owner: owner, user: user} = H.enrol!(ctx)
    H.enter!(ctx)
    assert H.hosted?(user)
    assert {:ok, %{status: :disabled}} = H.disable(ctx, owner.id, actor: user)
    refute H.hosted?(user)
    refute OperatorAction.match?(user, %{}, action: :assign)
    refute OperatorAction.match?(user, %{}, action: :review_read)
    assert {:error, _} = H.disable(ctx, owner.id, actor: user)
  end

  test "auditor cannot disable or read the owner's authority record", ctx do
    %{owner: owner} = H.enrol!(ctx)
    H.enter!(ctx)
    assert {:error, %Ash.Error.Forbidden{}} = H.disable(ctx, owner.id, actor: ctx.fx.auditor)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.get(@owner, owner.id, actor: ctx.fx.auditor)
  end

  test "terminal owner cannot be reactivated through an ordinary update", ctx do
    %{owner: owner} = H.enrol!(ctx)
    assert {:ok, disabled} = H.disable(ctx, owner.id)
    refute Ash.Resource.Info.action(@owner, :enable)

    assert {:error, _} =
             disabled
             |> Ash.Changeset.for_update(:disable, %{status: :active}, H.console(ctx))
             |> Ash.update()

    assert {:ok, %{status: :disabled}} = Ash.get(@owner, owner.id, H.kernel(ctx))
  end

  test "enrollment writes exactly one owner event and one redacted user event", ctx do
    enrolled = H.enrol!(ctx)

    %{rows: [[owner_payload]]} =
      Repo.query!(
        "SELECT payload FROM audit_events WHERE event_type = 'operations.hosted_owner.enrolled' AND subject_id = $1",
        [enrolled.owner.id]
      )

    assert owner_payload["record_sha256"] == RecordHash.hex(enrolled.owner)

    %{rows: [[user_payload]]} =
      Repo.query!(
        "SELECT payload FROM audit_events WHERE event_type = 'user.created' AND subject_id = $1",
        [enrolled.user.id]
      )

    assert "hashed_password" in user_payload["redacted"]
    refute Map.has_key?(user_payload["changes"], "hashed_password")
    all = Jason.encode!([owner_payload, user_payload])
    refute all =~ enrolled.enrollment_token
  end

  defp user_count, do: count("users")
  defp owner_count, do: count(AshPostgres.DataLayer.Info.table(@owner))

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end
end
