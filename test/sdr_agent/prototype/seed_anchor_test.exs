defmodule SdrAgent.Prototype.SeedAnchorTest do
  @moduledoc """
  `SettingsRevision :seed_prototype`, the anchor FK and the provenance note
  (supplement 1 r2 §4, Codex R7; interfaces r6 IF-6 R4; the seed design
  ruling b8d624fe, D1):

  - `created_by_id` is NOT NULL, so `SdrAgent.Prototype.Changes.SeedAnchor`
    sets it server-side, after live operator resolution, to the binding's
    `operator_user_id`, validated as that binding's `agent_operator` user in
    its tenant. A caller-supplied creator is not an input; the event actor
    stays the delegation; number 1 only; ordinary `:create_revision` is
    unchanged; the operator never reads settings content. The anchor check
    itself is reached with the policy intact: an anchor row whose role or
    tenant changed underneath is refused on `created_by_id`.
  - The note is a closed machine reference: exactly
    `"d237 seed provenance sha256:"` plus 64 lowercase hex naming the
    provenance Payload actually stored in the operator's tenant. It is kept
    byte for byte; a malformed note (case, whitespace, suffix, control
    character, prefix, length, type), a missing note, or a well-formed note
    naming no Payload of this tenant is refused on the note, value-free,
    writing nothing.

  The provenance is the synthetic seed's, stored through the genuine scoped
  Payload store (`SdrAgent.DossierFixtures.stored_provenance!/2`). The
  database admits one tenant, so a Payload of another tenant exists only by
  moving a real row's `tenant_id` (`SdrAgent.AuditCase.tamper!/2`).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.DossierFixtures, as: F

  setup do
    fixture = bound!()
    provenance = F.stored_provenance!(fixture.actor)

    %{
      fixture: fixture,
      actor: fixture.actor,
      tenant: fixture.tenant,
      provenance: provenance,
      note: provenance.note
    }
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

  defp revisions do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM settings_revisions", [])
    n
  end

  defp stored_note do
    %{rows: rows} = Repo.query!("SELECT note FROM settings_revisions", [])
    rows
  end

  defp note_refused?({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.any?(errors, &(Map.get(&1, :field) == :note))

  defp note_refused?(_result), do: false

  defp anchor_refused?({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.any?(errors, &(Map.get(&1, :field) == :created_by_id))

  defp anchor_refused?(_result), do: false

  test "the seed revision's creator is the binding's anchor; the event actor is the delegation",
       ctx do
    result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})

    assert match?({:ok, %SettingsRevision{}}, result),
           "seed_prototype returned #{inspect(result)}"

    {:ok, revision} = result

    assert revision.created_by_id == ctx.fixture.binding.operator_user_id
    assert revision.number == 1
    assert [event] = events_of_type(ctx.tenant, "settings.revision.created")
    assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
  end

  test "a caller-supplied creator is not an input", ctx do
    other = admin_outside_runtime!(ctx)

    result =
      seed_revision(ctx.actor, %{
        kind: :writing_guide,
        content: guide(),
        note: ctx.note,
        created_by_id: other.id
      })

    assert {:error, %Ash.Error.Invalid{errors: errors}} = result
    assert Enum.any?(errors, &(Map.get(&1, :input) == :created_by_id)), inspect(errors)
    assert revisions() == 0
  end

  test "number 1 only: a second seed revision of a kind is refused", ctx do
    first = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})
    assert match?({:ok, _}, first), "the first seed revision returned #{inspect(first)}"

    assert {:error, _} =
             seed_revision(ctx.actor, %{
               kind: :writing_guide,
               content: %{"text" => "Sign as the GTMscape team. Again."},
               note: ctx.note
             })

    assert revisions() == 1
  end

  test "a forged, foreign or non-operator actor is refused", ctx do
    for actor <- [
          %{ctx.actor | id: Ecto.UUID.generate()},
          %{ctx.actor | tenant_id: Ecto.UUID.generate()},
          SdrAgent.Actor.system(:agent_runtime, ctx.tenant.id),
          SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               seed_revision(actor, %{kind: :writing_guide, content: guide(), note: ctx.note})
    end

    assert revisions() == 0
  end

  # Codex 969bf261: this refusal comes from the live binding check (the
  # policy), not from SeedAnchor; it is no anchor-body proof. The isolated
  # anchor checks are in "the anchor check" below.
  test "a boot snapshot naming another user as the anchor is refused at the live check", ctx do
    # Enter prototype runtime with a snapshot naming another user as the
    # anchor: the live binding row no longer matches the snapshot.
    admin = admin_outside_runtime!(ctx)
    snapshot = %{ctx.fixture.snapshot | operator_user_id: admin.id}
    :ok = SdrAgent.PrototypeFixtures.enter_runtime(snapshot)

    assert {:error, _} =
             seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})

    assert revisions() == 0
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

    seeded = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})
    assert match?({:ok, _}, seeded), "seed_prototype returned #{inspect(seeded)}"

    # The read policy is unchanged: the operator reads no settings row or content.
    result = Ash.read(SettingsRevision, actor: ctx.actor)
    assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)
  end

  test "ordinary runtime: :seed_prototype is refused for everyone", ctx do
    :ok = SdrAgent.PrototypeFixtures.leave_runtime()

    assert {:error, %Ash.Error.Forbidden{}} =
             seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})
  end

  # Codex 969bf261: SeedAnchor itself, reached with the live binding,
  # delegation and policy intact. The operator resolver checks the
  # delegation's binding, tenant and anchor id, not the anchor User row, so a
  # real anchor row changed underneath (AuditCase.tamper!/2, one statement)
  # passes the policy and reaches the anchor check, which must refuse.
  describe "the anchor check" do
    test "an anchor whose role is no longer agent_operator is refused, writing nothing", ctx do
      tamper!("UPDATE users SET role = 'admin', hashed_password = $1 WHERE id = $2", [
        "not-a-real-hash",
        Ecto.UUID.dump!(ctx.fixture.binding.operator_user_id)
      ])

      result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})
      assert anchor_refused?(result), "returned #{inspect(result)}"
      assert revisions() == 0
      assert events_of_type(ctx.tenant, "settings.revision.created") == []
    end

    test "an anchor row of another tenant is refused, writing nothing", ctx do
      tamper!("UPDATE users SET tenant_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(ctx.fixture.binding.operator_user_id)
      ])

      result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})
      assert anchor_refused?(result), "returned #{inspect(result)}"
      assert revisions() == 0
    end
  end

  # Codex b8d624fe D1: the typed machine-reference contract of the note.
  describe "the provenance note" do
    test "the exact note naming the stored provenance Payload is kept byte for byte", ctx do
      result =
        seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: ctx.note})

      assert match?({:ok, _}, result), "seed_prototype returned #{inspect(result)}"
      assert stored_note() == [[ctx.note]]
    end

    test "a malformed note is refused on the note, value-free, writing nothing", ctx do
      hex = ctx.provenance.sha256
      prefix = F.note_prefix()

      malformed = [
        uppercase_hex: prefix <> String.upcase(hex),
        leading_space: " " <> ctx.note,
        trailing_space: ctx.note <> " ",
        trailing_newline: ctx.note <> "\n",
        suffix: ctx.note <> "x",
        control_character: ctx.note <> "\u0007",
        no_colon: "d237 seed provenance sha256 " <> hex,
        other_prefix: "seed provenance sha256:" <> hex,
        short_digest: prefix <> String.slice(hex, 0, 63),
        long_digest: prefix <> hex <> "0",
        digest_only: hex,
        not_text: 42,
        a_map: %{"sha256" => hex}
      ]

      for {label, note} <- malformed do
        result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note})
        assert note_refused?(result), "#{label}: returned #{inspect(result)}"
        refute inspect(result) =~ hex, "#{label}: the refusal echoes the digest"
        refute inspect(result) =~ String.upcase(hex), "#{label}: the refusal echoes the digest"
      end

      assert revisions() == 0
    end

    test "a missing note is refused, writing nothing", ctx do
      result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide()})
      assert note_refused?(result), "returned #{inspect(result)}"
      assert revisions() == 0
    end

    test "a well-formed note naming no Payload of this tenant is refused, value-free", ctx do
      # A digest of bytes never stored, and a Payload moved to another tenant.
      absent = F.sha256(~s({"schema":"never stored"}))
      foreign = F.stored_payload!(ctx.actor, ~s({"schema":"moved away"}))

      tamper!("UPDATE payloads SET tenant_id = $1 WHERE sha256 = $2", [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Base.decode16!(foreign, case: :lower)
      ])

      for {label, hex} <- [no_payload: absent, other_tenant: foreign] do
        note = F.note_prefix() <> hex
        result = seed_revision(ctx.actor, %{kind: :writing_guide, content: guide(), note: note})
        assert note_refused?(result), "#{label}: returned #{inspect(result)}"
        refute inspect(result) =~ hex, "#{label}: the refusal echoes the digest"
      end

      assert revisions() == 0
    end
  end
end
