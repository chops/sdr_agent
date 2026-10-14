defmodule SdrAgent.CalibrationConsole.PromptTest do
  @moduledoc """
  R0-07 slice E, row E-R5: the code-owned, synthetic calibration input,
  `calibration-prompt/1` and `calibration-output/1`. It takes no input, so
  nothing can be supplied or edited at run time; its SHA-256 commitments
  are what the evidence file records (row R11-3).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.CalibrationConsole.Prompt

  # A missing module fails as an assertion, never as a crash.
  setup do
    assert Code.ensure_loaded?(Prompt), "SdrAgent.CalibrationConsole.Prompt is not defined"
    :ok
  end

  test "the prompt reference is versioned and commits to the rendered text" do
    assert %{id: "calibration.prompt", version: "1", sha256: sha} = Prompt.prompt_ref()
    assert sha == :crypto.hash(:sha256, Prompt.render())
  end

  test "the output schema reference is versioned and commits to the canonical schema" do
    assert %{id: "calibration.output", version: "1", sha256: sha} = Prompt.schema_ref()
    assert sha == Canonical.sha256(Prompt.json_schema())
  end

  test "the input is fixed: render and the schema take no argument" do
    assert function_exported?(Prompt, :render, 0)
    refute function_exported?(Prompt, :render, 1)
    assert Prompt.render() == Prompt.render()
  end

  test "the prompt is synthetic: a fictional company, no address, email or URL" do
    text = Prompt.render()
    assert text =~ "fictional"
    refute text =~ "@"
    refute text =~ ~r{https?://}
    refute text =~ ~r/\d{3}[-. ]\d{3}[-. ]\d{4}/
  end

  test "the schema accepts a well-formed answer and refuses anything else" do
    assert {:ok, _} = Prompt.parse(%{"answer" => "blue", "confidence" => 0.5})
    assert {:error, _} = Prompt.parse(%{"answer" => "blue"})
    assert {:error, _} = Prompt.parse(%{"answer" => 1, "confidence" => 0.5})
    assert {:error, _} = Prompt.parse(%{"answer" => "blue", "confidence" => 2})
    assert {:error, _} = Prompt.parse(%{"answer" => "blue", "confidence" => -0.1})
  end

  test "confidence accepts both endpoints, 0 and 1" do
    assert {:ok, _} = Prompt.parse(%{"answer" => "blue", "confidence" => 0})
    assert {:ok, _} = Prompt.parse(%{"answer" => "blue", "confidence" => 1})
    assert {:ok, _} = Prompt.parse(%{"answer" => "blue", "confidence" => 1.0})
  end
end
