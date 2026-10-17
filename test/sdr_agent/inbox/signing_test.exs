defmodule SdrAgent.Inbox.SigningTest do
  @moduledoc "Stateless cursor/freshness signing reads configuration, not a running web endpoint."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures

  alias SdrAgent.Inbox.Cursor
  alias SdrAgentWeb.Endpoint

  test "a configured-secret cursor signs and continues while the web endpoint is stopped", ctx do
    for _ <- 1..3, do: failure!(ctx)
    token = session!(ctx.admin)
    secret = Application.fetch_env!(:sdr_agent, Endpoint)[:secret_key_base]
    :ok = Supervisor.terminate_child(SdrAgent.Supervisor, Endpoint)
    on_exit(fn -> assert {:ok, _} = Supervisor.restart_child(SdrAgent.Supervisor, Endpoint) end)
    assert Process.whereis(Endpoint) == nil

    assert {:ok, first} = safe_refresh(token, limit: 1)
    assert is_binary(first.next_cursor)

    assert {:ok, {scope, _key}} =
             Phoenix.Token.verify(secret, "c1-inbox-cursor/1", first.next_cursor, max_age: 86_400)

    assert scope == Cursor.scope(ctx.admin)
    assert {:ok, second} = safe_refresh(token, limit: 1, cursor: first.next_cursor)
    refute hd(first.items).subject_ref.id == hd(second.items).subject_ref.id
  end

  test "missing or invalid signing configuration fails closed after authentication", ctx do
    failure!(ctx)
    token = session!(ctx.admin)
    previous = Application.fetch_env!(:sdr_agent, Endpoint)
    on_exit(fn -> Application.put_env(:sdr_agent, Endpoint, previous) end)

    for config <- [
          nil,
          [],
          [secret_key_base: nil],
          [secret_key_base: "short"],
          [secret_key_base: 123]
        ] do
      if config,
        do: Application.put_env(:sdr_agent, Endpoint, config),
        else: Application.delete_env(:sdr_agent, Endpoint)

      assert {:error, :forbidden} = safe_refresh("invalid-session", limit: 0)
      assert {:error, :producer_error} = safe_refresh(token)
    end
  end

  defp safe_refresh(token, opts \\ []) do
    refresh(token, opts)
  rescue
    error -> {:unexpected_error, error.__struct__}
  end
end
