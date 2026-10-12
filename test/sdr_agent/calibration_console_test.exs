defmodule SdrAgent.CalibrationConsoleTest do
  @moduledoc """
  The calibration console's plan (R0-07 §3): from the configuration of the
  test-seam build it derives the only configuration it serves with — the
  fixed `sdr_agent_calibration` database on the local devenv Postgres,
  loopback 127.0.0.1:4124, the Fake provider (no model server) and Oban
  jobs never executed — or refuses. Pure: nothing is applied, created or
  started here.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.CalibrationConsole

  @secrets %{
    secret_key_base: Base.encode64(:binary.copy(<<1>>, 64)),
    token_signing_secret: Base.encode64(:binary.copy(<<2>>, 64))
  }

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        mix_env: :test,
        test_seams?: true,
        model_provider: Fake,
        repo: [
          username: "postgres",
          password: "postgres",
          hostname: "localhost",
          port: 5520,
          database: "sdr_agent_test_r07d",
          pool: Ecto.Adapters.SQL.Sandbox,
          pool_size: 20
        ],
        endpoint: [http: [ip: {127, 0, 0, 1}, port: 4002], server: false, secret_key_base: "k"],
        oban: [testing: :manual, queues: [research: 1]],
        secrets: @secrets
      },
      overrides
    )
  end

  test "the fixed names" do
    assert CalibrationConsole.database() == "sdr_agent_calibration"
    assert CalibrationConsole.bind() == {{127, 0, 0, 1}, 4124}
  end

  describe "plan/1 accepts the test-seam build" do
    test "and always serves sdr_agent_calibration, whatever partition the test config names" do
      for database <- ["sdr_agent_test", "sdr_agent_test_r07d", "sdr_agent_dev", "x"] do
        repo = Keyword.put(base().repo, :database, database)
        assert {:ok, plan} = CalibrationConsole.plan(base(%{repo: repo}))
        assert plan.repo[:database] == "sdr_agent_calibration"
      end
    end

    test "with an ordinary pool instead of the SQL sandbox" do
      assert {:ok, plan} = CalibrationConsole.plan(base())
      assert plan.repo[:pool] == DBConnection.ConnectionPool
      assert plan.repo[:hostname] == "localhost"
      assert plan.repo[:port] == 5520
    end

    test "listening on loopback 4124 only, whatever port or address was configured" do
      for http <- [[ip: {0, 0, 0, 0}, port: 4120], [port: 0], [ip: {0, 0, 0, 0, 0, 0, 0, 0}]] do
        endpoint = Keyword.put(base().endpoint, :http, http)
        assert {:ok, plan} = CalibrationConsole.plan(base(%{endpoint: endpoint}))
        assert plan.endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4124]
        assert plan.endpoint[:server] == true
        assert plan.endpoint[:url] == [host: "127.0.0.1", port: 4124]
        assert plan.endpoint[:check_origin] == ["//127.0.0.1:4124", "//localhost:4124"]
        refute Keyword.has_key?(plan.endpoint, :https)
      end
    end

    test "with no model server and no job execution" do
      assert {:ok, plan} = CalibrationConsole.plan(base())
      assert plan.model_provider == Fake
      assert plan.model_server == :none
      assert plan.oban[:testing] == :manual
    end

    test "with the per-machine secrets, never the checked-in test ones" do
      assert {:ok, plan} = CalibrationConsole.plan(base())
      assert plan.endpoint[:secret_key_base] == @secrets.secret_key_base
      assert plan.token_signing_secret == @secrets.token_signing_secret

      refute plan.endpoint[:secret_key_base] ==
               Application.fetch_env!(:sdr_agent, SdrAgentWeb.Endpoint)[:secret_key_base]

      refute plan.token_signing_secret ==
               Application.fetch_env!(:sdr_agent, :token_signing_secret)
    end

    test "described by one plan line" do
      assert {:ok, plan} = CalibrationConsole.plan(base())

      assert CalibrationConsole.plan_line(plan) ==
               "SDR_CALIBRATION_CONSOLE sdr_agent_calibration localhost 5520 127.0.0.1 4124 " <>
                 "SdrAgent.AI.ModelProvider.Fake none"
    end
  end

  describe "check_assets/1: serve refuses dead pages" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "calibration-static-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "refuses when the LiveView bundle or the stylesheet is missing", %{dir: dir} do
      assert {:error, reason} = CalibrationConsole.check_assets(dir)
      assert reason =~ "assets/js/app.js is missing"
      assert reason =~ "mix assets.build"

      File.mkdir_p!(Path.join(dir, "assets/js"))
      File.write!(Path.join(dir, "assets/js/app.js"), "")
      assert {:error, reason} = CalibrationConsole.check_assets(dir)
      assert reason =~ "assets/css/app.css is missing"
    end

    test "accepts built assets", %{dir: dir} do
      for file <- ["assets/js/app.js", "assets/css/app.css"] do
        File.mkdir_p!(Path.dirname(Path.join(dir, file)))
        File.write!(Path.join(dir, file), "x")
      end

      assert CalibrationConsole.check_assets(dir) == :ok
    end
  end

  describe "plan/1 refuses" do
    test "any build but the test-seam build" do
      for env <- [:dev, :prod] do
        assert {:error, reason} = CalibrationConsole.plan(base(%{mix_env: env}))
        assert reason =~ "runs only the test-seam build (MIX_ENV=test)"
      end

      assert {:error, reason} = CalibrationConsole.plan(base(%{test_seams?: false}))
      assert reason =~ "runs only the test-seam build"
    end

    test "a Repo URL (it would override the fixed database)" do
      repo = Keyword.put(base().repo, :url, "ecto://u:p@localhost:5520/sdr_agent_dev")
      assert {:error, reason} = CalibrationConsole.plan(base(%{repo: repo}))
      assert reason =~ "a Repo :url is configured"
      refute reason =~ "u:p@"
    end

    test "a database host that is not local" do
      repo = Keyword.put(base().repo, :hostname, "db.example.test")
      assert {:error, reason} = CalibrationConsole.plan(base(%{repo: repo}))
      assert reason =~ "database host db.example.test is not local"
    end

    test "a database port that is not the devenv Postgres 5520" do
      repo = Keyword.put(base().repo, :port, 5432)
      assert {:error, reason} = CalibrationConsole.plan(base(%{repo: repo}))
      assert reason =~ "database port 5432 is not the devenv Postgres port 5520"
    end

    test "missing secrets, or the checked-in test secrets" do
      assert {:error, reason} = CalibrationConsole.plan(Map.delete(base(), :secrets))
      assert reason =~ "no per-machine secrets"

      checked_in = %{
        secret_key_base:
          Application.fetch_env!(:sdr_agent, SdrAgentWeb.Endpoint)[:secret_key_base],
        token_signing_secret: Application.fetch_env!(:sdr_agent, :token_signing_secret)
      }

      for secrets <- [
            checked_in,
            %{@secrets | secret_key_base: checked_in.secret_key_base},
            %{@secrets | token_signing_secret: checked_in.token_signing_secret}
          ] do
        assert {:error, reason} = CalibrationConsole.plan(base(%{secrets: secrets}))
        assert reason =~ "the checked-in test secrets"
        refute reason =~ checked_in.secret_key_base
      end
    end

    test "any model provider but the Fake (the ClaudeCLI server would start)" do
      assert {:error, reason} = CalibrationConsole.plan(base(%{model_provider: ClaudeCLI}))
      assert reason =~ "starts no model server"
    end
  end
end
