defmodule SdrAgent.Outreach.Compliance do
  @moduledoc """
  The tenant-wide compliance defaults of checklist 1.6 that are not campaign
  attributes: the compliance time zone of the daily send cap (default
  `America/Denver`, `config :sdr_agent, :compliance_timezone`) and the cap
  itself (`config :sdr_agent, :daily_send_cap`, default 25). Config can only
  lower the cap: `daily_send_cap/0` is clamped to 1..25. Quiet hours, sender
  and footer are campaign attributes (`SdrAgent.Sales.Campaign`).
  """

  @max_daily_sends 25

  @doc "The time zone whose calendar day the daily send cap counts."
  @spec timezone() :: String.t()
  def timezone, do: Application.get_env(:sdr_agent, :compliance_timezone, "America/Denver")

  @doc "The effective daily send cap: `config` clamped to 1..25."
  @spec daily_send_cap() :: pos_integer()
  def daily_send_cap do
    :sdr_agent
    |> Application.get_env(:daily_send_cap, @max_daily_sends)
    |> min(@max_daily_sends)
    |> max(1)
  end

  @doc "Seconds a claimed delivery may stay `attempting` before the sweeper calls it unknown."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds, do: Application.get_env(:sdr_agent, :delivery_stale_after_seconds, 300)
end
