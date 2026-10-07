defmodule SdrAgent.Clock do
  @moduledoc """
  The single injectable UTC clock (ADR-0002, ADR-0009 "Time").

  Every persisted timestamp and every AuditEvent's `occurred_at` comes from
  `utc_now/0`; resources never call `DateTime.utc_now/0`. Each AuditEvent
  also records `source/0` (`:system_utc` or `:test_fixed`).

  Tests may `freeze/1` the clock for the calling process; tasks started by
  that process (via `$callers`) see the same frozen time.
  """

  @key {__MODULE__, :frozen}

  @doc "Current UTC time with microsecond precision."
  @spec utc_now() :: DateTime.t()
  def utc_now do
    case frozen() do
      nil -> DateTime.utc_now(:microsecond)
      %DateTime{} = fixed -> fixed
    end
  end

  @doc "Where `utc_now/0` currently takes its time from."
  @spec source() :: :system_utc | :test_fixed
  def source, do: if(frozen(), do: :test_fixed, else: :system_utc)

  @doc "Freezes the clock for this process and its callees (tests only)."
  @spec freeze(DateTime.t()) :: :ok
  def freeze(%DateTime{} = at) do
    {:ok, utc} = DateTime.shift_zone(at, "Etc/UTC")
    Process.put(@key, %{utc | microsecond: {elem(utc.microsecond, 0), 6}})
    :ok
  end

  @doc "Returns this process to the system clock."
  @spec unfreeze() :: :ok
  def unfreeze do
    Process.delete(@key)
    :ok
  end

  defp frozen do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      if pid == self(), do: Process.get(@key), else: remote_frozen(pid)
    end)
  end

  defp remote_frozen(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> dict |> List.keyfind(@key, 0, {@key, nil}) |> elem(1)
      nil -> nil
    end
  end
end
