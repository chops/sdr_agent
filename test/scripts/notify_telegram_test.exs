defmodule SdrAgent.Scripts.NotifyTelegramTest do
  @moduledoc """
  Hermetic tests for `bin/notify-telegram` (ADR-0006).

  The script runs as a child process against a localhost Bandit stub and a stub
  `sops` on PATH. Telegram is never contacted.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/notify-telegram", __DIR__)
  @prefix "[sdr_agent · github.com/chops/sdr_agent]"

  defmodule Stub do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test: pid, status: status, body: body}) do
      {:ok, raw, conn} = read_body(conn)
      send(pid, {:telegram_request, conn.method, conn.request_path, raw})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end

  setup context do
    tmp = Path.join(System.tmp_dir!(), "notify-telegram-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "bin"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Built at runtime so no token-shaped literal lives in the repository.
    token = "123456789:" <> String.duplicate("T", 35)
    sops = Path.join(tmp, "bin/sops")

    File.write!(
      sops,
      "#!/bin/sh\necho \"$@\" > \"#{tmp}/sops-args\"\nprintf '%s\\n' '#{token}'\n"
    )

    File.chmod!(sops, 0o755)

    recipient = Path.join(tmp, "recipient.json")

    File.write!(
      recipient,
      JSON.encode!(%{"schema_version" => 1, "chat_id" => 4242, "bot_username" => "stub_bot"})
    )

    status = Map.get(context, :stub_status, 200)
    body = Map.get(context, :stub_body, ~s({"ok":true,"result":{}}))

    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, %{test: self(), status: status, body: body}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    env = [
      {"PATH", Path.join(tmp, "bin") <> ":" <> System.get_env("PATH")},
      {"SDR_TELEGRAM_API_BASE", "http://127.0.0.1:#{port}"},
      {"SDR_TELEGRAM_RECIPIENT_FILE", recipient},
      {"SDR_NOTIFY_LOG_FILE", Path.join(tmp, "notifications.jsonl")}
    ]

    %{tmp: tmp, env: env, token: token}
  end

  defp run(args, env), do: System.cmd(@script, args, env: env, stderr_to_stdout: true)

  test "sends exactly one sendMessage with the project prefix and prints only http/ok",
       %{env: env, token: token, tmp: tmp} do
    assert {"http=200 ok=true\n", 0} = run(["milestone", "S0 ready on s0-foundation"], env)

    assert_receive {:telegram_request, "POST", path, raw}
    assert path == "/bot#{token}/sendMessage"

    payload = JSON.decode!(raw)
    assert payload["chat_id"] == 4242
    assert payload["text"] == "#{@prefix} milestone S0 ready on s0-foundation"
    refute_received {:telegram_request, _, _, _}

    assert File.read!(Path.join(tmp, "sops-args")) =~
             ~s(-d --extract ["notifications"]["telegram_bot_token"])
  end

  test "logs a sha256 of the text, never the text", %{env: env, tmp: tmp} do
    assert {_, 0} = run(["info", "secret-free status line"], env)

    [line] =
      tmp |> Path.join("notifications.jsonl") |> File.read!() |> String.split("\n", trim: true)

    entry = JSON.decode!(line)
    text = "#{@prefix} info secret-free status line"

    assert entry["kind"] == "info"
    assert entry["http"] == 200
    assert entry["ok"] == true
    assert entry["text_sha256"] == :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    refute line =~ "secret-free status line"
  end

  test "redacts token-shaped strings before sending", %{env: env, token: token} do
    github = "ghp_" <> String.duplicate("a1B2", 9)
    mixed = String.duplicate("Ab9", 12)

    assert {_, 0} = run(["stop", "leak #{token} #{github} #{mixed} sha 83f2534"], env)

    assert_receive {:telegram_request, _, _, raw}
    text = JSON.decode!(raw)["text"]
    refute text =~ token
    refute text =~ github
    refute text =~ mixed
    assert text =~ "[REDACTED]"
    assert text =~ "sha 83f2534"
  end

  test "rejects messages over 1024 bytes without sending", %{env: env} do
    assert {out, 2} = run(["info", String.duplicate("x", 1100)], env)
    assert out =~ "exceeds 1024"
    refute_received {:telegram_request, _, _, _}
  end

  test "rejects unknown kinds", %{env: env} do
    assert {out, 2} = run(["urgent", "hello"], env)
    assert out =~ "usage"
    refute_received {:telegram_request, _, _, _}
  end

  test "refuses a non-local API base override", %{env: env} do
    env =
      List.keystore(
        env,
        "SDR_TELEGRAM_API_BASE",
        0,
        {"SDR_TELEGRAM_API_BASE", "https://example.com"}
      )

    assert {out, 2} = run(["info", "hello"], env)
    assert out =~ "must be http://127.0.0.1"
  end

  test "fails closed when the recipient file is missing", %{env: env, tmp: tmp} do
    env =
      List.keystore(
        env,
        "SDR_TELEGRAM_RECIPIENT_FILE",
        0,
        {"SDR_TELEGRAM_RECIPIENT_FILE", Path.join(tmp, "absent.json")}
      )

    assert {out, 2} = run(["info", "hello"], env)
    assert out =~ "recipient file"
    refute out =~ "4242"
  end

  @tag stub_status: 401, stub_body: ~s({"ok":false,"description":"Unauthorized"})
  test "reports a rejected request as ok=false", %{env: env} do
    assert {"http=401 ok=false\n", 1} = run(["info", "hello"], env)
  end

  test "script source names no Bot API method other than sendMessage" do
    source = File.read!(@script)

    for forbidden <- ~w(getUpdates setWebhook deleteWebhook getWebhookInfo) do
      refute source =~ forbidden, "bin/notify-telegram must never reference #{forbidden}"
    end

    assert source =~ ~s(@allowed_methods ["sendMessage"])
  end
end
