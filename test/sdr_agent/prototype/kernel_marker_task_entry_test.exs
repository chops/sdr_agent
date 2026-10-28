defmodule SdrAgent.Prototype.KernelMarkerTaskEntryTest do
  @moduledoc """
  Direct controls of `SdrAgent.Prototype.Checks.KernelMarker` with
  `marker: :task_entry` (Codex ca4624a1 section A: controls before the
  marker is enabled). The check passes only for a `:kernel` actor whose
  request carries the audit-kernel marker (`KernelContext`) AND the task
  entry marker exactly `true`: never truthiness, never the operator, a
  user or another system actor.

  - positive: the kernel with `KernelMarker.context(:task_entry)`;
  - negatives: the task marker missing, `false`, truthy but not `true`
    (`"true"`, `1`, `:yes`), the setup marker instead, an unknown marker
    option, the task marker without the kernel marker, no context, and the
    wrong actor (admin, forged operator, agent runtime, no actor).

  The `:setup` controls stay in `setup_actions_test.exs`.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Prototype.Checks.KernelMarker

  defp marker?(actor, context, opts \\ [marker: :task_entry]),
    do: KernelMarker.match?(actor, %{subject: %{context: context}}, opts)

  defp kernel(tenant), do: Actor.system(:kernel, tenant.id)

  # The task-entry marker key, derived from the check's own context (the
  # one key it adds to the audit-kernel context).
  defp task_key do
    [key] = Map.keys(KernelMarker.context(:task_entry)) -- Map.keys(KernelContext.context())
    key
  end

  setup do
    %{tenant: bootstrap!()}
  end

  test "the kernel with the task-entry marker exactly true is the positive case", ctx do
    assert marker?(kernel(ctx.tenant), KernelMarker.context(:task_entry)),
           "the marked kernel task-entry request was refused"
  end

  test "every other request is refused", ctx do
    task_context = KernelMarker.context(:task_entry)
    with_marker = fn value -> Map.put(KernelContext.context(), task_key(), value) end

    refused = [
      marker_missing: marker?(kernel(ctx.tenant), KernelContext.context()),
      marker_false: marker?(kernel(ctx.tenant), with_marker.(false)),
      marker_string_true: marker?(kernel(ctx.tenant), with_marker.("true")),
      marker_one: marker?(kernel(ctx.tenant), with_marker.(1)),
      marker_atom: marker?(kernel(ctx.tenant), with_marker.(:yes)),
      setup_marker: marker?(kernel(ctx.tenant), KernelMarker.context(:setup)),
      unknown_marker_option: marker?(kernel(ctx.tenant), task_context, marker: :other),
      no_marker_option: marker?(kernel(ctx.tenant), task_context, []),
      task_marker_without_kernel_marker:
        marker?(kernel(ctx.tenant), Map.take(task_context, [task_key()])),
      no_context: marker?(kernel(ctx.tenant), %{}),
      admin: marker?(human(:admin, ctx.tenant), task_context),
      forged_operator:
        marker?(
          %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id},
          task_context
        ),
      agent_runtime: marker?(Actor.system(:agent_runtime, ctx.tenant.id), task_context),
      no_actor: marker?(nil, task_context)
    ]

    for {name, result} <- refused do
      refute result, "#{name} passed the task-entry marker check"
    end
  end
end
