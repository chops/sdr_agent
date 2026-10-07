defmodule SdrAgent.Sales.LocalTimeTest do
  @moduledoc """
  Local-time arithmetic for the compliance defaults (ADR-0011): quiet
  hours, the send-quota day and follow-up due dates in `America/Denver`,
  pinned to the 2026 DST transitions (spring forward 2026-03-08 02:00 MST,
  fall back 2026-11-01 02:00 MDT).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Sales.LocalTime

  @zone "America/Denver"
  @quiet {~T[18:00:00], ~T[08:00:00]}

  defp quiet?(utc), do: LocalTime.quiet?(utc, @zone, elem(@quiet, 0), elem(@quiet, 1))

  test "quiet hours 18:00–08:00 local, boundaries exact in winter and summer" do
    # Winter (MST, UTC-7)
    refute quiet?(~U[2026-01-06 15:00:00.000000Z])
    assert quiet?(~U[2026-01-06 14:59:59.999999Z])
    refute quiet?(~U[2026-01-07 00:59:59.999999Z])
    assert quiet?(~U[2026-01-07 01:00:00.000000Z])
    # Summer (MDT, UTC-6)
    refute quiet?(~U[2026-07-01 23:59:59.999999Z])
    assert quiet?(~U[2026-07-02 00:00:00.000000Z])
    assert quiet?(~U[2026-07-02 13:59:59.999999Z])
    refute quiet?(~U[2026-07-02 14:00:00.000000Z])
  end

  test "a window that does not wrap midnight, and an empty window" do
    refute LocalTime.quiet?(~U[2026-01-06 15:00:00Z], @zone, ~T[12:00:00], ~T[13:00:00])
    assert LocalTime.quiet?(~U[2026-01-06 19:30:00Z], @zone, ~T[12:00:00], ~T[13:00:00])
    refute LocalTime.quiet?(~U[2026-01-06 19:30:00Z], @zone, ~T[08:00:00], ~T[08:00:00])
  end

  test "the next 08:00 local across both DST transitions" do
    # 2026-03-07 20:00 MST → 2026-03-08 08:00 MDT
    assert LocalTime.next_wall_time(~U[2026-03-08 03:00:00Z], @zone, ~T[08:00:00]) ==
             ~U[2026-03-08 14:00:00.000000Z]

    # 2026-10-31 20:00 MDT → 2026-11-01 08:00 MST
    assert LocalTime.next_wall_time(~U[2026-11-01 02:00:00Z], @zone, ~T[08:00:00]) ==
             ~U[2026-11-01 15:00:00.000000Z]

    # 07:00 local → 08:00 the same local day
    assert LocalTime.next_wall_time(~U[2026-01-06 14:00:00Z], @zone, ~T[08:00:00]) ==
             ~U[2026-01-06 15:00:00.000000Z]
  end

  test "the local date and the next local midnight (the quota day)" do
    assert LocalTime.local_date(~U[2026-01-07 06:59:59.999999Z], @zone) == ~D[2026-01-06]
    assert LocalTime.local_date(~U[2026-01-07 07:00:00.000000Z], @zone) == ~D[2026-01-07]
    assert LocalTime.local_date(~U[2026-07-02 05:59:59.999999Z], @zone) == ~D[2026-07-01]
    assert LocalTime.local_date(~U[2026-07-02 06:00:00.000000Z], @zone) == ~D[2026-07-02]

    assert LocalTime.next_wall_time(~U[2026-10-31 18:00:00Z], @zone, ~T[00:00:00]) ==
             ~U[2026-11-01 06:00:00.000000Z]

    assert LocalTime.next_wall_time(~U[2026-11-01 19:00:00Z], @zone, ~T[00:00:00]) ==
             ~U[2026-11-02 07:00:00.000000Z]
  end

  test "adding local days keeps the local wall time across DST" do
    # 2026-10-30 10:00 MDT + 3 days → 2026-11-02 10:00 MST
    assert LocalTime.add_days(~U[2026-10-30 16:00:00Z], 3, @zone) ==
             ~U[2026-11-02 17:00:00.000000Z]

    # 2026-03-06 10:00 MST + 3 days → 2026-03-09 10:00 MDT
    assert LocalTime.add_days(~U[2026-03-06 17:00:00Z], 3, @zone) ==
             ~U[2026-03-09 16:00:00.000000Z]

    assert LocalTime.add_days(~U[2026-01-06 15:00:00Z], 0, @zone) ==
             ~U[2026-01-06 15:00:00.000000Z]
  end

  test "a wall time in the spring gap resolves to the first instant after it; a folded one to the earlier" do
    assert LocalTime.to_utc(~D[2026-03-08], ~T[02:30:00], @zone) ==
             ~U[2026-03-08 09:00:00.000000Z]

    assert LocalTime.to_utc(~D[2026-11-01], ~T[01:30:00], @zone) ==
             ~U[2026-11-01 07:30:00.000000Z]

    # 2026-03-05 02:30 MST + 3 days lands in the gap
    assert LocalTime.add_days(~U[2026-03-05 09:30:00Z], 3, @zone) ==
             ~U[2026-03-08 09:00:00.000000Z]
  end

  test "zones resolve through the time zone database" do
    assert LocalTime.valid_zone?("America/Denver")
    assert LocalTime.valid_zone?("Etc/UTC")
    refute LocalTime.valid_zone?("America/Nowhere")
  end
end
