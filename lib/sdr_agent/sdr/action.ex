defmodule SdrAgent.SDR.Action do
  @moduledoc """
  The SDR agent's Jido Action contract (spec §6: small, composable actions).

  `use SdrAgent.SDR.Action, name: …, schema: …, version: "1"` defines a
  `Jido.Action` whose `run/2` wraps the module's `perform/2` so that every
  execution is a ToolInvocation of the run (S2 row ToolInvocation, ADR-0002):
  the run's tool budget is counted and the canonical input stored *before*
  the action works; the output (and any external request references) or
  the error is recorded when it ends. The run's OpenTelemetry context is
  re-attached (Flow steps run in Task processes) and the action runs in an
  `sdr.action <name>` span.

  `perform(params, ctx)` receives the validated params (without the agent
  state, which is in `ctx.agent_state` if the step passed it) and the
  `SdrAgent.SDR.Context` with `tool_invocation` set, and returns
  `{:ok, output}`, `{:ok, output, directives}`,
  `{:ok, output, directives, external_request_refs}` or `{:error, reason}`.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.SDR.Context
  alias SdrAgent.Telemetry.Agent, as: Spans

  @callback perform(params :: map(), ctx :: Context.t()) ::
              {:ok, map()}
              | {:ok, map(), list()}
              | {:ok, map(), list(), [map()]}
              | {:error, term()}

  defmacro __using__(opts) do
    version = Keyword.get(opts, :version, "1")
    jido_opts = Keyword.delete(opts, :version)

    quote do
      @behaviour SdrAgent.SDR.Action
      use Jido.Action, unquote(jido_opts)

      @doc false
      def sdr_action_version, do: unquote(version)

      @impl Jido.Action
      def run(params, context), do: SdrAgent.SDR.Action.execute(__MODULE__, params, context)
    end
  end

  @doc false
  def execute(module, params, context) do
    ctx = %{Context.fetch!(context) | agent_state: Map.get(context, :agent_state)}

    Spans.with_context(ctx.otel, fn ->
      Spans.with_span("sdr.action #{module.name()}", %{"sdr.agent_run.id" => ctx.run_id}, fn ->
        invoke(module, params, ctx)
      end)
    end)
  end

  defp invoke(module, params, ctx) do
    input = Map.drop(params, [:state])

    with {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         {:ok, tool} <- start(module, run, input, ctx) do
      ctx = %{ctx | tool_invocation: tool}

      module
      |> safe_perform(params, ctx)
      |> finish(tool, ctx)
    end
  end

  defp start(module, run, input, ctx) do
    encoded = Canonical.encode!(input)
    digest = encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    Agents.start_tool_invocation(
      run,
      %{
        action_module: inspect(module),
        action_version: module.sdr_action_version(),
        input: encoded,
        idempotency_key: "tool:#{run.id}:#{ctx.signal_id}:#{module.name()}:#{digest}"
      },
      actor: ctx.actor
    )
  end

  defp safe_perform(module, params, ctx) do
    module.perform(params, ctx)
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  end

  defp finish({:ok, output}, tool, ctx), do: finish({:ok, output, [], []}, tool, ctx)

  defp finish({:ok, output, directives}, tool, ctx),
    do: finish({:ok, output, directives, []}, tool, ctx)

  defp finish({:ok, output, directives, refs}, tool, ctx) do
    attrs = %{output: Canonical.encode!(output), external_request_refs: refs}

    with {:ok, _tool} <- Agents.succeed_tool_invocation(tool, attrs, actor: ctx.actor) do
      if directives == [], do: {:ok, output}, else: {:ok, output, directives}
    end
  end

  defp finish({:error, reason}, tool, ctx) do
    error = %{"reason" => describe(reason)}
    {:ok, _tool} = Agents.fail_tool_invocation(tool, %{error: error}, actor: ctx.actor)
    {:error, reason}
  end

  defp describe({:halt, reason}), do: "halt: #{reason}"
  defp describe({:exception, module}), do: "exception: #{inspect(module)}"
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(_reason), do: "error"
end
