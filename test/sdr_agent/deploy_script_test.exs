defmodule SdrAgent.DeployScriptTest do
  @moduledoc """
  `scripts/deploy.sh` (the hosted deployment, Codex I3): it parses
  (`bash -n`), and its env-file check (`env_semantic_check`, run on the host
  against /run/secrets/sdr-agent/env before migrations) compares the file
  with the reviewed non-secret expectations — PHX_HOST, SDR_ANCHOR_SINKS,
  the DATABASE_URL socket directory, a non-empty SDR_LOGIN_ALLOWLIST,
  SDR_MODEL_PROVIDER unset or fake, SDR_BIND_IP unset or 127.0.0.1, a small
  POOL_SIZE and exactly the known keys — printing key names and ok/FAIL
  only, never a value. Every value here is synthetic.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/deploy.sh", __DIR__)

  @good [
    {"DATABASE_URL",
     "ecto://sdr_agent@localhost/sdr_agent_prod?socket_dir=/run/sdr-agent-postgresql"},
    {"SECRET_KEY_BASE", "synthetic-secret-key-base-0123456789"},
    {"TOKEN_SIGNING_SECRET", "synthetic-token-signing-secret-0123"},
    {"PHX_HOST", "sdr.a-z.bot"},
    {"POOL_SIZE", "5"},
    {"SDR_ANCHOR_SINKS", "none"},
    {"POSTMARK_API_KEY", "synthetic-postmark-api-key-0123"},
    {"SDR_MAIL_FROM", "SDR Agent <sign-in@example.test>"},
    {"SDR_LOGIN_ALLOWLIST", "owner@example.test"},
    {"SDR_OWNER_EMAIL", "owner@example.test"}
  ]

  @checks [
    "keys",
    "PHX_HOST",
    "SDR_ANCHOR_SINKS",
    "DATABASE_URL socket_dir",
    "SDR_LOGIN_ALLOWLIST",
    "SDR_MODEL_PROVIDER",
    "SDR_BIND_IP",
    "POOL_SIZE"
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "deploy-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp bash, do: System.find_executable("bash")

  # Writes `entries` ({key, value} or {key, :unset}) as an env file, as sops
  # renders it (KEY="value"), and runs the check against it.
  defp run_check(dir, entries) do
    file = Path.join(dir, "env-#{System.unique_integer([:positive])}")

    body =
      for {key, value} <- entries, value != :unset, into: "" do
        ~s(#{key}="#{value}"\n)
      end

    File.write!(file, body)

    # Inherited variables must not stand in for the file's (unset) ones.
    env = [{"SDR_MODEL_PROVIDER", "claude_cli"}, {"SDR_BIND_IP", "0.0.0.0"}]

    System.cmd(bash(), ["-c", ~s(source "$1" && env_semantic_check "$2"), "check", @script, file],
      stderr_to_stdout: true,
      env: env
    )
  end

  defp with_value(key, value), do: List.keystore(@good, key, 0, {key, value})

  test "bash -n accepts the script" do
    assert {_output, 0} = System.cmd(bash(), ["-n", @script], stderr_to_stdout: true)
  end

  test "the reviewed hosted values pass, and the output names keys only", %{dir: dir} do
    for extra <- [[], [{"SDR_MODEL_PROVIDER", "fake"}, {"SDR_BIND_IP", "127.0.0.1"}]] do
      {output, status} = run_check(dir, @good ++ extra)

      assert status == 0, output

      for check <- @checks do
        assert output =~ "env #{check}: ok", output
      end

      for {_key, value} <- @good ++ extra, String.length(value) > 4 do
        refute String.contains?(output, value), "a value was printed"
      end
    end
  end

  test "each wrong value fails under its key name without printing the value", %{dir: dir} do
    cases = [
      {"PHX_HOST", "PHX_HOST", "example.com"},
      {"PHX_HOST", "PHX_HOST", :unset},
      {"SDR_ANCHOR_SINKS", "SDR_ANCHOR_SINKS", "git+ots"},
      {"DATABASE_URL", "DATABASE_URL socket_dir",
       "ecto://sdr_agent@localhost/sdr_agent_prod?socket_dir=/run/postgresql"},
      {"DATABASE_URL", "DATABASE_URL socket_dir",
       "ecto://sdr_agent@db.example.test/sdr_agent_prod"},
      {"DATABASE_URL", "DATABASE_URL socket_dir",
       "ecto://sdr_agent@localhost/x?socket_dir=/run/sdr-agent-postgresql&socket_dir=/tmp/elsewhere"},
      {"SDR_LOGIN_ALLOWLIST", "SDR_LOGIN_ALLOWLIST", ""},
      {"SDR_LOGIN_ALLOWLIST", "SDR_LOGIN_ALLOWLIST", " , "},
      {"SDR_MODEL_PROVIDER", "SDR_MODEL_PROVIDER", "claude_cli"},
      {"SDR_MODEL_PROVIDER", "SDR_MODEL_PROVIDER", ""},
      {"SDR_BIND_IP", "SDR_BIND_IP", "0.0.0.0"},
      {"POOL_SIZE", "POOL_SIZE", "0"},
      {"POOL_SIZE", "POOL_SIZE", "five"},
      {"POOL_SIZE", "POOL_SIZE", "500"},
      {"SECRET_KEY_BASE", "keys", :unset},
      {"RELEASE_TMP", "keys", "/tmp/elsewhere-release-tmp"}
    ]

    for {key, check, value} <- cases do
      {output, status} = run_check(dir, with_value(key, value))
      label = "#{key}=#{inspect(value)}"

      assert status != 0, "#{label} passed:\n#{output}"
      assert output =~ "env #{check}: FAIL", "#{label}:\n#{output}"
      assert output =~ key, "#{label} does not name its key:\n#{output}"

      if is_binary(value) and String.length(value) > 4,
        do: refute(String.contains?(output, value), "#{label}: the value was printed")
    end
  end
end
