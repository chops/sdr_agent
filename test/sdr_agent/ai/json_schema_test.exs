defmodule SdrAgent.AI.JsonSchemaTest do
  @moduledoc """
  Deterministic schema generation (S12 follow-up; Codex consult 689587a9).
  `SdrAgent.AI.JsonSchema.render/1` is the single generator of new JSON
  schemas, used by `Sdr.Schemas.ref/1`, `ModelProvider` (stored app request)
  and `ClaudeCLI` (stdin). It sorts only the `required` keyword of schema
  nodes. Literal data (const/default/enum/examples) and every other list
  order are kept. `ClaudeCLI.render_prompt/2` (`prompt-builder/1`) is
  unchanged, so a historical stored schema keeps its bytes.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.SDR.Schemas

  @module SdrAgent.AI.JsonSchema

  # Fresh-VM children follow the child-environment boundary: no credentials,
  # provider routing or app secrets are inherited.
  defp scrubbed_env do
    for {key, _value} <- System.get_env(),
        key =~ ~r/\A(ANTHROPIC_|CLAUDE_|SDR_|HUBSPOT|AWS_|OPENAI|OTEL_|GITHUB_|GH_)/ or
          key in ~w(DATABASE_URL SECRET_KEY_BASE TOKEN_SIGNING_SECRET SOPS_AGE_KEY_FILE),
        do: {key, nil}
  end

  defp call(function, args) do
    Code.ensure_loaded(@module)

    if function_exported?(@module, function, length(args)),
      do: apply(@module, function, args),
      else: {:error, {:not_implemented, function}}
  end

  test "field definition order does not change the rendered bytes" do
    a =
      Zoi.object(
        zeta: Zoi.string(),
        alpha: Zoi.integer(),
        mid: Zoi.object(y: Zoi.string(), b: Zoi.string())
      )

    b =
      Zoi.object(
        mid: Zoi.object(b: Zoi.string(), y: Zoi.string()),
        alpha: Zoi.integer(),
        zeta: Zoi.string()
      )

    ra = call(:render, [a])
    rb = call(:render, [b])
    assert is_map(ra), inspect(ra)
    assert Canonical.encode!(ra) == Canonical.encode!(rb)
    assert ra["required"] == ["alpha", "mid", "zeta"]
    assert ra["properties"]["mid"]["required"] == ["b", "y"]
  end

  test "every SDR purpose schema renders identically in fresh VMs" do
    ebin = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    args = Enum.flat_map(ebin, &["-pa", &1])

    code = """
    for p <- [:evidence_extraction, :reply_classification, :qualification, :outreach_proposal] do
      s = SdrAgent.AI.JsonSchema.render(SdrAgent.SDR.Schemas.for_purpose(p))
      IO.puts(SdrAgent.Audit.Canonical.sha256(s) |> Base.encode16(case: :lower))
    end
    """

    runs =
      for _ <- 1..3 do
        {out, status} =
          System.cmd(System.find_executable("elixir"), args ++ ["-e", code],
            stderr_to_stdout: true,
            env: scrubbed_env()
          )

        {status, out}
      end

    assert Enum.all?(runs, &match?({0, _}, &1)), inspect(runs)
    assert runs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
  end

  test "tuple-form items lists are traversed in order, never reordered" do
    schema = %{
      "type" => "array",
      "items" => [%{"required" => ["b", "a"]}, %{"type" => "string"}, %{"required" => ["d", "c"]}]
    }

    n = call(:normalize, [schema])
    assert is_map(n), inspect(n)

    assert n["items"] == [
             %{"required" => ["a", "b"]},
             %{"type" => "string"},
             %{"required" => ["c", "d"]}
           ]
  end

  test "render/1 returns the value; bytes and digest are Canonical over that value" do
    rendered = call(:render, [Schemas.for_purpose(:qualification)])
    assert is_map(rendered), inspect(rendered)
    assert Enum.all?(Map.keys(rendered), &is_binary/1)
    bytes = Canonical.encode!(rendered)
    assert Canonical.sha256(rendered) == :crypto.hash(:sha256, bytes)
  end

  test "normalize sorts only schema-node required sets, recursively" do
    schema = %{
      "type" => "object",
      "required" => ["b", "a", "a"],
      "properties" => %{
        "o" => %{"type" => "object", "required" => ["z", "y"]},
        "l" => %{"type" => "array", "items" => %{"required" => ["d", "c"]}},
        "t" => %{"prefixItems" => [%{"required" => ["f", "e"]}, %{"type" => "string"}]}
      },
      "$defs" => %{"x" => %{"required" => ["h", "g"]}},
      "anyOf" => [%{"required" => ["j", "i"]}, %{"required" => ["l", "k"]}],
      "additionalProperties" => %{"required" => ["n", "m"]}
    }

    n = call(:normalize, [schema])
    assert is_map(n), inspect(n)
    # sorted, no dedupe
    assert n["required"] == ["a", "a", "b"]
    assert n["properties"]["o"]["required"] == ["y", "z"]
    assert n["properties"]["l"]["items"]["required"] == ["c", "d"]
    assert hd(n["properties"]["t"]["prefixItems"])["required"] == ["e", "f"]
    assert n["$defs"]["x"]["required"] == ["g", "h"]
    # combinator order kept, branches normalized
    assert n["anyOf"] == [%{"required" => ["i", "j"]}, %{"required" => ["k", "l"]}]
    assert n["additionalProperties"]["required"] == ["m", "n"]
  end

  test "malformed or non-list required values are left as they are (no repair)" do
    for required <- [["b", 1, "a"], ["b", nil], "a", %{"a" => true}, nil, 3, true] do
      schema = %{"type" => "object", "required" => required, "items" => true}
      n = call(:normalize, [schema])
      assert is_map(n), inspect(n)
      assert n["required"] == required, inspect(required)
      assert n["items"] == true
    end

    # Boolean schemas in schema positions stay as they are.
    schema = %{"additionalProperties" => false, "properties" => %{"a" => true}, "not" => false}
    assert call(:normalize, [schema]) == schema
  end

  test "literal data and other arrays are untouched" do
    literal = %{"required" => ["b", "a"]}

    schema = %{
      "type" => "object",
      "properties" => %{
        "d" => %{"type" => "object", "default" => literal},
        "c" => %{"const" => literal},
        "e" => %{"enum" => ["z", "a", literal]},
        "x" => %{"examples" => [literal]},
        "u" => %{"x-unknown" => literal}
      },
      "oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]
    }

    n = call(:normalize, [schema])
    assert is_map(n), inspect(n)
    assert n["properties"]["d"]["default"] == literal
    assert n["properties"]["c"]["const"] == literal
    assert n["properties"]["e"]["enum"] == ["z", "a", literal]
    assert n["properties"]["x"]["examples"] == [literal]
    assert n["properties"]["u"]["x-unknown"] == literal
    assert n["oneOf"] == schema["oneOf"]
  end

  test "Schemas.ref/1 tags version 2 and hashes the rendered bytes" do
    for purpose <- [
          :evidence_extraction,
          :reply_classification,
          :qualification,
          :outreach_proposal
        ] do
      ref = Schemas.ref(purpose)
      assert ref.version == "2", inspect(purpose)
      rendered = call(:render, [Schemas.for_purpose(purpose)])
      assert ref.sha256 == Canonical.sha256(rendered), inspect(purpose)
    end
  end

  test "render_prompt/2 (prompt-builder/1) keeps the bytes of a historical unsorted schema" do
    historical = %{"type" => "object", "required" => ["score", "answer"]}

    assert ClaudeCLI.render_prompt("p", historical) ==
             "p\nReturn only one JSON object matching this schema:\n" <>
               ~s({"required":["score","answer"],"type":"object"})

    assert ClaudeCLI.prompt_builder() == "prompt-builder/1"
  end
end
