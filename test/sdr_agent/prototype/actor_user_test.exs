defmodule SdrAgent.Prototype.ActorUserTest do
  @moduledoc """
  The scoped `SdrAgent.Outreach.Changes.ActorUser` (interfaces r6 IF-3
  "ActorUser scope"; amendment item 3 "Scoped approver attribution"; plan
  r7 section 6 row F1 principal and resolver, `actor_user_test.exs`):

  - only with `prototype_anchor: true` AND a resolved prototype operator is
    the field forced to the binding's anchor user id;
  - the option is set only on Approval `:approve`, `:reject` and `:revoke`;
  - everywhere else (a manual suppression, for example) an operator leaves
    the field unset, so the row's own constraints refuse it;
  - a forged operator struct, an operator outside prototype runtime and
    any other system actor never get the anchor;
  - a human user is attributed as before.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias Ash.Changeset
  alias SdrAgent.Actor
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.Changes.ActorUser
  alias SdrAgent.Outreach.Suppression

  defp applied(resource, opts, actor) do
    resource
    |> Changeset.new()
    |> ActorUser.change(opts, %{actor: actor})
    |> Changeset.get_attribute(opts[:field])
  end

  defp actor_user_opts(action) do
    action
    |> then(&Ash.Resource.Info.action(Approval, &1))
    |> Map.fetch!(:changes)
    |> Enum.find_value(fn
      %{change: {ActorUser, opts}} -> opts
      _ -> nil
    end)
  end

  test "the anchor option is set on exactly Approval :approve, :reject and :revoke" do
    assert Keyword.get(actor_user_opts(:approve), :prototype_anchor) == true
    assert Keyword.get(actor_user_opts(:reject), :prototype_anchor) == true
    assert Keyword.get(actor_user_opts(:revoke), :prototype_anchor) == true

    for {resource, action} <- [{Suppression, :manual}] do
      opts =
        resource
        |> Ash.Resource.Info.action(action)
        |> Map.fetch!(:changes)
        |> Enum.find_value(fn
          %{change: {ActorUser, opts}} -> opts
          _ -> nil
        end)

      refute Keyword.get(opts || [], :prototype_anchor),
             "#{inspect(resource)}.#{action} has the anchor option"
    end
  end

  test "a human user is attributed as before; a system actor leaves the field unset (control)" do
    tenant = bootstrap!()
    user = human(:reviewer, tenant)
    assert applied(Approval, [field: :approver_id, prototype_anchor: true], user) == user.id

    agent = Actor.system(:agent_runtime, tenant.id)
    assert applied(Approval, [field: :approver_id, prototype_anchor: true], agent) == nil
  end

  test "in prototype runtime the resolved operator gets the anchor only with the option" do
    fixture = bound!()
    operator = fixture.actor
    anchor_id = fixture.anchor.id

    assert applied(Approval, [field: :approver_id, prototype_anchor: true], operator) == anchor_id
    assert applied(Approval, [field: :approver_id], operator) == nil
    assert applied(Suppression, [field: :created_by_user_id], operator) == nil
  end

  test "a forged operator struct never gets the anchor" do
    fixture = bound!()

    forged = [
      %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: fixture.tenant.id},
      %Actor{type: :prototype_operator, id: fixture.actor.id, tenant_id: Ecto.UUID.generate()},
      %Actor{type: :prototype_operator, id: nil, tenant_id: fixture.tenant.id}
    ]

    for actor <- forged do
      assert applied(Approval, [field: :approver_id, prototype_anchor: true], actor) == nil
    end
  end

  test "outside prototype runtime the operator's delegation never maps to the anchor" do
    fixture = bound!(enter_runtime: false)
    assert applied(Approval, [field: :approver_id, prototype_anchor: true], fixture.actor) == nil
  end

  test "an operator on a manual suppression is refused, and no suppression row is written" do
    ctx = prototype_drafted!()
    before = Ash.read!(Suppression, actor: ctx.admin)

    result =
      Outreach.suppress(%{scope: :email, value: "operator-suppress@example.test"},
        actor: ctx.operator
      )

    assert match?({:error, _}, result), "an operator created a manual suppression"
    assert Ash.read!(Suppression, actor: ctx.admin) == before
  end

  test "an operator's approval records the anchor as approver" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    assert approval.approver_id == ctx.anchor.id
    assert approval.approver_authored_revision == false
    assert [_] = approvals!(ctx, ctx.draft)
  end
end
