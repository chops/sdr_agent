defmodule SdrAgent.Prototype.SeedAnchorTest do
  @moduledoc """
  `SettingsRevision :seed_prototype` and the anchor FK (supplement 1 r2 §4,
  Codex R7; interfaces r6 IF-6 R4): `created_by_id` is NOT NULL, so
  `SdrAgent.Prototype.Changes.SeedAnchor` sets it server-side, after live
  operator resolution, to the binding's `operator_user_id`, validated as
  that binding's `agent_operator` user in its tenant. No caller-supplied
  creator; the event actor stays the delegation; number 1 only; ordinary
  `:create_revision` is unchanged; the operator never reads settings
  content.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.DossierFixtures, as: F

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  defp seed_revision(actor, args) do
    SettingsRevision
    |> Ash.Changeset.for_create(:seed_prototype, args, actor: actor)
    |> Ash.create()
  end

  # User administration is refused in prototype runtime, so the extra user
  # is made in ordinary runtime and the test re-enters the binding.
  defp admin_outside_runtime!(ctx) do
    :ok = SdrAgent.PrototypeFixtures.leave_runtime()
    admin = new_human(:admin, ctx.tenant)
    :ok = SdrAgent.PrototypeFixtures.enter_runtime(ctx.fixture.snapshot)
    admin
  end

  defp guide, do: F.seed_contents()["writing_guide.json"]
  defp note, do: "d237 seed provenance sha256:" <> String.duplicate("a", 64)

  test "the seed revision's creator is the binding's anchor; the event actor is the delegation",
       ctx do
    result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note()})

    assert match?({:ok, %SettingsRevision{}}, result),
           "seed_prototype returned #{inspect(result)}"

    {:ok, revision} = result

    assert revision.created_by_id == ctx.fixture.binding.operator_user_id
    assert revision.number == 1
    assert [event] = events_of_type(ctx.tenant, "settings.revision.created")
    assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
  end

  test "a caller-supplied creator is refused", ctx do
    other = admin_outside_runtime!(ctx)

    assert {:error, _} =
             seed_revision(ctx.actor, %{
               kind: :writing_guide,
               content: guide(),
               note: note(),
               created_by_id: other.id
             })
  end

  test "number 1 only: a second seed revision of a kind is refused", ctx do
    assert {:ok, _} =
             seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note()})

    assert {:error, _} =
             seed_revision(ctx.actor, %{
               kind: :writing_guide,
               content: %{"text" => "Sign as the GTMscape team. Again."},
               note: note()
             })

    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM settings_revisions", [])
    assert n == 1
  end

  test "a forged, foreign or non-operator actor is refused", ctx do
    for actor <- [
          %{ctx.actor | id: Ecto.UUID.generate()},
          %{ctx.actor | tenant_id: Ecto.UUID.generate()},
          SdrAgent.Actor.system(:agent_runtime, ctx.tenant.id),
          SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               seed_revision(actor, %{kind: :writing_guide, content: guide(), note: note()})
    end
  end

  test "a binding whose anchor is not an agent_operator user is refused", ctx do
    # Enter prototype runtime with a snapshot naming another user as the
    # anchor: the live binding row no longer matches, and the anchor check
    # refuses before any write.
    admin = admin_outside_runtime!(ctx)
    snapshot = %{ctx.fixture.snapshot | operator_user_id: admin.id}
    :ok = SdrAgent.PrototypeFixtures.enter_runtime(snapshot)

    assert {:error, _} =
             seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note()})

    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM settings_revisions", [])
    assert n == 0
  end

  test "the operator stays refused on ordinary :create_revision; settings content is not read",
       ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             SettingsRevision
             |> Ash.Changeset.for_create(
               :create_revision,
               %{kind: :writing_guide, content: guide(), expected_number: 0},
               actor: ctx.actor
             )
             |> Ash.create()

    {:ok, _} = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note()})

    # The read policy is unchanged: the operator reads no settings row or content.
    result = Ash.read(SettingsRevision, actor: ctx.actor)
    assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)
  end

  test "ordinary runtime: :seed_prototype is refused for everyone", ctx do
    :ok = SdrAgent.PrototypeFixtures.leave_runtime()

    assert {:error, %Ash.Error.Forbidden{}} =
             seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note()})
  end
end
