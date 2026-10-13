defmodule SdrAgent.CalibrationConsole.Prompt do
  @moduledoc """
  The fixed, synthetic input of a calibration call (R0-07 slice E, row
  E-R5; harness round 13, entity PASS at 094caa86): `calibration-prompt/1`
  (reference `calibration.prompt`, version 1) and `calibration-output/1`
  (reference `calibration.output`, version 1).

  The prompt is code-owned text about a fictional company; it names no real
  person, address, email or URL, and takes no input, so nothing can be
  supplied or edited at run time. The output is `{answer: string,
  confidence: number in [0, 1]}`, parsed like every model output
  (`SdrAgent.AI.ModelProvider`). `prompt_ref/0` and `schema_ref/0` are the
  id, version and SHA-256 commitments recorded on the invocation and in the
  evidence file: the SHA-256 of the rendered text, and of the canonical
  rendered JSON Schema (`SdrAgent.AI.JsonSchema.render/1`). This module is
  input only; it proves nothing about a provider or model.
  """

  alias SdrAgent.AI.JsonSchema
  alias SdrAgent.Audit.Canonical

  @version "1"

  @text """
  This is a calibration request about a fictional company, Lumen Harbor
  Tiles, invented for this test. Lumen Harbor Tiles makes ceramic tiles in
  three colours: blue, green and white. Its best-selling colour is blue.

  Question: which colour sells best at Lumen Harbor Tiles?

  Answer with JSON only: {"answer": <the colour as a lowercase word>,
  "confidence": <a number from 0 to 1>}.
  """

  @doc "`{id, version, sha256}` of the prompt: the SHA-256 of `render/0`."
  def prompt_ref,
    do: %{id: "calibration.prompt", version: @version, sha256: :crypto.hash(:sha256, render())}

  @doc "`{id, version, sha256}` of the output schema (canonical JSON Schema hash)."
  def schema_ref,
    do: %{id: "calibration.output", version: @version, sha256: Canonical.sha256(json_schema())}

  @doc """
  Every code-owned prompt commitment a calibration may have been reserved
  with, current and historical (today only version 1). Frozen evidence is
  checked against this set and its own reservation, never against the
  latest definition alone, so a later version never invalidates it.
  """
  def prompt_refs, do: [prompt_ref()]

  @doc "Every code-owned output schema commitment, current and historical (see `prompt_refs/0`)."
  def schema_refs, do: [schema_ref()]

  @doc "The fixed prompt text."
  def render, do: @text

  @doc "The output schema."
  def schema do
    Zoi.object(
      %{
        answer: Zoi.string() |> Zoi.min(1),
        confidence: Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1)
      },
      coerce: true
    )
  end

  @doc "The output schema rendered as JSON Schema."
  def json_schema, do: JsonSchema.render(schema())

  @doc "Parses a model output against the schema: `{:ok, output}` or `{:error, errors}`."
  def parse(output), do: Zoi.parse(schema(), output)
end
