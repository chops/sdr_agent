defmodule SdrAgent.Prototype.HostedOwnerBootTest do
  @moduledoc "S-B5a RED: exact boot identity set across hosted enrollment, revocation and relocation."
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Prototype.BootCheck

  setup do
    H.activated!()
  end

  test "a current hosted reviewer is admitted alongside anchor and bound auditor", ctx do
    _owner = H.enrol!(ctx)
    assert {:ok, :prototype, _} = BootCheck.check(PrototypeFixtures.switch(ctx.fx))
  end

  test "a disabled historical owner with revoked tokens does not brick boot", ctx do
    %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
    _signed = H.consume!(link)
    assert {:ok, _} = H.disable(ctx, owner.id)
    assert {:ok, :prototype, _} = BootCheck.check(PrototypeFixtures.switch(ctx.fx))
  end

  test "an active hosted owner on a previous activation makes boot refuse", ctx do
    _owner = H.enrol!(ctx)
    _return = H.relocate!(ctx, ctx.destination, ctx.source, 2)
    assert {:error, :users_not_exact} = BootCheck.check(PrototypeFixtures.switch(ctx.fx))
  end

  test "disabled history with an outstanding stored token makes boot refuse", ctx do
    %{owner: owner, user: user} = H.enrol!(ctx)
    assert {:ok, _} = H.disable(ctx, owner.id)
    # Fault fixture: mint a stored token AFTER disable, through the existing
    # library API. This tests boot's independent check; never bypass a write policy.
    assert {:ok, _token, _} = AshAuthentication.Jwt.token_for_user(user)
    assert {:error, :users_not_exact} = BootCheck.check(PrototypeFixtures.switch(ctx.fx))
  end
end
