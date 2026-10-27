defmodule SdrAgent.HostedProdConfigTest do
  @moduledoc """
  The production configuration the hosted deployment (sdr.a-z.bot) boots
  with, read from `config/config.exs` (with `prod.exs`) and
  `config/runtime.exs` under the deploy's environment keys: a Unix-socket
  database URL, the proxy port, HTTPS behind the proxy, no anchor sinks,
  the Fake model, the Postmark mailer only when `POSTMARK_API_KEY` is set,
  and no seeding flag. Every value here is a synthetic test value.
  """
  # Sets and restores process environment variables.
  use ExUnit.Case, async: false

  @hosted %{
    "DATABASE_URL" => "ecto://sdr_agent@localhost/sdr_agent_prod?socket_dir=/run/postgresql",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("t", 32),
    "PHX_HOST" => "sdr.a-z.bot",
    "PORT" => "4005",
    "POOL_SIZE" => "5",
    "SDR_ANCHOR_SINKS" => "none",
    "POSTMARK_API_KEY" => "synthetic-postmark-token",
    "SDR_MAIL_FROM" => "SDR Agent <sign-in@example.test>",
    "SDR_LOGIN_ALLOWLIST" => "owner@example.test",
    "SDR_OWNER_EMAIL" => "owner@example.test"
  }

  @unset ~w(SDR_MODEL_PROVIDER PHX_SERVER SDR_WITNESS_STORE_ROOT ECTO_IPV6 DNS_CLUSTER_QUERY SDR_BIND_IP)

  setup do
    keys = Map.keys(@hosted) ++ @unset
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    Enum.each(@unset, &System.delete_env/1)
    System.put_env(@hosted)
    :ok
  end

  defp prod_config do
    base = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
    runtime = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    Config.Reader.merge(base, runtime)
  end

  test "the database URL connects over the Unix socket directory it names" do
    repo = get_in(prod_config(), [:sdr_agent, SdrAgent.Repo])
    assert repo[:url] == @hosted["DATABASE_URL"]
    assert repo[:pool_size] == 5

    parsed = Ecto.Repo.Supervisor.parse_url(repo[:url])
    assert parsed[:socket_dir] == "/run/postgresql"

    assert {parsed[:username], parsed[:database], parsed[:password]} ==
             {"sdr_agent", "sdr_agent_prod", nil}
  end

  test "the endpoint listens on PORT and serves https://PHX_HOST behind the proxy" do
    endpoint = get_in(prod_config(), [:sdr_agent, SdrAgentWeb.Endpoint])

    assert endpoint[:http][:port] == 4005
    assert endpoint[:url] == [host: "sdr.a-z.bot", port: 443, scheme: "https"]
    assert endpoint[:secret_key_base] == @hosted["SECRET_KEY_BASE"]
    refute endpoint[:server]
    # The default origin check compares against url[:host]: https://sdr.a-z.bot.
    assert Keyword.get(endpoint, :check_origin, true) == true
    assert :x_forwarded_proto in endpoint[:force_ssl][:rewrite_on]

    System.delete_env("PORT")
    assert get_in(prod_config(), [:sdr_agent, SdrAgentWeb.Endpoint, :http, :port]) == 4000
  end

  test "the endpoint binds loopback only unless SDR_BIND_IP names another address" do
    http = get_in(prod_config(), [:sdr_agent, SdrAgentWeb.Endpoint, :http])
    assert http[:ip] == {127, 0, 0, 1}
    assert http[:port] == 4005
    # HTTP/2 stays off (ADR-0008 amendment) after the prod http options merge.
    assert http[:http_2_options] == [enabled: false]

    for {value, ip} <- [{"::1", {0, 0, 0, 0, 0, 0, 0, 1}}, {"10.0.0.2", {10, 0, 0, 2}}] do
      System.put_env("SDR_BIND_IP", value)
      assert get_in(prod_config(), [:sdr_agent, SdrAgentWeb.Endpoint, :http, :ip]) == ip
    end

    for value <- ["", "localhost", "127.0.0.1 ", "127.1", "0:0", "1.2.3.4.5"] do
      System.put_env("SDR_BIND_IP", value)
      assert_raise RuntimeError, ~r/SDR_BIND_IP/, &prod_config/0
    end
  end

  test "secrets, anchors, model and seeding are the hosted ones" do
    sdr = Keyword.fetch!(prod_config(), :sdr_agent)

    assert sdr[:token_signing_secret] == @hosted["TOKEN_SIGNING_SECRET"]
    assert sdr[:anchor_sinks] == []
    assert sdr[:model_provider] == SdrAgent.AI.ModelProvider.Fake
    refute Keyword.has_key?(sdr, :seeding_allowed?)
    # Sign-in and every session admit only SDR_LOGIN_ALLOWLIST (fail closed).
    assert sdr[:login_allowlist_enforced] == true

    for env <- [:dev, :test] do
      base = Config.Reader.read!("config/config.exs", env: env, target: :host)
      refute get_in(base, [:sdr_agent, :login_allowlist_enforced]), "#{env}"
    end

    refute Keyword.has_key?(sdr, :delivery_adapter)
  end

  test "claude_cli is refused in prod" do
    System.put_env("SDR_MODEL_PROVIDER", "claude_cli")
    assert_raise RuntimeError, ~r/refused in prod/, &prod_config/0
  end

  test "the sign-in mailer is Postmark over Req only when POSTMARK_API_KEY is set" do
    config = prod_config()

    assert get_in(config, [:sdr_agent, SdrAgent.Mailer]) == [
             adapter: Swoosh.Adapters.Postmark,
             api_key: "synthetic-postmark-token"
           ]

    assert get_in(config, [:swoosh, :api_client]) == Swoosh.ApiClient.Req

    for value <- [nil, ""] do
      if value,
        do: System.put_env("POSTMARK_API_KEY", value),
        else: System.delete_env("POSTMARK_API_KEY")

      assert get_in(prod_config(), [:sdr_agent, SdrAgent.Mailer]) == [
               adapter: Swoosh.Adapters.Local
             ]
    end
  end
end
