defmodule SdrAgent.Agents.Changes.DecisionRules do
  @moduledoc """
  Decision invariants (S2 row Decision; spec §8), checked inside the create
  transaction:

    * `mode: :llm` ⇒ `model_invocation_id` and `output_pointer` present, the
      invocation is `completed` with `validation_status: :valid`, the
      pointer resolves in its `parsed_output`, and no rule fields;
    * `mode: :deterministic` ⇒ `rule_id` and `rule_version` present, no
      invocation and no pointer;
    * protected kinds (`SdrAgent.Agents.Decision.protected_kinds/0`) are
      always deterministic — the model never decides them.

  Also stores the canonical `inputs` snapshot as a Payload (via the kernel)
  and sets `inputs_sha256`, and derives `idempotency_key` when none is given.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Decision
  alias SdrAgent.Agents.JsonPointer
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> derive_key(context.actor)
    |> static_rules()
    |> Ash.Changeset.before_action(&invocation_rules/1)
    |> Ash.Changeset.before_action(&store_inputs/1)
  end

  defp derive_key(changeset, actor) do
    case Ash.Changeset.get_attribute(changeset, :idempotency_key) do
      nil ->
        attrs =
          Map.new(
            [
              :agent_run_id,
              :kind,
              :subject_resource,
              :subject_id,
              :model_invocation_id,
              :output_pointer
            ],
            &{&1, Ash.Changeset.get_attribute(changeset, &1)}
          )

        Ash.Changeset.force_change_attribute(
          changeset,
          :idempotency_key,
          Decision.idempotency_key(attrs, actor)
        )

      _key ->
        changeset
    end
  end

  defp static_rules(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    get.(:mode)
    |> mode_errors(get)
    |> Enum.filter(& &1)
    |> Enum.reduce(changeset, fn {field, message}, acc ->
      Ash.Changeset.add_error(acc, field: field, message: message)
    end)
  end

  defp mode_errors(:llm, get) do
    kind = get.(:kind)

    [
      kind in Decision.protected_kinds() && {:mode, "#{kind} decisions must be deterministic"},
      is_nil(get.(:model_invocation_id)) &&
        {:model_invocation_id, "is required for llm decisions"},
      is_nil(get.(:output_pointer)) && {:output_pointer, "is required for llm decisions"},
      (get.(:rule_id) || get.(:rule_version)) && {:rule_id, "must be empty for llm decisions"}
    ]
  end

  defp mode_errors(:deterministic, get) do
    [
      is_nil(get.(:rule_id)) && {:rule_id, "is required for deterministic decisions"},
      is_nil(get.(:rule_version)) && {:rule_version, "is required for deterministic decisions"},
      get.(:model_invocation_id) &&
        {:model_invocation_id, "must be empty for deterministic decisions"},
      get.(:output_pointer) && {:output_pointer, "must be empty for deterministic decisions"}
    ]
  end

  defp mode_errors(_mode, _get), do: []

  defp invocation_rules(changeset) do
    with :llm <- Ash.Changeset.get_attribute(changeset, :mode),
         id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :model_invocation_id) do
      tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
      check_invocation(changeset, Ash.get(ModelInvocation, id, Kernel.opts(tenant_id)))
    else
      _ -> changeset
    end
  end

  defp check_invocation(changeset, {:ok, %{status: :completed, validation_status: :valid} = inv}) do
    pointer = Ash.Changeset.get_attribute(changeset, :output_pointer)

    case JsonPointer.resolve(inv.parsed_output, pointer) do
      {:ok, _value} -> changeset
      :error -> invalid(changeset, :output_pointer, "does not resolve in parsed_output")
    end
  end

  defp check_invocation(changeset, {:ok, _invocation}),
    do: invalid(changeset, :model_invocation_id, "must be completed with a valid output")

  defp check_invocation(changeset, {:error, _}),
    do: invalid(changeset, :model_invocation_id, "does not exist")

  defp store_inputs(changeset) do
    inputs = Ash.Changeset.get_argument(changeset, :inputs) || %{}
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    Payload
    |> Ash.Changeset.for_create(
      :store,
      %{content: Canonical.encode!(inputs), content_type: "application/json"},
      Kernel.opts(tenant_id)
    )
    |> Ash.create(return_notifications?: true)
    |> case do
      {:ok, payload, notifications} ->
        {Ash.Changeset.force_change_attribute(changeset, :inputs_sha256, payload.sha256),
         %{notifications: notifications}}

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp invalid(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
