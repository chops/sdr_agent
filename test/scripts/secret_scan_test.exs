defmodule SdrAgent.Scripts.SecretScanTest do
  @moduledoc """
  The repository secret scan inside the gate (S13; checklist 4.4). CI also
  runs gitleaks on the full history (ADR-0007); this test makes
  `bin/verify` (`mix test`) fail locally too, without a network or an extra
  tool: every tracked file is scanned for unmistakable credential shapes,
  and the sops file must hold only encrypted values. The fabricated
  test shapes (`SdrAgent.Test.SecretShapes`) are assembled at run time, so no
  tracked line matches. When `gitleaks` is on `PATH` it also runs over the
  working tree with the reviewed `.gitleaksignore`.
  """
  use ExUnit.Case, async: true

  @shapes [
    private_key_pem: ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    age_secret_key: ~r/AGE-SECRET-KEY-1[0-9A-Z]{20,}/,
    anthropic_key: ~r/sk-ant-[a-z0-9]+-[A-Za-z0-9_\-]{20,}/,
    openai_key: ~r/sk-(proj-)?[A-Za-z0-9]{32,}/,
    live_secret_key: ~r/sk-live-[A-Za-z0-9]{24,}/,
    github_token: ~r/gh[pousr]_[A-Za-z0-9]{36,}/,
    aws_access_key: ~r/AKIA[0-9A-Z]{16}/,
    slack_token: ~r/xox[baprs]-[A-Za-z0-9-]{10,}/,
    telegram_bot_token: ~r/\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b/
  ]

  defp tracked_files do
    {out, 0} = System.cmd("git", ["ls-files", "-z"], stderr_to_stdout: true)

    out
    |> String.split(<<0>>, trim: true)
    |> Enum.filter(&File.regular?/1)
  end

  test "no tracked file contains a credential-shaped string" do
    findings =
      for file <- tracked_files(),
          content = File.read!(file),
          String.valid?(content),
          {name, shape} <- @shapes,
          Regex.match?(shape, content),
          do: {file, name}

    assert findings == []
  end

  test "the scan recognizes the fabricated credential shapes (self-check)" do
    [_bearer, anthropic, _password, _token, _jwt, pem] = SdrAgent.Test.SecretShapes.samples()

    for sample <- [anthropic, pem, SdrAgent.Test.SecretShapes.provider_key()] do
      assert Enum.any?(@shapes, fn {_name, shape} -> Regex.match?(shape, sample) end),
             "no shape matches a fabricated sample"
    end
  end

  test "the sops file stores only encrypted values" do
    content = File.read!("secrets/sdr_agent.sops.yaml")
    assert content =~ "sops:"

    values =
      for line <- String.split(content, "\n"),
          [_, key, value] <- [Regex.run(~r/^\s+([a-z0-9_]+):\s+(\S.*)$/, line)],
          key in ~w(ed25519_private_key key_id algorithm telegram_bot_token),
          do: value

    assert values != []
    assert Enum.all?(values, &String.starts_with?(&1, "ENC[AES256_GCM,"))
  end

  @gitleaks System.find_executable("gitleaks")
  @tag skip: is_nil(@gitleaks) && "gitleaks is not on PATH (CI runs it, ADR-0007)"
  test "gitleaks finds nothing in the working tree" do
    assert {_out, 0} =
             System.cmd(@gitleaks, ["dir", ".", "--no-banner", "--redact"],
               stderr_to_stdout: true
             )
  end
end
