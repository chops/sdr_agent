defmodule SdrAgentWeb.HTTP2ListenerTest do
  @moduledoc """
  ADR-0008 amendment (EEF-CVE-2026-105659), decision item 2: HTTP/2 is off
  on every Bandit listener.

  `Bandit.PhoenixAdapter` hands Bandit only each scheme's list, so these
  tests check the `http:` list each configuration actually produces (test,
  dev, prod with its runtime file, the calibration console plan and the demo
  server), not a top-level key. A live check then starts Bandit with the
  test endpoint's own `http:` options on an ephemeral loopback port and
  sends the HTTP/2 prior-knowledge preface: it is not served as HTTP/2,
  while the same listener with HTTP/2 enabled answers with a SETTINGS
  frame (the positive control).
  """
  use ExUnit.Case, async: false

  alias SdrAgent.CalibrationConsole

  @off [enabled: false]
  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  defp h2(config), do: get_in(config, [:sdr_agent, SdrAgentWeb.Endpoint, :http, :http_2_options])

  describe "every listener configuration disables HTTP/2 inside its scheme list" do
    test "the test VM's endpoint" do
      http = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint)[:http]
      assert http[:http_2_options] == @off
      assert http[:port] == 4002, "the environment file still merges into the base list"
    end

    test "dev, with and without PORT" do
      assert h2(Config.Reader.read!("config/config.exs", env: :dev)) == @off

      with_env(%{"PORT" => "4999"}, fn ->
        dev =
          Config.Reader.merge(
            Config.Reader.read!("config/config.exs", env: :dev),
            Config.Reader.read!("config/runtime.exs", env: :dev)
          )

        assert h2(dev) == @off
        assert get_in(dev, [:sdr_agent, SdrAgentWeb.Endpoint, :http, :port]) == 4999
      end)
    end

    test "prod, after its runtime configuration" do
      env = %{
        "DATABASE_URL" => "ecto://u:p@localhost/x",
        "SECRET_KEY_BASE" => String.duplicate("s", 64),
        "PHX_HOST" => "example.test",
        "TOKEN_SIGNING_SECRET" => String.duplicate("t", 64),
        "PORT" => nil,
        "SDR_BIND_IP" => nil
      }

      with_env(env, fn ->
        prod =
          Config.Reader.merge(
            Config.Reader.read!("config/config.exs", env: :prod),
            Config.Reader.read!("config/runtime.exs", env: :prod)
          )

        assert h2(prod) == @off

        # The runtime list still merges in (hosted deployment: loopback only).
        assert get_in(prod, [:sdr_agent, SdrAgentWeb.Endpoint, :http, :ip]) == {127, 0, 0, 1}

        refute get_in(prod, [:sdr_agent, SdrAgentWeb.Endpoint, :https])
      end)
    end

    test "the calibration console's rebuilt listener" do
      secrets = %{
        secret_key_base: Base.encode64(:binary.copy(<<1>>, 64)),
        token_signing_secret: Base.encode64(:binary.copy(<<2>>, 64))
      }

      assert {:ok, plan} =
               :test
               |> CalibrationConsole.current()
               |> Map.put(:secrets, secrets)
               |> CalibrationConsole.plan()

      assert plan.endpoint[:http][:http_2_options] == @off
      assert plan.endpoint[:http][:port] == 4124
    end

    test "the demo server's rebuilt listener" do
      endpoint = Mix.Tasks.Sdr.Demo.Serve.endpoint([http: [port: 1]], 4122)
      assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4122, http_2_options: @off]
    end
  end

  describe "a live listener with the endpoint's options" do
    test "does not serve the HTTP/2 preface; the H2-enabled control does" do
      http = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint)[:http]
      options = Keyword.take(http, [:http_2_options])

      refute settings_frame?(first_bytes(options)), "HTTP/2 was served with HTTP/2 off"
      assert settings_frame?(first_bytes(http_2_options: [enabled: true])), "positive control"
    end
  end

  defmodule Hello do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  defp first_bytes(options) do
    {:ok, server} =
      Bandit.start_link([plug: Hello, ip: :loopback, port: 0, startup_log: false] ++ options)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, @preface)

    reply =
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> data
        {:error, _closed_or_timeout} -> <<>>
      end

    :gen_tcp.close(socket)
    Supervisor.stop(server)
    reply
  end

  # A frame header whose type byte is 0x4 (SETTINGS) on stream 0.
  defp settings_frame?(<<_length::24, 4, _flags, 0::1, 0::31, _rest::binary>>), do: true
  defp settings_frame?(_data), do: false

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, &put_var/1)

    try do
      fun.()
    after
      Enum.each(previous, &put_var/1)
    end
  end

  defp put_var({k, nil}), do: System.delete_env(k)
  defp put_var({k, v}), do: System.put_env(k, v)
end
