defmodule SdrAgent.Prototype.ProvisionC2Test do
  @moduledoc """
  The C2 closure cases of D-237 provisioning (Codex a6850b13, D1-D3), over
  the real `bind/1` and owned scratch roots:

  - an identical replay with the evidence files removed returns the same
    grant and writes no grant, event or allocation (IF-2: replay needs no
    new worksheet);
  - a different worksheet, and an identical replay of a revoked grant,
    refuse `:grant_exists` and write nothing;
  - a direct `ModelCallGrant :provision_prototype` action with no worksheet,
    a worksheet that fails the check, or caller-supplied server metadata is
    refused and writes nothing (the action carries its own validation);
  - an ordinary grant named `d237-funding/1` is a conflict: provisioning
    refuses `:grant_exists`, and the operator cannot revoke it;
  - this binding's grant is found by its ORIGINAL provisioned-event
    provenance, not its mutable name (Codex 2c5af8ae must-fix 2): after an
    ordinary rename or terms change no second grant is minted (`:grant_exists`),
    and an identical replay by a later session of the same binding (another
    valid delegation) returns the original grant.

  Each direct-action test ends with the valid direct action (a positive
  control: exactly one grant, one provisioned event and the one exact `:b1`
  allocation), so its negatives count only when the subject is reachable;
  supplied metadata is refused even when it equals the server-derived
  value; a second valid direct action refuses `:grant_exists` (the raw
  action never renews, apart from the wrapper's replay). An untrusted
  provisioned event (another actor and creator) and two provisioned events
  (ambiguous) refuse `:grant_exists`; those events are appended through the
  public kernel API, so no audit row is mutated (Codex 3e05314f).
  Evidence file names use a safe token of `as_of` (IF-2 path grammar
  `^[A-Za-z0-9._/-]{1,200}$`, checked at construction); the worksheet keeps
  the original RFC 3339 `as_of`.

  The concurrent first-provision proof needs two real connections and is an
  `:external` harness case (closure note), not a sandbox test. Synthetic
  `.test` data only; the only files removed are this test's own.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.GrantContext
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Prototype

  @routes ~w(prototype_binding owner_dev owner_calibration hosted other_owner)
  @path_grammar ~r/\A[A-Za-z0-9._\/-]{1,200}\z/
  # The funding entry's golden sdr-canonical-json/1 digest and its compiled
  # decision refs (amendment r6 item 4; Codex 4281bb5c R2).
  @golden_funding_sha256 "d56308736c6c5ef7a4521b9b442ec85298ab06f82d8ea447de35637e45d6349a"
  @decision_refs ["D-238", "D-239", "D-243"]

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # A deterministic file-name token of `as_of`: every character outside the
  # IF-2 path grammar becomes "-". The worksheet keeps the original value.
  defp token(as_of), do: Regex.replace(~r/[^A-Za-z0-9.-]/, as_of, "-")

  defp evidence!(root, name) do
    assert Regex.match?(@path_grammar, name),
           "fixture: evidence path #{inspect(name)} is outside the IF-2 grammar"

    body = "counts-only receipt #{name}\n"
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o600)
    %{"path" => name, "sha256" => sha(body)}
  end

  defp worksheet_bytes(root, as_of \\ "2026-10-29T12:00:00Z") do
    routes =
      for route <- @routes do
        %{
          "route" => route,
          "basis" =>
            if(route == "prototype_binding", do: "agent_receipt", else: "owner_attestation"),
          "consumed" => 0,
          "evidence" => evidence!(root, "#{route}-#{token(as_of)}.receipt")
        }
      end

    Jason.encode!(%{
      "schema" => "d237-budget-worksheet/1",
      "shared_total" => 60,
      "window_starts_at" => "2026-10-28T02:38:32.000000Z",
      "as_of" => as_of,
      "routes" => routes,
      "previous_bindings" => %{
        "consumed" => 0,
        "evidence" => evidence!(root, "previous-#{token(as_of)}.receipt")
      }
    })
  end

  defp provision(actor, bytes, root) do
    Agents.provision_prototype_grant(%{worksheet: bytes, worksheet_sha256: sha(bytes)},
      actor: actor,
      evidence_root: root
    )
  end

  defp counts do
    q = fn sql ->
      %{rows: [[n]]} = Repo.query!(sql, [])
      n
    end

    %{
      grants: q.("SELECT count(*) FROM model_call_grants"),
      allocations: q.("SELECT count(*) FROM model_call_allocations"),
      provisioned:
        q.("SELECT count(*) FROM audit_events WHERE event_type = 'model.grant.provisioned'")
    }
  end

  # {key, applies_to, profile_id, attempts, available_from, available_until,
  # released_at} of every allocation of the grant.
  defp allocations_of(grant_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT key, applies_to, profile_id, attempts, available_from, available_until, released_at " <>
          "FROM model_call_allocations WHERE grant_id = $1 ORDER BY id",
        [Ecto.UUID.dump!(grant_id)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  # The `reason` an Invalid refusal of the raw action carries, if any.
  defp refusal_reason({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.find_value(errors, &Map.get(&1, :reason))

  defp refusal_reason(_other), do: nil

  defp first!(fx, root, bytes) do
    result = provision(fx.actor, bytes, root)

    assert match?({:ok, %ModelCallGrant{}}, result),
           "prerequisite: first provision: #{inspect(result)}"

    {:ok, grant} = result
    grant
  end

  setup do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)
    %{fx: fx, admin: admin, root: PrototypeFixtures.scratch_dir!()}
  end

  describe "replay and second grants (D1)" do
    test "an identical replay with the evidence files removed returns the same grant, writing nothing",
         ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      before = counts()

      for name <- File.ls!(ctx.root), do: File.rm!(Path.join(ctx.root, name))

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert match?({:ok, %{id: id}} when id == grant.id, result), "replay: #{inspect(result)}"
      assert counts() == before
    end

    test "a different worksheet refuses :grant_exists, writing nothing", ctx do
      _grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      before = counts()

      result =
        provision(ctx.fx.actor, worksheet_bytes(ctx.root, "2026-10-30T12:00:00Z"), ctx.root)

      assert result == {:error, :grant_exists}, "a different worksheet: #{inspect(result)}"
      assert counts() == before
    end

    test "an identical replay of a revoked grant refuses :grant_exists", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)

      revoked =
        Agents.revoke_grant(grant, %{expected_revision: grant.revision}, actor: ctx.fx.actor)

      assert match?({:ok, %{status: :revoked}}, revoked),
             "prerequisite: revoke: #{inspect(revoked)}"

      before = counts()

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert result == {:error, :grant_exists}, "a revoked replay: #{inspect(result)}"
      assert counts() == before
    end
  end

  describe "the action carries its own validation (raw-action boundary)" do
    defp direct(actor, args) do
      ModelCallGrant
      |> Ash.Changeset.for_create(:provision_prototype, args, actor: actor)
      |> Ash.create()
    end

    test "a direct action with no, an invalid or an unverifiable worksheet writes nothing", ctx do
      valid = worksheet_bytes(ctx.root)
      before = counts()

      cases = [
        no_worksheet: %{evidence_root: ctx.root},
        invalid_worksheet: %{worksheet: ~s({"schema":"other"}), evidence_root: ctx.root},
        no_evidence_root: %{worksheet: valid}
      ]

      for {name, args} <- cases do
        result = direct(ctx.fx.actor, args)
        assert match?({:error, _}, result), "#{name}: #{inspect(result)}"
      end

      assert counts() == before
      positive_control!(ctx, valid, before)
    end

    test "caller-supplied server metadata is refused, writing nothing", ctx do
      valid = worksheet_bytes(ctx.root)
      before = counts()

      # Implausible values, then plausible matching ones: any supplied value
      # is refused before minting, even one equal to the server-derived value.
      for {name, forged} <- [
            delegation_id: Ecto.UUID.generate(),
            funding_id: "d237-funding/2",
            binding_id: Ecto.UUID.generate(),
            budget_worksheet_sha256: String.duplicate("0", 64),
            delegation_id: ctx.fx.actor.id,
            funding_id: "d237-funding/1",
            binding_id: ctx.fx.snapshot.id,
            budget_worksheet_sha256: sha(valid),
            allocations: [
              %{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 50}
            ],
            funding_entry_sha256: @golden_funding_sha256,
            decision_refs: @decision_refs
          ] do
        args = Map.put(%{worksheet: valid, evidence_root: ctx.root}, name, forged)
        result = direct(ctx.fx.actor, args)

        assert match?({:error, %Ash.Error.Invalid{}}, result),
               "forged #{name}: expected Invalid, got #{inspect(result)}"
      end

      assert counts() == before
      positive_control!(ctx, valid, before)
    end

    # The valid direct action, differing from each negative above only in
    # the refused input: it must provision exactly one grant, one event and
    # one allocation set, so the negatives were refused for their own reason.
    defp positive_control!(ctx, valid, before) do
      result = direct(ctx.fx.actor, %{worksheet: valid, evidence_root: ctx.root})

      assert match?({:ok, %ModelCallGrant{}}, result),
             "positive control: the valid direct action: #{inspect(result)}"

      {:ok, grant} = result
      after_counts = counts()
      assert after_counts.grants == before.grants + 1
      assert after_counts.provisioned == before.provisioned + 1
      assert after_counts.allocations == before.allocations + 1
      assert allocations_of(grant.id) == [{"b1", ["b1"], "claude_cli_opus", 50, nil, nil, nil}]
    end

    test "a second valid direct action refuses :grant_exists (never renews), writing nothing",
         ctx do
      valid = worksheet_bytes(ctx.root)
      first = direct(ctx.fx.actor, %{worksheet: valid, evidence_root: ctx.root})

      assert match?({:ok, %ModelCallGrant{}}, first),
             "prerequisite: first direct: #{inspect(first)}"

      before = counts()

      second = direct(ctx.fx.actor, %{worksheet: valid, evidence_root: ctx.root})
      reason = refusal_reason(second)

      assert match?({:error, %Ash.Error.Invalid{}}, second) and reason == :grant_exists,
             "second direct action: #{inspect(second)}"

      assert counts() == before
    end
  end

  describe "ambiguous or untrusted provenance (must-fix 2 discrimination)" do
    # A provisioned-looking event appended through the public kernel API (a
    # kernel actor, chain intact): no audit row is mutated.
    defp provisioned_event!(ctx, grant_id, digest) do
      kernel = struct(SdrAgent.Actor, type: :kernel, tenant_id: ctx.fx.tenant.id)

      {:ok, _event} =
        SdrAgent.Audit.append(
          %{
            event_type: "model.grant.provisioned",
            category: :model,
            subject_resource: inspect(ModelCallGrant),
            subject_id: grant_id,
            action: "provision_prototype",
            payload: %{
              arguments: %{
                funding_id: "d237-funding/1",
                binding_id: ctx.fx.snapshot.id,
                delegation_id: ctx.fx.actor.id,
                budget_worksheet_sha256: digest
              }
            }
          },
          actor: kernel
        )
    end

    test "an untrusted provisioned event (another actor and creator) refuses :grant_exists",
         ctx do
      PrototypeFixtures.leave_runtime()

      {:ok, ordinary} =
        Agents.create_grant(
          %{
            name: "an-ordinary-grant",
            purpose: "ordinary grant named apart from the funding id",
            profile_ids: [:claude_cli_opus],
            total_attempts: 1,
            starts_at: ~U[2026-10-28 03:00:00.000000Z],
            expires_at: ~U[2026-10-29 03:00:00.000000Z]
          },
          actor: ctx.admin
        )

      bytes = worksheet_bytes(ctx.root)
      provisioned_event!(ctx, ordinary.id, sha(bytes))
      enter!(ctx.fx)
      before = counts()

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert result == {:error, :grant_exists}, "untrusted provenance: #{inspect(result)}"
      assert counts() == before
    end

    test "two provisioned events for this binding are ambiguous: a replay refuses :grant_exists",
         ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      provisioned_event!(ctx, grant.id, sha(bytes))
      before = counts()

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert result == {:error, :grant_exists}, "ambiguous provenance: #{inspect(result)}"
      assert counts() == before
    end
  end

  describe "this binding's grant by original provenance, not its name (must-fix 2)" do
    defp change_terms!(ctx, grant, changes) do
      PrototypeFixtures.leave_runtime()

      result =
        Agents.update_grant_terms(grant, Map.put(changes, :expected_revision, grant.revision),
          actor: ctx.admin
        )

      assert match?({:ok, %ModelCallGrant{}}, result),
             "prerequisite: ordinary terms change: #{inspect(result)}"

      enter!(ctx.fx)
    end

    test "after an ordinary rename, provisioning mints no second grant", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      change_terms!(ctx, grant, %{name: "renamed-after-provisioning"})
      before = counts()

      identical = provision(ctx.fx.actor, bytes, ctx.root)
      assert identical == {:error, :grant_exists}, "renamed, identical: #{inspect(identical)}"

      different =
        provision(ctx.fx.actor, worksheet_bytes(ctx.root, "2026-10-30T12:00:00Z"), ctx.root)

      assert different == {:error, :grant_exists}, "renamed, different: #{inspect(different)}"
      assert counts() == before
    end

    test "after an ordinary terms change, an identical replay refuses :grant_exists", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)
      change_terms!(ctx, grant, %{purpose: "changed after provisioning"})
      before = counts()

      result = provision(ctx.fx.actor, bytes, ctx.root)
      assert result == {:error, :grant_exists}, "changed terms, identical: #{inspect(result)}"
      assert counts() == before
    end

    test "a later session of the same binding replays the original grant", ctx do
      bytes = worksheet_bytes(ctx.root)
      grant = first!(ctx.fx, ctx.root, bytes)

      entered = Prototype.enter_session(:codex_cli, "codex-session:c2-replay-0002")
      assert match?({:ok, _id}, entered), "prerequisite: a later session: #{inspect(entered)}"
      {:ok, later_id} = entered
      refute later_id == ctx.fx.actor.id, "prerequisite: the later session is a new delegation"

      resolved = Prototype.operator_actor(later_id)
      assert match?({:ok, _actor}, resolved), "prerequisite: later operator: #{inspect(resolved)}"
      {:ok, later} = resolved

      for name <- File.ls!(ctx.root), do: File.rm!(Path.join(ctx.root, name))
      before = counts()

      result = provision(later, bytes, ctx.root)

      assert match?({:ok, %{id: id}} when id == grant.id, result),
             "later-session replay: #{inspect(result)}"

      assert counts() == before
    end
  end

  describe "the provisioned event's commitments (Codex 4281bb5c R2)" do
    test "the event commits exactly the funding id, its digest, the decision refs, the worksheet digest, the delegation and the binding",
         ctx do
      bytes = worksheet_bytes(ctx.root)
      _grant = first!(ctx.fx, ctx.root, bytes)
      assert Prototype.Authority.funding_entry_sha256() == @golden_funding_sha256

      [event] = events_of_type(ctx.fx.tenant, "model.grant.provisioned")

      assert event.payload["arguments"] == %{
               "funding_id" => "d237-funding/1",
               "funding_entry_sha256" => @golden_funding_sha256,
               "decision_refs" => @decision_refs,
               "budget_worksheet_sha256" => sha(bytes),
               "delegation_id" => ctx.fx.actor.id,
               "binding_id" => ctx.fx.snapshot.id
             },
             "provisioned arguments: #{inspect(event.payload["arguments"])}"
    end

    # The shared lookup's trust decision for one event (structural until
    # GREEN exposes it): `{:one, grant_id, event}` or `:untrusted`. The
    # tampered events are in-memory copies; no audit row is mutated.
    defp classify(snapshot, event) do
      Function.capture(SdrAgent.Prototype.Provisioning, :classify, 2).(snapshot, event)
    rescue
      error -> {:raised, error.__struct__}
    end

    test "the lookup trusts the original event only with its exact commitments", ctx do
      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      [event] = events_of_type(ctx.fx.tenant, "model.grant.provisioned")
      trusted = classify(ctx.fx.snapshot, event)

      assert match?({:one, id, _event} when id == grant.id, trusted),
             "the genuine event: #{inspect(trusted)}"

      arguments = event.payload["arguments"]

      tampered = [
        no_funding_digest: Map.delete(arguments, "funding_entry_sha256"),
        wrong_funding_digest:
          Map.put(arguments, "funding_entry_sha256", String.duplicate("0", 64)),
        uppercase_funding_digest:
          Map.put(arguments, "funding_entry_sha256", String.upcase(@golden_funding_sha256)),
        no_decision_refs: Map.delete(arguments, "decision_refs"),
        reordered_refs: Map.put(arguments, "decision_refs", Enum.reverse(@decision_refs)),
        extra_ref: Map.put(arguments, "decision_refs", @decision_refs ++ ["D-999"]),
        refs_as_string: Map.put(arguments, "decision_refs", Enum.join(@decision_refs, ",")),
        extra_argument: Map.put(arguments, "unexpected", "x"),
        no_worksheet_digest: Map.delete(arguments, "budget_worksheet_sha256"),
        worksheet_digest_number: Map.put(arguments, "budget_worksheet_sha256", 42)
      ]

      for {name, changed} <- tampered do
        copy = %{event | payload: Map.put(event.payload, "arguments", changed)}
        result = classify(ctx.fx.snapshot, copy)
        assert result == :untrusted, "#{name}: #{inspect(result)}"
      end
    end

    # Codex 4ebbce03: classify/2 must stand alone; lookup/1 filters the type
    # and tenant today, but the public decision must check them itself,
    # before any DB access. In-memory copies only.
    test "classify/2 refuses a genuine-event copy with another event type or another tenant",
         ctx do
      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      [event] = events_of_type(ctx.fx.tenant, "model.grant.provisioned")
      genuine = classify(ctx.fx.snapshot, event)

      assert match?({:one, id, _event} when id == grant.id, genuine),
             "genuine: #{inspect(genuine)}"

      copies = [
        other_event_type: %{event | event_type: "model.grant.created"},
        other_tenant: %{event | tenant_id: Ecto.UUID.generate()}
      ]

      for {name, copy} <- copies do
        result = classify(ctx.fx.snapshot, copy)
        assert result == :untrusted, "#{name}: #{inspect(result)}"
      end
    end
  end

  describe "malformed provisioned-event arguments (Codex 4281bb5c R3)" do
    # One operator-actor provisioned event per test (two would already be
    # ambiguous), appended through the public kernel API: no audit row is
    # mutated. Provisioning must refuse :grant_exists, never raise.
    for {name, arguments} <- [
          string: "not-a-map",
          list: ["funding_id", "d237-funding/1"],
          integer: 42,
          null: nil,
          empty_map: %{}
        ] do
      @malformed arguments

      test "arguments as #{name}: provisioning refuses :grant_exists, never a raise", ctx do
        {:ok, _event} =
          SdrAgent.Audit.append(
            %{
              event_type: "model.grant.provisioned",
              category: :model,
              subject_resource: inspect(ModelCallGrant),
              subject_id: Ecto.UUID.generate(),
              action: "provision_prototype",
              payload: %{arguments: @malformed}
            },
            actor: ctx.fx.actor
          )

        before = counts()

        result =
          try do
            provision(ctx.fx.actor, worksheet_bytes(ctx.root), ctx.root)
          rescue
            error -> {:raised, error.__struct__}
          end

        assert result == {:error, :grant_exists}, "malformed arguments: #{inspect(result)}"
        assert counts() == before
      end
    end
  end

  describe "the operator's raw allocation create (Codex 4281bb5c R1)" do
    defp all_events do
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM audit_events", [])
      n
    end

    test "is Forbidden with or without the public grant marker, writing nothing", ctx do
      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))

      assert allocations_of(grant.id) == [{"b1", ["b1"], "claude_cli_opus", 50, nil, nil, nil}],
             "prerequisite: the genuine provision created exactly the one :b1 allocation"

      before = counts()
      events_before = all_events()

      planned = %{
        grant_id: grant.id,
        grant_revision: grant.revision,
        profile_id: :claude_cli_opus
      }

      attempts = [
        extra_b2: Map.merge(planned, %{key: :b2, applies_to: [:b1], attempts: 51}),
        exact_terms_b2: Map.merge(planned, %{key: :b2, applies_to: [:b1], attempts: 50}),
        exact_copy_b1: Map.merge(planned, %{key: :b1, applies_to: [:b1], attempts: 50})
      ]

      for {name, attrs} <- attempts,
          {marker_name, context} <- [no_marker: %{}, public_marker: GrantContext.context()] do
        result =
          ModelCallAllocation
          |> Ash.Changeset.for_create(:create, attrs, actor: ctx.fx.actor, context: context)
          |> Ash.create()

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "#{name} with #{marker_name}: expected Forbidden, got #{inspect(result)}"
      end

      assert counts() == before, "a raw allocation create wrote"
      assert all_events() == events_before, "a raw allocation create appended an event"
      assert allocations_of(grant.id) == [{"b1", ["b1"], "claude_cli_opus", 50, nil, nil, nil}]
    end
  end

  # Codex e006f70a D1-D3 against design note r2 (1e6992c1): the operator's
  # one allocation write is authorized only by a registered,
  # transaction-bound ProvisionScope. Structural until GREEN: the scope
  # module, its test seam and the ProvisionPrototype hooks are absent at
  # this pin, so these tests stop at their first "hook ran" prerequisite or
  # at a captured UndefinedFunctionError. Hooks are process-local,
  # test-build-only keys.
  describe "the ProvisionScope boundary (Codex e006f70a D1-D3)" do
    @change SdrAgent.Agents.Changes.ProvisionPrototype
    @scope_module SdrAgent.Prototype.ProvisionScope
    @scope_key :sdr_prototype_provision_scope
    @b1 {"b1", ["b1"], "claude_cli_opus", 50, nil, nil, nil}

    defp scope_context(scope), do: Map.put(GrantContext.context(), @scope_key, scope)

    defp planned(grant_id, overrides \\ %{}) do
      Map.merge(
        %{
          grant_id: grant_id,
          grant_revision: 1,
          key: :b1,
          applies_to: [:b1],
          profile_id: :claude_cli_opus,
          attempts: 50
        },
        overrides
      )
    end

    defp allocation_changeset(actor, attrs, scope) do
      Ash.Changeset.for_create(ModelCallAllocation, :create, attrs,
        actor: actor,
        context: scope_context(scope)
      )
    end

    defp raw(actor, attrs, scope), do: actor |> allocation_changeset(attrs, scope) |> Ash.create()
    defp forbidden?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)
    defp hook(name, fun), do: Process.put({@change, name}, fun)
    defp see(name, value), do: Process.put({__MODULE__, name}, value)
    defp seen(name), do: Process.get({__MODULE__, name})

    defp scope_call(function, args) do
      Function.capture(@scope_module, function, length(args)) |> apply(args)
    rescue
      error -> {:raised, error.__struct__}
    end

    defp registered do
      Function.capture(Module.concat(@scope_module, TestSeam), :registered, 0).()
    rescue
      error -> {:raised, error.__struct__}
    end

    test "D1: repeated policy checks leave the plan available; the one insert consumes it", ctx do
      actor = ctx.fx.actor

      hook(:scope_bound, fn scope ->
        id = scope.grant_id
        changeset = allocation_changeset(actor, planned(id), scope)
        see(:checks, for(_ <- 1..3, do: Ash.can?(changeset, actor)))

        see(:mismatched,
          key: raw(actor, planned(id, %{key: :b2}), scope),
          attempts: raw(actor, planned(id, %{attempts: 49}), scope),
          grant_revision: raw(actor, planned(id, %{grant_revision: 2}), scope),
          grant_id: raw(actor, planned(Ecto.UUID.generate()), scope)
        )
      end)

      hook(:after_allocations, fn scope ->
        see(:second, raw(actor, planned(scope.grant_id), scope))
      end)

      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      assert seen(:checks) == [true, true, true], "policy checks: #{inspect(seen(:checks))}"
      assert is_list(seen(:mismatched)), "prerequisite: the :scope_bound hook ran"

      for {name, result} <- seen(:mismatched) do
        assert forbidden?(result), "mismatched #{name}: #{inspect(result)}"
      end

      assert forbidden?(seen(:second)), "the second write: #{inspect(seen(:second))}"
      assert allocations_of(grant.id) == [@b1]
    end

    test "D2: a captured scope is refused from another process and after its transaction", ctx do
      actor = ctx.fx.actor

      hook(:scope_bound, fn scope ->
        see(:scope, scope)
        task = Task.async(fn -> raw(actor, planned(scope.grant_id), scope) end)
        see(:cross_process, Task.await(task))
      end)

      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      scope = seen(:scope)
      assert scope != nil, "prerequisite: the :scope_bound hook ran"
      assert forbidden?(seen(:cross_process)), "cross-process: #{inspect(seen(:cross_process))}"

      before = counts()
      stale = raw(actor, planned(scope.grant_id), scope)
      assert forbidden?(stale), "stale: #{inspect(stale)}"
      assert counts() == before
      assert allocations_of(grant.id) == [@b1]
    end

    test "D2: a scope established after a rolled-back real SAVEPOINT is invalid", ctx do
      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      actor = ctx.fx.actor
      ref = make_ref()

      bindings = %{
        tenant_id: ctx.fx.tenant.id,
        binding_id: ctx.fx.snapshot.id,
        delegation_id: actor.id,
        anchor_id: ctx.fx.anchor.id,
        planned: SdrAgent.Prototype.Provisioning.allocations()
      }

      result =
        SdrAgent.Audit.transaction(fn ->
          Repo.query!("SAVEPOINT d237_scope_test")
          established = scope_call(:establish, [ref, bindings])
          bound = scope_call(:bind_grant, [ref, grant])
          Repo.query!("ROLLBACK TO SAVEPOINT d237_scope_test")

          valid =
            scope_call(:valid?, [
              bound,
              allocation_changeset(actor, planned(grant.id), bound),
              actor
            ])

          _released = scope_call(:release, [ref])
          {established, bound, valid}
        end)

      assert match?(
               {:ok, {%{__struct__: @scope_module}, %{__struct__: @scope_module}, false}},
               result
             ),
             "savepoint: #{inspect(result)}"
    end

    test "D2: no scope stays registered after a successful provision", ctx do
      _grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      assert registered() == 0, "after success: #{inspect(registered())}"
    end

    test "D2: no scope stays registered after a rolled-back provision", ctx do
      hook(:scope_bound, fn _scope ->
        see(:ran, true)
        Repo.rollback(:injected)
      end)

      before = counts()
      result = provision(ctx.fx.actor, worksheet_bytes(ctx.root), ctx.root)
      assert seen(:ran) == true, "prerequisite: the :scope_bound hook ran (#{inspect(result)})"
      assert match?({:error, _}, result)
      assert counts() == before
      assert registered() == 0, "after rollback: #{inspect(registered())}"
    end

    test "D2: no scope stays registered after a raised provision", ctx do
      hook(:scope_bound, fn _scope ->
        see(:ran, true)
        raise ArgumentError, "injected"
      end)

      before = counts()

      raised =
        try do
          provision(ctx.fx.actor, worksheet_bytes(ctx.root), ctx.root)
        rescue
          error -> {:raised, error}
        end

      assert seen(:ran) == true, "prerequisite: the :scope_bound hook ran (#{inspect(raised)})"
      # Ash raises the hook's exception wrapped as Ash.Error.Unknown (observed
      # at 936506e); the injected message must be the cause.
      assert match?({:raised, _error}, raised), "the injected raise: #{inspect(raised)}"
      {:raised, error} = raised
      assert Exception.message(error) =~ "injected", "raise cause: #{inspect(error)}"
      assert counts() == before
      assert registered() == 0, "after raise: #{inspect(registered())}"
    end

    # Codex 93af0eec qualification: during the LIVE hook (scope registered,
    # bound, unconsumed), a copy of the bound scope with any one field
    # altered, or a hand-built struct under a fresh ref, writing the exact
    # planned allocation is Forbidden; the genuine write still succeeds.
    test "D3: an altered-field or hand-built scope with the exact plan is refused during the live hook",
         ctx do
      actor = ctx.fx.actor

      hook(:scope_bound, fn scope ->
        exact = planned(scope.grant_id)
        [planned_row] = scope.planned

        altered = [
          marker: %{scope | marker: scope.marker <> "x"},
          xact_id: %{scope | xact_id: "0"},
          delegation_id: %{scope | delegation_id: Ecto.UUID.generate()},
          anchor_id: %{scope | anchor_id: Ecto.UUID.generate()},
          tenant_id: %{scope | tenant_id: Ecto.UUID.generate()},
          binding_id: %{scope | binding_id: Ecto.UUID.generate()},
          planned: %{scope | planned: [%{planned_row | attempts: 49}]},
          grant_revision: %{scope | grant_revision: 2},
          consumed: %{scope | consumed?: true},
          hand_built_fresh_ref:
            Map.put(Map.from_struct(scope), :ref, make_ref())
            |> Map.put(:__struct__, @scope_module)
        ]

        see(:altered, for({name, copy} <- altered, do: {name, raw(actor, exact, copy)}))
      end)

      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      assert is_list(seen(:altered)), "prerequisite: the :scope_bound hook ran"

      for {name, result} <- seen(:altered) do
        assert forbidden?(result), "#{name}: #{inspect(result)}"
      end

      assert allocations_of(grant.id) == [@b1]
    end

    test "D3: a forged ref, a hand-built scope and another delegation of the binding are refused",
         ctx do
      actor = ctx.fx.actor
      entered = Prototype.enter_session(:codex_cli, "codex-session:scope-other-1")
      assert match?({:ok, _id}, entered), "prerequisite: another session: #{inspect(entered)}"
      {:ok, other_id} = entered
      {:ok, other} = Prototype.operator_actor(other_id)

      hook(:scope_bound, fn scope ->
        see(:other_delegation, raw(other, planned(scope.grant_id), scope))
        see(:forged_ref, raw(actor, planned(scope.grant_id), %{scope | ref: make_ref()}))
      end)

      grant = first!(ctx.fx, ctx.root, worksheet_bytes(ctx.root))
      assert seen(:other_delegation) != nil, "prerequisite: the :scope_bound hook ran"

      assert forbidden?(seen(:other_delegation)),
             "other delegation: #{inspect(seen(:other_delegation))}"

      assert forbidden?(seen(:forged_ref)), "forged ref: #{inspect(seen(:forged_ref))}"

      hand_built = %{
        __struct__: @scope_module,
        ref: make_ref(),
        tenant_id: ctx.fx.tenant.id,
        binding_id: ctx.fx.snapshot.id,
        delegation_id: actor.id,
        anchor_id: ctx.fx.anchor.id,
        planned: SdrAgent.Prototype.Provisioning.allocations(),
        grant_id: grant.id,
        grant_revision: 1,
        xact_id: "1",
        marker: "sdr_forged",
        consumed?: false
      }

      assert forbidden?(raw(actor, planned(grant.id, %{key: :b2}), hand_built))
      assert allocations_of(grant.id) == [@b1]
    end
  end

  describe "an ordinary grant with the prototype's name (D1 conflict, D3 revoke)" do
    setup ctx do
      PrototypeFixtures.leave_runtime()

      {:ok, ordinary} =
        Agents.create_grant(
          %{
            name: "d237-funding/1",
            purpose: "ordinary grant with a conflicting name",
            profile_ids: [:claude_cli_opus],
            total_attempts: 1,
            starts_at: ~U[2026-10-28 03:00:00.000000Z],
            expires_at: ~U[2026-10-29 03:00:00.000000Z]
          },
          actor: ctx.admin
        )

      enter!(ctx.fx)
      %{ordinary: ordinary}
    end

    test "provisioning refuses :grant_exists and writes nothing", ctx do
      before = counts()
      result = provision(ctx.fx.actor, worksheet_bytes(ctx.root), ctx.root)
      assert result == {:error, :grant_exists}, "conflict: #{inspect(result)}"
      assert counts() == before
    end

    test "the operator cannot revoke it", ctx do
      result =
        Agents.revoke_grant(ctx.ordinary, %{expected_revision: ctx.ordinary.revision},
          actor: ctx.fx.actor
        )

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "operator revoke of an ordinary grant: #{inspect(result)}"
    end
  end
end
