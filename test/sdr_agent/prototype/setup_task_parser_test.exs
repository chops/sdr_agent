defmodule SdrAgent.Prototype.SetupTaskParserTest do
  @moduledoc "Behavioral pure-parser checks; never launches setup or reads a seed."
  use ExUnit.Case, async: true

  alias Mix.Tasks.Sdr.Prototype.Setup

  @pins Enum.map(1..4, &String.duplicate(Integer.to_string(&1), 64))
  @dir "/synthetic/seed"
  @argv [
    "--agent",
    "codex_cli",
    "--seed-dir",
    @dir,
    "--seed-sha256",
    Enum.join(@pins, ","),
    "--mode",
    "fresh"
  ]

  test "valid flags preserve exact values and the P G C V digest order" do
    assert Setup.parse(@argv) ==
             {:ok,
              %{
                agent: "codex_cli",
                seed_dir: @dir,
                mode: :fresh,
                seed_sha256s:
                  Map.new(
                    Enum.zip([:offering_profile, :writing_guide, :campaign, :provenance], @pins)
                  ),
                auditor_credential_out: nil
              }}
  end

  test "both exact agents and reordered flags are accepted" do
    assert {:ok, %{agent: "claude_code"}} =
             Setup.parse([
               "--mode",
               "fresh",
               "--agent",
               "claude_code",
               "--seed-sha256",
               Enum.join(@pins, ","),
               "--seed-dir",
               @dir
             ])
  end

  test "missing, duplicate, unknown, positional and valueless flags refuse" do
    for argv <- [
          [],
          Enum.drop(@argv, 2),
          @argv ++ ["--agent", "codex_cli"],
          @argv ++ ["--unknown", "sentinel"],
          @argv ++ ["sentinel"],
          Enum.drop(@argv, -1),
          @argv ++ ["--auditor-credential-out", "/synthetic/out"]
        ] do
      assert Setup.parse(argv) == {:error, :invalid_arguments}
    end
  end

  test "invalid agents, modes, paths and pins refuse without normalization" do
    for {flag, value} <- [
          {"--agent", "CODEX_CLI"},
          {"--agent", " codex_cli"},
          {"--mode", "resume"},
          {"--mode", "Fresh"},
          {"--seed-dir", "relative"},
          {"--seed-dir", ""},
          {"--seed-sha256", Enum.join(Enum.take(@pins, 3), ",")},
          {"--seed-sha256", Enum.join(@pins ++ [hd(@pins)], ",")},
          {"--seed-sha256", String.duplicate("A", 64) <> "," <> Enum.join(tl(@pins), ",")},
          {"--seed-sha256", " " <> Enum.join(@pins, ",")}
        ] do
      argv =
        @argv
        |> Enum.chunk_every(2)
        |> Enum.flat_map(fn
          [^flag, _old] -> [flag, value]
          pair -> pair
        end)

      assert Setup.parse(argv) == {:error, :invalid_arguments}
    end
  end
end
