defmodule SdrAgent.HostedReleaseConfigTest do
  @moduledoc """
  ADR-0024 hosted build and startup configuration, evaluated as data only.
  Synthetic fixtures never start the application, Repo, endpoint or a CLI.
  These checks also run directly under ExUnit without test_helper.exs.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Operations.HostedOwners

  @fixture %{
    "SDR_PROTOTYPE" => "d237-prototype/1",
    "SDR_PROTOTYPE_INSTANCE" => "11111111-1111-4111-8111-111111111111",
    "DATABASE_URL" => "ecto://synthetic:synthetic@localhost/sdr_hosted_config_test",
    "SECRET_KEY_BASE" => String.duplicate("synthetic-only-", 8),
    "TOKEN_SIGNING_SECRET" => String.duplicate("synthetic-token-", 4),
    "PHX_HOST" => "sdr.example.test",
    "PORT" => "4199"
  }
  @optional ~w(SDR_MODEL_PROVIDER SDR_MODEL_TRANSPORT SDR_CLAUDE_CLI_BIN
                SDR_CLAUDE_CLI_TIMEOUT_MS SDR_WITNESS_STORE_ROOT PHX_SERVER
                SDR_ANCHOR_SINKS SDR_ANCHOR_FILE_DIR DNS_CLUSTER_QUERY ECTO_IPV6 POOL_SIZE)
  @keys Map.keys(@fixture) ++ @optional

  setup do
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)
    System.put_env(@fixture)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "hosted build enables only the accepted authority, without development seams" do
    config = hosted_build!()
    app = config[:sdr_agent]
    assert app[:prototype_authority_compiled] == true
    assert app[:human_authority_provider] == HostedOwners

    for key <- [:dev_routes, :seeding_allowed?, :prototype_test_seams, :claude_cli_test_seams] do
      assert app[key] in [nil, false], "hosted build enabled #{key}"
    end

    endpoint = app[SdrAgentWeb.Endpoint]
    assert endpoint[:code_reloader] in [nil, false]
    assert endpoint[:debug_errors] in [nil, false]
    assert endpoint[:watchers] in [nil, []]
    assert endpoint[:live_reload] in [nil, false]
    assert endpoint[:force_ssl][:rewrite_on] == [:x_forwarded_proto]
    assert endpoint[:http][:http_2_options][:enabled] == false
    assert config[:swoosh][:api_client] == false
  end

  test "hosted build disables content exporters and leaves witness and waits unconfigured" do
    config = hosted_build!()
    assert config[:sdr_agent][:otel_capture_content] == false
    assert config[:opentelemetry][:traces_exporter] == :none
    assert config[:opentelemetry][:processors] == []
    assert config[:opentelemetry][:span_processor] == :undefined
    assert config[:opentelemetry][:sampler] == :always_off
    assert config[:sdr_agent][SdrAgent.Agents.Witness][:store_root] == nil
    refute Keyword.has_key?(config[:sdr_agent], :remote_wait_ms)
    refute Keyword.has_key?(config[:sdr_agent], SdrAgent.Agents.ResultGate)
  end

  test "hosted keeps the remote settler and workflow queues enabled" do
    config = hosted_build!()
    oban = config[:sdr_agent][Oban]
    assert oban[:queues][:agent] > 0
    assert oban[:queues][:integration] > 0
    refute oban[:testing] in [:inline, :manual]
    {Oban.Plugins.Cron, cron} = List.keyfind(oban[:plugins], Oban.Plugins.Cron, 0)
    assert {"* * * * *", SdrAgent.Agents.RemoteSettler} in cron[:crontab]
  end

  test "hosted runtime selects remote subscription transport without a local executable" do
    config = hosted_runtime!()
    app = config[:sdr_agent]
    assert app[:model_provider] == ClaudeCLI
    assert app[:model_transport] == :remote
    assert app[ClaudeCLI] in [nil, []]

    assert app[SdrAgent.Prototype][:switch] == %{
             policy_id: @fixture["SDR_PROTOTYPE"],
             instance_id: @fixture["SDR_PROTOTYPE_INSTANCE"]
           }

    assert app[SdrAgent.Repo][:url] == @fixture["DATABASE_URL"]
    refute app[SdrAgent.Repo][:port] == 5542
    refute app[SdrAgent.Repo][:database] == "sdr_agent_prototype"
    refute app[SdrAgent.Repo][:socket_dir] == "/private/tmp/d237-pg-5542"
  end

  test "hosted runtime uses an explicit HTTPS origin and loopback-only listener" do
    config = hosted_runtime!()
    endpoint = config[:sdr_agent][SdrAgentWeb.Endpoint]
    assert endpoint[:url] == [host: "sdr.example.test", port: 443, scheme: "https"]
    assert endpoint[:http][:port] == 4199
    assert endpoint[:http][:ip] == {127, 0, 0, 1}
    assert endpoint[:check_origin] == ["https://sdr.example.test"]
    assert endpoint[:secret_key_base] == @fixture["SECRET_KEY_BASE"]
    assert config[:sdr_agent][:token_signing_secret] == @fixture["TOKEN_SIGNING_SECRET"]
    assert config[:sdr_agent][:webhook_hmac][:source] == {:env, "SDR_WEBHOOK_HMAC_KEY"}
    assert config[:sdr_agent][:dns_cluster_query] == nil
  end

  test "hosted honors PHX_SERVER without enabling reload or development anchor exports" do
    System.put_env("PHX_SERVER", "true")
    System.put_env("SDR_ANCHOR_SINKS", "file")
    config = Config.Reader.merge(hosted_build!(), hosted_runtime!())
    assert config[:sdr_agent][SdrAgentWeb.Endpoint][:server] == true
    assert config[:sdr_agent][SdrAgentWeb.Endpoint][:live_reload] in [nil, false]
    assert config[:sdr_agent][:anchor_sinks] == []
  end

  for key <- ["SDR_PROTOTYPE", "SDR_PROTOTYPE_INSTANCE"] do
    test "hosted refuses partial switch without #{key}" do
      System.delete_env(unquote(key))
      assert_refusal(:switch_invalid)
    end
  end

  test "hosted requires a switch even when both selector variables are absent" do
    System.delete_env("SDR_PROTOTYPE")
    System.delete_env("SDR_PROTOTYPE_INSTANCE")
    assert_refusal(:switch_required)
  end

  for {key, value} <- [
        {"SDR_PROTOTYPE", "not-a-policy-secret-marker"},
        {"SDR_PROTOTYPE_INSTANCE", "not-a-uuid-secret-marker"}
      ] do
    test "hosted refuses invalid #{key} without echoing its value" do
      System.put_env(unquote(key), unquote(value))
      assert_refusal(:switch_invalid, unquote(value))
    end
  end

  for key <- ~w(DATABASE_URL SECRET_KEY_BASE TOKEN_SIGNING_SECRET PHX_HOST PORT),
      value <- [nil, ""] do
    test "hosted refuses #{key}=#{inspect(value)}" do
      put_environment(unquote(key), unquote(value))

      assert_refusal(:required_environment)
    end
  end

  for {key, value, code} <- [
        {"SDR_MODEL_PROVIDER", "fake", :provider_override},
        {"SDR_MODEL_PROVIDER", "claude_cli", :provider_override},
        {"SDR_MODEL_PROVIDER", "anthropic-secret-marker", :provider_override},
        {"SDR_MODEL_TRANSPORT", "local", :transport_override},
        {"SDR_MODEL_TRANSPORT", "typo", :transport_override},
        {"SDR_CLAUDE_CLI_BIN", "/synthetic-secret-marker/claude", :local_executable},
        {"SDR_WITNESS_STORE_ROOT", "/synthetic-secret-marker/witness", :witness_store},
        {"PORT", "0", :endpoint_invalid},
        {"PORT", "65536", :endpoint_invalid},
        {"PORT", "port-secret-marker", :endpoint_invalid},
        {"PHX_HOST", "https://host-secret-marker.test/path", :endpoint_invalid}
      ] do
    test "hosted refuses #{key}=#{value} with a fixed code" do
      System.put_env(unquote(key), unquote(value))
      assert_refusal(unquote(code), unquote(value))
    end
  end

  test "an explicit matching remote transport does not enable a provider override" do
    System.put_env("SDR_MODEL_TRANSPORT", "remote")
    assert hosted_runtime!()[:sdr_agent][:model_transport] == :remote
  end

  test "hosted Mix release is permanent and packages Unix entrypoints only" do
    original = Mix.env()
    on_exit(fn -> Mix.env(original) end)
    Mix.env(:hosted_prototype)
    project = SdrAgent.MixProject.project()
    assert project[:start_permanent] == true
    assert project[:elixirc_paths] == ["lib"]
    assert project[:releases][:sdr_agent][:include_executables_for] == [:unix]

    for dep <- [:tidewave, :phoenix_live_reload, :opentelemetry_exporter] do
      {^dep, _requirement, opts} = List.keyfind(project[:deps], dep, 0)
      refute :hosted_prototype in List.wrap(opts[:only])
      assert :dev in List.wrap(opts[:only])
    end
  end

  test "hosted dependency selection excludes development and test-only tools" do
    dependencies = SdrAgent.MixProject.project()[:deps]

    selected =
      for dependency <- dependencies,
          options = if(tuple_size(dependency) == 3, do: elem(dependency, 2), else: []),
          :hosted_prototype in List.wrap(Keyword.get(options, :only, :hosted_prototype)),
          do: elem(dependency, 0)

    for dependency <- [
          :tidewave,
          :usage_rules,
          :phoenix_live_reload,
          :opentelemetry_exporter,
          :sourceror,
          :credo,
          :igniter,
          :lazy_html
        ] do
      refute dependency in selected
    end

    assert :oban in selected
    assert :postgrex in selected
  end

  test "ordinary prod still compiles without prototype authority" do
    app = Config.Reader.read!("config/config.exs", env: :prod, target: :host)[:sdr_agent]
    refute app[:prototype_authority_compiled] == true
    refute app[:human_authority_provider] == HostedOwners
    refute app[:dev_routes] == true
    assert app[:model_provider] == Fake
  end

  test "ordinary prod and test still refuse the prototype switch" do
    for env <- [:prod, :test] do
      assert {:error, message} = runtime_result(env)
      assert message =~ "switch_outside_dev"
    end
  end

  test "ordinary dev and test keep hermetic provider and endpoint controls" do
    for env <- [:dev, :test] do
      System.delete_env("SDR_PROTOTYPE")
      System.delete_env("SDR_PROTOTYPE_INSTANCE")
      assert {:ok, runtime} = runtime_result(env)
      base = Config.Reader.read!("config/config.exs", env: env, target: :host)
      app = Config.Reader.merge(base, runtime)[:sdr_agent]
      assert app[:model_provider] == Fake
      assert app[:prototype_authority_compiled] == true
      if env == :test, do: assert(app[SdrAgentWeb.Endpoint][:server] == false)
    end
  end

  defp hosted_build! do
    result =
      try do
        {:ok, Config.Reader.read!("config/config.exs", env: :hosted_prototype, target: :host)}
      rescue
        error in File.Error -> {:missing_hosted_configuration, error.reason}
      end

    assert match?({:ok, _}, result), "hosted build configuration is missing"
    elem(result, 1)
  end

  defp hosted_runtime! do
    result = runtime_result(:hosted_prototype)

    assert match?({:ok, _}, result),
           "valid synthetic hosted runtime was refused"

    elem(result, 1)
  end

  defp assert_refusal(code, forbidden_value \\ nil) do
    assert {:error, message} = runtime_result(:hosted_prototype)
    assert message == "hosted_configuration_refused(#{code})"
    if forbidden_value, do: refute(message =~ forbidden_value)
  end

  defp runtime_result(env) do
    {:ok, Config.Reader.read!("config/runtime.exs", env: env, target: :host)}
  rescue
    error in RuntimeError -> {:error, Exception.message(error)}
  end

  defp put_environment(key, nil), do: System.delete_env(key)
  defp put_environment(key, value), do: System.put_env(key, value)
end
