defmodule SdrAgent.DependencySecurityTest do
  @moduledoc """
  Executable invariants from ADR-0008: the CI dependency audit stays blocking,
  and Ash counts string length in codepoints (the EEF-CVE-2026-82752 fix).
  """
  use ExUnit.Case, async: true

  @ci_workflow Path.expand("../../.github/workflows/ci.yml", __DIR__)

  defp ci_step(name_prefix) do
    @ci_workflow
    |> File.read!()
    |> String.split(~r/^      - name: /m)
    |> Enum.filter(&String.starts_with?(&1, name_prefix))
  end

  test "the CI dependency audit runs mix hex.audit and is not allowed to fail" do
    assert [step] = ci_step("Dependency audit")
    assert step =~ "mix hex.audit"
    refute step =~ "continue-on-error"
  end

  test "Ash string length constraints count codepoints, not graphemes" do
    assert Application.get_env(:ash, :default_string_length_count) == :codepoints
    assert Ash.Type.String.default_length_count() == :codepoints
  end
end
