defmodule SdrAgent.Prototype.SeedScopeTest do
  @moduledoc """
  Synthetic D-268 C-scope contract: live actor first, transaction markers,
  process registration, same-run event provenance and ordered stored members.
  No policy line or real seed execution is claimed by this scope increment.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.IcpDefinition
  alias SdrAgent.Sales.Sequence
  alias SdrAgent.Sales.SequenceStep

  @scope SdrAgent.Prototype.SeedScope
  @order [:offering_profile, :icp_definition, :sequence, :sequence_step, :campaign]

  setup do
    fixture = bound!()
    provenance = F.stored_provenance!(fixture.actor)
    %{actor: fixture.actor, tenant: fixture.tenant, provenance: provenance}
  end

  defp run(ctx, fun) do
    Repo.transaction(fn ->
      call(@scope, :run, [ctx.actor, %{digest: ctx.provenance.sha256}, fun])
    end)
  end

  defp create(resource, attrs, ctx, run_id) do
    resource
    |> Ash.Changeset.for_create(:seed_prototype, attrs,
      actor: ctx.actor,
      context: %{sdr_seed_run_id: run_id}
    )
    |> Ash.create!()
  end

  defp profile(ctx, run_id) do
    create(
      SettingsRevision,
      %{
        kind: :offering_profile,
        content: F.seed_read().offering_profile,
        note: ctx.provenance.note
      },
      ctx,
      run_id
    )
  end

  defp icp(ctx, run_id) do
    input = F.seed_read().campaign["icp"]

    create(
      IcpDefinition,
      %{
        name: input["name"] <> " " <> Integer.to_string(System.unique_integer([:positive])),
        description: input["description"],
        criteria: input["criteria"],
        seed_provenance_sha256: ctx.provenance.sha256
      },
      ctx,
      run_id
    )
  end

  defp bind!(ref, kind, record) do
    result = call(@scope, :bind, [ref, kind, record])
    assert match?(%{members: _}, result), "expected bound scope, got #{inspect(result)}"
    result
  end

  defp members!(ref, ctx) do
    run_id = call(@scope, :fetch_run_id, [ref])
    profile = profile(ctx, run_id)
    bind!(ref, :offering_profile, profile)
    icp = icp(ctx, run_id)
    bind!(ref, :icp_definition, icp)

    sequence =
      create(
        Sequence,
        %{name: "Synthetic sequence", seed_provenance_sha256: ctx.provenance.sha256},
        ctx,
        run_id
      )

    bind!(ref, :sequence, sequence)

    step =
      create(
        SequenceStep,
        %{
          sequence_id: sequence.id,
          instructions: "One synthetic question.",
          seed_provenance_sha256: ctx.provenance.sha256
        },
        ctx,
        run_id
      )

    bind!(ref, :sequence_step, step)

    campaign =
      create(
        Campaign,
        %{
          name: "Synthetic campaign",
          icp_definition_id: icp.id,
          sequence_id: sequence.id,
          sender_name: "the GTMscape team",
          sender_email: "team@gtmscape.example",
          footer_template_version: "footer/1",
          seed_provenance_sha256: ctx.provenance.sha256
        },
        ctx,
        run_id
      )

    bind!(ref, :campaign, campaign)

    %{
      offering_profile: profile,
      icp_definition: icp,
      sequence: sequence,
      sequence_step: step,
      campaign: campaign
    }
  end

  test "the live actor opens a registered transaction scope and cleanup removes it", ctx do
    parent = self()

    result =
      run(ctx, fn ref ->
        send(parent, {:opened_ref, ref})
        scope = call(@scope, :fetch, [ref])
        assert scope.actor == ctx.actor
        assert scope.tenant_id == ctx.tenant.id
        assert scope.delegation_id == ctx.actor.id
        assert scope.digest == ctx.provenance.sha256
        assert is_binary(scope.xact_id)
        assert is_binary(scope.marker)
        assert is_binary(scope.run_id)
        assert Ecto.UUID.cast(scope.run_id) == {:ok, scope.run_id}
        assert call(@scope, :fetch_run_id, [ref]) == scope.run_id
        assert scope.members == %{}
        :opened
      end)

    assert result == {:ok, :opened}
    assert_received {:opened_ref, ref}
    assert call(@scope, :fetch, [ref]) == nil
    assert call(@scope, :fetch_run_id, [ref]) == nil
  end

  test "outside a transaction refuses without invoking the callback", ctx do
    refute Repo.in_transaction?()
    parent = self()

    assert call(@scope, :run, [
             ctx.actor,
             %{digest: ctx.provenance.sha256},
             fn _ -> send(parent, :called) end
           ]) == {:error, :not_in_transaction}

    refute_received :called
  end

  test "a forged actor or ordinary runtime refuses before invoking the callback", ctx do
    forged = %{ctx.actor | id: Ecto.UUID.generate()}
    parent = self()

    assert Repo.transaction(fn ->
             call(@scope, :run, [
               forged,
               %{digest: ctx.provenance.sha256},
               fn _ -> send(parent, :called) end
             ])
           end) == {:ok, {:error, :forbidden}}

    :ok = PrototypeFixtures.leave_runtime()
    assert run(ctx, fn _ -> send(parent, :called) end) == {:ok, {:error, :forbidden}}
    refute_received :called
  end

  test "a bad digest refuses without invoking the callback", ctx do
    parent = self()

    for digest <- [nil, "bad", String.duplicate("A", 64), String.duplicate("a", 63)] do
      assert Repo.transaction(fn ->
               call(@scope, :run, [
                 ctx.actor,
                 %{digest: digest},
                 fn _ -> send(parent, :called) end
               ])
             end) == {:ok, {:error, :invalid_digest}}
    end

    refute_received :called
  end

  test "a nested registered scope refuses and leaves the outer scope registered", ctx do
    assert run(ctx, fn ref ->
             before = call(@scope, :fetch, [ref])

             assert call(@scope, :run, [
                      ctx.actor,
                      %{digest: ctx.provenance.sha256},
                      fn _ -> flunk("nested callback") end
                    ]) == {:error, :already_registered}

             assert call(@scope, :fetch, [ref]) == before
             :outer_kept
           end) == {:ok, :outer_kept}
  end

  test "all five ordered stored members bind using this run's creation evidence", ctx do
    assert run(ctx, fn ref ->
             members = members!(ref, ctx)
             scope = call(@scope, :fetch, [ref])
             assert Map.keys(scope.members) |> Enum.sort() == Enum.sort(@order)
             for kind <- @order, do: assert(scope.members[kind].id == members[kind].id)
             :complete
           end) == {:ok, :complete}
  end

  test "an old same-delegation ICP plus a new profile never vouches for this run", ctx do
    old = icp(ctx, nil)

    assert run(ctx, fn ref ->
             bind!(ref, :offering_profile, profile(ctx, call(@scope, :fetch_run_id, [ref])))
             assert call(@scope, :bind, [ref, :icp_definition, old]) == {:error, :scope_refused}
             :old_refused
           end) == {:ok, :old_refused}
  end

  test "a new member without this run's correlation is refused", ctx do
    assert run(ctx, fn ref ->
             bind!(ref, :offering_profile, profile(ctx, call(@scope, :fetch_run_id, [ref])))

             assert call(@scope, :bind, [ref, :icp_definition, icp(ctx, nil)]) ==
                      {:error, :scope_refused}

             :nonce_refused
           end) == {:ok, :nonce_refused}
  end

  test "binding out of order or twice refuses without altering registered members", ctx do
    assert run(ctx, fn ref ->
             nonce = call(@scope, :fetch_run_id, [ref])
             draft = icp(ctx, nonce)
             assert call(@scope, :bind, [ref, :icp_definition, draft]) == {:error, :scope_refused}
             revision = profile(ctx, nonce)
             bound = bind!(ref, :offering_profile, revision)

             assert call(@scope, :bind, [ref, :offering_profile, revision]) ==
                      {:error, :scope_refused}

             assert call(@scope, :fetch, [ref]) == bound
             :order_refused
           end) == {:ok, :order_refused}
  end

  test "a released or cross-process scope cannot authorize activation", ctx do
    result =
      run(ctx, fn ref ->
        scope = call(@scope, :fetch, [ref])
        parent = self()
        spawn(fn -> send(parent, {:other_process, call(@scope, :fetch, [ref])}) end)
        assert_receive {:other_process, nil}
        assert call(@scope, :valid?, [scope, %{}, ctx.actor]) == false
        scope
      end)

    assert match?({:ok, %{ref: _}}, result)
    {:ok, scope} = result
    assert call(@scope, :fetch, [scope.ref]) == nil
    assert call(@scope, :valid?, [scope, %{}, ctx.actor]) == false
  end

  test "opening a scope enqueues nothing and starts no product work", ctx do
    before = Repo.query!("SELECT count(*) FROM oban_jobs", []).rows
    assert run(ctx, fn _ref -> :no_work end) == {:ok, :no_work}
    assert Repo.query!("SELECT count(*) FROM oban_jobs", []).rows == before
  end

  test "callback raise and throw both release the process registration", ctx do
    for exit_kind <- [:raise, :throw] do
      parent = self()

      result =
        try do
          run(ctx, fn ref ->
            send(parent, {:cleanup_ref, ref})
            if exit_kind == :raise, do: raise("synthetic callback"), else: throw(:synthetic)
          end)
        rescue
          RuntimeError -> :raised
        catch
          :throw, :synthetic -> :thrown
        end

      assert result == if(exit_kind == :raise, do: :raised, else: :thrown)
      assert_received {:cleanup_ref, ref}
      assert call(@scope, :fetch, [ref]) == nil
    end
  end

  test "a savepoint rollback invalidates the marker for vouched member writes", ctx do
    assert run(ctx, fn ref ->
             Repo.query!("SAVEPOINT d268_seed_members", [])
             members = members!(ref, ctx)
             scope = call(@scope, :fetch, [ref])

             changeset =
               Ash.Changeset.for_update(members.icp_definition, :activate, %{}, actor: ctx.actor)

             Repo.query!("ROLLBACK TO SAVEPOINT d268_seed_members", [])
             Repo.query!("RELEASE SAVEPOINT d268_seed_members", [])
             assert call(@scope, :valid?, [scope, changeset, ctx.actor]) == false
             :marker_refused
           end) == {:ok, :marker_refused}
  end

  test "bind rechecks a now-stale actor before any privileged member read", ctx do
    old = icp(ctx, nil)

    assert run(ctx, fn ref ->
             parent = self()
             handler = "d268-seed-read-#{System.unique_integer([:positive])}"

             tables = [
               "settings_revisions",
               "icp_definitions",
               "sequences",
               "sequence_steps",
               "campaigns",
               "audit_events"
             ]

             :ok = PrototypeFixtures.leave_runtime()

             :ok =
               :telemetry.attach(
                 handler,
                 [:sdr_agent, :repo, :query],
                 fn _, _, metadata, _ ->
                   if self() == parent and metadata[:source] in tables,
                     do: send(parent, :member_read)
                 end,
                 nil
               )

             try do
               assert call(@scope, :bind, [ref, :icp_definition, old]) == {:error, :scope_refused}
               refute_received :member_read
             after
               :telemetry.detach(handler)
             end

             :stale_refused
           end) == {:ok, :stale_refused}
  end
end
