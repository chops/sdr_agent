defmodule SdrAgent.EndpointPortConfigTest do
  @moduledoc """
  The HTTP port the endpoint really listens on, after `config/runtime.exs`:
  development defaults to the project's Phoenix port 4120
  (`.workflow/project-facts.md`, `config/dev.exs`), `PORT` overrides it, and
  the test endpoint keeps its own port.
  """
  # Reads and sets the process environment (PORT).
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("PORT")

    on_exit(fn ->
      if previous, do: System.put_env("PORT", previous), else: System.delete_env("PORT")
    end)

    System.delete_env("PORT")
    :ok
  end

  defp http_port(env) do
    base = Config.Reader.read!("config/config.exs", env: env, target: :host)
    runtime = Config.Reader.read!("config/runtime.exs", env: env, target: :host)

    base
    |> Config.Reader.merge(runtime)
    |> get_in([:sdr_agent, SdrAgentWeb.Endpoint, :http, :port])
  end

  test "development listens on the project port 4120 when PORT is unset" do
    assert http_port(:dev) == 4120
  end

  test "PORT overrides the development port" do
    System.put_env("PORT", "4122")
    assert http_port(:dev) == 4122
  end

  test "the test endpoint keeps its configured port when PORT is unset" do
    assert http_port(:test) == 4002
  end
end
