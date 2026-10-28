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

  # Codex f3036a14 queue 1: the prototype-runtime refusal of the five user
  # administration actions holds for every caller class, on the raw action
  # paths too, including AshAuthentication's interaction context, whose
  # bypass would otherwise authorize any caller. Each call is executed and
  # each must be exactly Forbidden; no user row changes, and the only new
  # audit events are the guard's `authz.denied`.
  describe "prototype runtime: every caller class and raw path" do
    @interaction %{private: %{ash_authentication?: true}}
    @pw %{password: "test-password-1234", password_confirmation: "test-password-1234"}

    defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.test"

    defp raw_create(action, opts) do
      input =
        Map.merge(@pw, %{email: unique_email("raw"), display_name: "Raw", role: :reviewer})

      input = if action == :seed, do: Map.put(input, :id, Ecto.UUID.generate()), else: input

      User
      |> Ash.Changeset.for_create(action, input, opts)
      |> Ash.create()
    end

    defp raw_update(user, :change_role, opts),
      do: update(user, :change_role, %{role: :admin}, opts)

    defp raw_update(user, :change_status, opts),
      do: update(user, :change_status, %{status: :disabled}, opts)

    defp raw_update(user, :set_password, opts), do: update(user, :set_password, @pw, opts)

    defp update(user, action, input, opts) do
      user
      |> Ash.Changeset.for_update(action, input, opts)
      |> Ash.update()
    end

    defp users_rows do
      %{rows: rows} =
        Repo.query!(
          "SELECT id::text, email::text, role, status, hashed_password FROM users ORDER BY id",
          []
        )

      rows
    end

    defp event_counts do
      %{rows: rows} =
        Repo.query!("SELECT event_type, count(*) FROM audit_events GROUP BY event_type", [])

      Map.new(rows, fn [type, n] -> {type, n} end)
    end

    defp new_events(before, now) do
      for {type, n} <- now,
          n > Map.get(before, type, 0),
          into: %{},
          do: {type, n - Map.get(before, type, 0)}
    end

    test "prerequisite control (ordinary runtime): the interaction context reaches the bypass" do
      fx = bound!(enter_runtime: false)
      reviewer = new_human(:reviewer, fx.tenant)

      result = raw_create(:create_user, actor: reviewer, context: @interaction)

      assert match?({:ok, %User{}}, result),
             "prerequisite: the AshAuthentication bypass did not authorize: #{inspect(result)}"
    end

    test "all five actions are Forbidden for every caller class, with no user change" do
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      reviewer = new_human(:reviewer, fx.tenant)
      assert PrototypeFixtures.enter_runtime(fx.snapshot) == :ok
      assert SdrAgent.Prototype.runtime() == :prototype

      classes = [
        admin: [actor: admin],
        seeder: [actor: system_actor(:seeder, fx.tenant)],
        operator: [actor: fx.actor],
        kernel: SdrAgent.Audit.Kernel.opts(fx.tenant.id),
        interaction: [context: @interaction],
        admin_interaction: [actor: admin, context: @interaction]
      ]

      rows_before = users_rows()
      events_before = event_counts()

      calls =
        for {class, opts} <- classes,
            action <- [:create_user, :seed, :change_role, :change_status, :set_password] do
          result =
            if action in [:create_user, :seed],
              do: raw_create(action, opts),
              else: raw_update(reviewer, action, opts)

          {class, action, result}
        end

      offenders =
        for {class, action, result} <- calls,
            not match?({:error, %Ash.Error.Forbidden{}}, result),
            do: {class, action, summarize(result)}

      assert offenders == [], "not exactly Forbidden in prototype runtime: #{inspect(offenders)}"
      assert users_rows() == rows_before

      created = new_events(events_before, event_counts())

      assert Map.keys(created) -- ["authz.denied"] == [],
             "unexpected audit events #{inspect(created)}"
    end

    defp summarize({:ok, %User{} = user}), do: {:ok, :user, user.role, user.status}
    defp summarize({:error, %error{}}), do: {:error, error}
    defp summarize(other), do: other
  end

  describe "preserved controls in prototype runtime" do
    test "the bound auditor still signs in, and its session token resolves" do
      fx = bound!(enter_runtime: false, auditor: true)
      assert PrototypeFixtures.enter_runtime(fx.snapshot) == :ok

      result = Accounts.sign_in("d237-auditor@prototype.invalid", String.duplicate("A", 43))
      assert match?({:ok, %User{role: :auditor}}, result), "auditor sign-in: #{inspect(result)}"
      {:ok, auditor} = result

      token = auditor.__metadata__[:token]
      assert is_binary(token), "prerequisite: sign-in issued no token"
      assert match?({:ok, %User{role: :auditor}}, Accounts.current_operator(token))
    end

    test "an ordinary reviewer's minted session token still resolves" do
      fx = bound!(enter_runtime: false)
      reviewer = new_human(:reviewer, fx.tenant)
      assert PrototypeFixtures.enter_runtime(fx.snapshot) == :ok

      {:ok, token, _claims} =
        AshAuthentication.Jwt.token_for_user(reviewer, %{"purpose" => "user"})

      assert match?({:ok, %User{role: :reviewer}}, Accounts.current_operator(token))
    end
  end
end
