defmodule SdrAgent.Agents.Changes.SettingsRevisionChain do
  @moduledoc """
  Builds a `SdrAgent.Agents.SettingsRevision` in `:create_revision` (C4,
  `docs/product/c4/readiness.md` sections 3.2, 3.7, 4 and 12).

  When the changeset is built: the `content` argument is checked by
  `SdrAgent.Agents.RunSettings.ContentRules.validate/2` (every field error
  is kept under its own field name, never with its value) and only then
  cast into the embedded attribute named by `kind`; and `confirm_raised` must hold no
  duplicate and be empty for a kind other than `:operational_limits`.

  In a `before_action`, after authorization, inside the action's
  transaction and before the chain head is taken (section 4):

    1. the current revision of the tenant's kind is read and locked `FOR NO
       KEY UPDATE` (so a snapshot's foreign key check, `FOR KEY SHARE`,
       never waits on an editor);
    2. under that lock the latest committed number is read again in its own
       statement: the save is refused as stale (error field
       `expected_number`, rule `:stale`) unless it equals both the locked
       revision's number and `expected_number` (0 when there is none);
    3. `number` is the predecessor's + 1 and `supersedes_id` its id;
    4. for limits, `raised_fields` are the fields above the value in effect
       (the locked predecessor, else the current built-in default), sorted;
       the save is refused `confirm_raised: :mismatch` unless the confirmed
       set equals them exactly;
    5. `content_sha256` is computed from the cast content
       (`SdrAgent.Agents.SettingsRevision.content_sha256/2`).

  The insert, then the audit append (chain head), follow while the lock is
  held.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Agents.RunSettings.ContentRules
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :kind) do
      kind when is_atom(kind) and not is_nil(kind) ->
        changeset
        |> cast_content(kind)
        |> cast_note()
        |> check_confirmation(kind)
        |> Ash.Changeset.before_action(&chain(&1, kind))

      _invalid ->
        changeset
    end
  end

  ## Content

  defp cast_content(changeset, kind) do
    attribute = Ash.Resource.Info.attribute(SettingsRevision, kind)

    with content when is_map(content) <-
           ContentRules.plain(Ash.Changeset.get_argument(changeset, :content)),
         :ok <- ContentRules.validate(kind, content),
         {:ok, value} when not is_nil(value) <-
           Ash.Type.cast_input(attribute.type, content, attribute.constraints),
         {:ok, value} <- Ash.Type.apply_constraints(attribute.type, value, attribute.constraints) do
      Ash.Changeset.force_change_attribute(changeset, kind, value)
    else
      {:error, errors} -> add_field_errors(changeset, kind, errors)
      _other -> error(changeset, :content, :invalid)
    end
  end

  defp add_field_errors(changeset, kind, errors) do
    errors
    |> List.wrap()
    |> Enum.reduce(changeset, fn error, acc ->
      error(acc, error_field(error, kind), error_rule(error))
    end)
  end

  defp error_field({field, _rule}, _kind) when is_atom(field), do: field

  defp error_field(error, kind) do
    case field_of(error) do
      field when is_atom(field) and not is_nil(field) -> field
      _none -> kind
    end
  end

  defp field_of(error) when is_list(error), do: Keyword.get(error, :field)
  defp field_of(%{field: field}), do: field
  defp field_of(_error), do: nil

  defp error_rule({_field, rule}) when is_atom(rule), do: rule

  defp error_rule(error) when is_list(error) do
    Keyword.get(error, :rule) || Keyword.get(Keyword.get(error, :vars, []), :rule) || :invalid
  end

  defp error_rule(%{vars: vars}) when is_list(vars), do: Keyword.get(vars, :rule, :invalid)
  defp error_rule(_error), do: :invalid

  ## Note (a raw term: settings text, at most 200 characters)

  defp cast_note(changeset) do
    case note_value(Ash.Changeset.get_argument(changeset, :note)) do
      {:ok, value} -> Ash.Changeset.force_change_attribute(changeset, :note, value)
      {:error, rule} -> error(changeset, :note, rule)
    end
  end

  defp note_value(nil), do: {:ok, nil}

  defp note_value(note) when is_binary(note) do
    trimmed = String.trim(note)

    cond do
      ContentRules.text(note) != :ok -> ContentRules.text(note)
      String.length(trimmed) > 200 -> {:error, :too_long}
      trimmed == "" -> {:ok, nil}
      true -> {:ok, trimmed}
    end
  end

  defp note_value(_note), do: {:error, :not_text}

  ## Raise confirmation

  defp check_confirmation(changeset, kind) do
    confirm = Ash.Changeset.get_argument(changeset, :confirm_raised) || []

    cond do
      not is_list(confirm) ->
        changeset

      length(Enum.uniq(confirm)) != length(confirm) ->
        error(changeset, :confirm_raised, :duplicate)

      kind != :operational_limits and confirm != [] ->
        error(changeset, :confirm_raised, :not_limits)

      true ->
        changeset
    end
  end

  ## Chain (before_action)

  defp chain(changeset, kind) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    expected = Ash.Changeset.get_argument(changeset, :expected_number)

    case lock_current(tenant_id, kind) do
      {:ok, current} ->
        latest = latest_number(tenant_id, kind)
        number = if current, do: current.number, else: 0

        if number == expected and latest == number,
          do: append(changeset, kind, current),
          else: error(changeset, :expected_number, :stale, latest: latest)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp append(changeset, kind, current) do
    {number, supersedes_id} = if current, do: {current.number + 1, current.id}, else: {1, nil}
    value = Ash.Changeset.get_attribute(changeset, kind)

    changeset =
      changeset
      |> Ash.Changeset.force_change_attribute(:number, number)
      |> Ash.Changeset.force_change_attribute(:supersedes_id, supersedes_id)
      |> Ash.Changeset.force_change_attribute(
        :content_sha256,
        SettingsRevision.content_sha256(kind, value)
      )

    if kind == :operational_limits, do: raised(changeset, value, current), else: changeset
  end

  defp raised(changeset, value, current) do
    previous =
      case current do
        %{operational_limits: %{} = limits} -> limits
        nil -> CodeDefaults.current(:operational_limits).content
      end

    raised =
      Safeguards.limit_fields()
      |> Enum.filter(&(Map.fetch!(value, &1) > Map.fetch!(previous, &1)))
      |> Enum.sort()

    confirmed = changeset |> Ash.Changeset.get_argument(:confirm_raised) |> Enum.sort()

    if confirmed == raised,
      do: Ash.Changeset.force_change_attribute(changeset, :raised_fields, raised),
      else: error(changeset, :confirm_raised, :mismatch)
  end

  defp lock_current(tenant_id, kind) do
    tenant_id
    |> current_query(kind)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read_one()
  end

  @doc false
  # The latest committed revision number of a kind (0 when none), read in
  # its own statement.
  def latest_number(tenant_id, kind) do
    case tenant_id |> current_query(kind) |> Ash.read_one() do
      {:ok, %{number: number}} -> number
      _none -> 0
    end
  end

  defp current_query(tenant_id, kind) do
    SettingsRevision
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and kind == ^kind)
    |> Ash.Query.sort(number: :desc)
    |> Ash.Query.limit(1)
  end

  # Keys other than `field` and `message` become the error's vars.
  defp error(changeset, field, rule, vars \\ []) do
    Ash.Changeset.add_error(
      changeset,
      [field: field, message: "is invalid (%{rule})", rule: rule] ++ vars
    )
  end
end
