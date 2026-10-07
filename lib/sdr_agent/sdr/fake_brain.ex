defmodule SdrAgent.SDR.FakeBrain do
  @moduledoc """
  The deterministic fixture "model" behind `SdrAgent.AI.ModelProvider.Fake`
  for the SDR agent's three operations. It reads only the structured input
  the prompt was rendered from and answers like a careful model would, so
  the golden path is hermetic and reproducible (ADR-0004: Fake is the
  default). Its answers still pass through the Zoi schemas and every
  deterministic check (grounding, evidence citation) like a real model's.

    * `sdr.evidence_extraction` — every sentence of a source (the activity
      notes of a CRM record) becomes a claim quoting it verbatim; search
      snippets are rejected as duplicates of the fetched pages.
    * `sdr.qualification` — evaluates the ICP criteria against the company
      facts and the evidence (a trigger passes when a claim names one).
    * `sdr.outreach_proposal` — a short draft whose claim and
      personalization sentences are evidence claims copied verbatim.
  """

  @confidence %{
    crm_record: 0.95,
    news: 0.85,
    company_website: 0.8,
    web_page: 0.7,
    search_result: 0.5
  }

  @doc "Answers `operation` for structured `input`."
  def respond("sdr.evidence_extraction", %{sources: sources}) do
    %{claims: Enum.flat_map(sources, &claims/1)}
  end

  def respond("sdr.qualification", input), do: qualify(input)
  def respond("sdr.outreach_proposal", input), do: propose(input)

  defp claims(%{index: index, source_type: type, content: content}) do
    for sentence <- sentences(type, content) |> Enum.take(4) do
      rejected? = type == :search_result

      %{
        source: index,
        claim: sentence,
        quote: sentence,
        confidence: Map.get(@confidence, type, 0.6),
        quality: if(rejected?, do: "rejected", else: "accepted"),
        reason:
          if(rejected?,
            do: "search snippet duplicates the fetched page",
            else: "verbatim fact from a #{type} source"
          )
      }
    end
  end

  defp sentences(:crm_record, content) do
    ~r/"text":"([^"]+)"/
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
  end

  defp sentences(_type, content) do
    content
    |> String.split(~r/(?<=\.)\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.ends_with?(&1, "."))
  end

  defp qualify(%{icp: icp, company: company, contact: contact, evidence: evidence}) do
    text = Enum.map_join(evidence, " ", &String.downcase(&1.claim))

    criteria = %{
      company_size: size(company.employee_count, icp),
      industry: member(company.industry, icp.industries),
      geography: member(company.geography, icp.geographies),
      persona: persona(contact.title, icp.personas),
      trigger:
        if(Enum.any?(icp.triggers, &String.contains?(text, String.downcase(&1))),
          do: "pass",
          else: "unknown"
        )
    }

    qualified =
      criteria.company_size == "pass" and criteria.industry == "pass" and
        criteria.geography == "pass" and criteria.persona != "fail"

    passes = criteria |> Map.values() |> Enum.count(&(&1 == "pass"))

    %{
      qualified: qualified,
      score: passes * 20,
      criteria: criteria,
      confidence: 0.9,
      evidence_ids: Enum.map(evidence, & &1.id),
      reason:
        if(qualified,
          do: "Fits the ICP on size, industry and geography; #{passes} of 5 criteria pass.",
          else: "Misses the ICP: " <> misses(criteria) <> "."
        )
    }
  end

  defp size(nil, _icp), do: "unknown"

  defp size(count, %{employee_count_min: min, employee_count_max: max}),
    do: if(count >= min and count <= max, do: "pass", else: "fail")

  defp member(nil, _list), do: "unknown"
  defp member(value, list), do: if(value in list, do: "pass", else: "fail")

  defp persona(nil, _personas), do: "unknown"
  defp persona(title, personas), do: if(title in personas, do: "pass", else: "fail")

  defp misses(criteria) do
    criteria
    |> Enum.filter(fn {_key, verdict} -> verdict == "fail" end)
    |> Enum.map_join(", ", fn {key, _} -> key |> Atom.to_string() |> String.replace("_", " ") end)
  end

  defp propose(%{contact: contact, company: company, sender: sender, evidence: evidence} = input) do
    trigger = List.first(input.triggers) || hd(evidence)

    detail =
      Enum.find(evidence, &(&1.id != trigger.id and &1.claim =~ "employees")) ||
        Enum.find(evidence, &(&1.id != trigger.id)) || trigger

    body =
      "Hi #{contact.first_name},\n\n" <>
        "#{trigger.claim} #{detail.claim}\n\n" <>
        "Demo SDR helps revenue teams ramp new SDRs with researched, human-reviewed " <>
        "first touches. Would a 20-minute call next week be useful?\n\n" <>
        "Best,\n#{sender.name}"

    %{
      subject: "#{company.name}: ramping your new SDRs",
      body: body,
      angle: "Support the outbound hiring push with researched first touches",
      cta: "A 20-minute call next week",
      claims: [%{claim: trigger.claim, evidence_id: trigger.id, confidence: 0.9}],
      personalization: [%{text: detail.claim, evidence_id: detail.id}],
      risk_flags: [],
      evidence_ids: Enum.uniq([trigger.id, detail.id])
    }
  end
end
