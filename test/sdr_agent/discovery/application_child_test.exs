defmodule SdrAgent.Discovery.ApplicationChildTest do
  @moduledoc """
  ADR-0027 F1 (Claude backend source review at 81b4810e): the discovery
  subtree is a temporary root child. If it exhausts its own restarts, it stays
  down (search then fails closed as :unavailable) and never counts against the
  root supervisor's intensity, so it cannot stop sign-in or intake. It is not
  a root child at all while discovery is disabled.
  """
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:sdr_agent, :prospect_search_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :prospect_search_enabled, value)
        :error -> Application.delete_env(:sdr_agent, :prospect_search_enabled)
      end
    end)

    :ok
  end

  defp discovery_specs do
    SdrAgent.Application.children()
    |> Enum.map(&Supervisor.child_spec(&1, []))
    |> Enum.filter(&(&1.id == SdrAgent.Discovery.Supervisor))
  end

  test "enabled discovery is exactly one temporary root child" do
    Application.put_env(:sdr_agent, :prospect_search_enabled, true)
    assert [spec] = discovery_specs()
    assert spec.start == {SdrAgent.Discovery.Supervisor, :start_link, [[]]}
    # A spec without :restart is :permanent.
    assert Map.get(spec, :restart, :permanent) == :temporary
  end

  test "disabled discovery adds no root child" do
    Application.put_env(:sdr_agent, :prospect_search_enabled, false)
    assert [] = discovery_specs()
  end
end
