defmodule SdrAgent.Clock do
  @moduledoc """
  The single injectable UTC clock (ADR-0002, ADR-0009 "Time").

  Every persisted timestamp and every AuditEvent's `occurred_at` comes from
  `utc_now/0`; resources never call `DateTime.utc_now/0`. Each AuditEvent
  also records `source/0` (`:system_utc` or `:test_fixed`).

  Tests may `freeze/1` the clock for the calling process; tasks started by
  that process (via `$callers`) see the same frozen time.

  In test-seam builds only (`:claude_cli_test_seams`, R0-07 packet 8.14.10),
  a process may also `follow/1` one other local process: its frozen time is
  read live on every read, after the process's own freeze and before
  `$callers`. A dead or unfrozen followed process contributes nothing, and
  `$callers` is never changed. Other builds have no `follow/1`.
  """

  @key {__MODULE__, :frozen}
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

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

  @doc "Freezes the clock for this process and its callees (tests and the dev/test demo seed)."
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

  if @test_seams do
    @follow {__MODULE__, :follow}

    @doc """
    Test-seam builds only: this process also reads `pid`'s frozen time
    (see the moduledoc). `:ok`, or `{:error, :invalid_pid}` for anything but
    a local pid, which changes nothing.
    """
    @spec follow(term()) :: :ok | {:error, :invalid_pid}
    def follow(pid) when is_pid(pid) and node(pid) == node() do
      Process.put(@follow, pid)
      :ok
    end

    def follow(_other), do: {:error, :invalid_pid}

    defp followed do
      case Process.get(@follow) do
        nil -> []
        pid -> [pid]
      end
    end
  else
    defp followed, do: []
  end

  defp frozen do
    Enum.find_value([self()] ++ followed() ++ Process.get(:"$callers", []), fn pid ->
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
