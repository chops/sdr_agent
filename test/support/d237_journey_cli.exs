# The hermetic fake Claude CLI of the D-237 G4 journey
# (test/sdr_agent/prototype/journey_test.exs). Never a real model call.
#
# It is launched like `test/support/fake_claude_cli.exs` (`elixir <this>
# <variant>`, test launcher, `:claude_cli_test_seams` builds only) and
# answers like the CLI: one `system`/`init` event naming the reviewed model
# and version with no tools, MCP servers or slash commands, then one final
# `result` event, the only event the ClaudeCLI adapter decodes. The answer
# is built from the prompt's INPUT (the canonical JSON that
# `SdrAgent.SDR.Prompts.render/2` appends) for the three prototype
# purposes:
#
#   * evidence_extraction: every non-blank line of each source's content
#     (the bound dossier excerpts of the synthetic fixture row) becomes one
#     claim quoting that line verbatim, so grounding can accept it;
#   * qualification: argv variant "qualified" passes every criterion and
#     cites every evidence id; "disqualified" fails company size and cites
#     none;
#   * outreach_proposal: a short draft whose claim and personalization
#     sentences are evidence claims copied verbatim, with a call to action
#     the body asks verbatim, no URL and no proposed time.
#
# Synthetic fixtures only; it reads nothing but its stdin and argv.

variant = Enum.at(System.argv(), 0, "qualified")

model_arg =
  case Enum.drop_while(System.argv(), &(&1 != "--model")) do
    ["--model", model_alias | _] -> model_alias
    _ -> nil
  end

model =
  case model_arg do
    "opus" -> "claude-opus-5-5"
    "sonnet" -> "claude-sonnet-5-5"
    _ -> "claude-unreviewed"
  end

stdin = IO.read(:stdio, :eof)

input =
  case String.split(stdin, "INPUT:\n") do
    [_ | _] = parts -> parts |> List.last() |> String.trim() |> JSON.decode!()
    _ -> %{}
  end

lines = fn content ->
  content
  |> String.split("\n")
  |> Enum.reject(&(String.trim(&1) == ""))
end

answer =
  cond do
    String.contains?(stdin, "You are the research analyst") ->
      claims =
        for source <- Map.get(input, "sources", []),
            line <- source |> Map.get("content", "") |> lines.() |> Enum.take(6) do
          search? = source["source_type"] == "search_result"

          %{
            "source" => source["index"],
            "claim" => line,
            "quote" => line,
            "confidence" => 0.8,
            "quality" => if(search?, do: "rejected", else: "accepted"),
            "reason" =>
              if(search?,
                do: "search snippet duplicates the fetched page",
                else: "verbatim excerpt of the bound dossier source"
              )
          }
        end

      %{"claims" => claims}

    String.contains?(stdin, "You qualify a sales lead") ->
      evidence_ids = input |> Map.get("evidence", []) |> Enum.map(& &1["id"])

      if variant == "qualified" do
        %{
          "qualified" => true,
          "score" => 80,
          "criteria" => %{
            "company_size" => "pass",
            "industry" => "pass",
            "geography" => "pass",
            "persona" => "pass",
            "trigger" => "pass"
          },
          "confidence" => 0.7,
          "evidence_ids" => evidence_ids,
          "reason" => "the accepted size and location evidence fits the criteria"
        }
      else
        %{
          "qualified" => false,
          "score" => 10,
          "criteria" => %{
            "company_size" => "fail",
            "industry" => "unknown",
            "geography" => "unknown",
            "persona" => "unknown",
            "trigger" => "unknown"
          },
          "confidence" => 0.6,
          "evidence_ids" => [],
          "reason" => "the accepted size evidence is outside the criteria"
        }
      end

    String.contains?(stdin, "You draft a short, honest first-touch sales email") ->
      evidence = Map.get(input, "evidence", [])
      trigger = List.first(Map.get(input, "triggers", [])) || hd(evidence)
      detail = Enum.find(evidence, &(&1["id"] != trigger["id"])) || trigger
      first_name = get_in(input, ["contact", "first_name"]) || "there"
      sender = get_in(input, ["sender", "name"]) || ""
      company = get_in(input, ["company", "name"]) || "your team"
      cta = "Would it help to compare notes on how your team handles this today?"

      body =
        "Hi #{first_name},\n\n" <>
          "#{trigger["claim"]} #{detail["claim"]}\n\n" <>
          cta <> "\n\n" <> "Best,\n#{sender}"

      %{
        "subject" => "#{company}: a quick question",
        "body" => body,
        "angle" => "Connect the observed evidence to the offering",
        "cta" => cta,
        "claims" => [
          %{"claim" => trigger["claim"], "evidence_id" => trigger["id"], "confidence" => 0.8}
        ],
        "personalization" => [%{"text" => detail["claim"], "evidence_id" => detail["id"]}],
        "risk_flags" => [],
        "evidence_ids" => Enum.uniq([trigger["id"], detail["id"]])
      }

    true ->
      %{}
  end

IO.puts(
  JSON.encode!(%{
    "type" => "system",
    "subtype" => "init",
    "model" => model,
    "claude_code_version" => "2.1.294",
    "tools" => [],
    "mcp_servers" => [],
    "slash_commands" => []
  })
)

IO.puts(
  JSON.encode!(%{
    "type" => "result",
    "subtype" => "success",
    "is_error" => false,
    "result" => JSON.encode!(answer),
    "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
  })
)
