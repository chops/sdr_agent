defmodule SdrAgent.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SdrAgent.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SdrAgent.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import SdrAgent.DataCase
    end
  end

  setup tags do
    SdrAgent.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags. A module whose tests can hold
  the connection longer than the pool's default 120 s ownership timeout
  under load tags `ownership_timeout:` (milliseconds); otherwise the owner
  is disconnected and the shared mode reverts to `:manual` mid-test (#177).
  """
  def setup_sandbox(tags) do
    opts = [shared: not tags[:async]] ++ ownership_timeout(tags[:ownership_timeout])
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SdrAgent.Repo, opts)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  defp ownership_timeout(nil), do: []
  defp ownership_timeout(ms) when is_integer(ms) and ms > 0, do: [ownership_timeout: ms]

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
