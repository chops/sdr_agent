defmodule SdrAgent.Sales.LocalTime do
  @moduledoc """
  Local-time arithmetic for the compliance defaults (checklist 1.6;
  ADR-0011): quiet hours, the send-quota day and follow-up due times are
  rules about a zone's wall clock, evaluated with the `tz` database
  (`Tz.TimeZoneDatabase`, IANA data compiled in, no network).

  All inputs and outputs are UTC `DateTime`s with microsecond precision
  (the project's timestamp type). A local wall time that does not exist (the
  spring-forward gap) resolves to the first instant after the gap; one that
  exists twice (the fall-back fold) resolves to the earlier instant.
  """

  @db Tz.TimeZoneDatabase

  @doc "True when `zone` is a time zone the database knows."
  @spec valid_zone?(String.t()) :: boolean()
  def valid_zone?(zone) when is_binary(zone), do: match?({:ok, _}, DateTime.now(zone, @db))
  def valid_zone?(_zone), do: false

  @doc "The wall-clock time in `zone` at instant `utc`."
  @spec local_time(DateTime.t(), String.t()) :: Time.t()
  def local_time(utc, zone), do: utc |> local(zone) |> DateTime.to_time()

  @doc "The calendar date in `zone` at instant `utc`."
  @spec local_date(DateTime.t(), String.t()) :: Date.t()
  def local_date(utc, zone), do: utc |> local(zone) |> DateTime.to_date()

  @doc """
  True when the wall time in `zone` at `utc` is inside the window
  `[start, stop)`. A window with `start > stop` wraps midnight (18:00–08:00);
  `start == stop` is empty.
  """
  @spec quiet?(DateTime.t(), String.t(), Time.t(), Time.t()) :: boolean()
  def quiet?(utc, zone, start, stop) do
    time = utc |> local(zone) |> DateTime.to_time()

    case Time.compare(start, stop) do
      :eq -> false
      :lt -> after?(time, start) and Time.compare(time, stop) == :lt
      :gt -> after?(time, start) or Time.compare(time, stop) == :lt
    end
  end

  @doc "The earliest instant strictly after `utc` whose wall time in `zone` is `time`."
  @spec next_wall_time(DateTime.t(), String.t(), Time.t()) :: DateTime.t()
  def next_wall_time(utc, zone, time) do
    today = local_date(utc, zone)
    candidate = to_utc(today, time, zone)

    if DateTime.compare(candidate, utc) == :gt,
      do: candidate,
      else: to_utc(Date.add(today, 1), time, zone)
  end

  @doc "The instant `days` local calendar days after `utc`, at the same wall time in `zone`."
  @spec add_days(DateTime.t(), integer(), String.t()) :: DateTime.t()
  def add_days(utc, days, zone) do
    local = local(utc, zone)
    to_utc(Date.add(DateTime.to_date(local), days), DateTime.to_time(local), zone)
  end

  @doc "The UTC instant of wall time `time` on local `date` in `zone` (gaps and folds resolved)."
  @spec to_utc(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def to_utc(date, time, zone) do
    case DateTime.new(date, time, zone, @db) do
      {:ok, local} -> utc(local)
      {:ambiguous, earlier, _later} -> utc(earlier)
      {:gap, _before, just_after} -> utc(just_after)
      {:error, reason} -> raise ArgumentError, "cannot resolve #{zone}: #{inspect(reason)}"
    end
  end

  defp local(utc, zone), do: DateTime.shift_zone!(utc, zone, @db)

  defp utc(local) do
    local
    |> DateTime.shift_zone!("Etc/UTC", @db)
    |> then(fn %{microsecond: {us, _}} = dt -> %{dt | microsecond: {us, 6}} end)
  end

  defp after?(time, start), do: Time.compare(time, start) != :lt
end
