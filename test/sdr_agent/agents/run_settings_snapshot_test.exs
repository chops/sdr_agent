defmodule SdrAgent.Agents.RunSettingsSnapshotTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 5 tests 10-13 and 18-20;
  C4-R4..R8): every new run binds one immutable settings snapshot in the
  transaction that creates it. `SDR.assign_lead/2` pre-checks business
  completeness before any write; the snapshot records revisions, built-in
  defaults by version or "absent", with a recomputable `snapshot_sha256`;
  later saves never change a bound run; a retry shares its original's
  snapshot and a null-snapshot retry is refused before anything is written;
  the snapshot is created only through the run's own `:create`; built-in
  defaults are hash-pinned and fail closed; and only `SdrAgent.Agents`
  reads current revisions.

  RED: the resources and functions do not exist yet; calls are
  presence-guarded (`SdrAgent.SettingsFixtures`).
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.SettingsFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Operation
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.FakeBrain

  @moduletag :c4_01a

  # Golden `content_sha256` of every released built-in default version
  # (section 3.7 rule), keyed `{kind, version}`. Pinned when the defaults
  # are written (C4-01a GREEN); a released entry is never edited or removed.
  # Each value was recomputed independently of the implementation (a
  # standalone sdr-canonical-json/1 encoder over the reviewed content).
  @golden [
    {{:writing_guide, "1"}, "9af216ab3fdf3b11536fbb8fcfa47f816891b0a74f4e5cdcd4821e15831d02c3"},
    {{:research_brief, "1"}, "7f169d445f877e99845bd13871ba096d36aac6ac5db163969b93caa80408d709"},
    {{:operational_limits, "1"},
     "bff11e94226951b449ec75332157de80518b1cc08cfae17803464867e22b0874"}
  ]

  defmodule InvalidQualification do
    @moduledoc "Test responder: an invalid qualification score fails the run."
    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  defp golden(kind, version) do
    Enum.find_value(@golden, :unpinned, fn {key, sha} -> if key == {kind, version}, do: sha end)
  end

  defp failed_run!(ctx, key) do
    %{run: run} =
      assign!(ctx, key, model: [provider_options: [responder: InvalidQualification]])

    assert %{success: 1} = drain!()
    failed = run!(ctx, run)
    assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}
    failed
  end

  defp counts(ctx) do
    opts = Kernel.opts(ctx.tenant.id)
    {:ok, runs} = Ash.read(AgentRun, opts)
    {:ok, operations} = Ash.read(Operation, opts)

    %{
      runs: length(runs),
      operations: length(operations),
      jobs: length(all_enqueued(worker: AgentWorker)),
      snapshots: table_exists?("run_settings_snapshots") and count_rows("run_settings_snapshots"),
      ledger: length(events(ctx.tenant))
    }
  end

  ## Test 10

  describe "test 10: business completeness before any write" do
    test "assign_lead/2 with no offering is refused and writes nothing", ctx do
      assert not table_exists?("settings_revisions") or
               latest_number(ctx.tenant.id, :offering_profile) == 0,
             "precondition: the demo seed saves no offering profile"

      lead = fixture_lead!(ctx, "01")
      before = counts(ctx)
      result = SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: ctx.admin)

      assert result == {:error, {:settings_incomplete, [:offering_profile]}},
             "C4-01a: assign_lead without an offering: #{short(result)}"

      assert counts(ctx) == before
      assert fixture_lead!(ctx, "01").status == lead.status
    end
  end

  ## Test 11

  describe "test 11: assignment binds a snapshot" do
    test "revisions for saved kinds, built-in defaults by version otherwise; hash recomputes",
         ctx do
      offering = save_offering!(ctx.admin)
      booking = save!(:booking_link, content(:booking_link), ctx.admin)
      %{run: run} = assign!(ctx, "01")
      snapshot = snapshot_of!(run, ctx.agent)

      for revision <- [offering, booking] do
        kind = revision.kind

        assert {Map.get(snapshot, :"#{kind}_source"), Map.get(snapshot, :"#{kind}_revision_id"),
                Map.get(snapshot, :"#{kind}_content_sha256"),
                Map.get(snapshot, :"#{kind}_code_default_version")} ==
                 {:revision, revision.id, revision.content_sha256, nil}
      end

      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        default = current_default(kind)

        assert {Map.get(snapshot, :"#{kind}_source"),
                Map.get(snapshot, :"#{kind}_code_default_version"),
                Map.get(snapshot, :"#{kind}_content_sha256"),
                Map.get(snapshot, :"#{kind}_revision_id")} ==
                 {:code_default, default.version, default.content_sha256, nil}
      end

      assert snapshot.tenant_id == ctx.tenant.id
      assert snapshot.hash_version == "c4-run-settings-snapshot/1"
      assert snapshot.safeguards_version == safeguards_version()
      assert limits_map(snapshot.limits) == limits_map(limit_defaults())
      assert snapshot.snapshot_sha256 == recompute_snapshot_sha256(snapshot)

      assert {run.budget.max_model_calls, run.budget.max_tool_calls, run.budget.max_tokens} ==
               {20, 60, 100_000}

      assert {:ok, settings} = run_settings(run, ctx.agent)

      for revision <- [offering, booking] do
        assert slot_value(settings, revision.kind, :source) == :revision
        assert slot_value(settings, revision.kind, :revision_id) == revision.id
        assert slot_value(settings, revision.kind, :content_sha256) == revision.content_sha256

        assert slot_value(settings, revision.kind, :content) ==
                 Map.fetch!(revision, revision.kind)
      end

      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        default = current_default(kind)
        assert slot_value(settings, kind, :source) == :code_default
        assert slot_value(settings, kind, :version) == default.version
        assert slot_value(settings, kind, :content) == default.content
      end

      assert [created] = events_of_type(ctx.tenant, "agents.run.created") |> by_subject(run.id)
      assert created.payload["changes"]["settings_snapshot_id"] == snapshot.id

      assert [snap_event] =
               events_of_type(ctx.tenant, "settings.snapshot.created") |> by_subject(snapshot.id)

      assert snap_event.payload["changes"]["snapshot_sha256"] == snapshot.snapshot_sha256
      refute inspect(snap_event.payload, limit: :infinity) =~ "Example Widgets Scheduler"
      refute inspect(snap_event.payload, limit: :infinity) =~ "book.example.test"
    end
  end

  defp by_subject(events, id), do: Enum.filter(events, &(&1.subject_id == id))

  ## Test 12

  describe "test 12: a later save never changes a bound run" do
    test "the queued run keeps its settings; the next assignment sees the new revision", ctx do
      save_offering!(ctx.admin)
      %{run: queued} = assign!(ctx, "01")
      before = snapshot_of!(queued, ctx.agent)
      assert {:ok, settings} = run_settings(queued, ctx.agent)

      guide = save!(:writing_guide, %{text: "Guide revision one, synthetic."}, ctx.admin)

      queued = run!(ctx, queued)
      assert snapshot_of!(queued, ctx.agent) == before
      assert {:ok, ^settings} = run_settings(queued, ctx.agent)
      assert slot_value(settings, :writing_guide, :source) == :code_default

      %{run: next} = assign!(ctx, "02")
      refute next.settings_snapshot_id == queued.settings_snapshot_id
      snapshot = snapshot_of!(next, ctx.agent)

      assert {snapshot.writing_guide_source, snapshot.writing_guide_revision_id} ==
               {:revision, guide.id}

      assert {:ok, next_settings} = run_settings(next, ctx.agent)
      assert slot_value(next_settings, :writing_guide, :content) == guide.writing_guide
    end
  end

  describe "absent slots (Codex f2d2253 ruling)" do
    test "an absent slot has an explicit shape and never falls back to a later revision",
         ctx do
      save_offering!(ctx.admin)
      %{run: run} = assign!(ctx, "01")

      absent = %{
        source: :absent,
        revision_id: nil,
        version: nil,
        content_sha256: nil,
        content: nil
      }

      assert {:ok, settings} = run_settings(run, ctx.agent)

      assert Map.take(slot(settings, :booking_link) || %{}, Map.keys(absent)) == absent,
             "C4-01a: absent booking slot: #{short(slot(settings, :booking_link))}"

      save!(:booking_link, content(:booking_link), ctx.admin)
      assert {:ok, after_save} = run_settings(run!(ctx, run), ctx.agent)

      assert Map.take(slot(after_save, :booking_link) || %{}, Map.keys(absent)) == absent,
             "C4-01a: the bound run fell back to the current booking revision"
    end
  end

  ## Test 13

  describe "test 13: retry" do
    test "a retry shares the original snapshot, whatever was saved since", ctx do
      save_offering!(ctx.admin)
      failed = failed_run!(ctx, "01")
      original = snapshot_of!(failed, ctx.agent)
      save!(:writing_guide, %{text: "A guide saved after the failure."}, ctx.admin)

      assert {:ok, %{run: retry}} = SDR.retry_run(failed.id, actor: ctx.admin)
      assert retry.settings_snapshot_id == original.id
      assert {:ok, settings} = run_settings(retry, ctx.agent)
      assert slot_value(settings, :writing_guide, :source) == :code_default
    end

    test "a retry of a historical null-snapshot run is refused before anything is written",
         ctx do
      save_offering!(ctx.admin)
      failed = failed_run!(ctx, "01")
      require_column!("agent_runs", "settings_snapshot_id")

      tamper!("UPDATE agent_runs SET settings_snapshot_id = NULL WHERE id = $1", [
        Ecto.UUID.dump!(failed.id)
      ])

      before = counts(ctx)
      result = SDR.retry_run(failed.id, actor: ctx.admin)
      assert result == {:error, :no_settings_snapshot}, "C4-01a: #{short(result)}"
      assert counts(ctx) == before

      {:ok, failure} = Operations.get_failure(failed.attention_failure_id, actor: ctx.admin)
      assert failure.status == :open, "the attention Failure was resolved"
    end
  end

  ## Test 18

  describe "test 18: the snapshot is created only by the run's :create" do
    test "a direct snapshot create is forbidden, with or without supplied attributes", ctx do
      snapshot = require_module!(snapshot_resource())
      before = count_rows("run_settings_snapshots")

      for actor <- [ctx.agent, system_actor(:kernel, ctx.tenant), ctx.admin] do
        result = snapshot |> Ash.Changeset.for_create(:create, %{}, actor: actor) |> Ash.create()

        assert ash_forbidden?(result),
               "C4-01a: direct snapshot create by #{short(actor)}: #{short(result)}"
      end

      # Markers a caller could put on a changeset: the module's own accessor
      # (called here, outside any run creation, and from another process)
      # and forged keys. None may authorize a create.
      context_module = require_module!(SdrAgent.Agents.Checks.SettingsSnapshotContext)

      copied =
        if function_exported?(context_module, :context, 0),
          do: [
            apply(context_module, :context, []),
            Task.await(Task.async(context_module, :context, []))
          ],
          else: []

      forged = [
        %{sdr_agent_settings_snapshot: true},
        %{sdr_agent_run_settings_snapshot: true},
        %{settings_snapshot: true, run_settings_snapshot: true}
      ]

      supplied = [
        %{},
        %{id: Ash.UUIDv7.generate()},
        %{snapshot_sha256: String.duplicate("a", 64)},
        %{offering_profile_revision_id: Ash.UUIDv7.generate()},
        %{writing_guide_code_default_version: "1"},
        %{limits: limit_defaults()},
        %{tenant_id: ctx.tenant.id}
      ]

      for marker <- copied ++ forged, attrs <- supplied do
        result =
          snapshot
          |> Ash.Changeset.for_create(:create, attrs, actor: ctx.agent, context: marker)
          |> Ash.create()

        assert ash_forbidden?(result),
               "C4-01a: snapshot create with marker #{short(marker)} and #{short(attrs)}: #{short(result)}"
      end

      # From an arbitrary process, too.
      result =
        Task.async(fn ->
          marker = if copied == [], do: hd(forged), else: hd(copied)

          snapshot
          |> Ash.Changeset.for_create(:create, %{}, actor: ctx.agent, context: marker)
          |> Ash.create()
        end)
        |> Task.await()

      assert ash_forbidden?(result),
             "C4-01a: snapshot create from another process: #{short(result)}"

      assert count_rows("run_settings_snapshots") == before
    end

    test "settings_snapshot_id cannot be supplied to AgentRun :create", ctx do
      assert Ash.Resource.Info.attribute(AgentRun, :settings_snapshot_id),
             "C4-01a: AgentRun.settings_snapshot_id missing"

      save_offering!(ctx.admin)
      %{run: run} = assign!(ctx, "01")
      definition = SdrAgent.AgentsFixtures.definition!(ctx.tenant)

      attrs =
        definition
        |> SdrAgent.AgentsFixtures.run_attrs(usage_origin: :reply)
        |> Map.put(:settings_snapshot_id, run.settings_snapshot_id)

      result = Agents.create_run(attrs, actor: ctx.agent)

      assert ash_invalid?(result),
             "C4-01a: a caller-supplied settings_snapshot_id was not refused as input: #{short(result)}"
    end
  end

  ## Test 19

  describe "test 19: built-in defaults" do
    test "golden hashes: every released default version is pinned and recomputes", _ctx do
      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        released = released_defaults(kind)
        assert released != [], "C4-01a: no released built-in #{kind}"
        versions = Enum.map(released, & &1.version)
        assert versions == Enum.uniq(versions)

        for %{version: version, content: content, content_sha256: sha} <- released do
          assert sha == content_sha256(kind, content),
                 "#{kind} v#{version} hash does not recompute"

          assert golden(kind, version) == sha,
                 "C4-01a: pin the golden hash of built-in #{kind} v#{version}"
        end
      end

      for kind <- [:offering_profile, :booking_link] do
        assert released_defaults(kind) == [], "#{kind} has no built-in default (C4-R7)"
      end

      limits = current_default(:operational_limits).content
      assert limits_map(limits) == limits_map(limit_defaults())
    end

    test "each built-in default passes the same validation as an admin save", ctx do
      broken = %{
        writing_guide: &Map.put(&1, :text, Map.fetch!(&1, :text) <> "\a"),
        research_brief: &Map.put(&1, :depth, :deep),
        operational_limits: &Map.put(&1, :run_max_model_calls, 0)
      }

      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        default = current_default(kind)

        # The same validation: a default broken in one field is refused.
        attrs =
          revision_attrs(kind, broken[kind].(default.content), ctx.admin, expected_number: 0)

        result = observe(fn -> create_revision(attrs, ctx.admin) end)

        assert invalid_errors(result),
               "C4-01a: a broken built-in #{kind} was saved: #{short(result)}"

        revision = save!(kind, default.content, ctx.admin, expected_number: 0)
        assert revision.content_sha256 == default.content_sha256
        assert revision.raised_fields == []
      end
    end

    test "a removed default version or a changed hash makes run_settings/2 fail closed", ctx do
      save_offering!(ctx.admin)
      %{run: removed} = assign!(ctx, "01")
      %{run: changed} = assign!(ctx, "02")
      require_column!("run_settings_snapshots", "writing_guide_code_default_version")
      _ = snapshot_of!(removed, ctx.agent)
      _ = snapshot_of!(changed, ctx.agent)

      tamper!(
        "UPDATE run_settings_snapshots SET writing_guide_code_default_version = '999999' " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(removed.settings_snapshot_id)]
      )

      tamper!(
        "UPDATE run_settings_snapshots SET writing_guide_content_sha256 = repeat('0', 64) " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(changed.settings_snapshot_id)]
      )

      for run <- [removed, changed] do
        result = run_settings(run, ctx.agent)
        assert result == {:error, :settings_default_unavailable}, "C4-01a: #{short(result)}"
      end
    end

    test "a run without a snapshot gets no settings", ctx do
      save_offering!(ctx.admin)
      %{run: run} = assign!(ctx, "01")
      require_column!("agent_runs", "settings_snapshot_id")

      tamper!("UPDATE agent_runs SET settings_snapshot_id = NULL WHERE id = $1", [
        Ecto.UUID.dump!(run.id)
      ])

      run = run!(ctx, run)
      assert run_settings(run, ctx.agent) == {:error, :no_settings_snapshot}
      assert allowance(run, :research_max_sources) == {:error, :no_settings_snapshot}
    end
  end

  ## Test 20

  describe "test 20: only SdrAgent.Agents reads current revisions" do
    test "no module outside SdrAgent.Agents references SettingsRevision or current_settings/1",
         _ctx do
      revision = require_module!(revision_resource())

      assert function_exported?(Agents, :current_settings, 1),
             "C4-01a: SdrAgent.Agents.current_settings/1 is not implemented"

      {:ok, modules} = :application.get_key(:sdr_agent, :modules)

      offenders =
        for module <- modules, not settings_reader?(module), reads_current?(module, revision) do
          module
        end

      assert offenders == [], "modules reading current revisions: #{inspect(offenders)}"
    end
  end

  # Allowed readers: the Agents domain itself (with the protocol
  # implementations generated for its resources), the settings page
  # (C4-01b), and test-support modules (never part of a release).
  defp settings_reader?(module) do
    name = Atom.to_string(module)
    source = module.module_info(:compile)[:source] |> to_string()

    module == Agents or String.starts_with?(name, "Elixir.SdrAgent.Agents.") or
      String.starts_with?(name, "Elixir.Inspect.SdrAgent.Agents.") or
      String.starts_with?(name, "Elixir.SdrAgentWeb.SettingsLive") or
      String.contains?(source, "/test/support/")
  end

  defp reads_current?(module, revision) do
    {:ok, {_module, [imports: imports, atoms: atoms]}} =
      :beam_lib.chunks(:code.which(module), [:imports, :atoms])

    {Agents, :current_settings, 1} in imports or
      Enum.any?(atoms, fn {_index, atom} -> atom == revision end)
  end
end
