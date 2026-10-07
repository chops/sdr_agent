defmodule SdrAgent.Audit.OtsRuntimeConfigTest do
  use ExUnit.Case, async: false

  setup do
    previous =
      Map.new(
        ["SDR_ANCHOR_SINKS", "DATABASE_URL", "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET"],
        &{&1, System.get_env(&1)}
      )

    System.delete_env("SDR_ANCHOR_SINKS")
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/sdr_config_test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("test-only-key-", 8))
    System.put_env("TOKEN_SIGNING_SECRET", "test-only-token-secret")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    :ok
  end

  defp sinks(env) do
    Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    |> Keyword.get(:sdr_agent, [])
    |> Keyword.get(:anchor_sinks, [])
  end

  test "dev and prod both enable Git plus OTS by default, test stays hermetic" do
    for env <- [:dev, :prod] do
      assert Enum.map(sinks(env), &elem(&1, 0)) == [:git, :ots]
    end

    assert sinks(:test) == []
  end

  test "an explicit offline override selects no sinks or the local file sink" do
    System.put_env("SDR_ANCHOR_SINKS", "none")
    assert sinks(:prod) == []
    assert sinks(:dev) == []
    System.put_env("SDR_ANCHOR_SINKS", "file")
    for env <- [:dev, :prod], do: assert(Enum.map(sinks(env), &elem(&1, 0)) == [:file])
    assert sinks(:test) == []
  end

  test "unknown override values are refused rather than enabling network sinks" do
    System.put_env("SDR_ANCHOR_SINKS", "typo")
    assert_raise RuntimeError, ~r/SDR_ANCHOR_SINKS/, fn -> sinks(:dev) end
  end

  test "the ten-minute upgrade scheduler is part of Oban config" do
    cron =
      Application.fetch_env!(:sdr_agent, Oban)[:plugins]
      |> Keyword.fetch!(Oban.Plugins.Cron)
      |> Keyword.fetch!(:crontab)

    assert {"*/10 * * * *", SdrAgent.Audit.OtsUpgradeWorker} in cron
  end
end
