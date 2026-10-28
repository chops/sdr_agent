defmodule SdrAgent.Prototype.SeedWriteTest do
  @moduledoc """
  The GTM seed write `SdrAgent.Prototype.Seed.run/2` (interfaces r6 IF-7
  "How it is written", IF-6 R4 SettingsRevision; supplement 1 r2 §3-§4, R5;
  plan r7 section 6 "GTM seed"): the profile and guide through
  `SettingsRevision :seed_prototype` (number 1 only, the actual content
  rules, the anchor as `created_by_id`, the provenance digest in the note,
  the provenance file as a scoped Payload), the ICP, the one-step sequence
  and the campaign through their `:seed_prototype` actions, then the
  seed-scoped activation; replay and a differing seed; value-free codes.
  Synthetic seed documents built directly in the `SeedDir.read/2` output
  shape, so these tests reach the seed write without the parser.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F

  @seed SdrAgent.Prototype.Seed

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  defp seed(contents \\ F.seed_contents()), do: F.seed_read(contents)

  defp run!(seed, actor) do
    result = call(@seed, :run, [seed, actor])
    assert match?({:ok, %{result: _}}, result), "Seed.run/2 returned #{inspect(result)}"
    {:ok, summary} = result
    summary
  end

  defp count(table, where \\ "TRUE", params \\ []) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE #{where}", params)
    n
  end

  describe "a first seed" do
    test "writes revision 1 of the profile and the guide with the anchor and the provenance note",
         ctx do
      seed = seed()
      summary = run!(seed, ctx.actor)
      assert summary.result == :created
      assert summary.revisions == 2

      %{rows: rows} =
        Repo.query!(
          "SELECT kind, number, created_by_id, note, content_sha256 FROM settings_revisions ORDER BY kind",
          []
        )

      assert [
               ["offering_profile", 1, anchor_a, note_a, _],
               ["writing_guide", 1, anchor_b, note_b, _]
             ] = rows

      assert Ecto.UUID.cast!(anchor_a) == ctx.fixture.anchor.id
      assert Ecto.UUID.cast!(anchor_b) == ctx.fixture.anchor.id
      assert note_a =~ seed.sha256.provenance
      assert note_b =~ seed.sha256.provenance

      for event <- events_of_type(ctx.tenant, "settings.revision.created") do
        assert event.actor_type == :prototype_operator
        assert event.actor_id == ctx.actor.id
      end
    end

    test "stores the provenance file as a Payload, never as settings keys", ctx do
      seed = seed()
      run!(seed, ctx.actor)

      digest = Base.decode16!(seed.sha256.provenance, case: :lower)

      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM payloads WHERE sha256 = $1", [digest])

      assert content == seed.provenance_bytes

      %{rows: profiles} =
        Repo.query!(
          "SELECT offering_profile::text FROM settings_revisions WHERE kind = 'offering_profile'",
          []
        )

      refute hd(hd(profiles)) =~ "public_url"
    end

    test "creates and activates the ICP, the one-step sequence and the campaign with the reserved sender",
         ctx do
      summary = run!(seed(), ctx.actor)

      %{rows: [[icp_status, icp_name]]} =
        Repo.query!("SELECT status, name FROM icp_definitions WHERE id = $1", [
          Ecto.UUID.dump!(summary.icp_id)
        ])

      assert {icp_status, icp_name} == {"active", "Synthetic small B2B software"}

      %{rows: [["active"]]} =
        Repo.query!("SELECT status FROM sequences WHERE id = $1", [
          Ecto.UUID.dump!(summary.sequence_id)
        ])

      %{rows: steps} =
        Repo.query!(
          "SELECT position, channel, delay_days, requires_approval, stop_on_reply FROM sequence_steps WHERE sequence_id = $1",
          [Ecto.UUID.dump!(summary.sequence_id)]
        )

      assert steps == [[1, "email", 0, true, true]]

      %{rows: [[status, sender_name, sender_email, icp_id, sequence_id]]} =
        Repo.query!(
          "SELECT status, sender_name, sender_email, icp_definition_id, sequence_id FROM campaigns WHERE id = $1",
          [Ecto.UUID.dump!(summary.campaign_id)]
        )

      assert {status, sender_name, sender_email} ==
               {"active", "the GTMscape team", "team@gtmscape.example"}

      assert byte_size(sender_name) == 17
      assert Ecto.UUID.cast!(icp_id) == summary.icp_id
      assert Ecto.UUID.cast!(sequence_id) == summary.sequence_id

      for type <-
            ~w(sales.icp_definition.activated sales.sequence.activated sales.campaign.activated) do
        assert [event] = events_of_type(ctx.tenant, type)
        assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
      end

      assert count("oban_jobs") == 0
    end

    test "the ICP criteria are the campaign file's, and only they reach qualification", ctx do
      summary = run!(seed(), ctx.actor)

      {:ok, icp} =
        Ash.get(
          SdrAgent.Sales.IcpDefinition,
          summary.icp_id,
          SdrAgent.Audit.Kernel.opts(ctx.tenant.id)
        )

      criteria = F.seed_contents()["campaign.json"]["icp"]["criteria"]

      assert icp.criteria.employee_count_min == criteria["employee_count_min"]
      assert icp.criteria.employee_count_max == criteria["employee_count_max"]
      assert icp.criteria.industries == criteria["industries"]
      assert icp.criteria.geographies == criteria["geographies"]
      assert icp.criteria.personas == criteria["personas"]
      assert icp.criteria.triggers == criteria["triggers"]
    end
  end

  describe "the actual settings content rules (no bypass)" do
    test "a forbidden control character, an over-bound guide or an over-long item refuses the whole seed",
         ctx do
      contents = F.seed_contents()

      cases = [
        put_in(contents, ["writing_guide.json", "text"], "Sign as the GTMscape team.\u0007"),
        put_in(
          contents,
          ["writing_guide.json", "text"],
          "the GTMscape team " <> String.duplicate("g", 5_983)
        ),
        F.update(contents, ["offering_profile.json", "items", 0, "text"], fn _ ->
          String.duplicate("i", 401)
        end),
        put_in(
          contents,
          ["campaign.json", "sequence", "step", "instructions"],
          "Ask one question.\u001B"
        )
      ]

      for bad <- cases do
        assert call(@seed, :run, [seed(bad), ctx.actor]) == {:error, :seed_invalid}
        assert count("settings_revisions") == 0
        assert count("icp_definitions") == 0
        assert count("campaigns") == 0
      end
    end

    test "the guide at exactly its 6000-character bound is accepted", ctx do
      text = "the GTMscape team " <> String.duplicate("g", 5_982)
      assert String.length(text) == 6_000
      contents = put_in(F.seed_contents(), ["writing_guide.json", "text"], text)
      assert run!(seed(contents), ctx.actor).result == :created
    end

    test "the canonical profile over 16 KiB is refused", ctx do
      items =
        for k <- 1..30 do
          %{"id" => "feature-#{k}", "kind" => "feature", "text" => String.duplicate("f", 400)}
        end

      contents = put_in(F.seed_contents(), ["offering_profile.json", "items"], items)
      assert call(@seed, :run, [seed(contents), ctx.actor]) == {:error, :seed_invalid}
      assert count("settings_revisions") == 0
    end

    test "the seed action's content errors equal :create_revision's (field and rule, no value)",
         ctx do
      content = %{"text" => "Sign as the GTMscape team.\u0007"}

      errors = fn action, args ->
        SdrAgent.Agents.SettingsRevision
        |> Ash.Changeset.for_create(action, args, actor: ctx.actor)
        |> Map.fetch!(:errors)
        |> Enum.map(&{Map.get(&1, :field), &1 |> Map.get(:vars, []) |> Keyword.get(:rule)})
        |> Enum.sort()
      end

      seed_errors = errors.(:seed_prototype, %{kind: :writing_guide, content: content})

      ordinary =
        errors.(:create_revision, %{kind: :writing_guide, content: content, expected_number: 0})

      assert seed_errors != []
      assert seed_errors == ordinary
      refute inspect(seed_errors) =~ "\u0007"
    end
  end

  describe "replay, a differing seed and number 1 only" do
    test "an identical second run is a replay and writes nothing", ctx do
      seed = seed()
      first = run!(seed, ctx.actor)

      before =
        {count("settings_revisions"), count("icp_definitions"), count("campaigns"),
         length(events(ctx.tenant))}

      again = run!(seed, ctx.actor)
      assert again.result == :replay

      assert Map.take(again, [:icp_id, :sequence_id, :campaign_id]) ==
               Map.take(first, [:icp_id, :sequence_id, :campaign_id])

      assert {count("settings_revisions"), count("icp_definitions"), count("campaigns"),
              length(events(ctx.tenant))} == before
    end

    test "a seed with another provenance digest is refused, and no revision 2 is written", ctx do
      run!(seed(), ctx.actor)

      other =
        put_in(
          F.seed_contents(),
          ["writing_guide.json", "text"],
          "Sign as the GTMscape team. Be brief."
        )

      assert call(@seed, :run, [seed(other), ctx.actor]) == {:error, :seed_differs}
      assert count("settings_revisions", "number > 1") == 0
      assert count("icp_definitions") == 1
    end
  end

  describe "the campaign sender address" do
    test "the reserved-name guard stays on the campaign sender address", ctx do
      changeset =
        SdrAgent.Sales.Campaign
        |> Ash.Changeset.for_create(
          :seed_prototype,
          %{
            name: "x",
            icp_definition_id: Ecto.UUID.generate(),
            sender_name: "the GTMscape team",
            sender_email: "team@gtmscape.com",
            footer_template_version: "v1"
          },
          actor: ctx.actor
        )

      assert Enum.any?(changeset.errors, &(Map.get(&1, :field) == :sender_email)),
             "a non-reserved sender address passed: #{inspect(changeset.errors)}"
    end
  end
end
