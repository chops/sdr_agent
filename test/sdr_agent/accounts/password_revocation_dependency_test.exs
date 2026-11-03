defmodule SdrAgent.Accounts.PasswordRevocationDependencyTest do
  @moduledoc """
  ADR-0008 / EEF-CVE-2026-110826: the library-generated password watcher
  checks the hash after action hooks, not before HashPasswordChange sets it.
  App-level revocation remains independently covered through Accounts APIs.
  """
  use ExUnit.Case, async: true

  alias AshAuthentication.AddOn.LogOutEverywhere.OnPasswordChange
  alias SdrAgent.Accounts.User

  test "the generated password watcher has no early changing-hash condition" do
    watchers =
      User
      |> Ash.Resource.Info.changes()
      |> Enum.filter(fn
        %{change: {OnPasswordChange, _}} -> true
        _ -> false
      end)

    assert [%{change: {OnPasswordChange, opts}, on: [:update], where: []}] = watchers
    assert Keyword.fetch!(opts, :hashed_password_field) == :hashed_password
  end
end
