defmodule SdrAgent.Prototype.ProvisionTest do
  @moduledoc """
  D-269 owner-receipt provisioning through the existing domain API.
  The grant keeps d237-funding/1, the anchor as creator/updater, one-issue
  provenance and unchanged-term replay without new capacity.
  Parser/privacy controls now live in OwnerAllowanceControlsTest: historical
  six-route counting is superseded, never rewritten as zero consumption.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.OwnerAllowanceFixtures

  @authority SdrAgent.Prototype.Authority

  defp scratch_dir!, do: PrototypeFixtures.scratch_dir!()
  defp worksheet(root), do: OwnerAllowanceFixtures.worksheet(root)
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp provision(ctx, actor \\ nil) do
    call(Agents, :provision_prototype_grant, [
      %{worksheet: ctx.bytes, worksheet_sha256: ctx.digest},
      [actor: actor || ctx.fx.actor, evidence_root: ctx.root]
    ])
  end

  defp provision_result(ctx, actor \\ nil) do
    call(Agents, :provision_prototype_grant_result, [
      %{worksheet: ctx.bytes, worksheet_sha256: ctx.digest},
      [actor: actor || ctx.fx.actor, evidence_root: ctx.root]
    ])
  end

  test "the owner allowance resolves its exact receipt without asserting historical consumption" do
    root = scratch_dir!()
    bytes = root |> worksheet() |> Jason.encode!()

    assert {:ok, %{remaining: 100}} =
             call(@authority, :check_worksheet, [bytes, sha(bytes), root])
  end

  describe "provisioning" do
    setup do
      # Users are arranged before prototype runtime, which refuses user administration.
      fx = bound!(enter_runtime: false)
      admin = human(:admin, fx.tenant)
      enter!(fx)
      root = scratch_dir!()
      bytes = Jason.encode!(worksheet(root))
      %{fx: fx, admin: admin, root: root, bytes: bytes, digest: sha(bytes)}
    end

    test "the operator provisions exactly the entry's terms, with the anchor as creator and updater",
         ctx do
      result = provision(ctx)
      assert match?({:ok, _}, result), "provision: #{inspect(result)}"
      {:ok, grant} = result

      assert grant.total_attempts == 100
      assert grant.starts_at == ~U[2026-10-30 15:05:40.000000Z]
      assert grant.expires_at == ~U[2026-11-07 07:00:00.000000Z]
      assert grant.profile_ids == [:claude_cli_opus]
      assert grant.created_by_id == ctx.fx.anchor.id
      assert grant.updated_by_id == ctx.fx.anchor.id

      [event] = events_of_type(ctx.fx.tenant, "model.grant.provisioned")
      assert event.actor_type == :prototype_operator
      assert event.actor_id == ctx.fx.delegation.id
      assert event.payload["arguments"]["funding_id"] == "d237-funding/1"
      assert event.payload["arguments"]["budget_worksheet_sha256"] == ctx.digest
      assert event.payload["arguments"]["delegation_id"] == ctx.fx.delegation.id
    end

    test "an identical replay returns the same grant; no second grant is created", ctx do
      first = provision(ctx)
      assert match?({:ok, _}, first), "provision: #{inspect(first)}"
      {:ok, grant} = first
      assert match?({:ok, %{id: id}} when id == grant.id, provision(ctx))

      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM model_call_grants", [])
      assert n == 1
    end

    # D-268 M6b (Codex rulings a3f14552, f1bffa89): the companion reports
    # the actual replay/mint branch; no clock or before-read inference.
    test "the result companion reports :created, then :replay of the same grant with no write or evidence reread",
         ctx do
      first = provision_result(ctx)
      assert match?({:ok, %{result: :created}}, first), "first: #{inspect(first)}"
      {:ok, %{grant: grant}} = first

      # A replay reads no evidence: the receipts are gone and it still replays.
      for name <- File.ls!(ctx.root), do: File.rm!(Path.join(ctx.root, name))

      second = provision_result(ctx)
      assert match?({:ok, %{result: :replay}}, second), "replay: #{inspect(second)}"
      {:ok, %{grant: replayed}} = second
      assert replayed.id == grant.id

      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM model_call_grants", [])
      assert n == 1
      assert length(events_of_type(ctx.fx.tenant, "model.grant.provisioned")) == 1
    end

    test "after the companion created the grant, the old API still returns {:ok, grant}", ctx do
      assert match?({:ok, %{result: :created}}, provision_result(ctx))
      result = provision(ctx)
      assert match?({:ok, %SdrAgent.Agents.ModelCallGrant{}}, result), inspect(result)
    end

    test "the companion's refusals equal the old API's", ctx do
      bad_digest = %{ctx | digest: sha("other bytes")}
      assert provision(bad_digest) == {:error, :worksheet_invalid}
      assert provision_result(bad_digest) == {:error, :worksheet_invalid}

      assert match?({:error, %Ash.Error.Forbidden{}}, provision_result(ctx, ctx.admin))

      nested = Repo.transaction(fn -> provision_result(ctx) end)
      assert nested == {:ok, {:error, :binding_mismatch}}, inspect(nested)
    end

    test "a non-operator cannot provision", ctx do
      for {name, actor} <- [
            admin: ctx.admin,
            agent_runtime: system_actor(:agent_runtime, ctx.fx.tenant)
          ] do
        result = provision(ctx, actor)

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "#{name}: expected Forbidden, got #{inspect(result)}"
      end
    end

    test "in prototype runtime grant creation, term changes and releases are refused; revoke is the operator's",
         ctx do
      provisioned = provision(ctx)
      assert match?({:ok, _}, provisioned), "provision: #{inspect(provisioned)}"
      {:ok, grant} = provisioned
      admin = ctx.admin

      created =
        Agents.create_grant(
          %{
            name: "ordinary",
            purpose: "ordinary",
            profile_ids: [:claude_cli_opus],
            total_attempts: 1,
            starts_at: ~U[2026-10-28 03:00:00.000000Z],
            expires_at: ~U[2026-10-29 03:00:00.000000Z]
          },
          actor: admin
        )

      terms =
        Agents.update_grant_terms(grant, %{expected_revision: grant.revision, total_attempts: 40},
          actor: admin
        )

      released =
        Agents.release_allocation(grant, %{expected_revision: grant.revision, key: :b1},
          actor: admin
        )

      for {name, result} <- [create: created, update_terms: terms, release: released] do
        assert match?({:error, %Ash.Error.Forbidden{}}, result), "#{name} was not forbidden"
      end

      assert match?(
               {:ok, %{status: :revoked}},
               Agents.revoke_grant(grant, %{expected_revision: grant.revision},
                 actor: ctx.fx.actor
               )
             )
    end
  end
end
