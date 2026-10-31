defmodule SdrAgent.Prototype.HostedOwnerLinkTest do
  @moduledoc "S-B5a RED: signed purpose-bound single-use links and normal stored sessions."
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.HostedOwnerFixtures, as: H

  setup do
    H.activated!()
  end

  test "enrollment token has a 15-minute expiry and is not a user session", ctx do
    %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
    assert {:ok, claims, _} = AshAuthentication.Jwt.verify(link, :sdr_agent)
    assert claims["exp"] - claims["iat"] == 900
    assert claims["hosted_owner_id"] == owner.id
    assert claims["relocation_id"] == ctx.relocation.id
    assert :error = Accounts.current_operator(link)
  end

  test "consumption produces an ordinary signed stored session once", ctx do
    %{enrollment_token: link, user: user} = H.enrol!(ctx)
    signed = H.consume!(link)
    assert signed.id == user.id
    assert is_binary(signed.__metadata__.token)
    refute signed.__metadata__.token == link
    assert {:ok, %{id: id}} = Accounts.current_operator(signed.__metadata__.token)
    assert id == user.id
    assert {:error, _} = H.consume(link)
  end

  test "a valid ordinary-purpose token cannot be exchanged as an enrollment link", ctx do
    %{user: user} = H.enrol!(ctx)
    assert {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    assert {:error, _} = H.consume(token)
  end

  test "a signed expired enrollment token never creates a session", ctx do
    %{user: user, owner: owner} = H.enrol!(ctx)

    assert {:ok, expired, _} =
             AshAuthentication.Jwt.token_for_user(
               user,
               %{"hosted_owner_id" => owner.id, "relocation_id" => ctx.relocation.id},
               purpose: :hosted_owner_enrollment,
               token_lifetime: -60
             )

    assert {:error, _} = H.consume(expired)
    assert :error = Accounts.current_operator(expired)
  end

  test "malformed or tampered links return closed failures", ctx do
    %{enrollment_token: link} = H.enrol!(ctx)

    for bad <- ["not-a-token", "", link <> "tampered"] do
      assert {:error, _} = H.consume(bad)
    end

    assert {:ok, _} = H.consume(link)
  end

  test "a signed link naming the wrong owner or activation is refused", ctx do
    %{user: user, owner: owner} = H.enrol!(ctx)

    for claims <- [
          %{"hosted_owner_id" => Ecto.UUID.generate(), "relocation_id" => ctx.relocation.id},
          %{"hosted_owner_id" => owner.id, "relocation_id" => Ecto.UUID.generate()}
        ] do
      assert {:ok, token, _} =
               AshAuthentication.Jwt.token_for_user(user, claims,
                 purpose: :hosted_owner_enrollment,
                 token_lifetime: 900
               )

      assert {:error, _} = H.consume(token)
    end
  end

  test "a link is refused after its activation ceases to be current", ctx do
    %{enrollment_token: link} = H.enrol!(ctx)
    _return = H.relocate!(ctx, ctx.destination, ctx.source, 2)
    assert {:error, _} = H.consume(link)
  end

  test "disable revokes an unused link without creating a session", ctx do
    %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
    assert {:ok, _} = H.disable(ctx, owner.id)
    assert {:error, _} = H.consume(link)
  end
end
