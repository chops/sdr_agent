defmodule SdrAgent.Prototype.AnchorAuthTest do
  @moduledoc """
  IF-3 authentication denial (interfaces r6; F1): the credential-less anchor
  never signs in, never resolves from a session subject or token, and its
  role can be neither assigned nor changed; in prototype runtime user
  administration is refused for every actor.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User

  test "the User role set includes :agent_operator" do
    roles = Ash.Resource.Info.attribute(User, :role).constraints[:one_of]
    assert :agent_operator in roles
  end

  describe "the anchor never authenticates" do
    test "password sign-in refuses the anchor for any password and issues no token" do
      fx = bound!()
      assert to_string(fx.anchor.email) == "d237-operator@prototype.invalid"

      for password <- ["", "test-password-1234", String.duplicate("x", 40)] do
        assert match?({:error, _}, Accounts.sign_in("d237-operator@prototype.invalid", password))
      end

      subject = AshAuthentication.user_to_subject(fx.anchor)

      %{rows: [[tokens]]} =
        Repo.query!("SELECT count(*) FROM tokens WHERE subject = $1", [subject])

      assert tokens == 0, "a token was issued for the anchor"
    end

    test "the session subject lookup refuses the anchor" do
      fx = bound!()
      subject = AshAuthentication.user_to_subject(fx.anchor)
      assert match?({:error, _}, AshAuthentication.subject_to_user(subject, User))
    end

    test "a signed, stored session token for the anchor does not resolve in current_operator/1" do
      fx = bound!()
      # A token minted directly for the anchor (never issued by sign-in): the
      # session lookup must still refuse it.
      token_result = AshAuthentication.Jwt.token_for_user(fx.anchor, %{"purpose" => "user"})

      assert match?({:ok, _token, _claims}, token_result),
             "prerequisite: minting a test token returned #{inspect(token_result)}"

      {:ok, token, _claims} = token_result
      assert Accounts.current_operator(token) == :error
    end
  end

  describe "the role is immutable" do
    test "no change to or from :agent_operator, and no create or seed with it" do
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      reviewer = new_human(:reviewer, fx.tenant)

      from_anchor = Accounts.change_role(fx.anchor, :reviewer, actor: admin)
      to_anchor = Accounts.change_role(reviewer, :agent_operator, actor: admin)

      created =
        Accounts.create_user(
          %{
            email: "machine@example.test",
            display_name: "Machine",
            role: :agent_operator,
            password: "test-password-1234",
            password_confirmation: "test-password-1234"
          },
          actor: admin
        )

      seeded =
        Accounts.seed_user(
          %{
            id: Ecto.UUID.generate(),
            email: "machine-seed@example.test",
            display_name: "Machine seed",
            role: :agent_operator,
            password: "test-password-1234",
            password_confirmation: "test-password-1234"
          },
          actor: system_actor(:seeder, fx.tenant)
        )

      set =
        Accounts.set_password(
          fx.anchor,
          %{password: "test-password-1234", password_confirmation: "test-password-1234"},
          actor: admin
        )

      for {name, result} <- [
            from_anchor: from_anchor,
            to_anchor: to_anchor,
            create_user: created,
            seed: seeded,
            set_password: set
          ] do
        assert match?({:error, _}, result), "#{name} with :agent_operator succeeded"
      end

      %{rows: [[role, hash]]} =
        Repo.query!("SELECT role, hashed_password FROM users WHERE id = $1", [
          Ecto.UUID.dump!(fx.anchor.id)
        ])

      assert {role, hash} == {"agent_operator", nil}
    end
  end

  describe "prototype runtime" do
    test "user administration is refused for every actor" do
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      reviewer = new_human(:reviewer, fx.tenant)
      assert PrototypeFixtures.enter_runtime(fx.snapshot) == :ok
      assert SdrAgent.Prototype.runtime() == :prototype

      pw = %{password: "test-password-1234", password_confirmation: "test-password-1234"}

      results = [
        create_user:
          Accounts.create_user(
            Map.merge(pw, %{email: "late@example.test", display_name: "Late", role: :reviewer}),
            actor: admin
          ),
        seed:
          Accounts.seed_user(
            Map.merge(pw, %{
              id: Ecto.UUID.generate(),
              email: "late-seed@example.test",
              display_name: "Late seed",
              role: :reviewer
            }),
            actor: system_actor(:seeder, fx.tenant)
          ),
        change_role: Accounts.change_role(reviewer, :admin, actor: admin),
        change_status: Accounts.change_status(reviewer, :disabled, actor: admin),
        set_password: Accounts.set_password(reviewer, pw, actor: admin)
      ]

      for {name, result} <- results do
        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "#{name} in prototype runtime was not forbidden: #{inspect(result)}"
      end
    end
  end
end
