defmodule SdrAgent.SDR.UnicodeEvidenceTest do
  @moduledoc """
  S7b review (Codex, PR #12) must-fix 3: evidence offsets are Unicode code
  points (S5 choice 12, `SdrAgent.Research.SourceLocation`), not graphemes.
  A source whose text contains combining marks and emoji ZWJ sequences —
  before and inside quoted sentences — is grounded through the whole flow
  and the domain check, and every stored span slices back to its quote.
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.Audit
  alias SdrAgent.Integrations.FixtureWeb
  alias SdrAgent.Research

  defmodule UnicodeWeb do
    @moduledoc false
    @behaviour SdrAgent.Integrations.WebFetch

    @prefix "Résumé of the café team: the company is hiring SDRs. " <>
              "\u{1F469}‍\u{1F4BB} Engineers é lead the platform. "

    @impl true
    def fetch(url) do
      with {:ok, page} <- FixtureWeb.fetch(url) do
        if page.source_type == :company_website,
          do: {:ok, %{page | content: @prefix <> page.content}},
          else: {:ok, page}
      end
    end
  end

  setup do
    previous = Application.get_env(:sdr_agent, :integrations)
    Application.put_env(:sdr_agent, :integrations, web: UnicodeWeb)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, :integrations, previous),
        else: Application.delete_env(:sdr_agent, :integrations)
    end)

    :ok
  end

  test "claims around combining marks and emoji sequences are grounded by code point", ctx do
    %{run: run, lead: lead} = assign!(ctx, "01")
    assert %{success: 1} = drain!()
    assert run!(ctx, run).status == :succeeded

    {:ok, claims} =
      Research.list_records(Research.EvidenceClaim, filter: [lead_id: lead.id], actor: ctx.admin)

    quotes = Enum.map(claims, & &1.quote)
    assert Enum.any?(quotes, &String.contains?(&1, "Résumé"))
    assert Enum.any?(quotes, &String.starts_with?(&1, "\u{1F469}‍\u{1F4BB}"))
    assert Enum.any?(quotes, &String.contains?(&1, "employees"))

    for claim <- claims do
      {:ok, artifact} =
        Research.fetch(Research.ResearchArtifact, claim.research_artifact_id, actor: ctx.admin)

      {:ok, content} = Audit.read_content(artifact.content_sha256, actor: ctx.admin)
      %{char_start: from, char_end: to} = claim.source_location

      assert content |> String.codepoints() |> Enum.slice(from, to - from) |> Enum.join() ==
               claim.quote
    end
  end
end
