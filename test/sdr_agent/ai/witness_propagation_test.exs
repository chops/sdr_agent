defmodule SdrAgent.AI.WitnessPropagationTest do
  @moduledoc """
  S12b step 4 (ADR-0005 S12 amendment, C6/C8): the facade hands ClaudeCLI
  the invocation UUID it already reserved and the caller's W3C context of
  the `gen_ai.*` span — captured in the calling process, before the
  serialized GenServer hop — and the adapter forwards both only through the
  per-call child environment.
  """
  use SdrAgent.AuditCase, async: false

  require Record
  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Telemetry.InMemoryExporter

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @traceparent ~r/\A00-([0-9a-f]{32})-([0-9a-f]{16})-01\z/

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    dump = Path.join(System.tmp_dir!(), "sdr-facade-env-#{System.unique_integer([:positive])}")

    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "env_dump", dump]
      )

    InMemoryExporter.reset()

    on_exit(fn ->
      (dump <> ".*") |> Path.wildcard() |> Enum.each(&File.rm/1)
      InMemoryExporter.reset()
    end)

    %{tenant: tenant, run: run, agent: agent, dump: dump, server: server}
  end

  test "each call carries its own persisted invocation id and gen_ai parent context", ctx do
    before = System.get_env()

    assert {:ok, first} = complete(ctx, "witness-1")
    assert {:ok, second} = complete(ctx, "witness-2")

    assert System.get_env() == before
    assert [one, two] = read_dumps(ctx.dump)

    assert one["SDR_MODEL_INVOCATION_ID"] == first.invocation.id
    assert two["SDR_MODEL_INVOCATION_ID"] == second.invocation.id
    assert first.invocation.id != second.invocation.id

    assert [_, trace_one, parent_one] = Regex.run(@traceparent, one["SDR_TRACEPARENT"] || "")
    assert [_, trace_two, parent_two] = Regex.run(@traceparent, two["SDR_TRACEPARENT"] || "")
    assert {trace_one, parent_one} != {trace_two, parent_two}

    spans = gen_ai_spans(2)

    for {trace_id, parent_id} <- [{trace_one, parent_one}, {trace_two, parent_two}] do
      assert Enum.any?(
               spans,
               &(hex(span(&1, :trace_id), 32) == trace_id and
                   hex(span(&1, :span_id), 16) == parent_id)
             ),
             "traceparent #{trace_id}/#{parent_id} is not a gen_ai span of this call"
    end
  end

  test "the persisted invocation is unchanged in shape (no new columns or statuses)", ctx do
    assert {:ok, result} = complete(ctx, "witness-shape")
    assert result.invocation.provider == :claude_cli
    assert result.invocation.status == :completed

    {:ok, [invocation]} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    assert invocation.id == result.invocation.id
    assert [child] = read_dumps(ctx.dump)
    assert child["SDR_MODEL_INVOCATION_ID"] == invocation.id
  end

  defp complete(ctx, id) do
    attrs = AgentsFixtures.model_attrs(id)

    audit =
      Map.take(attrs, [
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    ModelProvider.complete(
      %{
        id: id,
        run: ctx.run,
        actor: ctx.agent,
        operation: "model.complete",
        prompt: "Qualify the fixture lead",
        schema: @schema,
        audit: audit
      },
      provider: ClaudeCLI,
      provider_options: [server: ctx.server]
    )
  end

  defp read_dumps(dump) do
    (dump <> ".*")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
    |> Enum.sort_by(& &1["started_us"])
  end

  defp gen_ai_spans(minimum, attempts \\ 100)
  defp gen_ai_spans(_minimum, 0), do: flunk("gen_ai spans were not exported")

  defp gen_ai_spans(minimum, attempts) do
    spans = Enum.filter(InMemoryExporter.spans(), &(span(&1, :name) == "gen_ai.model.complete"))

    if length(spans) >= minimum do
      spans
    else
      Process.sleep(10)
      gen_ai_spans(minimum, attempts - 1)
    end
  end

  defp hex(id, width) when is_integer(id),
    do: id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
end
