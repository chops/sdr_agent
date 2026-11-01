defmodule SdrAgent.Prototype.HostedOwnerPasswordTest do
  @moduledoc """
  Owner password setup RED (entity 842b2321, plan e10228d3): the one-use link
  exchange must set an owner-chosen password atomically, and a console-only
  reissue recovers the existing owner without new rows. Synthetic only; the
  only fault injection is a session-local trigger, never a production seam.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.HostedOwnerFixtures, as: H

  @owner SdrAgent.Operations.HostedOwner
  @set_action :set_hosted_owner_password
  @reissue_action :reissue_hosted_owner_link

  setup do
    H.activated!()
  end

  describe "setup at link exchange" do
    test "the pre-repair token-only exchange fails closed and leaves the link usable", ctx do
      %{enrollment_token: link} = H.enrol!(ctx)
      before = state(ctx)
      assert {:error, _} = H.consume_token_only(link)
      assert state(ctx) == before
      assert {:ok, _} = H.consume(link)
    end

    test "missing, short or mismatched passwords are refused without any write", ctx do
      %{enrollment_token: link, user: user} = H.enrol!(ctx)
      assert {:ok, old, _} = AshAuthentication.Jwt.token_for_user(user)
      hash = hashed_password(user.id)
      before = state(ctx)
      good = H.setup_password()

      for attrs <- [
            %{},
            %{"password" => good},
            H.setup_attrs("eleven-char"),
            %{"password" => good, "password_confirmation" => good <> "x"}
          ] do
        assert {:error, _} = H.consume(link, attrs)
        assert state(ctx) == before
        assert hashed_password(user.id) == hash
        assert {:ok, _} = Accounts.current_operator(old)
      end

      assert {:ok, _} = H.consume(link)
    end

    test "the chosen password signs in as the same owner; the random one never did", ctx do
      %{enrollment_token: link, user: user} = H.enrol!(ctx)
      email = to_string(user.email)
      assert {:error, _} = Accounts.sign_in(email, H.setup_password())
      signed = H.consume!(link)
      assert signed.id == user.id
      assert {:ok, %{id: id}} = Accounts.sign_in(email, H.setup_password())
      assert id == user.id
      assert {:error, _} = H.consume(link)
    end

    test "setup mints the session last, revokes older sessions and creates no rows", ctx do
      %{enrollment_token: link, user: user, owner: owner} = H.enrol!(ctx)
      assert {:ok, old, _} = AshAuthentication.Jwt.token_for_user(user)
      assert {:ok, _} = Accounts.current_operator(old)
      {users, owners, _tokens, _head} = state(ctx)
      before_events = events(ctx, "user.password_set")

      signed = H.consume!(link)

      assert {:ok, %{id: id}} = Accounts.current_operator(signed.__metadata__.token)
      assert id == user.id
      assert :error = Accounts.current_operator(old)
      assert {^users, ^owners, _, _} = state(ctx)
      assert {:ok, %{status: :active}} = Ash.get(@owner, owner.id, H.kernel(ctx))
      assert events(ctx, "user.password_set") == before_events + 1
      refute_credentials_in_audit(ctx, link)
    end

    test "a failure after the hash rolls back password, revocation and consumption", ctx do
      %{enrollment_token: link, user: user} = H.enrol!(ctx)
      assert {:ok, old, _} = AshAuthentication.Jwt.token_for_user(user)
      hash = hashed_password(user.id)
      before = state(ctx)
      inject!("audit_events", "NEW.event_type = 'user.password_set'")

      result = safely(fn -> H.consume(link) end)

      refute match?({:ok, _}, result)
      assert state(ctx) == before
      assert hashed_password(user.id) == hash
      assert {:ok, _} = Accounts.current_operator(old)
      Repo.query!("DROP TRIGGER sdr_test_hosted_owner_fault ON audit_events", [])
      assert {:ok, _} = H.consume(link)
    end

    test "the new user actions refuse direct callers outside the operations scope", ctx do
      %{enrollment_token: link, user: user} = H.enrol!(ctx)
      signed = H.consume!(link)

      for action <- [@set_action, @reissue_action] do
        assert Ash.Resource.Info.action(User, action), "missing User #{action} action"

        # A forged auth-library interaction context must not reach the
        # AshAuthentication bypass: the scope guard is declared before it.
        forged = %{private: %{ash_authentication?: true}}

        for actor <- [signed, ctx.fx.auditor, Actor.system(:kernel, ctx.fx.tenant.id), nil],
            context <- [%{}, forged] do
          args = if action == @set_action, do: H.setup_attrs("direct-caller-pass"), else: %{}

          result =
            safely(fn ->
              user
              |> Ash.Changeset.for_update(action, args, actor: actor, context: context)
              |> Ash.update()
            end)

          assert match?({:error, %Ash.Error.Forbidden{}}, result),
                 "#{action} did not forbid a direct #{inspect(actor)} with " <>
                   "#{inspect(context)}: #{inspect(result)}"
        end
      end

      assert {:ok, _} = Accounts.sign_in(to_string(user.email), H.setup_password())
    end
  end

  describe "console reissue" do
    test "reissue revokes the old link and sessions and issues one fresh 900 s link", ctx do
      %{enrollment_token: first, user: user, owner: owner} = H.enrol!(ctx)
      signed = H.consume!(first)
      {users, owners, _tokens, _head} = state(ctx)
      before_events = events(ctx, "operations.hosted_owner.link_reissued")

      assert {:ok, %{enrollment_token: fresh, owner: %{id: owner_id}}} =
               H.reissue(ctx, owner.id)

      assert owner_id == owner.id
      assert :error = Accounts.current_operator(signed.__metadata__.token)
      assert {:ok, claims, _} = AshAuthentication.Jwt.verify(fresh, :sdr_agent)
      assert claims["exp"] - claims["iat"] == 900
      assert claims["hosted_owner_id"] == owner.id
      assert claims["relocation_id"] == ctx.relocation.id
      assert {^users, ^owners, _, _} = state(ctx)
      assert events(ctx, "operations.hosted_owner.link_reissued") == before_events + 1

      new_password = "synthetic-owner-recovered"
      assert {:ok, %{id: id}} = H.consume(fresh, H.setup_attrs(new_password))
      assert id == user.id
      assert {:ok, _} = Accounts.sign_in(to_string(user.email), new_password)
      assert {:error, _} = Accounts.sign_in(to_string(user.email), H.setup_password())
      refute_credentials_in_audit(ctx, fresh)
    end

    test "reissue invalidates an unused earlier link", ctx do
      %{enrollment_token: first, owner: owner} = H.enrol!(ctx)
      assert {:ok, %{enrollment_token: fresh}} = H.reissue(ctx, owner.id)
      assert {:error, _} = H.consume(first)
      assert {:ok, _} = H.consume(fresh)
    end

    test "reissue refuses every non-console actor without any write", ctx do
      %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
      signed = H.consume!(link)
      {users, owners, tokens, _audit} = state(ctx)
      reissued = events(ctx, "operations.hosted_owner.link_reissued")

      # Reissue is a guarded console call: a refusal may append exactly the
      # kernel's authz.denied record after the rollback, never a reissue.
      for opts <- [
            [actor: signed],
            [actor: ctx.fx.auditor],
            [actor: Actor.system(:kernel, ctx.fx.tenant.id)],
            []
          ] do
        denied = events(ctx, "authz.denied")
        assert {:error, _} = H.reissue(ctx, owner.id, opts)
        assert {^users, ^owners, ^tokens, _} = state(ctx)
        assert events(ctx, "operations.hosted_owner.link_reissued") == reissued
        assert (events(ctx, "authz.denied") - denied) in [0, 1]
      end

      assert {:ok, _} = Accounts.current_operator(signed.__metadata__.token)
    end

    test "reissue refuses a disabled owner and an unknown owner", ctx do
      %{owner: owner} = H.enrol!(ctx)
      assert {:error, _} = H.reissue(ctx, Ecto.UUID.generate())
      assert {:ok, _} = H.disable(ctx, owner.id)
      {users, owners, tokens, _audit} = state(ctx)
      reissued = events(ctx, "operations.hosted_owner.link_reissued")
      assert {:error, _} = H.reissue(ctx, owner.id)
      # A guarded refusal may add only the kernel's authz.denied record.
      assert {^users, ^owners, ^tokens, _} = state(ctx)
      assert events(ctx, "operations.hosted_owner.link_reissued") == reissued
    end

    test "reissue refuses once the owner's activation is no longer current", ctx do
      %{owner: owner} = H.enrol!(ctx)
      _return = H.relocate!(ctx, ctx.destination, ctx.source, 2)
      {users, owners, tokens, _audit} = state(ctx)
      reissued = events(ctx, "operations.hosted_owner.link_reissued")
      assert {:error, _} = H.reissue(ctx, owner.id)
      assert {^users, ^owners, ^tokens, _} = state(ctx)
      assert events(ctx, "operations.hosted_owner.link_reissued") == reissued
    end

    test "a failed reissue audit rolls back revocation and keeps the session", ctx do
      %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
      signed = H.consume!(link)
      before = state(ctx)
      inject!("audit_events", "NEW.event_type = 'operations.hosted_owner.link_reissued'")
      result = safely(fn -> H.reissue(ctx, owner.id) end)
      refute match?({:ok, _}, result)
      assert state(ctx) == before
      assert {:ok, _} = Accounts.current_operator(signed.__metadata__.token)
    end
  end

  test "setup and reissue leave the Mac worker credential and other subjects untouched", ctx do
    %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
    %{worker: worker} = SdrAgent.RemoteCallFixtures.enrol!(ctx.fx)
    assert {:ok, other, _} = AshAuthentication.Jwt.token_for_user(ctx.fx.auditor)
    digest = worker_digest(worker.id)

    _signed = H.consume!(link)
    assert {:ok, _} = H.reissue(ctx, owner.id)

    assert worker_digest(worker.id) == digest
    assert {:ok, _} = Accounts.current_operator(other)
  end

  defp state(ctx) do
    table = AshPostgres.DataLayer.Info.table(@owner)

    %{rows: [head]} =
      Repo.query!(
        "SELECT last_sequence, last_event_hash FROM audit_chain_heads WHERE tenant_id = $1",
        [Ecto.UUID.dump!(ctx.fx.tenant.id)]
      )

    %{rows: tokens} =
      Repo.query!(
        "SELECT jti, subject, purpose, expires_at, extra_data::text FROM tokens ORDER BY jti",
        []
      )

    maxima =
      Repo.query!(
        "SELECT count(*), max(sequence) FROM audit_events WHERE tenant_id = $1",
        [Ecto.UUID.dump!(ctx.fx.tenant.id)]
      ).rows

    {scalar("SELECT count(*) FROM users", []), scalar("SELECT count(*) FROM \"#{table}\"", []),
     tokens, {head, maxima}}
  end

  defp events(ctx, type) do
    scalar("SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2", [
      Ecto.UUID.dump!(ctx.fx.tenant.id),
      type
    ])
  end

  defp refute_credentials_in_audit(ctx, link) do
    %{rows: rows} =
      Repo.query!(
        "SELECT payload::text, convert_from(canonical_bytes, 'UTF8') FROM audit_events " <>
          "WHERE tenant_id = $1 AND event_type IN ('user.password_set', " <>
          "'operations.hosted_owner.link_reissued')",
        [Ecto.UUID.dump!(ctx.fx.tenant.id)]
      )

    assert rows != []

    for text <- List.flatten(rows) do
      refute text =~ link
      refute text =~ H.setup_password()
      # The field may be named in the audit's redaction list, never valued.
      refute text =~ ~r/"hashed_password"\s*:/
      refute text =~ "$2b$"
    end
  end

  defp hashed_password(id) do
    scalar("SELECT hashed_password FROM users WHERE id = $1", [Ecto.UUID.dump!(id)])
  end

  defp worker_digest(id) do
    table = AshPostgres.DataLayer.Info.table(SdrAgent.Operations.MacWorker)
    scalar("SELECT token_sha256 FROM \"#{table}\" WHERE id = $1", [Ecto.UUID.dump!(id)])
  end

  defp inject!(table, condition) do
    Repo.query!(
      """
      CREATE FUNCTION pg_temp.sdr_test_hosted_owner_fault() RETURNS trigger AS $$
      BEGIN
        IF #{condition} THEN RAISE EXCEPTION 'synthetic hosted owner fault'; END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """,
      []
    )

    Repo.query!(
      "CREATE TRIGGER sdr_test_hosted_owner_fault BEFORE INSERT ON \"#{table}\" " <>
        "FOR EACH ROW EXECUTE FUNCTION pg_temp.sdr_test_hosted_owner_fault()",
      []
    )
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  end

  defp scalar(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end
end
