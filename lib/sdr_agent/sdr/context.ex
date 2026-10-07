defmodule SdrAgent.SDR.Context do
  @moduledoc """
  The caller context every SDR Action receives under `context.sdr` (Jido
  keeps caller context out of agent state and emitted signals): the agent
  runtime actor, the run's ids, the signal being handled, the OpenTelemetry
  context of the run, model-provider options, and — set by
  `SdrAgent.SDR.Action` while an action runs — its ToolInvocation and the
  agent's current working state (`agent_state`).

  Also records Decisions (`decide/2`) with the run, a stable idempotency key
  per decision point, and input refs.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Audit.RecordHash

  @enforce_keys [:actor, :tenant_id, :run_id, :correlation_id]
  defstruct [
    :actor,
    :tenant_id,
    :run_id,
    :correlation_id,
    :signal_id,
    :signal_type,
    :otel,
    :tool_invocation,
    :agent_state,
    model: []
  ]

  @type t :: %__MODULE__{}

  @doc "The context of `context.sdr`; raises when an action is run outside the agent."
  def fetch!(%{sdr: %__MODULE__{} = sdr}), do: sdr

  def fetch!(_context),
    do: raise(ArgumentError, "SDR actions run inside SdrAgent.SDR.Runner (context.sdr missing)")

  @doc """
  Records a Decision of this run. `attrs` are Decision `:record` attributes;
  `point` names the decision point and makes the idempotency key
  (`run:<id>:<kind>:<point>`); `refs` are records used as inputs (their
  canonical hashes are recorded as `input_refs`).
  """
  def decide(%__MODULE__{} = ctx, attrs, point, refs \\ []) do
    attrs
    |> Map.merge(%{
      agent_run_id: ctx.run_id,
      idempotency_key: "run:#{ctx.run_id}:#{attrs.kind}:#{point}",
      input_refs: Enum.map(refs, &input_ref/1)
    })
    |> Map.put_new(:subject_resource, "SdrAgent.Sales.Lead")
    |> Agents.record_decision(actor: ctx.actor)
  end

  defp input_ref(%resource{id: id} = record),
    do: %{resource: inspect(resource), id: id, record_sha256: RecordHash.hex(record)}
end
