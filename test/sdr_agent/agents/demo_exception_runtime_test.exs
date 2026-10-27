defmodule SdrAgent.Agents.DemoExceptionRuntimeTest do
  @moduledoc """
  C2* slice S3 RED-1, AC2 and T-N2: the `SDR_DEMO_EXCEPTION` selector's
  value and environment parsing in `config/runtime.exs` (plan r2 §2 AC2,
  §6 `config/runtime.exs`, R6; accepted design r4, ADR-0005 C2* amendment
  item 2 "Selector").

  Unset means off, in every environment. The only accepted value is
  `c2star-demo-v4/1`, and only in `dev`, where it configures
  `config :sdr_agent, SdrAgent.Agents.DemoException, selector:
  "c2star-demo-v4/1"`. Any other value, the empty string included (R6:
  presence, not absence), and any value in `test` or `prod` refuses boot:
  reading `config/runtime.exs` raises a `RuntimeError` naming
  `SDR_DEMO_EXCEPTION`. The selector is never authority on its own; that is
  covered by the release tests, not here.

  The matrix is MIX env {dev, test, prod} × value {unset, `""`,
  `c2star-demo-v4/1`, `C2STAR-DEMO-V4/1`, `" c2star-demo-v4/1"`, `other`},
  read through `Config.Reader` as `SdrAgent.AI.ProviderRuntimeTest` does.
  `SDR_AGENT_ENV` is unset throughout: this is S3's value axis, the
  "dev, unset" row of plan r2 §11's combined matrix. S1 owns the presence
  rule outside `run` mode and the combined matrix (second merger).

  `async: false`: it sets the process environment.

  RED report labels: `control: ...` passes now and after GREEN; every other
  test fails as an assertion (behavioural: `config/runtime.exs` does not
  read `SDR_DEMO_EXCEPTION` at this head, so nothing is selected and
  nothing raises).
  """
  use ExUnit.Case, async: false

  @selector "c2star-demo-v4/1"
  @variable "SDR_DEMO_EXCEPTION"
  @envs [:dev, :test, :prod]
  @values [:unset, "", @selector, "C2STAR-DEMO-V4/1", " c2star-demo-v4/1", "other"]
  @env ~w(SDR_DEMO_EXCEPTION SDR_AGENT_ENV SDR_MODEL_PROVIDER DATABASE_URL SECRET_KEY_BASE
          TOKEN_SIGNING_SECRET)

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})

    System.delete_env(@variable)
    System.delete_env("SDR_AGENT_ENV")
    System.delete_env("SDR_MODEL_PROVIDER")
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/sdr_config_test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("test-only-key-", 8))
    System.put_env("TOKEN_SIGNING_SECRET", "test-only-token-secret")

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    :ok
  end

  # {:boots, selector} when config/runtime.exs reads cleanly, :refused when
  # it raises a RuntimeError naming the variable, otherwise {:raised, ...}.
  defp outcome(env, value) do
    put_value(value)

    try do
      {:boots, selector(env)}
    rescue
      error in RuntimeError ->
        message = Exception.message(error)
        if message =~ @variable, do: :refused, else: {:raised, RuntimeError, message}

      error ->
        {:raised, error.__struct__, Exception.message(error)}
    end
  end

  defp put_value(:unset), do: System.delete_env(@variable)

  defp put_value(value) do
    System.put_env(@variable, value)
    # The empty value must be present, not unset, for the R6 cell to mean anything.
    assert System.get_env(@variable) == value
  end

  defp selector(env) do
    base = Config.Reader.read!("config/config.exs", env: env, target: :host)
    runtime = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    config = Config.Reader.merge(base, runtime)[:sdr_agent]

    config
    |> Keyword.get(SdrAgent.Agents.DemoException, [])
    |> Keyword.get(:selector)
  end

  defp expected(_env, :unset), do: {:boots, nil}
  defp expected(:dev, @selector), do: {:boots, @selector}
  defp expected(_env, _value), do: :refused

  test "control: unset SDR_DEMO_EXCEPTION boots with the selector off in dev, test and prod" do
    for env <- @envs, do: assert(outcome(env, :unset) == {:boots, nil}, inspect(env))
  end

  test "AC2: c2star-demo-v4/1 in dev boots with the selector on" do
    assert outcome(:dev, @selector) == {:boots, @selector}
  end

  test "T-N2 (R6): the empty value is presence and refuses boot in every environment" do
    observed = for env <- @envs, into: %{}, do: {env, outcome(env, "")}
    assert observed == Map.new(@envs, &{&1, :refused})
  end

  test "T-N2: only c2star-demo-v4/1 in dev selects, only unset is silent, all else refuses boot" do
    cells = for env <- @envs, value <- @values, do: {env, value}
    observed = Map.new(cells, fn {env, value} -> {{env, value}, outcome(env, value)} end)
    wanted = Map.new(cells, fn {env, value} -> {{env, value}, expected(env, value)} end)

    assert observed == wanted
  end
end
