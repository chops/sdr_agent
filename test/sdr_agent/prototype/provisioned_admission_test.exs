defmodule SdrAgent.Prototype.ProvisionedAdmissionTest do
  @moduledoc """
  RED-b2 r2, admission and launch on the provisioned grant (interfaces r6
  IF-4; amendment item 4; S1 C2 r2; Codex ff812f6d rulings a-c), D-237
  slice S2, in prototype runtime with S1's real provisioning
  (`PrototypeGateFixtures.provision!/1`).

  - **(a) Only this binding's grant funds a prototype call:** the unique
    grant the ORIGINAL `model.grant.provisioned` event links, found by
    provenance, then read as its current locked rows. Ordinary or
    admin-created grants never fund one, not even with the identical name
    and terms; with nothing provisioned the call is refused before charge
    (`grant_not_eligible`, an audited refusal).
  - **Identity through the commitments** (Codex 4281bb5c R2): the grant is
    the subject of the one original provisioned event, which commits
    exactly the six S1 arguments (S1 d0b764b): `funding_id`,
    `funding_entry_sha256` (the golden digest), `decision_refs`,
    `budget_worksheet_sha256`, `delegation_id` (the event actor) and
    `binding_id`; a rewritten `funding_entry_sha256` or `decision_refs`
    (labelled tamper) funds no call.
  - **One `:b1` allocation** and **the 14 recorded keys** on the one
    original reservation event, server-derived.
  - **(b) Grant validation order:** status, then the anchor as creator and
    updater, then exact terms and allocation, then the recorded revision.
    An admin's real rename gives `operator_mismatch`.
  - **(c) Raw `:reserve` validates.** A forged admission context whose
    authority equals the server-derived one is still Forbidden, and so is a
    caller-supplied authority (atom and string keys), before any
    invocation, event, counter or charge.
  - **Launch.** An admitted reservation launches. Each recorded key
    rewritten, a missing, malformed, extra-key or missing-key record, a
    duplicated original event, a revoked grant, an admin's change and a
    revision change behind the application each refuse with its code, and
    every launch refusal keeps its charge.

  Setup and first-success calls are asserted as prerequisites: a stop
  there is not the subject's failure. Tamper negatives are isolated and
  labelled; every other state comes from the real actions. Synthetic
  `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G

  @keys ~w(allocation_id binding_id dataset_class entry_sha256 funding_id grant_id
           grant_revision instance_id operator_user_id policy_id profile_id purpose
           tenant_id witness_mode)
  @golden "d8e675ce642857511ed201fab998484d9cfd40e040f891f141a469d3294d825b"
  @decision_refs ["D-238", "D-239", "D-243", "D-269"]
  # The exact arguments of S1's model.grant.provisioned event (S1 d0b764b).
  @provisioned_keys ~w(binding_id budget_worksheet_sha256 decision_refs delegation_id
                       funding_entry_sha256 funding_id)

  ## Helpers

  defp refused(result, stage, check) do
    match?(
      {:error, %Refused{reason: :prototype_not_authorized, check: ^check, stage: ^stage}},
      result
    )
  end

  defp status(invocation), do: Ash.get!(ModelInvocation, invocation.id, authorize?: false).status

  defp charged(grant) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.count!(authorize?: false)
  end

  defp claude_invocations(fx) do
    ModelInvocation
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id and provider == :claude_cli)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  # Every invocation of the tenant (any provider), its reservation events and
  # the run's reserved-call counter.
  defp effects(ctx) do
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.fx.agent)

    {G.invocations(ctx.fx), length(events_of_type(ctx.fx.tenant, "model.invocation.reserved")),
     run.budget.model_calls_reserved}
  end

  defp reserved!(fx, run) do
    result = G.reserve(fx, run)
    assert match?({:ok, %ModelInvocation{}}, result), "prerequisite: reserve: #{inspect(result)}"
    {:ok, invocation} = result
    invocation
  end

  # The reservation whose admission is itself the subject (not a
  # prerequisite): it must be admitted on the provisioned grant.
  defp admitted_on_provisioned!(fx, run) do
    result = G.reserve(fx, run)

    assert match?({:ok, %ModelInvocation{}}, result),
           "admission did not pick the provenance grant: #{inspect(result)}"

    {:ok, invocation} = result
    invocation
  end

  # Changes a grant as the tenant admin in ordinary runtime (the only
  # runtime D3 allows it in), then re-enters prototype runtime.
  defp in_ordinary_runtime(fx, fun) do
    :ok = PrototypeFixtures.leave_runtime()
    result = fun.()
    G.enter!(fx)
    result
  end

  defp admin_update!(fx, grant, attrs) do
    result =
      in_ordinary_runtime(fx, fn ->
        Agents.update_grant_terms(grant, Map.put(attrs, :expected_revision, grant.revision),
          actor: fx.admin
        )
      end)

    assert match?({:ok, _}, result), "prerequisite: admin update: #{inspect(result)}"
    {:ok, updated} = result
    updated
  end

  # Exactly one model.reservation.refused event, linked to the Refused
  # receipt's event and failure, for `run` and `check`.
  defp assert_audited_refusal!(fx, run, %Refused{} = refused, check) do
    events = events_of_type(fx.tenant, "model.reservation.refused")
    assert [event] = events, "refusal events: #{inspect(events)}"
    assert event.id == refused.event_id
    assert event.agent_run_id == run.id

    assert {event.payload["reason"], event.payload["check"], event.payload["failure_id"]} ==
             {"prototype_not_authorized", Atom.to_string(check), refused.failure_id}

    failure = Ash.get!(SdrAgent.Operations.Failure, refused.failure_id, authorize?: false)

    assert {failure.class, failure.subject_resource, failure.subject_id, failure.operation_id} ==
             {:provider_error, "SdrAgent.Agents.AgentRun", run.id, run.operation_id}
  end

  # Labelled tamper of a real action-created row: the whole recorded
  # authority of the invocation's original reservation event.
  defp rewrite_authority!(fx, invocation, :remove) do
    [event] = G.reserved_events(fx, invocation)

    tamper!(
      "UPDATE audit_events SET payload = payload #- '{arguments,prototype_authority}' WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )
  end

  defp rewrite_authority!(fx, invocation, value) do
    [event] = G.reserved_events(fx, invocation)

    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments,prototype_authority}', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(event.id), Jason.encode!(value)]
    )
  end

  # A second original reservation event for `invocation`, appended through
  # the audit kernel with the same payload.
  defp duplicate_reserved!(fx, invocation) do
    [event] = G.reserved_events(fx, invocation)

    SdrAgent.Audit.Kernel.append(
      %{
        event_type: "model.invocation.reserved",
        category: :model,
        subject_resource: "SdrAgent.Agents.ModelInvocation",
        subject_id: invocation.id,
        action: "reserve",
        model_invocation_id: invocation.id,
        agent_run_id: invocation.agent_run_id,
        payload: event.payload
      },
      actor: fx.agent,
      tenant_id: invocation.tenant_id
    )
  end

  # The one original model.grant.provisioned event of the tenant.
  defp provisioned_event!(fx) do
    events = events_of_type(fx.tenant, "model.grant.provisioned")
    assert [event] = events, "prerequisite: one provisioned event: #{inspect(length(events))}"
    event
  end

  # Labelled tamper of the original provisioned event: one argument rewritten.
  defp rewrite_commitment!(event, key, value) do
    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, ARRAY['arguments', $2], $3::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(event.id), key, Jason.encode!(value)]
    )
  end

  ## (a) this binding's provenance grant

  describe "this binding's provenance grant" do
    setup do
      fx = G.prototype!()
      %{fx: fx, run: G.run!(fx)}
    end

    test "an in-scope call is admitted on it and records exactly the 14 keys", ctx do
      invocation = admitted_on_provisioned!(ctx.fx, ctx.run)

      assert invocation.grant_id == ctx.fx.grant.id
      assert [allocation] = ctx.fx.grant.allocations
      assert invocation.allocation_id == allocation.id

      assert [event] = G.reserved_events(ctx.fx, invocation)
      recorded = event.payload["arguments"]["prototype_authority"]
      assert recorded |> Map.keys() |> Enum.sort() == @keys
      assert recorded == G.expected_authority(ctx.fx, invocation)
    end

    test "its grant is the subject of the one original provisioned event, which commits the funding digest and decision_refs",
         ctx do
      event = provisioned_event!(ctx.fx)
      assert event.subject_id == ctx.fx.grant.id
      args = event.payload["arguments"]
      assert args |> Map.keys() |> Enum.sort() == @provisioned_keys, inspect(Map.keys(args))

      assert {args["funding_id"], args["funding_entry_sha256"], args["decision_refs"]} ==
               {"d237-funding/1", @golden, @decision_refs}

      assert {args["binding_id"], args["delegation_id"]} == {ctx.fx.snapshot.id, event.actor_id}
      assert args["budget_worksheet_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

      invocation = reserved!(ctx.fx, ctx.run)
      assert invocation.grant_id == event.subject_id
    end

    for {key, value} <- [
          {"funding_entry_sha256", String.duplicate("0", 64)},
          {"decision_refs", ["D-238"]}
        ] do
      test "a rewritten #{key} commitment funds no call: grant_not_eligible, audited (labelled tamper)",
           ctx do
        rewrite_commitment!(provisioned_event!(ctx.fx), unquote(key), unquote(value))

        result = G.reserve(ctx.fx, ctx.run)
        assert refused(result, :reservation, :grant_not_eligible), "rewritten: #{inspect(result)}"
        {:error, refused} = result
        assert_audited_refusal!(ctx.fx, ctx.run, refused, :grant_not_eligible)
        assert charged(ctx.fx.grant) == 0
      end
    end

    test "it carries exactly the funding entry's one :b1 allocation", ctx do
      assert [allocation] = ctx.fx.grant.allocations

      assert {allocation.key, allocation.applies_to, allocation.profile_id, allocation.attempts} ==
               {:b1, [:b1], :claude_cli_opus, 100}
    end

    test "after an admin's real rename it admits no call: operator_mismatch, audited", ctx do
      renamed = admin_update!(ctx.fx, ctx.fx.grant, %{name: "renamed.test"})
      result = G.reserve(ctx.fx, ctx.run)

      assert refused(result, :reservation, :operator_mismatch), "renamed: #{inspect(result)}"
      {:error, refused} = result
      assert_audited_refusal!(ctx.fx, ctx.run, refused, :operator_mismatch)
      assert charged(renamed) == 0
    end
  end

  describe "ordinary grants never fund a prototype call" do
    test "with the provisioned grant present, only it is charged" do
      fx = G.bound!()
      ordinary = AgentsFixtures.grant!(fx.tenant, %{}, fx.admin)
      G.enter!(fx)
      fx = Map.put(fx, :grant, G.provision!(fx))

      # The subject: admission picks only the provenance grant (never an
      # ambiguity or a fallback), so this reserve is the behaviour itself.
      invocation = admitted_on_provisioned!(fx, G.run!(fx))
      assert invocation.grant_id == fx.grant.id
      assert charged(ordinary) == 0
    end

    test "an admin grant with the identical name and terms is never charged" do
      fx = Map.put(G.bound!(), :grant, nil)
      G.enter!(fx)
      fx = %{fx | grant: G.provision!(fx)}
      funding = fx.grant

      lookalike =
        in_ordinary_runtime(fx, fn ->
          Agents.create_grant(
            %{
              name: funding.name,
              purpose: funding.purpose,
              profile_ids: funding.profile_ids,
              total_attempts: funding.total_attempts,
              per_utc_day_attempts: funding.per_utc_day_attempts,
              starts_at: funding.starts_at,
              expires_at: funding.expires_at,
              allocations: [
                %{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 100}
              ]
            },
            actor: fx.admin
          )
        end)

      assert match?({:ok, _}, lookalike), "prerequisite: lookalike grant: #{inspect(lookalike)}"
      {:ok, lookalike} = lookalike

      invocation = admitted_on_provisioned!(fx, G.run!(fx))
      assert invocation.grant_id == fx.grant.id
      assert charged(lookalike) == 0
    end

    test "with nothing provisioned, an in-scope call is refused grant_not_eligible, audited" do
      fx = G.bound!()
      ordinary = AgentsFixtures.grant!(fx.tenant, %{}, fx.admin)
      G.enter!(fx)
      run = G.run!(fx)
      {:ok, before} = Agents.get_run(run.id, actor: fx.agent)

      result = G.reserve(fx, run)

      assert refused(result, :reservation, :grant_not_eligible), "ordinary: #{inspect(result)}"
      {:error, refused} = result
      assert_audited_refusal!(fx, run, refused, :grant_not_eligible)
      assert G.invocations(fx) == 0
      assert events_of_type(fx.tenant, "model.invocation.reserved") == []
      {:ok, reread} = Agents.get_run(run.id, actor: fx.agent)
      assert reread.budget.model_calls_reserved == before.budget.model_calls_reserved
      assert charged(ordinary) == 0
    end
  end

  ## (c) raw :reserve validates

  describe "raw :reserve validates the authority" do
    setup do
      fx = G.prototype!()
      %{fx: fx, run: G.run!(fx)}
    end

    test "a forged admission context with the server-derived authority is Forbidden", ctx do
      [allocation] = ctx.fx.grant.allocations
      n = System.unique_integer([:positive])

      seed =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("forge-seed-#{n}"),
          actor: ctx.fx.agent
        )

      assert match?({:ok, _}, seed), "prerequisite: Fake seed: #{inspect(seed)}"
      {:ok, seed} = seed

      # Effects are snapshotted AFTER the Fake prerequisite: the forged call
      # must add no invocation, reservation event or counter.
      before = effects(ctx)

      attrs =
        "forge-#{n}"
        |> AgentsFixtures.claude_attrs()
        |> Map.drop([:request])
        |> Map.merge(%{
          agent_run_id: ctx.run.id,
          sequence_in_run: 100 + n,
          request_sha256: seed.request_sha256
        })

      matching =
        G.expected_authority(ctx.fx, %{
          profile_id: :claude_cli_opus,
          purpose: :qualification,
          grant_id: ctx.fx.grant.id,
          allocation_id: allocation.id
        })

      context =
        AdmissionContext.context(%{
          grant_id: ctx.fx.grant.id,
          allocation_id: allocation.id,
          reserved_at: SdrAgent.Clock.utc_now(),
          prototype_authority: matching
        })

      result =
        ModelInvocation
        |> Ash.Changeset.for_create(:reserve, attrs, actor: ctx.fx.agent, context: context)
        |> Ash.create()

      assert match?({:error, %Ash.Error.Forbidden{}}, result), "forged: #{inspect(result)}"
      assert effects(ctx) == before
      assert claude_invocations(ctx.fx) == 0
      assert charged(ctx.fx.grant) == 0
    end

    test "a caller-supplied authority (atom and string keys) is Forbidden before any effect",
         ctx do
      {:ok, before} = Agents.get_run(ctx.run.id, actor: ctx.fx.agent)
      authority = Map.new(@keys, &{&1, "synthetic-#{&1}"})

      outcomes =
        for {label, attrs} <- [
              atom: Map.put(G.call_attrs(), :prototype_authority, authority),
              string:
                G.call_attrs()
                |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
                |> Map.put("prototype_authority", authority)
            ] do
          {label, Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.fx.agent)}
        end

      assert Enum.all?(outcomes, &match?({_label, {:error, %Ash.Error.Forbidden{}}}, &1)),
             inspect(outcomes)

      assert claude_invocations(ctx.fx) == 0
      assert events_of_type(ctx.fx.tenant, "model.invocation.reserved") == []
      {:ok, reread} = Agents.get_run(ctx.run.id, actor: ctx.fx.agent)
      assert reread.budget.model_calls_reserved == before.budget.model_calls_reserved
      assert charged(ctx.fx.grant) == 0
    end
  end

  ## Launch

  describe "launch of an admitted reservation" do
    setup do
      fx = G.prototype!()
      run = G.run!(fx)
      %{fx: fx, run: run, invocation: reserved!(fx, run)}
    end

    test "it launches", ctx do
      result = G.launch(ctx.fx, ctx.invocation)
      assert match?({:ok, %ModelInvocation{status: :sent}}, result), "launch: #{inspect(result)}"
    end

    test "each recorded key rewritten refuses with its code; every charge is kept", ctx do
      # Labelled tamper: one fresh admitted reservation per key. Every case
      # runs before any assertion; a reservation stop is a prerequisite.
      outcomes =
        for key <- @keys do
          invocation = reserved!(ctx.fx, G.run!(ctx.fx))
          G.forge_authority!(ctx.fx, invocation, key, "tampered-#{key}")
          {key, G.launch(ctx.fx, invocation), status(invocation)}
        end

      expected = fn
        "witness_mode" -> :witness_mode_mismatch
        "operator_user_id" -> :operator_mismatch
        _other -> :authority_mismatch
      end

      wrong =
        Enum.reject(outcomes, fn {key, result, status} ->
          refused(result, :launch, expected.(key)) and status == :failed
        end)

      assert wrong == [], "launch outcomes: #{inspect(wrong)}"
      # 1 (setup) + 14: no refund.
      assert charged(ctx.fx.grant) == 15
    end

    test "a missing, malformed, extra-key or missing-key record refuses; charges kept", ctx do
      full = G.expected_authority(ctx.fx, ctx.invocation)

      # unknown_key and wrong_type: GREEN-time controls (Codex review of
      # d16e460: unknown keys fail through real validation; the revision
      # must not be coerced, which would give grant_changed instead).
      cases = [
        missing: {:remove, :authority_unrecorded},
        malformed: {"not-a-map", :authority_unrecorded},
        extra_key: {Map.put(full, "extra", "x"), :authority_mismatch},
        missing_key: {Map.delete(full, "purpose"), :authority_mismatch},
        unknown_key:
          {full |> Map.delete("purpose") |> Map.put("purpose_v2", full["purpose"]),
           :authority_mismatch},
        wrong_type:
          {Map.put(full, "grant_revision", to_string(full["grant_revision"])),
           :authority_mismatch}
      ]

      outcomes =
        for {label, {value, check}} <- cases do
          invocation = reserved!(ctx.fx, G.run!(ctx.fx))
          rewrite_authority!(ctx.fx, invocation, value)
          result = G.launch(ctx.fx, invocation)
          {label, refused(result, :launch, check) and status(invocation) == :failed, result}
        end

      assert Enum.all?(outcomes, &elem(&1, 1)), inspect(outcomes)
      assert charged(ctx.fx.grant) == 1 + length(cases)
    end

    test "a duplicated original reservation event refuses authority_unrecorded, charged", ctx do
      appended = duplicate_reserved!(ctx.fx, ctx.invocation)
      assert match?({:ok, _}, appended), "prerequisite: duplicate event: #{inspect(appended)}"

      result = G.launch(ctx.fx, ctx.invocation)
      assert refused(result, :launch, :authority_unrecorded), "duplicate: #{inspect(result)}"
      assert status(ctx.invocation) == :failed
      assert charged(ctx.fx.grant) == 1
    end

    test "a revoked grant refuses grant_not_eligible, charged", ctx do
      revoked =
        Agents.revoke_grant(ctx.fx.grant, %{expected_revision: ctx.fx.grant.revision},
          actor: ctx.fx.actor
        )

      assert match?({:ok, _}, revoked), "prerequisite: revoke: #{inspect(revoked)}"
      result = G.launch(ctx.fx, ctx.invocation)

      assert refused(result, :launch, :grant_not_eligible), "revoked: #{inspect(result)}"
      assert status(ctx.invocation) == :failed
      assert charged(ctx.fx.grant) == 1
    end

    test "a grant an admin changed (ordinary runtime) refuses operator_mismatch, charged", ctx do
      admin_update!(ctx.fx, ctx.fx.grant, %{purpose: "changed by an admin (synthetic)"})
      result = G.launch(ctx.fx, ctx.invocation)

      assert refused(result, :launch, :operator_mismatch), "admin change: #{inspect(result)}"
      assert status(ctx.invocation) == :failed
      assert charged(ctx.fx.grant) == 1
    end

    test "a revision change behind the application refuses grant_changed (labelled tamper)",
         ctx do
      G.tamper_grant!(ctx.fx, "revision = revision + 1")
      result = G.launch(ctx.fx, ctx.invocation)

      assert refused(result, :launch, :grant_changed), "revision: #{inspect(result)}"
      assert status(ctx.invocation) == :failed
      assert charged(ctx.fx.grant) == 1
    end
  end
end
