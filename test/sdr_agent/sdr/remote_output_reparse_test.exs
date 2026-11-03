defmodule SdrAgent.SDR.RemoteOutputReparseTest do
  @moduledoc """
  RED (fix plan notes/fixes/remote-released-output-reparse.org; plan r1
  c77fa9cc, Codex technical PASS): `SdrAgent.SDR.Model.reparse_released/3`
  re-parses a released remote read (jsonb, string keys) with the purpose's
  own Zoi schema, after checking the invocation's recorded output schema
  hash. Pure: no database, model, CLI or network.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Schemas

  @purposes [:evidence_extraction, :qualification, :outreach_proposal, :reply_classification]

  # Dynamic: the function is the missing behavior under test, so its absence
  # fails as an assertion rather than an UndefinedFunctionError.
  defp reparse(purpose, invocation, read) do
    assert Code.ensure_loaded?(Model)

    assert function_exported?(Model, :reparse_released, 3),
           "SdrAgent.SDR.Model.reparse_released/3 is not exported"

    Function.capture(Model, :reparse_released, 3).(purpose, invocation, read)
  end

  defp invocation(purpose), do: %{output_schema_sha256: Schemas.ref(purpose).sha256}

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp output(:evidence_extraction) do
    %{
      claims: [
        %{
          source: 0,
          claim: "Example Robotics builds warehouse robots.",
          quote: "We build warehouse robots.",
          confidence: 0.9,
          quality: "accepted",
          reason: "verbatim company statement"
        }
      ]
    }
  end

  defp output(:qualification) do
    %{
      qualified: true,
      score: 82,
      criteria: %{
        company_size: "pass",
        industry: "pass",
        geography: "unknown",
        persona: "pass",
        trigger: "fail"
      },
      confidence: 0.5,
      evidence_ids: ["e-1"],
      reason: "synthetic qualification"
    }
  end

  defp output(:outreach_proposal) do
    %{
      subject: "Warehouse robots",
      body: "Hello, a short synthetic body.",
      angle: "expansion",
      cta: "Worth a short call?",
      claims: [%{claim: "Builds warehouse robots.", evidence_id: "e-1", confidence: 0.8}],
      personalization: [%{text: "your warehouse robots", evidence_id: "e-1"}],
      risk_flags: [],
      evidence_ids: ["e-1"]
    }
  end

  defp output(:reply_classification) do
    %{
      classification: "interested",
      sentiment: "positive",
      intent: "wants a call",
      suggested_next_action: "hand_off",
      confidence: 0.7,
      reason: "asks for a time"
    }
  end

  describe "T1 JSON roundtrip" do
    for purpose <- @purposes do
      test "#{purpose}: the string-keyed read re-parses to the atom-keyed output" do
        purpose = unquote(purpose)
        expected = output(purpose)
        assert {:ok, ^expected} = Zoi.parse(Schemas.for_purpose(purpose), expected)

        result = reparse(purpose, invocation(purpose), json(expected))
        assert result == {:ok, expected}, "#{purpose}: #{inspect(result, limit: 12)}"
        {:ok, parsed} = result
        refute is_struct(parsed)
      end
    end

    test "T1b an unknown string key never becomes an atom" do
      key = "zz_reparse_unknown_#{System.unique_integer([:positive])}"
      read = Map.put(json(output(:qualification)), key, "x")
      _result = reparse(:qualification, invocation(:qualification), read)
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  describe "T5a schema hash mismatch" do
    test "another purpose's schema hash is refused" do
      read = json(output(:evidence_extraction))
      result = reparse(:evidence_extraction, invocation(:qualification), read)
      assert result == {:error, :schema_mismatch}, inspect(result, limit: 12)
    end

    test "an unknown schema hash is refused" do
      read = json(output(:qualification))
      bogus = %{output_schema_sha256: :crypto.strong_rand_bytes(32)}
      result = reparse(:qualification, bogus, read)
      assert result == {:error, :schema_mismatch}, inspect(result, limit: 12)
    end
  end

  describe "T5b invalid released map" do
    test "an out-of-range value is refused" do
      read = json(output(:qualification)) |> Map.put("score", 101)
      result = reparse(:qualification, invocation(:qualification), read)
      assert result == {:error, :invalid_output}, inspect(result, limit: 12)
    end

    test "a missing required key is refused" do
      read = json(output(:reply_classification)) |> Map.delete("classification")
      result = reparse(:reply_classification, invocation(:reply_classification), read)
      assert result == {:error, :invalid_output}, inspect(result, limit: 12)
    end

    test "a non-map read is refused" do
      for read <- [nil, [], "claims", 1] do
        result = reparse(:evidence_extraction, invocation(:evidence_extraction), read)
        assert result == {:error, :invalid_output}, "#{inspect(read)}: #{inspect(result)}"
      end
    end
  end
end

defmodule SdrAgent.SDR.RemoteOutputConsumerTest do
  @moduledoc """
  RED (fix plan notes/fixes/remote-released-output-reparse.org): under the
  trusted `:remote` transport, `SdrAgent.SDR.Model.call/4` returns output
  the consumers can read with their own atom access. Reproduces hosted
  Trope run 01a19f64 (`:crash`, KeyError at `output.claims`). Synthetic
  worker completions only; no model, CLI or network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.RemoteSettlerFixtures, as: S
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    agent = Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    F.remote!()
    put_env!(:model_provider, ClaudeCLI)
    Map.merge(ctx, %{fx: fx})
  end

  defp put_env!(key, value) do
    previous = Application.fetch_env(:sdr_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:sdr_agent, key, old)
        :error -> Application.delete_env(:sdr_agent, key)
      end
    end)

    Application.put_env(:sdr_agent, key, value)
  end

  defp world!(ctx) do
    pins = F.pins()
    _owner = H.enrol!(ctx)
    %{token: token, worker: worker} = F.enrol!(ctx.fx, pins)
    H.enter!(ctx)
    assert {:ok, :open} = F.heartbeat(token, pins)
    grant = G.provision!(ctx.fx)
    run = G.run!(ctx.fx)
    fx = Map.merge(ctx.fx, %{grant: grant, run: run})
    Map.merge(ctx, %{fx: fx, token: token, worker: worker})
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, error.__struct__, Exception.message(error)}
  catch
    kind, reason -> {kind, reason}
  end

  defp sdr(ctx) do
    %Context{
      actor: ctx.fx.agent,
      tenant_id: ctx.fx.tenant.id,
      run_id: ctx.fx.run.id,
      correlation_id: ctx.fx.run.correlation_id,
      signal_id: "sig-reparse-#{System.unique_integer([:positive])}",
      model: []
    }
  end

  defp invocations(ctx),
    do: F.rows(SdrAgent.Agents.ModelInvocation, "agent_run_id = $1", [F.dump(ctx.fx.run.id)])

  defp await_pending!(ctx, tries \\ 200) do
    case invocations(ctx) do
      [invocation | _] ->
        case F.call_of(F.load(invocation["id"])) do
          %{"state" => "pending"} = call -> call
          _other -> retry_pending!(ctx, tries)
        end

      [] ->
        retry_pending!(ctx, tries)
    end
  end

  defp retry_pending!(_ctx, 0), do: flunk("no pending remote call appeared for the run")

  defp retry_pending!(ctx, tries) do
    Process.sleep(25)
    await_pending!(ctx, tries - 1)
  end

  # The caller in its own process, in prototype runtime; `access` is the
  # consumer's own read of the returned output.
  defp call_async(ctx, purpose, input, access) do
    Task.async(fn ->
      H.enter!(ctx)

      safely(fn ->
        case Model.call(sdr(ctx), purpose, input, Ecto.UUID.generate()) do
          {:ok, output, invocation} -> {:ok, safely(fn -> access.(output) end), invocation}
          other -> other
        end
      end)
    end)
  end

  defp drive!(ctx, output) do
    _call = await_pending!(ctx)
    nonce = F.nonce()
    launch = F.claim!(ctx.token, nonce)

    result =
      F.complete(
        ctx.token,
        nonce,
        launch.call_id,
        launch.request_sha256,
        S.valid_transcript(output)
      )

    assert F.kind(result) == :accepted, "prerequisite: completion #{inspect(result)}"
    S.settle!(ctx.fx)
    launch
  end

  defp evidence_input do
    %{
      company: %{name: "Example Robotics", domain: "example.test"},
      contact: %{name: "Avery Example", title: "VP Operations"},
      research_brief: "Synthetic brief.",
      sources: [
        %{
          index: 0,
          source_type: :company_site,
          title: "Example Robotics",
          url: "https://example.test/",
          trust_level: :primary,
          content: "We build warehouse robots."
        }
      ]
    }
  end

  defp qualification_input do
    %{
      icp: %{
        name: "Synthetic ICP",
        version: 1,
        employee_count_min: 50,
        employee_count_max: 500,
        industries: ["robotics"],
        geographies: ["US"],
        personas: ["operations"],
        triggers: ["expansion"]
      },
      company: %{
        name: "Example Robotics",
        industry: "robotics",
        employee_count: 120,
        geography: "US"
      },
      contact: %{title: "VP Operations", persona: "operations"},
      evidence: []
    }
  end

  test "T2 evidence extraction: BuildEvidenceBundle's own access reads the claims", ctx do
    ctx = world!(ctx)

    released = %{
      "claims" => [
        %{
          "source" => 0,
          "claim" => "Example Robotics builds warehouse robots.",
          "quote" => "We build warehouse robots.",
          "confidence" => 0.9,
          "quality" => "accepted",
          "reason" => "verbatim company statement"
        }
      ]
    }

    # build_evidence_bundle.ex: output.claims, then claim.source/quote/quality.
    access = fn output ->
      Enum.map(output.claims, &{&1.source, &1.quote, &1.quality, &1.confidence})
    end

    task = call_async(ctx, :evidence_extraction, evidence_input(), access)
    _launch = drive!(ctx, released)
    result = Task.await(task, 30_000)

    assert match?({:ok, [{0, "We build warehouse robots.", "accepted", 0.9}], _}, result),
           "remote evidence consumer access: #{inspect(result, limit: 12)}"

    {:ok, _claims, invocation} = result
    assert invocation.status == :completed
    assert S.release_count(invocation.id) == 1
    assert G.charged(ctx.fx) == 1
  end

  test "T3 qualification: ScoreLead's own access reads the result", ctx do
    ctx = world!(ctx)
    access = fn output -> {output.score, output.criteria.company_size, output.evidence_ids} end
    task = call_async(ctx, :qualification, qualification_input(), access)
    _launch = drive!(ctx, S.valid_output())
    result = Task.await(task, 30_000)

    assert match?({:ok, {82, "pass", []}, _}, result),
           "remote qualification consumer access: #{inspect(result, limit: 12)}"

    {:ok, _value, invocation} = result
    assert S.release_count(invocation.id) == 1
    assert G.charged(ctx.fx) == 1
  end
end
