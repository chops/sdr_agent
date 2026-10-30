defmodule SdrAgent.Prototype.ProvisionedReleaseTest do
  @moduledoc """
  RED-b2 r2, the release on the provisioned grant (interfaces r6 IF-4;
  amendment items 5 and 6; Codex A2, A3; Codex ff812f6d), D-237 slice S2, in
  prototype runtime with S1's real provisioning.

  - **Release.** A completed call on the absent store with no known
    evidence is decided `released_unverified` / `owner_prototype_unverified`
    (no link, projection, method or evidence digest), with exactly one
    `model.result.released_unverified` event whose arguments are the closed
    `d237-basis/1` and its `sdr-canonical-json/1` SHA256. The basis has
    exactly the closed keys at every level (the proposed d237-basis/1 key
    set, pinned here for review), no null, at most 8192 canonical bytes
    (the bytes whose SHA is stored), the funding entry's golden digest, the
    window and the decision instant (the row's `decided_at`), and assurance
    `unverified` with the label `UNVERIFIED (PROTOTYPE)`. Every key is typed and
    sourced: an exact expected dictionary from the boot snapshot, the
    compiled entries, the charged grant and the stored invocation, plus the
    grammar of every UUID, digest, timestamp, decimal and integer.
  - **Refusal codes**, by real actions where possible: revoked
    `grant_not_eligible`; an admin's change in ordinary runtime
    `operator_mismatch`; a revision change behind the application
    (labelled tamper) `grant_changed`; an invalid output `output_invalid`;
    a run no longer running `scope_mismatch`; a live binding drift
    `binding_mismatch`. The run stops `witness_unreconciled`.
  - **Replay** returns the same release and output from the ORIGINAL basis
    and appends nothing: after the window end, after the grant is revoked,
    after an admin changes it in ordinary runtime, and after a binding drift
    recovers (current use refuses during the drift). A released_unverified
    decision with a different valid basis is a `ReleaseConflict` after a
    valid release. Recovery returns an existing release and decides none.
  - **The bounded repeat** (the `before_head` hook moves the hermetic clock
    to the exclusive end): nothing is written, and the one refusal-only
    repeat withholds `outside_window`, even when conditions recover.
  - **Release-branch locks:** the run `FOR UPDATE`, its Operation, the
    invocation, the grant and its allocation `FOR SHARE`, then the head;
    nothing after it. (Sandbox-injected lock-order evidence, not
    two-connection concurrency.)

  The first release, provision, reservation and launch are prerequisites:
  a stop there is classified as such, not as the subject's failure.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Errors.ReleaseConflict
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.Prototype.Release
  alias SdrAgent.PrototypeGateFixtures, as: G

  @golden "d8e675ce642857511ed201fab998484d9cfd40e040f891f141a469d3294d825b"
  @last ~U[2026-11-07 06:59:59.999999Z]
  @end_ ~U[2026-11-07 07:00:00.000000Z]

  # The proposed closed d237-basis/1 key set, at every level.
  @shape %{
    "schema" => nil,
    "policy" => ~w(acceptance_ref entry_sha256 id),
    "funding" => ~w(allocation_id grant_id grant_revision id operator_user_id sha256),
    "prototype" =>
      ~w(binding_id database database_oid dataset_class instance_id system_identifier tenant_id),
    "window" => ~w(decided_at expires_at starts_at),
    "invocation" =>
      ~w(id lead_id output_schema_sha256 purpose request_sha256 response_sha256 run_id usage_origin),
    "identity" => ~w(cli_version ledger_generation model_id profile_id prompt_builder provider),
    "observation" => ~w(classification witness_mode),
    "assurance" => nil,
    "label" => nil
  }

  setup do
    fx = G.prototype!()
    run = G.run!(fx)
    invocation = G.completed!(fx, run)
    previous = Application.get_env(:sdr_agent, Release)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, Release, previous),
        else: Application.delete_env(:sdr_agent, Release)
    end)

    %{fx: fx, run: run, invocation: invocation}
  end

  ## Helpers

  defp refused_code(fx, result, code) do
    with {:withheld, release, _run} <- result,
         true <-
           {release.disposition, release.reason} == {:withheld, :prototype_authority_refused},
         [event] <- G.release_events(fx, "model.result.withheld", release) do
      event.payload["arguments"]["prototype_refusal"] == Atom.to_string(code)
    else
      _ -> false
    end
  end

  defp run_status(run) do
    run = Ash.get!(AgentRun, run.id, authorize?: false)
    {run.status, run.status_reason}
  end

  defp released_events(fx), do: events_of_type(fx.tenant, "model.result.released_unverified")

  defp canonical_hex(term), do: Base.encode16(Canonical.sha256(term), case: :lower)

  # The closed basis records no null at any depth.
  defp no_nil?(nil), do: false
  defp no_nil?(%{} = map), do: Enum.all?(map, fn {_key, value} -> no_nil?(value) end)
  defp no_nil?(list) when is_list(list), do: Enum.all?(list, &no_nil?/1)
  defp no_nil?(_value), do: true

  defp shape(basis) do
    Map.new(basis, fn
      {key, %{} = nested} -> {key, nested |> Map.keys() |> Enum.sort()}
      {key, _scalar} -> {key, nil}
    end)
  end

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

  # The proposed d237-basis/1 dictionary, every key typed and sourced: the
  # exact value from its source (locked rows, the boot snapshot, the
  # compiled entries, the stored invocation), then its grammar.
  defp assert_basis_dictionary!(basis, ctx, release) do
    inv = Ash.get!(SdrAgent.Agents.ModelInvocation, ctx.invocation.id, authorize?: false)
    run = Ash.get!(AgentRun, ctx.run.id, authorize?: false)
    s = ctx.fx.snapshot
    hex = &Base.encode16(&1, case: :lower)

    expected = %{
      "schema" => "d237-basis/1",
      "policy" => %{
        "id" => "d237-prototype/1",
        "acceptance_ref" => "D-249",
        "entry_sha256" => s.policy_entry_sha256
      },
      "funding" => %{
        "id" => "d237-funding/1",
        "sha256" => @golden,
        "grant_id" => ctx.fx.grant.id,
        "grant_revision" => ctx.fx.grant.revision,
        "allocation_id" => inv.allocation_id,
        "operator_user_id" => s.operator_user_id
      },
      "prototype" => %{
        "binding_id" => s.id,
        "instance_id" => s.instance_id,
        "tenant_id" => s.tenant_id,
        "dataset_class" => s.dataset_class,
        "database" => s.database,
        "database_oid" => s.database_oid,
        "system_identifier" => Integer.to_string(s.system_identifier)
      },
      "window" => %{
        "starts_at" => "2026-10-30T15:05:40.000000Z",
        "expires_at" => "2026-11-07T07:00:00.000000Z",
        "decided_at" => Calendar.strftime(release.decided_at, "%Y-%m-%dT%H:%M:%S.%fZ")
      },
      "invocation" => %{
        "id" => inv.id,
        "run_id" => inv.agent_run_id,
        "lead_id" => run.lead_id,
        "usage_origin" => "assignment",
        "purpose" => "qualification",
        "request_sha256" => hex.(inv.request_sha256),
        "response_sha256" => hex.(inv.response_sha256),
        "output_schema_sha256" => hex.(inv.output_schema_sha256)
      },
      "identity" => %{
        "provider" => "claude_cli",
        "cli_version" => inv.provider_version,
        "profile_id" => "claude_cli_opus",
        "model_id" => inv.model_id,
        "prompt_builder" => inv.model_catalog_entry["prompt_builder"],
        "ledger_generation" => 2
      },
      "observation" => %{"witness_mode" => "absent", "classification" => "store_unconfigured"},
      "assurance" => "unverified",
      "label" => "UNVERIFIED (PROTOTYPE)"
    }

    assert basis == expected

    grammar = [
      {@uuid,
       ~w(funding.grant_id funding.allocation_id funding.operator_user_id prototype.binding_id
                 prototype.instance_id prototype.tenant_id invocation.id invocation.run_id
                 invocation.lead_id)},
      {@hex64, ~w(policy.entry_sha256 funding.sha256 invocation.request_sha256
                  invocation.response_sha256 invocation.output_schema_sha256)},
      {@timestamp, ~w(window.starts_at window.expires_at window.decided_at)},
      {~r/\A[0-9]+\z/, ~w(prototype.system_identifier)}
    ]

    for {pattern, paths} <- grammar, path <- paths do
      value = get_in(basis, String.split(path, "."))
      assert is_binary(value) and value =~ pattern, "#{path}: #{inspect(value)}"
    end

    for path <- ~w(funding.grant_revision prototype.database_oid identity.ledger_generation) do
      value = get_in(basis, String.split(path, "."))
      assert is_integer(value) and value > 0, "#{path}: #{inspect(value)}"
    end
  end

  defp released!(ctx) do
    result = G.finalize(ctx.invocation, ctx.run)

    assert match?({:released, %{disposition: :released_unverified}, _}, result),
           "prerequisite: first release: #{inspect(result)}"

    result
  end

  defp basis_event!(fx, release) do
    assert [event] = G.release_events(fx, "model.result.released_unverified", release)
    event
  end

  ## The release

  describe "the release" do
    test "released_unverified with its one closed basis event", ctx do
      result = G.finalize(ctx.invocation, ctx.run)
      assert match?({:released, %{disposition: :released_unverified}, _}, result), inspect(result)
      {:released, release, output} = result

      assert release.reason == :owner_prototype_unverified

      assert {release.wire_witness_link_id, release.projection_version, release.method,
              release.evidence_sha256} == {nil, nil, nil, nil}

      assert output == SdrAgent.AgentsFixtures.completion().parsed_output
      assert run_status(ctx.run) == {:running, nil}

      args = basis_event!(ctx.fx, release).payload["arguments"]
      basis = args["basis"]
      assert Map.keys(args) |> Enum.sort() == ["basis", "basis_sha256"]
      assert shape(basis) == @shape
      assert_basis_dictionary!(basis, ctx, release)
      assert no_nil?(basis), "the basis records a null: #{inspect(basis)}"
      assert byte_size(Canonical.encode!(basis)) <= 8192
      assert args["basis_sha256"] == canonical_hex(basis)

      assert {basis["schema"], basis["assurance"], basis["label"]} ==
               {"d237-basis/1", "unverified", "UNVERIFIED (PROTOTYPE)"}

      assert basis["funding"]["sha256"] == @golden
      assert basis["funding"]["grant_id"] == ctx.fx.grant.id
      assert basis["invocation"]["id"] == ctx.invocation.id
      assert basis["prototype"]["tenant_id"] == ctx.invocation.tenant_id
      assert basis["prototype"]["binding_id"] == ctx.fx.snapshot.id

      assert basis["observation"] == %{
               "witness_mode" => "absent",
               "classification" => "store_unconfigured"
             }

      assert {basis["window"]["starts_at"], basis["window"]["expires_at"]} ==
               {"2026-10-30T15:05:40.000000Z", "2026-11-07T07:00:00.000000Z"}

      assert basis["window"]["decided_at"] ==
               Calendar.strftime(release.decided_at, "%Y-%m-%dT%H:%M:%S.%fZ")
    end
  end

  ## Refusal codes

  describe "refusal codes" do
    test "a revoked grant: grant_not_eligible", ctx do
      revoked =
        Agents.revoke_grant(ctx.fx.grant, %{expected_revision: ctx.fx.grant.revision},
          actor: ctx.fx.actor
        )

      assert match?({:ok, _}, revoked), "prerequisite: revoke: #{inspect(revoked)}"
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :grant_not_eligible), inspect(result)
      assert run_status(ctx.run) == {:failed, :witness_unreconciled}
    end

    test "a grant an admin changed in ordinary runtime: operator_mismatch", ctx do
      :ok = PrototypeFixtures.leave_runtime()

      changed =
        Agents.update_grant_terms(
          ctx.fx.grant,
          %{purpose: "changed by an admin (synthetic)", expected_revision: ctx.fx.grant.revision},
          actor: ctx.fx.admin
        )

      G.enter!(ctx.fx)
      assert match?({:ok, _}, changed), "prerequisite: admin change: #{inspect(changed)}"
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :operator_mismatch), inspect(result)
    end

    test "a revision change behind the application: grant_changed (labelled tamper)", ctx do
      G.tamper_grant!(ctx.fx, "revision = revision + 1")
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :grant_changed), inspect(result)
    end

    test "an invalid output: output_invalid", ctx do
      run = G.run!(ctx.fx)

      invocation =
        G.completed!(ctx.fx, run,
          completion: %{SdrAgent.AgentsFixtures.completion() | validation_status: :invalid}
        )

      result = G.finalize(invocation, run)
      assert refused_code(ctx.fx, result, :output_invalid), inspect(result)
    end

    test "a run no longer running: scope_mismatch", ctx do
      cancelled = Agents.cancel_run(ctx.run, actor: ctx.fx.agent)
      assert match?({:ok, _}, cancelled), "prerequisite: cancel: #{inspect(cancelled)}"
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :scope_mismatch), inspect(result)
    end

    test "a live binding drift: binding_mismatch", ctx do
      G.drift!()
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :binding_mismatch), inspect(result)
    end
  end

  ## Replay

  describe "replay" do
    test "a second finalize replays the original basis, appending nothing", ctx do
      {:released, release, output} = released!(ctx)
      original = basis_event!(ctx.fx, release).payload["arguments"]

      result = G.finalize(ctx.invocation, ctx.run)

      assert match?({:released, %{id: id}, ^output} when id == release.id, result),
             inspect(result)

      assert [event] = released_events(ctx.fx)
      assert event.payload["arguments"] == original
    end

    test "after the window end the replay still uses the original basis", ctx do
      {:released, release, output} = released!(ctx)
      original = basis_event!(ctx.fx, release).payload["arguments"]
      Clock.freeze(@end_)

      result = G.finalize(ctx.invocation, ctx.run)

      assert match?({:released, %{id: id}, ^output} when id == release.id, result),
             inspect(result)

      assert [event] = released_events(ctx.fx)
      assert event.payload["arguments"] == original
    end

    # Historical replay verifies the ORIGINAL facts, never the current grant
    # or authority; only current use (the live binding) is checked again.
    for {label, change} <- [
          revoked: :revoke,
          admin_changed: :admin_update,
          drift_recovered: :drift_then_recover
        ] do
      test "after #{label} the replay returns the original release, output and basis", ctx do
        {:released, release, output} = released!(ctx)
        original = basis_event!(ctx.fx, release).payload["arguments"]
        historical_change!(ctx, unquote(change))

        result = G.finalize(ctx.invocation, ctx.run)

        assert match?({:released, %{id: id}, ^output} when id == release.id, result),
               "#{unquote(label)}: #{inspect(result)}"

        assert [event] = released_events(ctx.fx)
        assert event.payload["arguments"] == original
        assert events_of_type(ctx.fx.tenant, "model.result.withheld") == []
      end
    end

    test "a different valid basis after a valid release is a ReleaseConflict", ctx do
      {:released, release, _output} = released!(ctx)
      basis = basis_event!(ctx.fx, release).payload["arguments"]["basis"]

      # Valid in every field; only the decision instant differs (inside the window).
      different = put_in(basis, ["window", "decided_at"], "2026-11-01T00:00:00.000000Z")
      result = decide_under_gate(ctx, %{basis: different, basis_sha256: canonical_hex(different)})

      assert conflict?(result), "expected ReleaseConflict: #{inspect(result)}"
      assert length(released_events(ctx.fx)) == 1
    end

    test "Recovery returns the existing release and decides none", ctx do
      {:released, release, output} = released!(ctx)
      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert match?({:released, %{id: id}, ^output} when id == release.id, result),
             inspect(result)

      assert length(released_events(ctx.fx)) == 1
    end
  end

  ## The bounded repeat

  describe "the bounded repeat" do
    test "an under-head recheck failure writes nothing; the refusal-only repeat withholds",
         ctx do
      Clock.freeze(@last)
      hook!(fn call -> if call == 1, do: Clock.freeze(@end_) end)

      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :outside_window), inspect(result)
      assert Process.get(:repeat_calls) == 2
      assert released_events(ctx.fx) == []
    end

    test "the repeat never releases, even when conditions recover", ctx do
      Clock.freeze(@last)

      hook!(fn
        1 -> Clock.freeze(@end_)
        _repeat -> Clock.freeze(@last)
      end)

      result = G.finalize(ctx.invocation, ctx.run)

      assert match?({:withheld, %{reason: :prototype_authority_refused}, _}, result),
             inspect(result)

      assert Process.get(:repeat_calls) == 2
      assert released_events(ctx.fx) == []
      # G5 (Codex 3122b0d4 Q2): the carried code is attempt 1's under-head
      # failure (the repeat's own checks all hold again), and only the final
      # decision survives.
      assert refused_code(ctx.fx, result, :outside_window), inspect(result)
      assert length(events_of_type(ctx.fx.tenant, "model.result.withheld")) == 1
      assert release_count(ctx) == 1
    end

    # Q2 control (Codex 3122b0d4): a CURRENT refusal on the repeat wins over
    # the carried code. Attempt 1 fails its under-head recheck at the end;
    # before the repeat's head the binding drifts (process state survives the
    # rollback, unlike rows) while the clock recovers.
    test "a current refusal on the repeat wins over the carried code", ctx do
      Clock.freeze(@last)

      hook!(fn
        1 ->
          Clock.freeze(@end_)

        _repeat ->
          Clock.freeze(@last)
          G.drift!()
      end)

      result = G.finalize(ctx.invocation, ctx.run)

      assert match?({:withheld, %{reason: :prototype_authority_refused}, _}, result),
             inspect(G.summary(result))

      assert Process.get(:repeat_calls) == 2
      assert refused_code(ctx.fx, result, :binding_mismatch), inspect(G.summary(result))
      assert released_events(ctx.fx) == []
      assert length(events_of_type(ctx.fx.tenant, "model.result.withheld")) == 1
      assert release_count(ctx) == 1
    end
  end

  ## RED-b2c: existing-first inside the action (Codex 3122b0d4 R2, G4)

  describe "an own-context request on an existing release (G4)" do
    test "the identical original basis is a replay: the same row and one event", ctx do
      {:released, release, _output} = released!(ctx)
      original = basis_event!(ctx.fx, release).payload["arguments"]

      result =
        decide_under_gate(ctx, %{basis: original["basis"], basis_sha256: original["basis_sha256"]})

      assert match?({:ok, %{id: id}} when id == release.id, result), inspect(G.summary(result))
      assert [event] = released_events(ctx.fx)
      assert event.payload["arguments"] == original
    end

    # Historical: an existing release is compared with its ORIGINAL event,
    # never re-derived from the current grant or window.
    for {label, change} <- [revoked: :revoke, window_end: :window_end] do
      test "after #{label} the identical original basis is still a replay", ctx do
        {:released, release, _output} = released!(ctx)
        original = basis_event!(ctx.fx, release).payload["arguments"]
        own_context_change!(ctx, unquote(change))

        result =
          decide_under_gate(ctx, %{
            basis: original["basis"],
            basis_sha256: original["basis_sha256"]
          })

        assert match?({:ok, %{id: id}} when id == release.id, result),
               "#{unquote(label)}: #{inspect(G.summary(result))}"

        assert [_event] = released_events(ctx.fx)
        assert events_of_type(ctx.fx.tenant, "model.result.withheld") == []
      end
    end

    # The exact contract (R2): a requested basis is identical only when its
    # body AND digest equal the original's; a changed body carrying the
    # original digest is not self-consistent, so it is refused on :basis
    # (never called identical, never a ReleaseConflict), writing nothing.
    test "a changed body carrying the original digest is refused on :basis", ctx do
      {:released, release, _output} = released!(ctx)
      original = basis_event!(ctx.fx, release).payload["arguments"]
      changed = put_in(original["basis"], ["window", "decided_at"], "2026-11-01T00:00:00.000000Z")

      result = decide_under_gate(ctx, %{basis: changed, basis_sha256: original["basis_sha256"]})

      assert refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
             inspect(G.summary(result))

      assert [event] = released_events(ctx.fx)
      assert event.payload["arguments"] == original
    end

    # B1 (Codex be36b5df): the raw own-context branch verifies the ORIGINAL
    # basis against the stored facts (the row, the invocation, its run and
    # the original reservation authority), not only its shape and digest.
    # Labelled tamper: the original event's basis is rewritten behind the
    # application to a grammar-valid value that contradicts the stored
    # charge, binding or identity, with its canonical digest recomputed; the
    # identical rewritten arguments are then requested under a fresh own
    # context. Refused on :basis (an invalid ORIGINAL is never a replay or a
    # ReleaseConflict); no row or event is written; the original release and
    # its one event stay.
    for variant <- [:charge, :binding, :identity] do
      test "a self-consistent rewritten ORIGINAL (#{variant}) requested verbatim is refused on :basis (labelled tamper)",
           ctx do
        {:released, release, _output} = released!(ctx)
        event = basis_event!(ctx.fx, release)
        rewritten = rewritten_original(event.payload["arguments"], unquote(variant))
        rewrite_original!(event, rewritten)

        result =
          decide_under_gate(ctx, %{
            basis: rewritten["basis"],
            basis_sha256: rewritten["basis_sha256"]
          })

        assert refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
               "#{unquote(variant)}: #{inspect(G.summary(result))}"

        assert release_count(ctx) == 1
        assert G.release(ctx.invocation).id == release.id
        assert [kept] = released_events(ctx.fx)
        assert kept.id == event.id
        assert events_of_type(ctx.fx.tenant, "model.result.withheld") == []
      end
    end
  end

  ## RED-b2c: identity and the recorded authority at release (G6, G7, Q4)

  describe "identity and the recorded authority at release" do
    test "G6: an invocation whose profile is not the compiled identity's is identity_mismatch (labelled tamper)",
         ctx do
      tamper_profile!(ctx.invocation)
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :identity_mismatch), inspect(G.summary(result))
      assert released_events(ctx.fx) == []
    end

    # Q4 double defect: identity is checked before the recorded authority.
    test "identity and a recorded key both wrong: identity_mismatch first (labelled tamper)",
         ctx do
      tamper_profile!(ctx.invocation)
      G.forge_authority!(ctx.fx, ctx.invocation, "policy_id", "tampered-policy_id")
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :identity_mismatch), inspect(G.summary(result))
    end

    # The shared comparator at release, one fresh completed call per key.
    # The general key also passes under the b1 refusal (authority_mismatch
    # for every present record): no credit for it until GREEN.
    test "G7: a recorded key rewritten after launch refuses with its code (labelled tamper)",
         ctx do
      outcomes =
        for {key, code} <- [
              {"policy_id", :authority_mismatch},
              {"operator_user_id", :operator_mismatch},
              {"witness_mode", :witness_mode_mismatch}
            ] do
          run = G.run!(ctx.fx)
          invocation = G.completed!(ctx.fx, run)
          G.forge_authority!(ctx.fx, invocation, key, "tampered-#{key}")
          result = G.finalize(invocation, run)
          {key, refused_code(ctx.fx, result, code), G.summary(result)}
        end

      wrong = for {key, false, summary} <- outcomes, do: {key, summary}
      assert wrong == [], "release outcomes: #{inspect(wrong)}"
      assert released_events(ctx.fx) == []
    end
  end

  ## Locks

  describe "the release branch's locks" do
    test "run, Operation, invocation, grant and allocation before the head; none after", ctx do
      {result, sql} = GateFixtures.capture(fn -> G.finalize(ctx.invocation, ctx.run) end)
      assert match?({:released, _, _}, result), inspect(result)

      order = [
        {"agent_runs", "FOR UPDATE"},
        {"operations", "FOR SHARE"},
        {"model_invocations", "FOR SHARE"},
        {"model_call_grants", "FOR SHARE"},
        {"model_call_allocations", "FOR SHARE"},
        {"audit_chain_heads", "FOR UPDATE"}
      ]

      indices =
        for {table, mode} <- order,
            do:
              GateFixtures.index(sql, &GateFixtures.locks?(&1, table, mode)) ||
                flunk("#{table} #{mode}: #{inspect(sql)}")

      assert indices == Enum.sort(indices), inspect(Enum.zip(order, indices))

      after_head = Enum.drop(sql, List.last(indices) + 1)

      assert Enum.reject(
               Enum.filter(after_head, &GateFixtures.lock?/1),
               &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
             ) == [],
             inspect(after_head)
    end
  end

  defp historical_change!(ctx, :revoke) do
    revoked =
      Agents.revoke_grant(ctx.fx.grant, %{expected_revision: ctx.fx.grant.revision},
        actor: ctx.fx.actor
      )

    assert match?({:ok, _}, revoked), "prerequisite: revoke: #{inspect(revoked)}"
  end

  defp historical_change!(ctx, :admin_update) do
    :ok = PrototypeFixtures.leave_runtime()

    changed =
      Agents.update_grant_terms(
        ctx.fx.grant,
        %{purpose: "changed by an admin (synthetic)", expected_revision: ctx.fx.grant.revision},
        actor: ctx.fx.admin
      )

    G.enter!(ctx.fx)
    assert match?({:ok, _}, changed), "prerequisite: admin change: #{inspect(changed)}"
  end

  # While the binding drifts, current use refuses; once it recovers, the
  # original release replays.
  defp historical_change!(ctx, :drift_then_recover) do
    G.drift!()
    drifted = G.finalize(ctx.invocation, ctx.run)
    assert match?({:error, _}, drifted), "current use during drift: #{inspect(drifted)}"
    assert PrototypeFixtures.put_live_identity(%{}) == :ok
  end

  # A before_head hook (test builds only) called with the 1-based attempt.
  defp hook!(fun) do
    Application.put_env(:sdr_agent, Release,
      before_head: fn _invocation ->
        call = Process.get(:repeat_calls, 0) + 1
        Process.put(:repeat_calls, call)
        fun.(call)
      end
    )
  end

  # A released_unverified decision for the invocation under a Prelocked
  # context with the prototype gate's finalizer and caller-built `extra`.
  defp decide_under_gate(ctx, extra) do
    tenant_id = ctx.invocation.tenant_id

    SdrAgent.Audit.transaction(fn ->
      {:ok, _held} =
        SdrAgent.Agents.ModelInvocation
        |> Ash.Query.for_read(:read, %{}, SdrAgent.Audit.Kernel.opts(tenant_id))
        |> Ash.Query.filter(id == ^ctx.invocation.id)
        |> Ash.Query.lock("FOR SHARE")
        |> Ash.read_one()

      {:ok, _head} = SdrAgent.Audit.Kernel.lock_head(tenant_id)

      bindings = %{
        tenant_id: tenant_id,
        model_invocation_id: ctx.invocation.id,
        finalizer: :prototype_gate
      }

      SdrAgent.Agents.ReleaseDecision.Prelocked.run(bindings, &decide_or_rollback(ctx, extra, &1))
    end)
  end

  defp decide_or_rollback(ctx, extra, prelocked) do
    attrs =
      Map.merge(
        %{
          model_invocation_id: ctx.invocation.id,
          disposition: :released_unverified,
          reason: :owner_prototype_unverified
        },
        extra
      )

    case Agents.decide_result_release(attrs, actor: ctx.fx.agent, prelocked: prelocked) do
      {:ok, release} -> release
      {:error, error} -> SdrAgent.Repo.rollback(error)
    end
  end

  defp conflict?({:error, %ReleaseConflict{}}), do: true

  defp conflict?({:error, error}) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%ReleaseConflict{}, &1))
  end

  defp conflict?(_result), do: false

  ## RED-b2c helpers

  # B1 labelled tamper: the original basis with one stored fact contradicted
  # (a grammar-valid value) and its canonical digest recomputed.
  defp rewritten_original(arguments, variant) do
    {path, value} =
      case variant do
        :charge -> {["funding", "allocation_id"], Ecto.UUID.generate()}
        :binding -> {["prototype", "binding_id"], Ecto.UUID.generate()}
        :identity -> {["identity", "model_id"], "claude-synthetic-other"}
      end

    basis = put_in(arguments["basis"], path, value)
    %{"basis" => basis, "basis_sha256" => canonical_hex(basis)}
  end

  defp rewrite_original!(event, arguments) do
    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments}', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(event.id), Jason.encode!(arguments)]
    )
  end

  defp release_count(ctx) do
    SdrAgent.Agents.ModelResultRelease
    |> Ash.Query.filter(model_invocation_id == ^ctx.invocation.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(ctx.invocation.tenant_id))
  end

  defp own_context_change!(ctx, :revoke), do: historical_change!(ctx, :revoke)
  defp own_context_change!(_ctx, :window_end), do: Clock.freeze(@end_)

  # Labelled tamper: the stored invocation's profile rewritten behind the
  # application to a catalog profile outside the compiled identity.
  defp tamper_profile!(invocation) do
    tamper!(
      "UPDATE model_invocations SET profile_id = 'claude_cli_sonnet' WHERE id = $1",
      [Ecto.UUID.dump!(invocation.id)]
    )
  end

  # The decision was refused with an error on `field` with `message`.
  defp refused_on?({:error, error}, field, message) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&(Map.get(&1, :field) == field and Map.get(&1, :message) == message))
  end

  defp refused_on?(_result, _field, _message), do: false
end
