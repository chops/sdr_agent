defmodule SdrAgent.TestSeamsConfigTest do
  @moduledoc """
  The compile-time test-seam switch `:claude_cli_test_seams` (C2* S3 plan
  r2 §10 OQ15; Codex S3-G2): every `if @test_seams` branch, including the
  demo exception's source and authorization overrides, is compiled only
  when it is true. Reading `config/config.exs` (which imports the
  environment's file) through `Config.Reader`, as
  `SdrAgent.AI.ProviderRuntimeTest` does: dev and prod leave it unset or
  false; test sets it true (the positive control).

  Compile-time configuration only: `config/runtime.exs` is not read, no
  application is started, and no environment variable is set or needed.
  The compiled dev and prod artifacts are proven separately (the seam
  evidence); this suite check guards the configuration itself.
  """
  use ExUnit.Case, async: true

  defp test_seams(env) do
    "config/config.exs"
    |> Config.Reader.read!(env: env, target: :host)
    |> Keyword.get(:sdr_agent, [])
    |> Keyword.fetch(:claude_cli_test_seams)
  end

  test "dev and prod compile-time config leave :claude_cli_test_seams unset or false" do
    for env <- [:dev, :prod] do
      seams = test_seams(env)
      assert seams in [:error, {:ok, false}], "#{env}: #{inspect(seams)}"
    end
  end

  test "control: the test compile-time config sets :claude_cli_test_seams true" do
    assert test_seams(:test) == {:ok, true}
  end
end
