defmodule SdrAgent.Agents.ModelResultReleaseTest do
  @moduledoc """
  R0-07 slice A: the immutable `ModelResultRelease` (R0-07 entity PASS at
  1da747a, section 2; REQ-07-5). One release per completed generation-2
  ClaudeCLI invocation, decided by AGT only:

    * `:released` ↔ `:reconciled`, with this invocation's current,
      reconciled primary link whose evidence names the invocation's identity
      and an exact allowlist entry, and a `:valid` output;
    * `:withheld` ↔ `:witness_mismatch | :witness_missing |
      :witness_timeout | :store_unreadable | :gate_interrupted`;
    * `:calibration` ↔ `:calibration`, only under `CalibrationContext`, for a
      `:proof` run's invocation in any terminal status, with
      `evidence_sha256`.

  Composite FKs keep the invocation in the release's tenant and the link on
  this invocation; a trigger blocks update and delete; an identical replay
  returns the existing row and a conflicting one is refused; concurrent
  decides are covered in `ModelResultReleaseRaceTest`.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.CalibrationContext
  alias SdrAgent.Agents.Errors.ReleaseConflict
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.RecordHash

  @withheld [
    :witness_mismatch,
    :witness_missing,
    :witness_timeout,
    :store_unreadable,
    :gate_interrupted
  ]

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    invocation = AgentsFixtures.claude_completed!(run, agent, "rel-1")

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: rec,
      invocation: invocation,
      link: AgentsFixtures.reconciled_link!(invocation, rec)
    }
  end

  defp decide(attrs, opts), do: Agents.decide_result_release(attrs, opts)

  defp released(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        model_invocation_id: ctx.invocation.id,
        disposition: :released,
        reason: :reconciled,
        wire_witness_link_id: ctx.link.id
      },
      Map.new(overrides)
    )
  end

  defp withheld(invocation, reason, link \\ nil) do
    %{
      model_invocation_id: invocation.id,
      disposition: :withheld,
      reason: reason,
      wire_witness_link_id: link && link.id
    }
  end

  defp new_invocation(ctx, key, completion \\ AgentsFixtures.completion()),
    do: AgentsFixtures.claude_completed!(ctx.run, ctx.agent, key, completion)

  defp releases(ctx) do
    {:ok, rows} = Agents.list_result_releases(actor: system_actor(:auditor_cli, ctx.tenant))
    rows
  end

  defp result_events(ctx),
    do: Enum.filter(events(ctx.tenant), &String.starts_with?(&1.event_type, "model.result."))

  defp invalid?(result), do: match?({:error, %Ash.Error.Invalid{}}, result)

  describe ":decide released" do
    test "AGT releases a reconciled output; the event, link, projection and method are recorded",
         ctx do
      assert {:ok, release} = decide(released(ctx), actor: ctx.agent)

      assert {release.disposition, release.reason} == {:released, :reconciled}
      assert release.model_invocation_id == ctx.invocation.id
      assert release.tenant_id == ctx.tenant.id
      assert release.wire_witness_link_id == ctx.link.id
      assert release.projection_version == AgentsFixtures.release_projection()
      assert release.method == :propagated_id
      assert release.evidence_sha256 == nil
      assert %DateTime{} = release.decided_at
      assert release.trace_id =~ ~r/^[0-9a-f]{32}$/

      assert [event] = events_of_type(ctx.tenant, "model.result.released")
      assert event.subject_id == release.id
      assert event.model_invocation_id == ctx.invocation.id
      assert event.agent_run_id == ctx.run.id
      assert event.actor_type == :agent_runtime
      assert event.payload["record_sha256"] == RecordHash.hex(release)

      # The invocation itself is never updated for its release.
      {:ok, stored} = Ash.get(Agents.ModelInvocation, ctx.invocation.id, actor: ctx.rec)
      assert stored.updated_at == ctx.invocation.updated_at

      assert {:ok, %{id: id}} = Agents.get_result_release(ctx.invocation.id, actor: ctx.agent)
      assert id == release.id

      assert {:ok, report} = SdrAgent.Audit.verify_chain(actor: human(:admin, ctx.tenant))
      assert report.valid?, inspect(report.issues)
    end

    test "an invalid-schema completion cannot be released (but can be withheld)", ctx do
      invalid = %{AgentsFixtures.completion() | validation_status: :invalid}
      invocation = new_invocation(ctx, "rel-invalid", invalid)
      link = AgentsFixtures.reconciled_link!(invocation, ctx.rec)

      assert invalid?(
               decide(
                 released(ctx, model_invocation_id: invocation.id, wire_witness_link_id: link.id),
                 actor: ctx.agent
               )
             )

      assert {:ok, %{disposition: :withheld}} =
               decide(withheld(invocation, :witness_missing), actor: ctx.agent)
    end

    test "the link must be this invocation's current, reconciled primary link", ctx do
      other = new_invocation(ctx, "rel-other")
      other_link = AgentsFixtures.reconciled_link!(other, ctx.rec)
      inferred = AgentsFixtures.reconciled_link!(other, ctx.rec, link_status: :inferred)

      ancillary =
        AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec,
          evidence: %{"classification" => "ancillary"}
        )

      for {label, attrs} <- [
            {"no link", released(ctx, wire_witness_link_id: nil)},
            {"another invocation's link", released(ctx, wire_witness_link_id: other_link.id)},
            {"an inferred link",
             released(ctx, model_invocation_id: other.id, wire_witness_link_id: inferred.id)},
            {"an ancillary link", released(ctx, wire_witness_link_id: ancillary.id)},
            {"an unknown link", released(ctx, wire_witness_link_id: Ash.UUIDv7.generate())}
          ] do
        assert invalid?(decide(attrs, actor: ctx.agent)), label
      end

      assert releases(ctx) == []
    end

    test "a superseded link is refused at decision time", ctx do
      {:ok, successor} =
        ctx.invocation
        |> AgentsFixtures.link_attrs(
          proxy_record_ref: ctx.link.proxy_record_ref,
          supersedes_id: ctx.link.id,
          evidence: %{"supersede_reason" => "reconciliation_rerun"}
        )
        |> Agents.link_wire_witness(actor: ctx.rec)

      assert invalid?(decide(released(ctx), actor: ctx.agent))

      assert {:ok, %{wire_witness_link_id: id}} =
               decide(released(ctx, wire_witness_link_id: successor.id), actor: ctx.agent)

      assert id == successor.id
    end

    test "the evidence must name the invocation's identity", ctx do
      for {label, evidence} <- [
            {"other CLI version", %{"cli_version" => "2.1.294"}},
            {"other request digest", %{"app_request_sha256" => hex(digest("other"))}},
            {"other response digest", %{"app_response_sha256" => hex(digest("other"))}}
          ] do
        link = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, evidence: evidence)

        assert invalid?(decide(released(ctx, wire_witness_link_id: link.id), actor: ctx.agent)),
               label
      end
    end

    test "the exact tuple must be on the allowlist", ctx do
      for entries <- [
            [],
            [%{AgentsFixtures.release_entry() | profile_id: :claude_cli_sonnet}],
            [%{AgentsFixtures.release_entry() | profile_id: nil}],
            [
              %{
                AgentsFixtures.release_entry()
                | projection_version: "claude-message-json/3+prompt-builder/1"
              }
            ]
          ] do
        AgentsFixtures.put_allowlist!(entries)
        assert invalid?(decide(released(ctx), actor: ctx.agent)), inspect(entries)
      end

      AgentsFixtures.put_allowlist!()
      assert {:ok, _release} = decide(released(ctx), actor: ctx.agent)
    end

    test "every other current link must leave the invocation reconciled", ctx do
      AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec,
        link_status: :inferred,
        evidence: %{"classification" => "unclassified"}
      )

      assert invalid?(decide(released(ctx), actor: ctx.agent))
    end
  end

  describe ":decide withheld" do
    test "each withheld reason is recorded, with or without a link", ctx do
      for reason <- @withheld do
        invocation = new_invocation(ctx, "rel-#{reason}")

        assert {:ok, release} = decide(withheld(invocation, reason), actor: ctx.agent)
        assert {release.disposition, release.reason} == {:withheld, reason}
        assert release.wire_witness_link_id == nil
      end

      assert length(events_of_type(ctx.tenant, "model.result.withheld")) == length(@withheld)

      mismatch = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :mismatch)

      assert {:ok, %{wire_witness_link_id: id}} =
               decide(withheld(ctx.invocation, :witness_mismatch, mismatch), actor: ctx.agent)

      assert id == mismatch.id
    end

    test "a withheld decision with a link copies the link's projection and method (MF2)", ctx do
      mismatch = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :mismatch)
      attrs = withheld(ctx.invocation, :witness_mismatch, mismatch)

      assert {:ok, release} = decide(attrs, actor: ctx.agent)
      assert release.wire_witness_link_id == mismatch.id
      assert release.projection_version == mismatch.evidence["projection_version"]
      assert release.method == mismatch.method
      assert release.projection_version == AgentsFixtures.release_projection()

      [event] = events_of_type(ctx.tenant, "model.result.withheld")
      assert event.payload["changes"]["projection_version"] == release.projection_version
      assert event.payload["changes"]["method"] == "propagated_id"

      # An identical replay returns the same row and appends no event.
      assert {:ok, again} = decide(attrs, actor: ctx.agent)
      assert again.id == release.id

      assert {again.projection_version, again.method} ==
               {release.projection_version, release.method}

      assert length(events_of_type(ctx.tenant, "model.result.withheld")) == 1

      # Without a link, both stay nil.
      other = new_invocation(ctx, "rel-nolink")
      assert {:ok, bare} = decide(withheld(other, :witness_timeout), actor: ctx.agent)
      assert {bare.projection_version, bare.method} == {nil, nil}
    end

    test "released and withheld need a completed generation-2 ClaudeCLI invocation", ctx do
      fake =
        "rel-fake"
        |> AgentsFixtures.model_attrs()
        |> then(&Agents.reserve_model_invocation(ctx.run, &1, actor: ctx.agent))
        |> then(fn {:ok, reserved} -> reserved end)

      {:ok, fake} = Agents.mark_model_invocation_sent(fake, actor: ctx.agent)

      {:ok, fake} =
        Agents.complete_model_invocation(fake, AgentsFixtures.completion(), actor: ctx.agent)

      {:ok, sent} =
        SdrAgent.AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(ctx.run, AgentsFixtures.claude_attrs("rel-sent"),
            actor: ctx.agent
          )
        end)
        |> then(fn {:ok, reserved} ->
          Agents.mark_model_invocation_sent(reserved, actor: ctx.agent)
        end)

      {:ok, failed} =
        SdrAgent.AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(ctx.run, AgentsFixtures.claude_attrs("rel-failed"),
            actor: ctx.agent
          )
        end)
        |> then(fn {:ok, reserved} ->
          Agents.fail_model_invocation(reserved, %{error: %{"kind" => "x"}}, actor: ctx.agent)
        end)

      legacy = new_invocation(ctx, "rel-legacy")

      tamper!(
        "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
          "allocation_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(legacy.id)]
      )

      for {label, invocation} <- [
            {"fake", fake},
            {"sent", sent},
            {"failed", failed},
            {"generation 1", legacy}
          ] do
        assert invalid?(decide(withheld(invocation, :witness_missing), actor: ctx.agent)), label
      end

      assert releases(ctx) == []
    end

    # C2* S3 (plan r2 §8): widened to the 4 × 8 matrix with the
    # demo-exception disposition and reason; the valid demo pair is excluded
    # here and decided only by the result-gate finalizer.
    test "every invalid disposition/reason pair is refused", ctx do
      pairs =
        for disposition <- [:released, :withheld, :calibration, :demo_exception],
            reason <- [:reconciled, :calibration, :v4_uncalibrated | @withheld],
            not valid_pair?(disposition, reason),
            do: {disposition, reason}

      assert length(pairs) == 4 * 8 - 8

      for {disposition, reason} <- pairs do
        attrs = %{released(ctx) | disposition: disposition, reason: reason}
        attrs = Map.put(attrs, :evidence_sha256, hex(digest("evidence")))
        assert invalid?(decide(attrs, actor: ctx.agent)), inspect({disposition, reason})
      end

      for attrs <- [
            %{released(ctx) | disposition: :approved},
            %{released(ctx) | reason: :looks_fine},
            Map.put(released(ctx), :evidence_sha256, hex(digest("evidence"))),
            Map.put(
              withheld(ctx.invocation, :witness_missing),
              :evidence_sha256,
              hex(digest("e"))
            )
          ] do
        assert invalid?(decide(attrs, actor: ctx.agent)), inspect(attrs)
      end

      assert releases(ctx) == []
      assert result_events(ctx) == []
    end
  end

  describe "database constraints" do
    test "the pair check rejects invalid rows inserted behind the application", ctx do
      {:ok, release} = decide(released(ctx), actor: ctx.agent)

      for set <- [
            "disposition = 'released', reason = 'witness_missing'",
            "disposition = 'withheld', reason = 'reconciled'",
            "disposition = 'released', wire_witness_link_id = NULL",
            "disposition = 'calibration', reason = 'calibration'",
            "evidence_sha256 = 'not-a-digest'"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 copy(release, set),
               set
      end
    end

    test "composite FKs keep the invocation in the tenant and the link on the invocation", ctx do
      other = new_invocation(ctx, "rel-fk")
      other_link = AgentsFixtures.reconciled_link!(other, ctx.rec)
      third = new_invocation(ctx, "rel-fk-3")
      {:ok, release} = decide(released(ctx), actor: ctx.agent)

      # This release's link, but another invocation; another invocation's link.
      for {set, params} <- [
            {"model_invocation_id = $1", [Ecto.UUID.dump!(other.id)]},
            {"model_invocation_id = $1, wire_witness_link_id = $2",
             [Ecto.UUID.dump!(third.id), Ecto.UUID.dump!(other_link.id)]}
          ] do
        assert {:error,
                %Postgrex.Error{
                  postgres: %{
                    code: :foreign_key_violation,
                    constraint: "model_result_releases_link_invocation_fkey"
                  }
                }} = copy(release, set, params),
               set
      end

      # Move an invocation to another tenant id behind the application's back.
      tamper!("UPDATE model_invocations SET tenant_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(third.id)
      ])

      withheld =
        "model_invocation_id = $1, disposition = 'withheld', reason = 'witness_missing', " <>
          "wire_witness_link_id = NULL, projection_version = NULL, method = NULL"

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :foreign_key_violation,
                  constraint: "model_result_releases_invocation_tenant_fkey"
                }
              }} = copy(release, withheld, [Ecto.UUID.dump!(third.id)])
    end

    test "a trigger blocks update and delete", ctx do
      {:ok, release} = decide(released(ctx), actor: ctx.agent)
      id = Ecto.UUID.dump!(release.id)

      for sql <- [
            "UPDATE model_result_releases SET reason = 'reconciled' WHERE id = $1",
            "UPDATE model_result_releases SET decided_at = now() WHERE id = $1",
            "DELETE FROM model_result_releases WHERE id = $1"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
                 raw_error(sql, [id]),
               sql
      end
    end
  end

  describe "duplicate decide" do
    test "an identical replay returns the existing row with no second event", ctx do
      {:ok, first} = decide(released(ctx), actor: ctx.agent)
      assert {:ok, again} = decide(released(ctx), actor: ctx.agent)
      assert again.id == first.id
      assert length(releases(ctx)) == 1
      assert length(events_of_type(ctx.tenant, "model.result.released")) == 1
    end

    test "a conflicting duplicate is refused and changes nothing", ctx do
      {:ok, first} = decide(released(ctx), actor: ctx.agent)
      other = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :mismatch)

      for attrs <- [
            withheld(ctx.invocation, :witness_mismatch, other),
            withheld(ctx.invocation, :witness_timeout)
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} = decide(attrs, actor: ctx.agent)

        assert Enum.any?(
                 errors,
                 &match?(%ReleaseConflict{existing_id: id} when id == first.id, &1)
               )
      end

      assert [%{id: id, disposition: :released}] = releases(ctx)
      assert id == first.id
      assert length(result_events(ctx)) == 1
    end
  end

  describe "actors" do
    test "only AGT decides; an auditor's attempt is refused and audited", ctx do
      for actor <- [
            ctx.rec,
            system_actor(:kernel, ctx.tenant),
            system_actor(:auditor_cli, ctx.tenant),
            system_actor(:delivery_worker, ctx.tenant),
            human(:admin, ctx.tenant),
            human(:reviewer, ctx.tenant),
            nil
          ] do
        assert match?({:error, %Ash.Error.Forbidden{}}, decide(released(ctx), actor: actor)),
               inspect(actor)
      end

      assert events_of_type(ctx.tenant, "authz.denied") == []

      assert {:error, %Ash.Error.Forbidden{}} =
               decide(released(ctx), actor: human(:auditor, ctx.tenant))

      assert [%{actor_role: :auditor}] = events_of_type(ctx.tenant, "authz.denied")
      assert releases(ctx) == []
    end

    test "admin, auditor, AGT, REC and AUD read releases; others read nothing", ctx do
      {:ok, release} = decide(released(ctx), actor: ctx.agent)

      for actor <- [
            human(:admin, ctx.tenant),
            human(:auditor, ctx.tenant),
            ctx.agent,
            ctx.rec,
            system_actor(:auditor_cli, ctx.tenant)
          ] do
        assert {:ok, %{id: id}} = Agents.get_result_release(ctx.invocation.id, actor: actor)
        assert id == release.id, inspect(actor)
      end

      for actor <- [human(:reviewer, ctx.tenant), system_actor(:delivery_worker, ctx.tenant), nil] do
        assert {:ok, nil} = Agents.get_result_release(ctx.invocation.id, actor: actor),
               inspect(actor)
      end
    end
  end

  describe ":decide calibration" do
    setup ctx do
      %{run: proof, agent: agent} =
        AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

      {:ok, reserved} =
        SdrAgent.AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(proof, AgentsFixtures.claude_attrs("cal-1"),
            actor: agent,
            calibration: SdrAgent.AdmissionFixtures.calibration()
          )
        end)

      {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)

      {:ok, failed} =
        Agents.fail_model_invocation(sent, %{error: %{"kind" => "provider_error"}}, actor: agent)

      %{proof: proof, calibration: failed}
    end

    defp calibration(invocation, overrides \\ %{}) do
      Map.merge(
        %{
          model_invocation_id: invocation.id,
          disposition: :calibration,
          reason: :calibration,
          evidence_sha256: hex(digest("calibration evidence"))
        },
        Map.new(overrides)
      )
    end

    defp cal_context(invocation, profile \\ :claude_cli_opus),
      do: CalibrationContext.context(profile, invocation.id)

    test "under CalibrationContext a terminal proof invocation gets its latch", ctx do
      assert {:ok, latch} =
               decide(calibration(ctx.calibration),
                 actor: ctx.agent,
                 context: cal_context(ctx.calibration)
               )

      assert {latch.disposition, latch.reason} == {:calibration, :calibration}
      assert latch.evidence_sha256 == hex(digest("calibration evidence"))
      assert [event] = events_of_type(ctx.tenant, "model.result.calibration")
      assert event.agent_run_id == ctx.proof.id
    end

    test "a calibration latch with a link copies its projection and method (MF2)", ctx do
      link = AgentsFixtures.reconciled_link!(ctx.calibration, ctx.rec, link_status: :inferred)
      attrs = calibration(ctx.calibration, wire_witness_link_id: link.id)
      opts = [actor: ctx.agent, context: cal_context(ctx.calibration)]

      assert {:ok, latch} = decide(attrs, opts)
      assert latch.wire_witness_link_id == link.id

      assert {latch.projection_version, latch.method} ==
               {AgentsFixtures.release_projection(), :propagated_id}

      assert {:ok, again} = decide(attrs, opts)
      assert again.id == latch.id
      assert length(events_of_type(ctx.tenant, "model.result.calibration")) == 1
    end

    test "a calibration latch is refused without the context, evidence, proof run or profile",
         ctx do
      business = new_invocation(ctx, "cal-business")

      for {label, attrs, opts} <- [
            {"no context", calibration(ctx.calibration), []},
            {"forged context", calibration(ctx.calibration),
             [context: %{calibration: %{profile_id: :claude_cli_opus}}]},
            {"no evidence", calibration(ctx.calibration, evidence_sha256: nil),
             [context: cal_context(ctx.calibration)]},
            {"bad evidence digest", calibration(ctx.calibration, evidence_sha256: "XYZ"),
             [context: cal_context(ctx.calibration)]},
            {"other profile", calibration(ctx.calibration),
             [context: cal_context(ctx.calibration, :claude_cli_sonnet)]},
            {"context for another invocation", calibration(ctx.calibration),
             [context: cal_context(business)]},
            {"business run", calibration(business), [context: cal_context(business)]}
          ] do
        result = decide(attrs, [actor: ctx.agent] ++ opts)

        assert match?({:error, %Ash.Error.Invalid{}}, result) or
                 match?({:error, %Ash.Error.Forbidden{}}, result),
               label
      end

      assert releases(ctx) == []
    end

    test "the builder accepts only a reviewed real profile", ctx do
      for profile <- [:fake, :claude_cli_haiku, nil, "claude_cli_opus"] do
        assert_raise ArgumentError, fn ->
          CalibrationContext.context(profile, ctx.calibration.id)
        end
      end
    end

    test "a calibration invocation is never released or withheld", ctx do
      assert invalid?(decide(withheld(ctx.calibration, :witness_missing), actor: ctx.agent))
    end
  end

  defp valid_pair?(:released, :reconciled), do: true
  defp valid_pair?(:withheld, reason), do: reason in @withheld
  defp valid_pair?(:calibration, :calibration), do: true
  defp valid_pair?(:demo_exception, :v4_uncalibrated), do: true
  defp valid_pair?(_disposition, _reason), do: false

  # Inserts a copy of `release` with `set` applied (a fresh id) in a rolled
  # back transaction, triggers on; returns the Postgres error, or
  # `{:error, :inserted}`.
  defp copy(release, set, params \\ []) do
    Repo.transaction(fn ->
      query = &Ecto.Adapters.SQL.query(Repo, &1, &2)

      with {:ok, _} <-
             query.(
               "CREATE TEMP TABLE release_copy ON COMMIT DROP AS " <>
                 "SELECT * FROM model_result_releases WHERE id = $1",
               [Ecto.UUID.dump!(release.id)]
             ),
           {:ok, _} <- query.("UPDATE release_copy SET id = gen_random_uuid(), #{set}", params),
           {:ok, _} <- query.("INSERT INTO model_result_releases SELECT * FROM release_copy", []) do
        Repo.rollback(:inserted)
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end
end
