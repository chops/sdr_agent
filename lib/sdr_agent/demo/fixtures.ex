defmodule SdrAgent.Demo.Fixtures do
  @moduledoc """
  The fictional demo data set (checklist 1.5–1.6; build plan step 1): one
  ICP, a two-touch sequence, one campaign with the compliance defaults, ten
  companies with one contact and one lead each, and three operators (admin,
  reviewer, auditor). Every id and every timestamp is fixed, every domain
  and email is under `.test` (ADR-0009 synthetic-data guard), and no row
  names a real person or company.

  Designated outcomes for later slices (S2 allows them only with their own
  records, so the seed creates every lead as `new`):

    * `expected_outcome: :qualify` / `:disqualify` — accounts whose fixture
      research (S7) fits or misses the ICP (size, industry or geography);
    * `:suppressed` — the account whose contact (`suppressed_contact_emails/0`)
      S8 seeds a Suppression for, so the send gate refuses it.

  The operator passwords below are demo-only test values for local dev/test
  databases; seeding is refused anywhere else.
  """

  @epoch ~U[2026-01-05 15:00:00.000000Z]

  @doc "The fixed instant all seeded timestamps derive from."
  def epoch, do: @epoch

  @doc "The singleton tenant the seed bootstraps (if absent)."
  def tenant, do: [slug: "demo", name: "Demo Tenant"]

  @doc "Demo operators: one per role."
  def users do
    [
      %{
        id: "61a43b0c-0a3c-474b-934c-85bfc76c0a0c",
        email: "admin@example.test",
        display_name: "Demo Admin",
        role: :admin,
        password: "demo-admin-password"
      },
      %{
        id: "e7ba3553-1427-4c47-9ccb-de252301db9e",
        email: "reviewer@example.test",
        display_name: "Demo Reviewer",
        role: :reviewer,
        password: "demo-reviewer-password"
      },
      %{
        id: "3c774f99-d2d7-4d21-9a8e-1d67597991ad",
        email: "auditor@example.test",
        display_name: "Demo Auditor",
        role: :auditor,
        password: "demo-auditor-password"
      }
    ]
  end

  @doc "The demo ICP (activated by the seed)."
  def icp do
    %{
      id: "019b8eac-1180-7ff1-9506-a1b83d48d2b4",
      name: "Mid-market logistics software",
      version: 1,
      description: "Fictional demo ICP: North American logistics software companies of 50–500.",
      criteria: %{
        employee_count_min: 50,
        employee_count_max: 500,
        industries: ["logistics software", "supply chain SaaS"],
        geographies: ["US", "Canada"],
        personas: ["VP Operations", "Head of Revenue Operations"],
        triggers: ["hiring SDRs", "recent funding"]
      }
    }
  end

  @doc "The demo sequence (activated by the seed after its steps)."
  def sequence,
    do: %{id: "019b8eac-1180-7709-9193-2233d0ef4696", name: "Demo two-touch email", version: 1}

  @doc "The sequence's steps: an initial email and one follow-up."
  def sequence_steps do
    [
      %{
        id: "019b8eac-1180-7b76-9047-896de264a180",
        position: 1,
        channel: :email,
        delay_days: 0,
        instructions:
          "Introduce Demo SDR in two short paragraphs; cite one verified fact about the company."
      },
      %{
        id: "019b8eac-1180-729b-b26a-533843d0c993",
        position: 2,
        channel: :email,
        delay_days: 3,
        instructions: "Brief follow-up to the first email; offer one concrete next step."
      }
    ]
  end

  @doc "The demo campaign (Tier 0, compliance defaults; activated by the seed)."
  def campaign do
    %{
      id: "019b8eac-1180-7203-b70d-0594e9071b19",
      name: "Demo outreach — mid-market logistics",
      icp_definition_id: icp().id,
      sequence_id: sequence().id,
      sender_name: "Demo SDR",
      sender_email: "sdr@example.test",
      timezone: "America/Denver",
      quiet_hours_start: ~T[18:00:00],
      quiet_hours_end: ~T[08:00:00],
      footer_template_version: "footer/1"
    }
  end

  # {key, account id, contact id, lead id, company, domain, industry, size,
  #  geography, expected outcome, contact first, last, title, timezone}
  @companies [
    {"01", "019b8eac-1180-7ded-ba65-3f8113ecf70e", "019b8eac-1180-7a5f-aafe-f27b368a52a5",
     "019b8eac-1180-74d8-9f38-54127081d946", "Brightpath Freight Systems",
     "brightpath-freight.test", "logistics software", 180, "US", :qualify, "Avery", "Lindqvist",
     "VP Operations", "America/Denver"},
    {"02", "019b8eac-1180-720e-af2d-9aec88d848e1", "019b8eac-1180-7cfc-a219-b45199aad01d",
     "019b8eac-1180-7c3d-a4ad-c369e27a97f1", "Cobalt Dock Analytics", "cobalt-dock.test",
     "supply chain SaaS", 95, "US", :qualify, "Bram", "Okafor", "Head of Revenue Operations",
     "America/Chicago"},
    {"03", "019b8eac-1180-70d8-96fe-f7fcfcd06131", "019b8eac-1180-7a92-8982-c2eb25748990",
     "019b8eac-1180-761c-9fad-f113afaa661b", "Ferngrove Fleetworks", "ferngrove-fleet.test",
     "logistics software", 320, "Canada", :qualify, "Celia", "Marchetti", "VP Operations",
     "America/Toronto"},
    {"04", "019b8eac-1180-7632-94f5-41e89fdcdc09", "019b8eac-1180-7e87-b8f3-02e787a4434b",
     "019b8eac-1180-77ee-a0ef-2345da8dc7f4", "Harborline Routing", "harborline-routing.test",
     "logistics software", 60, "US", :suppressed, "Dario", "Penn", "VP Operations",
     "America/Denver"},
    {"05", "019b8eac-1180-784e-a18d-e19e6d43c30a", "019b8eac-1180-70bf-9a54-37527fd88516",
     "019b8eac-1180-7ab2-b67c-259f956f0d59", "Juniper Crate Labs", "juniper-crate.test",
     "supply chain SaaS", 22, "US", :disqualify, "Elin", "Sato", "Founder",
     "America/Los_Angeles"},
    {"06", "019b8eac-1180-70d6-b360-f75a070626fb", "019b8eac-1180-7747-b745-7866baf041bf",
     "019b8eac-1180-77a0-85e0-3d5289a5da0b", "Kestrel Yard Goods", "kestrel-yard.test",
     "consumer retail", 140, "US", :disqualify, "Farah", "Quist", "Store Operations Lead",
     "America/New_York"},
    {"07", "019b8eac-1180-7f45-875a-d80ab9985873", "019b8eac-1180-739e-bbb5-33bba72149d9",
     "019b8eac-1180-721c-a76d-099b436b5bf6", "Lumen Pallet Co", "lumen-pallet.test",
     "logistics software", 4200, "US", :disqualify, "Gus", "Holloway", "VP Operations",
     "America/Chicago"},
    {"08", "019b8eac-1180-70eb-8373-6ce4737d4dce", "019b8eac-1180-700c-a90a-d0581fcda136",
     "019b8eac-1180-75d8-b980-dd14c3041b7e", "Marigold Cold Chain", "marigold-coldchain.test",
     "supply chain SaaS", 210, "Germany", :disqualify, "Hana", "Brecht",
     "Head of Revenue Operations", "Europe/Berlin"},
    {"09", "019b8eac-1180-77a0-be68-fa647a4ae617", "019b8eac-1180-7f6a-95b2-f694c01ea1fb",
     "019b8eac-1180-7ac2-81bb-c970986aa7be", "Northgate Parcel Tech", "northgate-parcel.test",
     "logistics software", 450, "US", :qualify, "Ivo", "Castellan", "VP Operations",
     "America/Denver"},
    {"10", "019b8eac-1180-76b4-a90a-f831e787bbb0", "019b8eac-1180-7e5a-b1df-a63b265b2524",
     "019b8eac-1180-742a-89d2-cc1ca61efd6a", "Quillmark Ledger Freight", "quillmark-ledger.test",
     "logistics software", 75, "Canada", :qualify, "June", "Talbot", "Head of Revenue Operations",
     "America/Toronto"}
  ]

  @doc "The ten fictional companies, each with its designated `expected_outcome`."
  def accounts do
    for {key, id, _contact, _lead, name, domain, industry, size, geography, outcome, _, _, _, _} <-
          @companies do
      %{
        id: id,
        name: name,
        domain: domain,
        website_url: "https://#{domain}",
        industry: industry,
        employee_count: size,
        geography: geography,
        crm_provider: :fake_crm,
        crm_external_id: "fake-crm-account-#{key}",
        source: :fixture,
        expected_outcome: outcome
      }
    end
  end

  @doc "One contact per company."
  def contacts do
    for {key, account, id, _lead, _name, domain, _, _, _, _, first, last, title, zone} <-
          @companies do
      %{
        id: id,
        account_id: account,
        first_name: first,
        last_name: last,
        email: "#{String.downcase(first)}.#{String.downcase(last)}@#{domain}",
        title: title,
        persona: title,
        timezone: zone,
        crm_external_id: "fake-crm-contact-#{key}"
      }
    end
  end

  @doc "One new lead per contact."
  def leads do
    for {_key, account, contact, id, _, _, _, _, _, _, _, _, _, _} <- @companies do
      %{id: id, contact_id: contact, account_id: account, source: :fixture}
    end
  end

  @doc "Emails S8 seeds Suppressions for (contacts of `:suppressed` accounts)."
  def suppressed_contact_emails do
    suppressed = for %{expected_outcome: :suppressed, id: id} <- accounts(), do: id
    for %{account_id: account, email: email} <- contacts(), account in suppressed, do: email
  end
end
