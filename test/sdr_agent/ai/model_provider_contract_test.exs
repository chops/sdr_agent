defmodule SdrAgent.AI.ModelProviderContractTest do
  @moduledoc """
  R0-04 (#50) contract tests for the `ModelProvider` facade
  (`docs/product/r0/r0-04-seam.md`, contract PASS at 72bd298): the closed
  reply envelope, state precedence, storable output, the typed
  pre-reservation refusal, and the plugged-in test adapter.

  Tests tagged `:r0_04_red` were the RED gate (Codex VERIFIED at 059674c):
  they failed before the R0-04 implementation for the intended reason (a
  crash or an untyped return) and are now regression coverage. The others
  are characterization: they passed on the code before R0-04 and document
  it.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ContractProvider
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations.Failure

  @object Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})
  @output %{answer: "qualified", score: 7}
  @usage %{input_tokens: 3, output_tokens: 4, plan_calls: 1}

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, run: run, agent: agent}
  end

  defp request(ctx, id, schema \\ @object) do
    audit =
      id
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    %{
      id: id,
      run: ctx.run,
      actor: ctx.agent,
      operation: "model.complete",
      prompt: "Qualify the fixture lead",
      schema: schema,
      audit: audit
    }
  end

  defp call(ctx, id, options, schema \\ @object) do
    ModelProvider.complete(request(ctx, id, schema),
      provider: ContractProvider,
      provider_options: Keyword.put(options, :notify, self())
    )
  end

  # RED only: runs just the facade call and turns a crash into a value, so
  # the test fails on its assertion about the required return, not on an
  # uncaught exception. Fixtures and postconditions stay outside it.
  defp observe(fun) do
    fun.()
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    kind, reason -> {kind, reason}
  end

  defp assert_calls(prepare, complete) do
    for {callback, count} <- [prepare: prepare, complete: complete] do
      for _ <- List.duplicate(nil, count), do: assert_received({:contract_provider, ^callback})
      refute_received {:contract_provider, ^callback}
    end
  end

  defp invocations(ctx) do
    {:ok, invocations} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    invocations
  end

  defp budget(ctx) do
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    Map.take(run.budget, [:model_calls_reserved, :model_calls_used, :tokens_used])
  end

  defp failures_for(invocation) do
    Failure
    |> Ash.Query.filter(subject_id == ^invocation.id)
    |> Ash.read!(authorize?: false)
  end

  defp ok(fields), do: {:ok, Map.merge(%{output: @output, raw_response: "raw"}, fields)}

  describe "R0-04-1: a malformed reply after send is unknown, never a crash" do
    for {label, reply} <- [
          {"bare :ok", Macro.escape(:ok)},
          {"nil", nil},
          {"a 3-tuple", Macro.escape({:ok, %{}, :extra})},
          {"{:ok, non_map}", Macro.escape({:ok, "x"})},
          {"no :output", Macro.escape({:ok, %{raw_response: "raw"}})},
          {"no :raw_response", Macro.escape({:ok, %{output: %{answer: "a", score: 1}}})},
          {"a non-binary :raw_response",
           Macro.escape({:ok, %{output: %{answer: "a", score: 1}, raw_response: 123}})},
          {"a negative usage field",
           Macro.escape(
             {:ok,
              %{
                output: %{answer: "a", score: 1},
                raw_response: "raw",
                usage: %{input_tokens: -1, output_tokens: 0, plan_calls: 0}
              }}
           )},
          {"a nil usage field",
           Macro.escape(
             {:ok,
              %{
                output: %{answer: "a", score: 1},
                raw_response: "raw",
                usage: %{input_tokens: nil, output_tokens: 0, plan_calls: 0}
              }}
           )},
          {"an incomplete usage",
           Macro.escape(
             {:ok,
              %{output: %{answer: "a", score: 1}, raw_response: "raw", usage: %{input_tokens: 1}}}
           )},
          {"an explicit nil usage",
           Macro.escape(
             {:ok, %{output: %{answer: "a", score: 1}, raw_response: "raw", usage: nil}}
           )},
          {"a usage with an extra key",
           Macro.escape(
             {:ok,
              %{
                output: %{answer: "a", score: 1},
                raw_response: "raw",
                usage: %{input_tokens: 1, output_tokens: 1, plan_calls: 1, cost_usd: 5}
              }}
           )},
          {"a usage struct",
           Macro.escape(
             {:ok,
              %{
                output: %{answer: "a", score: 1},
                raw_response: "raw",
                usage: %SdrAgent.Agents.ModelInvocation.Usage{
                  input_tokens: 1,
                  output_tokens: 1,
                  plan_calls: 1
                }
              }}
           )}
        ] do
      @tag :r0_04_red
      test "#{label}", ctx do
        before = budget(ctx)

        result = observe(fn -> call(ctx, "malformed", reply: unquote(reply)) end)
        assert {:error, :provider_outcome_unknown} = result
        assert_calls(1, 1)

        assert [invocation] = invocations(ctx)
        assert invocation.status == :unknown
        assert invocation.sent_at
        assert [_] = events_of_type(ctx.tenant, "model.invocation.unknown")
        assert events_of_type(ctx.tenant, "model.invocation.completed") == []
        assert events_of_type(ctx.tenant, "model.invocation.failed") == []
        assert failures_for(invocation) == []
        after_budget = budget(ctx)
        assert after_budget.model_calls_used == before.model_calls_used + 1
        assert after_budget.model_calls_reserved == before.model_calls_reserved + 1
      end
    end
  end

  describe "R0-04-2: output must be storable as a map" do
    for {label, schema, output, type} <- [
          {"a Zoi-valid string", Macro.escape(Zoi.string()), "accepted scalar", "string"},
          {"a Zoi-valid list", Macro.escape(Zoi.array(Zoi.string())), ["a", "b"], "list"}
        ] do
      @tag :r0_04_red
      test "#{label} is validation_failed, never completed", ctx do
        result =
          observe(fn ->
            call(ctx, "non-map", [reply: ok(%{output: unquote(output)})], unquote(schema))
          end)

        assert {:error, {:validation_failed, _errors}} = result
        assert_calls(1, 1)

        assert [invocation] = invocations(ctx)
        assert invocation.status == :failed
        assert invocation.validation_status == :invalid
        assert invocation.parsed_output == nil
        assert invocation.error == %{"kind" => "validation_failed"}
        assert invocation.response_sha256 == :crypto.hash(:sha256, "raw")

        assert invocation.validation_errors == [
                 %{"message" => "output is not an object", "type" => unquote(type)}
               ]

        assert events_of_type(ctx.tenant, "model.invocation.completed") == []
      end
    end

    @tag :r0_04_red
    test "a Zoi-invalid non-map output is validation_failed with the type entry", ctx do
      result =
        observe(fn -> call(ctx, "invalid-non-map", reply: ok(%{output: "a private value"})) end)

      assert {:error, {:validation_failed, errors}} = result
      assert errors != []
      assert [invocation] = invocations(ctx)
      assert invocation.status == :failed
      assert invocation.parsed_output == nil
      assert invocation.response_sha256 == :crypto.hash(:sha256, "raw")
      type_entries = Enum.filter(invocation.validation_errors, &Map.has_key?(&1, "type"))
      assert type_entries == [%{"message" => "output is not an object", "type" => "string"}]
      refute inspect(type_entries) =~ "a private value"
    end

    test "a Zoi-invalid map output keeps it as parsed_output (characterization)", ctx do
      bad = %{answer: "qualified", score: "seven"}

      assert {:error, {:validation_failed, _}} =
               call(ctx, "invalid-map", reply: ok(%{output: bad}))

      assert [invocation] = invocations(ctx)
      assert invocation.status == :failed
      assert invocation.parsed_output == %{"answer" => "qualified", "score" => "seven"}
    end
  end

  describe "R0-04-3: a malformed prepare is refused before reservation" do
    for {label, prepare} <- [
          {"bare :ok", Macro.escape(:ok)},
          {"nil", nil},
          {"{:ok, non_map}", Macro.escape({:ok, "provenance"})},
          {"a 3-tuple", Macro.escape({:ok, %{}, :extra})}
        ] do
      @tag :r0_04_red
      test "#{label}", ctx do
        before = budget(ctx)

        result =
          observe(fn -> call(ctx, "bad-prepare", prepare: unquote(prepare), reply: ok(%{})) end)

        assert {:error, :malformed_provider_prepare} = result
        assert_calls(1, 0)
        assert invocations(ctx) == []
        assert events_of_type(ctx.tenant, "model.invocation.reserved") == []
        assert budget(ctx) == before
      end
    end

    test "a valid {:error, reason} from prepare is returned as is (characterization)", ctx do
      assert {:error, :not_today} = call(ctx, "prep-error", prepare: {:error, :not_today})
      assert invocations(ctx) == []
    end
  end

  describe "R0-04-4: the plugged-in adapter's valid outcomes (characterization)" do
    test "success completes with the normalized usage", ctx do
      assert {:ok, result} = call(ctx, "ok", reply: ok(%{usage: @usage}))
      assert result.output == @output
      assert result.invocation.status == :completed
      assert result.invocation.provider == :fake
      assert result.invocation.profile_id == :fake
      assert result.invocation.usage.input_tokens == 3
    end

    # The facade's existing default for an omitted usage: no tokens, one call.
    test "success without usage keeps the full default", ctx do
      assert {:ok, result} = call(ctx, "ok-no-usage", reply: ok(%{}))

      assert Map.take(result.invocation.usage, [:input_tokens, :output_tokens, :plan_calls]) ==
               %{input_tokens: 0, output_tokens: 0, plan_calls: 1}
    end

    test "a complete numeric-string usage follows the embedded type's cast", ctx do
      before = budget(ctx)
      usage = %{input_tokens: "3", output_tokens: "4", plan_calls: "1"}

      assert {:ok, result} = call(ctx, "ok-string-usage", reply: ok(%{usage: usage}))

      assert Map.take(result.invocation.usage, [:input_tokens, :output_tokens, :plan_calls]) ==
               %{input_tokens: 3, output_tokens: 4, plan_calls: 1}

      assert budget(ctx).tokens_used == before.tokens_used + 7
    end

    test "a known failure is failed as provider_error, with no Failure", ctx do
      assert {:error, :quota_reached} = call(ctx, "known", reply: {:error, :quota_reached})
      assert [invocation] = invocations(ctx)
      assert invocation.status == :failed
      assert invocation.error["kind"] == "provider_error"
      assert failures_for(invocation) == []
    end

    test "a drift failure opens its critical attention Failure", ctx do
      assert {:error, :model_attestation_drift} =
               call(ctx, "drift", reply: {:error, :model_attestation_drift})

      assert [invocation] = invocations(ctx)
      assert [%{class: :provider_error, severity: :critical}] = failures_for(invocation)
    end

    for {label, reply} <- [
          {"an unknown reply", Macro.escape({:unknown, :transport})},
          {"a raise", quote(do: fn -> raise "synthetic provider failure" end)},
          {"an exit", quote(do: fn -> exit(:synthetic) end)}
        ] do
      test "#{label} is unknown", ctx do
        assert {:error, :provider_outcome_unknown} =
                 call(ctx, "unknown", reply: unquote(reply))

        assert [%{status: :unknown}] = invocations(ctx)
      end
    end

    test "an unknown provider value is refused at reservation", ctx do
      {:ok, provenance} = SdrAgent.AI.ModelProvider.Fake.prepare(%{}, [])

      assert {:error, %Ash.Error.Invalid{}} =
               call(ctx, "bogus-provider",
                 prepare: {:ok, %{provenance | provider: :not_a_provider}},
                 reply: ok(%{})
               )

      assert invocations(ctx) == []
    end

    # The run is cancelled between send and settlement, so settlement's
    # budget step refuses: that Agents error must come back as itself.
    test "a settlement error is returned as itself, not relabeled", ctx do
      stop = fn ->
        {:ok, _} = Agents.cancel_run(ctx.run, actor: ctx.agent)
        {:ok, %{output: @output, raw_response: "raw"}}
      end

      assert {:error, %Ash.Error.Invalid{}} = call(ctx, "settle-error", reply: stop)
      assert [%{status: :sent}] = invocations(ctx)
    end
  end

  describe "state precedence for ClaudeCLI-class replies" do
    setup ctx do
      SdrAgent.AdmissionFixtures.admit_tuples!()
      admin = human(:admin, ctx.tenant)
      AgentsFixtures.grant!(ctx.tenant, %{}, admin)
      :ok
    end

    defp cli(ctx, id, reply) do
      ModelProvider.complete(request(ctx, id),
        provider: __MODULE__.NeverLaunched,
        provider_options: [reply: reply]
      )
    end

    @tag :r0_04_red
    test "a reserved row with a malformed reply is failed, never sent", ctx do
      result = observe(fn -> cli(ctx, "reserved-malformed", :ok) end)
      assert {:error, :launch_not_admitted} = result
      assert [invocation] = invocations(ctx)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      assert invocation.error["reason"] == "launch_not_admitted"
      assert events_of_type(ctx.tenant, "model.invocation.unknown") == []
    end

    for {label, reply, reason} <- [
          {"{:ok, _}",
           Macro.escape({:ok, %{output: %{answer: "a", score: 1}, raw_response: "r"}}),
           :launch_not_admitted},
          {"{:error, r}", Macro.escape({:error, :provider_queue_timeout}),
           :provider_queue_timeout},
          {"{:unknown, r}", Macro.escape({:unknown, :queue_lost}), :queue_lost}
        ] do
      test "a reserved row with a valid #{label} keeps its reason (characterization)", ctx do
        assert {:error, unquote(reason)} = cli(ctx, "reserved-#{unquote(label)}", unquote(reply))
        assert [invocation] = invocations(ctx)
        assert {invocation.status, invocation.sent_at} == {:failed, nil}
        assert invocation.error["reason"] == to_string(unquote(reason))
      end
    end

    test "an already settled row gets no second write (characterization)", ctx do
      settle_first = fn invocation_id ->
        {:ok, invocation} = Agents.get_model_invocation(invocation_id, actor: ctx.agent)

        {:ok, _} =
          Agents.fail_model_invocation(invocation, %{error: %{"kind" => "test"}},
            actor: ctx.agent
          )
      end

      assert {:error, :invocation_already_settled} =
               ModelProvider.complete(request(ctx, "terminal"),
                 provider: __MODULE__.SettledFirst,
                 provider_options: [settle: settle_first, reply: :ok]
               )

      assert [invocation] = invocations(ctx)
      assert invocation.status == :failed
      assert [_] = events_of_type(ctx.tenant, "model.invocation.failed")
      assert events_of_type(ctx.tenant, "model.invocation.unknown") == []
    end
  end

  defmodule NeverLaunched do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, ClaudeCLI.provenance()}
    def complete(_request, opts), do: Keyword.fetch!(opts, :reply)
  end

  defmodule SettledFirst do
    @moduledoc false
    @behaviour SdrAgent.AI.ModelProvider

    def prepare(_request, _opts), do: {:ok, ClaudeCLI.provenance()}

    def complete(request, opts) do
      Keyword.fetch!(opts, :settle).(request.witness.model_invocation_id)
      Keyword.fetch!(opts, :reply)
    end
  end
end
