defmodule SdrAgent.Accounts.PasswordOnlyStrategyTest do
  @moduledoc """
  ADR-0008 amendment (2026-10-31): `assent` 0.3.2 is overridden beyond the
  `< 0.3.0` cap of stable `ash_authentication` 4.x. That is acceptable only
  while no Assent-backed (OAuth2, OIDC, Apple, Google, ...) strategy exists.
  Adding one must fail here and send the change back to that ADR.
  """
  use ExUnit.Case, async: true

  alias AshAuthentication.Info
  alias SdrAgent.Accounts.User

  test "the only authentication strategy is the password strategy" do
    strategies = Info.authentication_strategies(User)

    assert Enum.map(strategies, &{&1.__struct__, &1.name}) == [
             {AshAuthentication.Strategy.Password, :password}
           ]
  end

  test "the only add-on is log-out-everywhere, which uses no Assent strategy" do
    add_ons = Info.authentication_add_ons(User)

    assert Enum.map(add_ons, &{&1.__struct__, &1.name}) == [
             {AshAuthentication.AddOn.LogOutEverywhere, :log_out_everywhere}
           ]
  end
end
