defmodule SdrAgentWeb.GrantForm do
  @moduledoc """
  The admin page's model-call budget form (C9-05): pure functions between
  the form's string params and the terms `SdrAgent.Agents.create_grant/2`
  and `SdrAgent.Agents.update_grant_terms/3` take.

    * Wall times are entered in America/Denver (`zone/0`) and converted to
      UTC explicitly with the IANA database (`Tz.TimeZoneDatabase`). A wall
      time in the fall-back fold resolves to the earlier instant, as
      `SdrAgent.Sales.LocalTime` does, and the review step says so; one in
      the spring-forward gap does not exist and is refused.
    * Profiles, allocation keys and buckets are matched against the reviewed
      closed sets (`ModelCallGrant.real_profiles/0`,
      `ModelCallAllocation.keys/0`, `ModelCallAllocation.buckets/0`); input
      never creates an atom.
    * An edit is the exact difference from the loaded grant (`changes/2`),
      sent with the loaded grant's `revision` as `expected_revision`
      (`update_attrs/2`), so a form opened before someone else's change is
      refused by the domain instead of overwriting it.

  Only the shape of the input is checked here (required fields, numbers,
  times, known values, repeated key/profile pairs). The domain validates the
  terms themselves (window order, positive limits, the allocation sum,
  profile membership) and `SdrAgentWeb.AdminLive` shows its errors inline.
  """

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant

  @zone "America/Denver"
  @db Tz.TimeZoneDatabase
  @grant_terms [
    :name,
    :purpose,
    :profile_ids,
    :total_attempts,
    :per_utc_day_attempts,
    :starts_at,
    :expires_at
  ]
  @allocation_terms [:applies_to, :attempts, :available_from, :available_until]
  @set_fields [:profile_ids, :applies_to]

  @doc "The zone budget times are entered and shown in."
  def zone, do: @zone

  @doc "The reviewed real profiles a grant may name."
  def profiles, do: ModelCallGrant.real_profiles()

  @doc "The allocation keys."
  def keys, do: ModelCallAllocation.keys()

  @doc "The usage buckets an allocation may fund."
  def buckets, do: ModelCallAllocation.buckets()

  @doc "The grant terms an edit may change, in display order."
  def grant_terms, do: @grant_terms

  @doc "Empty params for a new grant."
  def new_params do
    %{
      "name" => "",
      "purpose" => "",
      "profile_ids" => [],
      "total_attempts" => "",
      "per_utc_day_attempts" => "",
      "starts_at" => "",
      "expires_at" => "",
      "allocations" => %{}
    }
  end

  @doc "Params showing `grant`'s current terms (times as Denver wall times); rows are indexed 0..n-1."
  def params_for(%ModelCallGrant{} = grant) do
    allocations =
      grant.allocations
      |> sort_allocations()
      |> Enum.with_index()
      |> Map.new(fn {allocation, index} ->
        {Integer.to_string(index), allocation_params(allocation)}
      end)

    %{
      "name" => grant.name,
      "purpose" => grant.purpose,
      "profile_ids" => Enum.map(grant.profile_ids, &Atom.to_string/1),
      "total_attempts" => int_param(grant.total_attempts),
      "per_utc_day_attempts" => int_param(grant.per_utc_day_attempts),
      "starts_at" => local_param(grant.starts_at),
      "expires_at" => local_param(grant.expires_at),
      "allocations" => allocations
    }
  end

  @doc "Allocations in a stable display order: by key, then profile."
  def sort_allocations(allocations) do
    Enum.sort_by(allocations, fn allocation ->
      {Enum.find_index(keys(), &(&1 == allocation.key)), to_string(allocation.profile_id)}
    end)
  end

  @doc "Appends an empty allocation row."
  def add_allocation(params) do
    rows = allocation_map(params)
    next = rows |> Map.keys() |> Enum.map(&index_of/1) |> Enum.max(fn -> -1 end) |> Kernel.+(1)
    Map.put(params, "allocations", Map.put(rows, Integer.to_string(next), blank_allocation()))
  end

  @doc "Removes the allocation row `index`."
  def remove_allocation(params, index),
    do: Map.put(params, "allocations", Map.delete(allocation_map(params), index))

  @doc "The allocation rows as `{index, row}`, in row order."
  def allocation_rows(params),
    do: params |> allocation_map() |> Enum.sort_by(fn {index, _row} -> index_of(index) end)

  defp allocation_map(params) do
    case Map.get(params, "allocations") do
      rows when is_map(rows) -> rows
      _other -> %{}
    end
  end

  defp blank_allocation do
    %{
      "key" => "",
      "profile_id" => "",
      "applies_to" => [],
      "attempts" => "",
      "available_from" => "",
      "available_until" => ""
    }
  end

  defp allocation_params(allocation) do
    %{
      "key" => Atom.to_string(allocation.key),
      "profile_id" =>
        if(allocation.profile_id, do: Atom.to_string(allocation.profile_id), else: ""),
      "applies_to" => Enum.map(allocation.applies_to, &Atom.to_string/1),
      "attempts" => int_param(allocation.attempts),
      "available_from" => local_param(allocation.available_from),
      "available_until" => local_param(allocation.available_until)
    }
  end

  defp index_of(index) when is_binary(index) do
    case Integer.parse(index) do
      {n, ""} -> n
      _other -> -1
    end
  end

  defp index_of(_index), do: -1

  ## Parsing

  @doc """
  The stored instants of `grant` an edit form shows, keyed `{:grant, field}`
  and `{:allocation, key, profile_id, field}`, for `parse/2`. A Denver wall
  time does not name one instant (the fall-back hour occurs twice) and the
  form shows no microseconds, so an untouched time field must keep the
  stored instant rather than be parsed again.
  """
  def originals(%ModelCallGrant{} = grant) do
    grant_times = Enum.map([:starts_at, :expires_at], &{{:grant, &1}, Map.get(grant, &1)})

    allocation_times =
      for allocation <- grant.allocations, field <- [:available_from, :available_until] do
        {{:allocation, allocation.key, allocation.profile_id, field}, Map.get(allocation, field)}
      end

    (grant_times ++ allocation_times)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  The stored instant (from `originals/1`) behind an allocation row's
  `field`, matched by the row's key and profile; nil for a new row.
  """
  def row_original(originals, row, field) do
    with {:ok, key} when not is_nil(key) <- choice(row["key"], keys()),
         {:ok, profile_id} <- choice(row["profile_id"], profiles()) do
      Map.get(originals, {:allocation, key, profile_id, field})
    else
      _unknown -> nil
    end
  end

  @doc """
  Parses form params into grant terms: `{:ok, terms}` (with `:allocations`,
  each carrying its row `:index`, and `:notes` for the review step) or
  `{:error, errors}`, a map from field (or `{:allocation, index}`) to
  messages. With an edit's `originals` (`originals/1`), a time field whose
  value is still exactly what the form showed for its stored instant keeps
  that instant (to the microsecond, in either half of the fall-back hour);
  only a changed time is parsed.
  """
  def parse(params, originals \\ %{}) when is_map(params) do
    acc =
      params
      |> grant_results(originals)
      |> Enum.reduce(%{terms: %{}, errors: %{}, notes: []}, &put_result/2)
      |> parse_allocations(Map.get(params, "allocations") || %{}, originals)

    if acc.errors == %{},
      do: {:ok, Map.put(acc.terms, :notes, Enum.reverse(acc.notes))},
      else: {:error, acc.errors}
  end

  defp grant_results(params, originals) do
    [
      name: required(text(params["name"])),
      purpose: required(text(params["purpose"])),
      profile_ids: choices(params["profile_ids"], profiles(), "includes an unknown profile"),
      total_attempts: required(integer(params["total_attempts"])),
      per_utc_day_attempts: integer(params["per_utc_day_attempts"]),
      starts_at:
        required(wall_time(params["starts_at"], "Starts", originals[{:grant, :starts_at}])),
      expires_at:
        required(wall_time(params["expires_at"], "Expires", originals[{:grant, :expires_at}]))
    ]
  end

  defp put_result({field, {:ok, value}}, acc), do: put_in(acc, [:terms, field], value)

  defp put_result({field, {:ok, value, note}}, acc),
    do: %{put_in(acc, [:terms, field], value) | notes: [note | acc.notes]}

  defp put_result({field, {:error, message}}, acc), do: add_error(acc, field, message)

  defp add_error(acc, field, message),
    do:
      update_in(
        acc,
        [:errors],
        &Map.update(&1, field, [message], fn list -> list ++ [message] end)
      )

  defp parse_allocations(acc, rows, originals) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> index_of(index) end)
    |> Enum.reduce(Map.put(acc, :allocations, []), &parse_allocation(&1, &2, originals))
    |> finish_allocations()
  end

  defp parse_allocations(acc, _rows, _originals),
    do: add_error(acc, :allocations, "must be a list of rows")

  defp parse_allocation({index, row}, acc, originals) when is_map(row) do
    original = &row_original(originals, row, &1)

    results = [
      key: required(choice(row["key"], keys())),
      profile_id: choice(row["profile_id"], profiles()),
      applies_to: choices(row["applies_to"], buckets(), "includes an unknown bucket"),
      attempts: required(integer(row["attempts"])),
      available_from:
        wall_time(
          row["available_from"],
          "Allocation available from",
          original.(:available_from)
        ),
      available_until:
        wall_time(
          row["available_until"],
          "Allocation available until",
          original.(:available_until)
        )
    ]

    acc = %{acc | allocations: [%{index: index} | acc.allocations]}
    Enum.reduce(results, acc, &put_allocation_result(&1, &2, index))
  end

  defp parse_allocation({index, _row}, acc, _originals),
    do: add_error(acc, {:allocation, index}, "is not an allocation row")

  defp put_allocation_result({field, {:ok, value}}, acc, _index),
    do: put_allocation(acc, field, value)

  defp put_allocation_result({field, {:ok, value, note}}, acc, _index),
    do: %{put_allocation(acc, field, value) | notes: [note | acc.notes]}

  defp put_allocation_result({field, {:error, message}}, acc, index),
    do: add_error(acc, {:allocation, index}, "#{label(field)} #{message}")

  defp put_allocation(%{allocations: [current | rest]} = acc, field, value),
    do: %{acc | allocations: [Map.put(current, field, value) | rest]}

  defp finish_allocations(acc) do
    allocations = Enum.reverse(acc.allocations)
    pairs = Enum.map(allocations, &{&1[:key], &1[:profile_id]})
    acc = %{Map.delete(acc, :allocations) | terms: Map.put(acc.terms, :allocations, allocations)}

    if length(Enum.uniq(pairs)) == length(pairs),
      do: acc,
      else: add_error(acc, :allocations, "lists the same key and profile more than once")
  end

  defp label(field), do: field |> Atom.to_string() |> String.replace("_", " ")

  defp required({:ok, nil}), do: {:error, "is required"}
  defp required(result), do: result

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  defp text(nil), do: {:ok, nil}
  defp text(_value), do: {:error, "must be text"}

  defp integer(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> parse_integer(text)
    end
  end

  defp integer(nil), do: {:ok, nil}
  defp integer(_value), do: {:error, "must be a whole number"}

  defp parse_integer(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _other -> {:error, "must be a whole number"}
    end
  end

  defp choice(value, allowed) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> known(text, allowed)
    end
  end

  defp choice(nil, _allowed), do: {:ok, nil}
  defp choice(_value, _allowed), do: {:error, "is not a known value"}

  defp known(text, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == text)) do
      nil -> {:error, "is not a known value"}
      atom -> {:ok, atom}
    end
  end

  # Checkbox groups: a hidden "" keeps an empty group in the params.
  defp choices(values, allowed, message) when is_list(values) do
    values = values |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == ""))
    names = Enum.map(allowed, &Atom.to_string/1)

    if Enum.all?(values, &(&1 in names)),
      do: {:ok, Enum.filter(allowed, &(Atom.to_string(&1) in values))},
      else: {:error, message}
  end

  defp choices(nil, _allowed, _message), do: {:ok, []}
  defp choices(_values, _allowed, message), do: {:error, message}

  # An untouched field (still the text shown for its stored instant) keeps
  # that instant; anything else is parsed as a Denver wall time.
  defp wall_time(value, label, original) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text ->
        if untouched?(text, original), do: {:ok, original}, else: parse_wall_time(text, label)
    end
  end

  defp wall_time(nil, _label, _original), do: {:ok, nil}
  defp wall_time(_value, _label, _original), do: {:error, "must be a date and time"}

  defp untouched?(_text, nil), do: false
  defp untouched?(text, %DateTime{} = original), do: text == local_param(original)

  defp parse_wall_time(text, label), do: text |> naive() |> resolve(label)

  # A datetime-local value: "YYYY-MM-DDTHH:MM" (seconds optional).
  defp naive(text) do
    text = if String.length(text) == 16, do: text <> ":00", else: text

    case NaiveDateTime.from_iso8601(text) do
      {:ok, naive} -> {:ok, %{naive | microsecond: {0, 0}}}
      {:error, _reason} -> :error
    end
  end

  defp resolve(:error, _label), do: {:error, "must be a date and time"}

  defp resolve({:ok, naive}, label) do
    case DateTime.from_naive(naive, @zone, @db) do
      {:ok, local} ->
        {:ok, to_utc(local)}

      {:ambiguous, earlier, _later} ->
        {:ok, to_utc(earlier),
         "#{label}: #{Calendar.strftime(earlier, "%b %-d, %Y %H:%M")} occurs twice in " <>
           "#{@zone} (DST ends); the earlier instant (#{earlier.zone_abbr}) is used."}

      {:gap, _before, _after} ->
        {:error, "does not exist in #{@zone} (the clocks skip it when DST starts)"}

      {:error, _reason} ->
        {:error, "must be a date and time"}
    end
  end

  defp to_utc(local) do
    utc = DateTime.shift_zone!(local, "Etc/UTC", @db)
    %{utc | microsecond: {elem(utc.microsecond, 0), 6}}
  end

  ## Attributes for the domain

  @doc "The attrs `SdrAgent.Agents.create_grant/2` takes."
  def create_attrs(terms) do
    terms
    |> Map.take(@grant_terms)
    |> Map.put(:allocations, Enum.map(terms.allocations, &allocation_attrs/1))
  end

  defp allocation_attrs(allocation),
    do: Map.take(allocation, [:key, :profile_id | @allocation_terms])

  @doc """
  What saving `terms` changes on `grant`: `%{terms: [{field, old, new}],
  allocations: [{:create, allocation} | {:update, %{key, profile_id},
  [{field, old, new}]}]}`. An allocation is matched by `{key, profile_id}`,
  as the domain matches it.
  """
  def changes(%ModelCallGrant{} = grant, terms) do
    %{
      terms: diff(grant, terms, @grant_terms),
      allocations: Enum.flat_map(terms.allocations, &allocation_change(grant, &1))
    }
  end

  defp allocation_change(grant, allocation) do
    case Enum.find(grant.allocations, &same_pair?(&1, allocation)) do
      nil ->
        [{:create, allocation_attrs(allocation)}]

      stored ->
        case diff(stored, allocation, @allocation_terms) do
          [] -> []
          diffs -> [{:update, Map.take(allocation, [:key, :profile_id]), diffs}]
        end
    end
  end

  defp same_pair?(stored, allocation),
    do: stored.key == allocation.key and stored.profile_id == allocation.profile_id

  defp diff(old, new, fields) do
    Enum.flat_map(fields, fn field ->
      before = Map.get(old, field)
      value = Map.get(new, field)
      if same?(field, before, value), do: [], else: [{field, before, value}]
    end)
  end

  defp same?(_field, %DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq

  defp same?(field, a, b) when field in @set_fields and is_list(a) and is_list(b),
    do: MapSet.new(a) == MapSet.new(b)

  defp same?(_field, a, b), do: a == b

  @doc "The attrs `SdrAgent.Agents.update_grant_terms/3` takes for `changes` of the loaded `grant`."
  def update_attrs(%ModelCallGrant{} = grant, changes) do
    attrs =
      Map.new(changes.terms, fn {field, _old, new} -> {field, new} end)
      |> Map.put(:expected_revision, grant.revision)

    case Enum.map(changes.allocations, &allocation_update/1) do
      [] -> attrs
      allocations -> Map.put(attrs, :allocations, allocations)
    end
  end

  defp allocation_update({:create, allocation}), do: allocation

  defp allocation_update({:update, pair, diffs}),
    do: Map.merge(pair, Map.new(diffs, fn {field, _old, new} -> {field, new} end))

  ## Display

  @doc """
  The UTC instant a Denver wall-time input names, for a live hint; nil when
  blank or invalid. With the field's stored `original`, an untouched value
  previews that instant (as `parse/2` keeps it).
  """
  def preview(value, original \\ nil) do
    case wall_time(value, "", original) do
      {:ok, %DateTime{} = instant} -> utc(instant)
      {:ok, %DateTime{} = instant, _note} -> utc(instant) <> " (the earlier of two)"
      _blank_or_invalid -> nil
    end
  end

  @doc "`utc` as a Denver wall time with its zone abbreviation (\"Oct 31, 2026 12:00 MDT\")."
  def denver(nil), do: "—"

  def denver(%DateTime{} = utc),
    do: utc |> DateTime.shift_zone!(@zone, @db) |> Calendar.strftime("%b %-d, %Y %H:%M %Z")

  @doc "`utc` in UTC (\"Nov 2, 2026 19:00 UTC\")."
  def utc(nil), do: "—"
  def utc(%DateTime{} = utc), do: Calendar.strftime(utc, "%b %-d, %Y %H:%M UTC")

  defp int_param(nil), do: ""
  defp int_param(n) when is_integer(n), do: Integer.to_string(n)

  defp local_param(nil), do: ""

  defp local_param(%DateTime{} = utc) do
    local = DateTime.shift_zone!(utc, @zone, @db)
    format = if local.second == 0, do: "%Y-%m-%dT%H:%M", else: "%Y-%m-%dT%H:%M:%S"
    Calendar.strftime(local, format)
  end
end
