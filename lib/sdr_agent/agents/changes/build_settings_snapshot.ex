defmodule SdrAgent.Agents.Changes.BuildSettingsSnapshot do
  @moduledoc """
  Binds a new agent run to its run settings snapshot in `AgentRun :create`
  (C4, `docs/product/c4/readiness.md` sections 3.2, 3.7, 3.8 and 4).

  In a `before_action` (after authorization, inside the creating
  transaction):

    1. the tenant's audit chain head is taken (`SdrAgent.Audit.Kernel.lock_head/1`,
       reentrant), so the revisions read next are exactly those whose events
       precede this run's, and none can commit until this transaction ends;
    2. the current revision of each kind is read, each in its own statement;
    3. business completeness is checked for the run's usage origin
       (`SdrAgent.Agents.RunSettings.completeness/0`): a missing kind refuses
       the run (`settings_incomplete`) before anything is written;
    4. each slot is the current revision, else the kind's current built-in
       default (its version and pinned hash re-checked,
       `SdrAgent.Agents.RunSettings.CodeDefaults.fetch/2`), else absent; the
       limits are the limits revision's, else the built-in default's;
       `snapshot_sha256` is computed from the same values (section 3.7);
    5. the snapshot is created through `RunSettingsSnapshot :create` inside a
       phase opened here (below), and the run gets its id;
    6. the run's budget is frozen: each of `max_model_calls`,
       `max_tool_calls` and `max_tokens` is the lower of the caller's
       argument, when given, and the snapshot's `run_*` limit.

  ## Phases (`SdrAgent.Agents.Checks.SettingsSnapshotContext`)

  A phase is opened only by this change, with a private function. It
  registers a binding (actor, tenant and the computed snapshot values)
  under a fresh reference in the calling process and gives the snapshot
  action a context carrying only that reference, for the duration of that
  one call. `phase/1` is a read-only accessor: a direct snapshot create, a
  copied or forged context, or a context used from another process names no
  open binding, so it is refused and carries no values.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Agents.RunSettingsSnapshot
  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel

  @budget [
    max_model_calls: :run_max_model_calls,
    max_tool_calls: :run_max_tool_calls,
    max_tokens: :run_max_tokens
  ]
  @phases {__MODULE__, :phases}

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &build(&1, context.actor))
  end

  defp build(changeset, actor) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    origin = Ash.Changeset.get_argument(changeset, :usage_origin)

    with {:ok, _head} <- Kernel.lock_head(tenant_id),
         current = current_revisions(tenant_id),
         [] <- missing(origin, current),
         {:ok, values} <- snapshot_values(tenant_id, current),
         {:ok, snapshot} <- create_snapshot(tenant_id, actor, values) do
      changeset
      |> Ash.Changeset.force_change_attribute(:settings_snapshot_id, snapshot.id)
      |> Ash.Changeset.force_change_attribute(:budget, budget(changeset, values.limits))
    else
      [_ | _] = kinds ->
        Ash.Changeset.add_error(changeset, settings_incomplete(kinds))

      {:error, :settings_default_unavailable} ->
        Ash.Changeset.add_error(changeset,
          field: :settings_snapshot_id,
          message: "settings_default_unavailable",
          rule: :settings_default_unavailable
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # The same error as before (field, message and vars, `rule:
  # :settings_incomplete`), plus the missing kinds as structured private
  # vars (C3-02 G4: the admission maps this refusal to `{:settings_incomplete,
  # kinds}` from the rule and these kinds, never from the message).
  defp settings_incomplete(kinds) do
    message = "settings_incomplete: #{Enum.join(kinds, ", ")}"

    InvalidAttribute.exception(
      field: :usage_origin,
      message: message,
      vars: [field: :usage_origin, message: message, rule: :settings_incomplete],
      private_vars: [kinds: kinds]
    )
  end

  @doc """
  The current revision of each settings kind of `tenant_id` (nil when
  none), each read in its own statement under the kernel context.
  """
  @spec current_revisions(String.t()) :: %{atom() => struct() | nil}
  def current_revisions(tenant_id) do
    Map.new(RunSettings.kinds(), fn kind ->
      SettingsRevision
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id and kind == ^kind)
      |> Ash.Query.sort(number: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!()
      |> then(&{kind, &1})
    end)
  end

  @doc "The kinds `origin` requires that `current` lacks, in packet order."
  @spec missing(atom(), map()) :: [atom()]
  def missing(origin, current) do
    RunSettings.completeness()
    |> Map.get(origin, [])
    |> Enum.filter(&is_nil(Map.get(current, &1)))
  end

  defp snapshot_values(tenant_id, current) do
    slots = Map.new(RunSettings.kinds(), &{&1, slot(&1, Map.get(current, &1))})

    if Enum.any?(slots, fn {_kind, slot} -> slot == :unavailable end) do
      {:error, :settings_default_unavailable}
    else
      limits = limits(current.operational_limits)

      {:ok,
       %{
         slots: slots,
         limits: limits,
         safeguards_version: Safeguards.version(),
         snapshot_sha256: snapshot_sha256(tenant_id, Safeguards.version(), slots, limits)
       }}
    end
  end

  defp slot(_kind, %SettingsRevision{id: id, content_sha256: sha}),
    do: %{source: :revision, revision_id: id, code_default_version: nil, content_sha256: sha}

  defp slot(kind, nil) do
    case CodeDefaults.current(kind) do
      nil ->
        %{source: :absent, revision_id: nil, code_default_version: nil, content_sha256: nil}

      %{version: version} ->
        case CodeDefaults.fetch(kind, version) do
          {:ok, entry} ->
            %{
              source: :code_default,
              revision_id: nil,
              code_default_version: entry.version,
              content_sha256: entry.content_sha256
            }

          :error ->
            :unavailable
        end
    end
  end

  defp limits(%SettingsRevision{operational_limits: limits}),
    do: Map.new(Safeguards.limit_fields(), &{&1, Map.fetch!(limits, &1)})

  defp limits(nil) do
    content = CodeDefaults.current(:operational_limits).content
    Map.new(Safeguards.limit_fields(), &{&1, Map.fetch!(content, &1)})
  end

  @doc """
  `snapshot_sha256` (section 3.7): the lowercase hex sha256 of the
  canonical encoding of `{"schema": "c4-run-settings-snapshot/1",
  "tenant_id", "safeguards_version", "slots", "limits"}`, where `slots` maps
  all five kinds to exactly their hashed slot and `limits` all twelve
  fields to integers.
  """
  @spec snapshot_sha256(String.t(), String.t(), map(), map()) :: String.t()
  def snapshot_sha256(tenant_id, safeguards_version, slots, limits) do
    %{
      "schema" => RunSettingsSnapshot.hash_version(),
      "tenant_id" => tenant_id,
      "safeguards_version" => safeguards_version,
      "slots" => Map.new(slots, fn {kind, slot} -> {Atom.to_string(kind), hashed(slot)} end),
      "limits" => Map.new(limits, fn {field, value} -> {Atom.to_string(field), value} end)
    }
    |> Canonical.sha256()
    |> Base.encode16(case: :lower)
  end

  defp hashed(%{source: :revision} = slot),
    do: %{
      "source" => "revision",
      "revision_id" => slot.revision_id,
      "content_sha256" => slot.content_sha256
    }

  defp hashed(%{source: :code_default} = slot),
    do: %{
      "source" => "code_default",
      "version" => slot.code_default_version,
      "content_sha256" => slot.content_sha256
    }

  defp hashed(%{source: :absent}), do: %{"source" => "absent"}

  defp create_snapshot(tenant_id, actor, values) do
    binding = %{action: :create, tenant_id: tenant_id, actor: actor, values: values}

    with_phase(binding, fn context ->
      RunSettingsSnapshot
      |> Ash.Changeset.for_create(:create, %{}, actor: actor, context: context)
      |> Ash.create()
    end)
  end

  defp budget(changeset, limits) do
    Map.new(@budget, fn {field, limit} ->
      snapshot = Map.fetch!(limits, limit)

      case Ash.Changeset.get_argument(changeset, field) do
        given when is_integer(given) -> {field, min(given, snapshot)}
        _none -> {field, snapshot}
      end
    end)
  end

  @doc """
  The open phase binding a changeset context names (`{:ok, binding}`), or
  `:error`. Read-only: it never opens a phase.
  """
  @spec phase(term()) :: {:ok, map()} | :error
  def phase(%{run_settings_snapshot: %{token: token}}) when is_reference(token),
    do: Map.fetch(Process.get(@phases, %{}), token)

  def phase(_context), do: :error

  defp with_phase(binding, fun) do
    token = make_ref()
    Process.put(@phases, Map.put(Process.get(@phases, %{}), token, binding))

    try do
      fun.(%{run_settings_snapshot: %{token: token}})
    after
      Process.put(@phases, Map.delete(Process.get(@phases, %{}), token))
    end
  end
end
