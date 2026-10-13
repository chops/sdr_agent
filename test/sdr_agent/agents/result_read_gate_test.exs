defmodule SdrAgent.Agents.ResultReadGateTest do
  @moduledoc """
  R0-07 slice A read gate (REQ-07-5; entity PASS at 1da747a, ModelInvocation
  delta). For a generation-2 ClaudeCLI invocation, `parsed_output` is
  readable only through `SdrAgent.Agents.released_output/2` (which requires
  a `:released` release) and by the witness evidence seam (REC and AUD).
  Generic Ash reads, the domain list and detail APIs, kernel-context reads,
  admins and AGT see it as forbidden — released or not. Generation-1 and
  Fake rows are unchanged. LLM Decisions refuse an unreleased output with
  `:result_not_released`.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Errors.ResultNotReleased
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Kernel

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: rec,
      invocation: AgentsFixtures.claude_completed!(run, agent, "gate-1")
    }
  end

  @output AgentsFixtures.completion().parsed_output

  defp release!(ctx, invocation) do
    link = AgentsFixtures.reconciled_link!(invocation, ctx.rec)

    {:ok, release} =
      Agents.decide_result_release(
        %{
          model_invocation_id: invocation.id,
          disposition: :released,
          reason: :reconciled,
          wire_witness_link_id: link.id
        },
        actor: ctx.agent
      )

    release
  end

  defp withhold!(ctx, invocation, reason) do
    attrs = %{model_invocation_id: invocation.id, disposition: :withheld, reason: reason}
    {:ok, release} = Agents.decide_result_release(attrs, actor: ctx.agent)
    release
  end

  # Every business read path of one invocation, as `actor`.
  defp business_reads(ctx, invocation, actor) do
    {:ok, got} = Ash.get(ModelInvocation, invocation.id, actor: actor)
    {:ok, listed} = Agents.list_model_invocations(ctx.run.id, actor: actor)
    listed = Enum.find(listed, &(&1.id == invocation.id))

    [{"Ash.get", got}, {"list_model_invocations", listed}]
  end

  defp business_actors(ctx) do
    [
      ctx.agent,
      human(:admin, ctx.tenant),
      human(:reviewer, ctx.tenant),
      human(:auditor, ctx.tenant),
      system_actor(:delivery_worker, ctx.tenant)
    ]
  end

  defp kernel_read(invocation) do
    {:ok, row} = Ash.get(ModelInvocation, invocation.id, Kernel.opts(invocation.tenant_id))
    row
  end

  defp assert_withheld(row, label) do
    assert %Ash.ForbiddenField{} = row.parsed_output, label
    # Metadata stays readable.
    assert row.status == :completed, label
    assert row.validation_status == :valid, label
  end

  describe "an unreleased generation-2 ClaudeCLI output" do
    test "is forbidden through generic, list and detail reads and kernel context", ctx do
      for actor <- business_actors(ctx),
          {label, row} <- business_reads(ctx, ctx.invocation, actor) do
        assert_withheld(row, "#{label} as #{inspect(actor)}")
      end

      assert_withheld(kernel_read(ctx.invocation), "kernel context")

      # The output does not leak through an input filter on the field either.
      {:ok, matches} =
        ModelInvocation
        |> Ash.Query.for_read(:read, %{}, actor: ctx.agent)
        |> Ash.Query.filter(id == ^ctx.invocation.id)
        |> Ash.Query.filter_input(%{parsed_output: %{is_nil: false}})
        |> Ash.read()

      assert matches == []
    end

    test "is readable by the witness evidence seam (REC and AUD)", ctx do
      for actor <- [ctx.rec, system_actor(:auditor_cli, ctx.tenant)] do
        {:ok, row} = Ash.get(ModelInvocation, ctx.invocation.id, actor: actor)
        assert row.parsed_output == @output, inspect(actor)
      end

      assert {:ok, %{request: request}} =
               Agents.read_reconciliation_payloads(ctx.invocation, actor: ctx.rec)

      assert is_binary(request)
    end

    test "the calibration context reads only its own proof invocation (as AGT)", ctx do
      %{run: proof, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
      calibration = AgentsFixtures.proof_completed!(proof, agent, "gate-cal")

      context =
        SdrAgent.Agents.Checks.CalibrationContext.context(:claude_cli_opus, calibration.id)

      read = fn invocation, actor ->
        {:ok, row} = Ash.get(ModelInvocation, invocation.id, actor: actor, context: context)
        row
      end

      assert read.(calibration, ctx.agent).parsed_output == @output

      # Another gated row under the same marker stays masked.
      assert_withheld(read.(ctx.invocation, ctx.agent), "other invocation")

      # A context naming a business-run invocation reads nothing.
      business =
        SdrAgent.Agents.Checks.CalibrationContext.context(:claude_cli_opus, ctx.invocation.id)

      {:ok, row} =
        Ash.get(ModelInvocation, ctx.invocation.id, actor: ctx.agent, context: business)

      assert_withheld(row, "business invocation")

      # The marker does nothing for any other actor.
      for actor <- [human(:admin, ctx.tenant), system_actor(:delivery_worker, ctx.tenant)],
          do: assert_withheld(read.(calibration, actor), inspect(actor))
    end

    test "released_output/2 refuses it with :result_not_released", ctx do
      for actor <- [ctx.agent, human(:admin, ctx.tenant), system_actor(:kernel, ctx.tenant)] do
        assert {:error, :result_not_released} =
                 Agents.released_output(ctx.invocation, actor: actor),
               inspect(actor)
      end
    end

    test "a withheld output stays refused everywhere", ctx do
      withhold!(ctx, ctx.invocation, :witness_mismatch)

      assert {:error, :result_not_released} =
               Agents.released_output(ctx.invocation.id, actor: ctx.agent)

      for {label, row} <- business_reads(ctx, ctx.invocation, ctx.agent),
          do: assert_withheld(row, label)
    end
  end

  describe "a released output" do
    test "is returned by released_output/2 only; generic reads still see it withheld", ctx do
      release!(ctx, ctx.invocation)

      for actor <- [ctx.agent, human(:admin, ctx.tenant), system_actor(:kernel, ctx.tenant)] do
        assert {:ok, @output} = Agents.released_output(ctx.invocation, actor: actor),
               inspect(actor)
      end

      for {label, row} <- business_reads(ctx, ctx.invocation, ctx.agent),
          do: assert_withheld(row, label)

      assert_withheld(kernel_read(ctx.invocation), "kernel context")
    end

    test "released_output/2 is scoped to the actor's tenant and needs an actor", ctx do
      release!(ctx, ctx.invocation)

      stranger = %{system_actor(:agent_runtime, ctx.tenant) | tenant_id: Ecto.UUID.generate()}

      for actor <- [stranger, nil] do
        assert {:error, _} = Agents.released_output(ctx.invocation, actor: actor), inspect(actor)
      end
    end
  end

  describe "input queries over the output-bearing fields (G2)" do
    setup ctx do
      a = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-g2-a", g2_completion("aaa"))
      z = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-g2-z", g2_completion("zzz"))
      %{g2: [a.id, z.id]}
    end

    defp g2_completion(tag),
      do: Map.put(AgentsFixtures.completion(), :refusal, "refusal #{tag}")

    defp g2_query(ctx, actor) do
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(id in ^ctx.g2)
    end

    test "input filters derive nothing from an unreleased field", ctx do
      for input <- [
            %{refusal: %{eq: "refusal aaa"}},
            %{refusal: %{is_nil: false}},
            %{parsed_output: %{is_nil: false}},
            %{validation_errors: %{is_nil: false}}
          ] do
        assert {:ok, []} =
                 ctx |> g2_query(ctx.agent) |> Ash.Query.filter_input(input) |> Ash.read(),
               inspect(input)
      end

      # The witness seam still filters on the stored value.
      assert {:ok, [_]} =
               ctx
               |> g2_query(ctx.rec)
               |> Ash.Query.filter_input(%{refusal: %{eq: "refusal aaa"}})
               |> Ash.read()
    end

    test "input sorts derive no order from an unreleased field", ctx do
      ids = fn sort ->
        {:ok, rows} =
          ctx
          |> g2_query(ctx.agent)
          |> Ash.Query.sort_input(sort)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read()

        Enum.map(rows, & &1.id)
      end

      assert ids.("refusal") == ids.("-refusal")
    end

    # Ash applies field policies to filters and sorts, but by design never to
    # the field of an ad-hoc aggregate (`Ash.aggregate/3` in trusted code,
    # the G2 limit). So no aggregate or calculation a caller can load may
    # reach the output-bearing fields, and no application code may run a
    # field aggregate.
    # Documents the trusted-code limit (Codex code review, important 1): a
    # default ad-hoc aggregate returns the unreleased value; only
    # `authorize_fields?: true` applies the field policy. Any aggregate
    # surface exposed later must use it and add protected-field regressions.
    test "an ad-hoc aggregate leaks by default; authorize_fields?: true withholds", ctx do
      query = g2_query(ctx, ctx.agent)
      max = {:out, :max, field: :refusal}

      assert {:ok, %{out: "refusal zzz"}} = Ash.aggregate(query, max, actor: ctx.agent)

      assert {:ok, %{out: nil}} =
               Ash.aggregate(query, max,
                 actor: ctx.agent,
                 authorize?: true,
                 authorize_fields?: true
               )

      # The ordinary read of the same rows stays masked.
      {:ok, rows} = Ash.read(query)
      assert Enum.all?(rows, &match?(%Ash.ForbiddenField{}, &1.refusal))
    end

    test "no declared aggregate or calculation reaches an output-bearing field" do
      fields = ModelInvocation.output_fields()

      resources =
        :sdr_agent
        |> Application.get_env(:ash_domains, [])
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)

      for resource <- resources, aggregate <- Ash.Resource.Info.aggregates(resource) do
        destination = Ash.Resource.Info.related(resource, aggregate.relationship_path)

        refute destination == ModelInvocation and aggregate.field in fields,
               "#{inspect(resource)}.#{aggregate.name}"
      end

      assert Ash.Resource.Info.aggregates(ModelInvocation) == []
      assert Ash.Resource.Info.calculations(ModelInvocation) == []
    end

    test "no application code runs a field aggregate" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(
          &(File.read!(&1) =~
              ~r/Ash\.(aggregate|max|min|sum|avg|list|first)\(|Query\.aggregate\(/)
        )

      assert offenders == []
    end
  end

  describe "rows outside the gate" do
    test "Fake and generation-1 outputs are unchanged", ctx do
      {:ok, fake} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("gate-fake"),
          actor: ctx.agent
        )

      {:ok, fake} = Agents.mark_model_invocation_sent(fake, actor: ctx.agent)

      {:ok, fake} =
        Agents.complete_model_invocation(fake, AgentsFixtures.completion(), actor: ctx.agent)

      legacy = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-legacy")

      tamper!(
        "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
          "allocation_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(legacy.id)]
      )

      for invocation <- [fake, legacy] do
        for actor <- business_actors(ctx),
            {label, row} <- business_reads(ctx, invocation, actor) do
          assert row.parsed_output == @output, "#{label} as #{inspect(actor)}"
        end

        assert kernel_read(invocation).parsed_output == @output
        assert {:ok, @output} = Agents.released_output(invocation, actor: ctx.agent)
      end
    end
  end

  describe "LLM decisions (DecisionRules)" do
    defp llm_decision(ctx, invocation, key) do
      Agents.record_decision(
        %{
          agent_run_id: ctx.run.id,
          kind: :qualification,
          mode: :llm,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: ctx.run.lead_id,
          model_invocation_id: invocation.id,
          output_pointer: "/qualified",
          outcome: "qualified",
          idempotency_key: "gate-decision-#{key}",
          inputs: %{"lead" => ctx.run.lead_id}
        },
        actor: ctx.agent
      )
    end

    test "refuse an unreleased or withheld output with :result_not_released", ctx do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = llm_decision(ctx, ctx.invocation, "u")
      assert Enum.any?(errors, &match?(%ResultNotReleased{}, &1)), inspect(errors)

      withheld = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-withheld")
      withhold!(ctx, withheld, :witness_timeout)
      assert {:error, %Ash.Error.Invalid{errors: errors}} = llm_decision(ctx, withheld, "w")
      assert Enum.any?(errors, &match?(%ResultNotReleased{}, &1)), inspect(errors)

      assert {:ok, []} = Agents.list_decisions(ctx.run.id, actor: ctx.agent)
    end

    test "accept a released output, and resolve the pointer in it", ctx do
      release!(ctx, ctx.invocation)
      assert {:ok, decision} = llm_decision(ctx, ctx.invocation, "r")
      assert decision.model_invocation_id == ctx.invocation.id

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(
                 %{
                   agent_run_id: ctx.run.id,
                   kind: :qualification,
                   mode: :llm,
                   subject_resource: "SdrAgent.Sales.Lead",
                   subject_id: ctx.run.lead_id,
                   model_invocation_id: ctx.invocation.id,
                   output_pointer: "/missing",
                   outcome: "qualified",
                   idempotency_key: "gate-decision-missing",
                   inputs: %{}
                 },
                 actor: ctx.agent
               )
    end
  end

  test "the chain verifier still checks generation-2 invocation rows", ctx do
    release!(ctx, ctx.invocation)
    assert {:ok, report} = SdrAgent.Audit.verify_chain(actor: human(:admin, ctx.tenant))
    assert report.valid?, inspect(report.issues)
  end
end
