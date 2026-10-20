defmodule SdrAgent.SDR.AdmissionInputTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 G (T-G1, T-G2): the admission input hash,
  version 1 (packet section 5.2). `doc` always carries every v1 key (absent
  values are `null`); normalization runs in the packet's order: reject
  non-UTF-8, Unicode NFC, trim, collapse internal whitespace runs in `name`,
  `first_name`, `last_name`, `title`, `industry` and `geography`, empty
  string to null, the domain through `company/1` (canonical), the email
  trimmed and lowercased, `website_url` trimmed only, `timezone` as given,
  uuids lowercased. `input_sha256 = lowercase hex
  sha256(SdrAgent.Audit.Canonical.encode(doc))`.

  RED form: `SdrAgent.SDR.Admission.Input` and `SdrAgent.SDR.admit_lead/2`
  do not exist on main; every test asserts their presence (`C3-02:`
  messages) before any call and calls them through `apply/3`.

  Each vector pins its expected document literally, its canonical JSON
  bytes (in a comment) and its sha256. The literal hashes were computed
  with main's `SdrAgent.Audit.Canonical.encode/1` over the literal expected
  documents (and re-hashed over the recorded bytes with `shasum -a 256`);
  they are not an independent implementation of `sdr-canonical-json/1`.

  Interface names chosen here for review:
    * `SdrAgent.SDR.Admission.Input.normalize(input, tenant_id)` returns
      `{:ok, doc}` with string keys and string or null leaves, or
      `{:error, {:invalid, [field]}}` naming the leaf field (`:domain`,
      `:email`, `:first_name`, `:employee_count`);
    * `SdrAgent.SDR.Admission.Input.sha256(doc)` returns the 64-character
      lowercase hex digest;
    * `SdrAgent.SDR.bootstrap_definitions/1` and `SdrAgent.SDR.admit_lead/2`
      as in the RED-2 brief; the stored hash is `admission.input_sha256`.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SettingsFixtures

  @input SdrAgent.SDR.Admission.Input
  @sdr SdrAgent.SDR
  @admission SdrAgent.Sales.LeadAdmission

  # Uppercase on purpose: uuids are lowercased by rule (7).
  @tenant_id "0192A6C4-3B1E-7F21-9C3D-5E6F7A8B9C0D"
  @campaign_id "0192A6C4-3B1E-7F21-9C3D-5E6F7A8B9C1E"

  # Every field, every normalization step: NFC (decomposed "e" + U+0301),
  # trim, whitespace collapse (tab, newlines), empty and blank to null,
  # canonical domain (one "www.", one trailing dot, case), email lowercase,
  # website_url trimmed only (case kept), readmit defaulted to false.
  @manual_full_input %{
    source_kind: :manual,
    source_ref: "manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c2f",
    campaign_id: @campaign_id,
    company: %{
      domain: " WWW.Acme-Freight.Test. ",
      name: "  Acme \t Freight\n\n Logistics  ",
      website_url: "  https://acme-freight.test/About  ",
      industry: " Logistics   Software ",
      employee_count: 120,
      geography: "   "
    },
    person: %{
      email: "  Jo.Doe@Acme-Freight.TEST ",
      first_name: " Renée ",
      last_name: "Doe  Smith",
      title: "",
      timezone: "America/Denver"
    }
  }

  # {"agent_run_id":null,"campaign_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e","company":{"domain":"acme-freight.test","employee_count":120,"geography":null,"industry":"Logistics Software","name":"Acme Freight Logistics","website_url":"https://acme-freight.test/About"},"original_lead_id":null,"person":{"email":"jo.doe@acme-freight.test","first_name":"Renée","last_name":"Doe Smith","timezone":"America/Denver","title":null},"readmit":false,"source_kind":"manual","source_ref":"manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c2f","tenant_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d","v":"c3-admission-input/1"}
  @manual_full_doc %{
    "v" => "c3-admission-input/1",
    "tenant_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d",
    "campaign_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e",
    "source_kind" => "manual",
    "source_ref" => "manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c2f",
    "readmit" => false,
    "agent_run_id" => nil,
    "original_lead_id" => nil,
    "company" => %{
      "domain" => "acme-freight.test",
      "name" => "Acme Freight Logistics",
      "website_url" => "https://acme-freight.test/About",
      "industry" => "Logistics Software",
      "employee_count" => 120,
      "geography" => nil
    },
    "person" => %{
      "email" => "jo.doe@acme-freight.test",
      "first_name" => "Renée",
      "last_name" => "Doe Smith",
      "title" => nil,
      "timezone" => "America/Denver"
    }
  }
  @manual_full_sha "5faf58d6967b93597087086f538817d4219417bae13666499b646b4c2dd0c1f3"

  # Only the required fields, plus readmit: true (manual only); every absent
  # optional field is null in the document.
  @manual_minimal_input %{
    source_kind: :manual,
    source_ref: "manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c6d",
    campaign_id: @campaign_id,
    readmit: true,
    company: %{domain: "acme-freight.test", name: "Acme Freight"},
    person: %{email: "jo.doe@acme-freight.test", first_name: "Jo", last_name: "Doe"}
  }

  # {"agent_run_id":null,"campaign_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e","company":{"domain":"acme-freight.test","employee_count":null,"geography":null,"industry":null,"name":"Acme Freight","website_url":null},"original_lead_id":null,"person":{"email":"jo.doe@acme-freight.test","first_name":"Jo","last_name":"Doe","timezone":null,"title":null},"readmit":true,"source_kind":"manual","source_ref":"manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c6d","tenant_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d","v":"c3-admission-input/1"}
  @manual_minimal_doc %{
    "v" => "c3-admission-input/1",
    "tenant_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d",
    "campaign_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e",
    "source_kind" => "manual",
    "source_ref" => "manual:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c6d",
    "readmit" => true,
    "agent_run_id" => nil,
    "original_lead_id" => nil,
    "company" => %{
      "domain" => "acme-freight.test",
      "name" => "Acme Freight",
      "website_url" => nil,
      "industry" => nil,
      "employee_count" => nil,
      "geography" => nil
    },
    "person" => %{
      "email" => "jo.doe@acme-freight.test",
      "first_name" => "Jo",
      "last_name" => "Doe",
      "title" => nil,
      "timezone" => nil
    }
  }
  @manual_minimal_sha "8de3aedc6733141a7c2bb47151675747a7df48252f186d8febe982c626dbdcab"

  # agent_found: the run uuid lowercased, a subdomain kept distinct,
  # employee_count 0 kept (integer >= 0).
  @agent_found_input %{
    source_kind: :agent_found,
    source_ref:
      "agent_found:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c3a:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c4b",
    campaign_id: @campaign_id,
    agent_run_id: "0192A6C4-3B1E-7F21-9C3D-5E6F7A8B9C3A",
    company: %{domain: "Sales.Acme-Freight.Test", name: "Acme Freight Sales", employee_count: 0},
    person: %{
      email: "Sam.Roe@acme-freight.test",
      first_name: "Sam",
      last_name: "Roe",
      timezone: "Europe/Berlin"
    }
  }

  # {"agent_run_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c3a","campaign_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e","company":{"domain":"sales.acme-freight.test","employee_count":0,"geography":null,"industry":null,"name":"Acme Freight Sales","website_url":null},"original_lead_id":null,"person":{"email":"sam.roe@acme-freight.test","first_name":"Sam","last_name":"Roe","timezone":"Europe/Berlin","title":null},"readmit":false,"source_kind":"agent_found","source_ref":"agent_found:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c3a:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c4b","tenant_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d","v":"c3-admission-input/1"}
  @agent_found_doc %{
    "v" => "c3-admission-input/1",
    "tenant_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d",
    "campaign_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e",
    "source_kind" => "agent_found",
    "source_ref" =>
      "agent_found:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c3a:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c4b",
    "readmit" => false,
    "agent_run_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c3a",
    "original_lead_id" => nil,
    "company" => %{
      "domain" => "sales.acme-freight.test",
      "name" => "Acme Freight Sales",
      "website_url" => nil,
      "industry" => nil,
      "employee_count" => 0,
      "geography" => nil
    },
    "person" => %{
      "email" => "sam.roe@acme-freight.test",
      "first_name" => "Sam",
      "last_name" => "Roe",
      "title" => nil,
      "timezone" => "Europe/Berlin"
    }
  }
  @agent_found_sha "5e6776ae9079dd68b3ab5f6658f730084ade864af318bcbee5fbd3ee21b8641b"

  # csv: an example.org company, an uppercase email, a collapsed geography.
  @csv_input %{
    source_kind: :csv,
    source_ref: "csv:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c5c:7",
    campaign_id: @campaign_id,
    company: %{domain: "Orbit.Example.Org", name: "Orbit", geography: "  North   America "},
    person: %{email: "PAT@EXAMPLE.ORG", first_name: "Pat", last_name: "Lee"}
  }

  # {"agent_run_id":null,"campaign_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e","company":{"domain":"orbit.example.org","employee_count":null,"geography":"North America","industry":null,"name":"Orbit","website_url":null},"original_lead_id":null,"person":{"email":"pat@example.org","first_name":"Pat","last_name":"Lee","timezone":null,"title":null},"readmit":false,"source_kind":"csv","source_ref":"csv:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c5c:7","tenant_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d","v":"c3-admission-input/1"}
  @csv_doc %{
    "v" => "c3-admission-input/1",
    "tenant_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d",
    "campaign_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e",
    "source_kind" => "csv",
    "source_ref" => "csv:0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c5c:7",
    "readmit" => false,
    "agent_run_id" => nil,
    "original_lead_id" => nil,
    "company" => %{
      "domain" => "orbit.example.org",
      "name" => "Orbit",
      "website_url" => nil,
      "industry" => nil,
      "employee_count" => nil,
      "geography" => "North America"
    },
    "person" => %{
      "email" => "pat@example.org",
      "first_name" => "Pat",
      "last_name" => "Lee",
      "title" => nil,
      "timezone" => nil
    }
  }
  @csv_sha "86f3e191f290332abbef377e30dcb93e47e531d7208689a027ffe86590780ab5"

  # hubspot: NFC of a decomposed umlaut ("u" + U+0308), a collapsed title.
  @hubspot_input %{
    source_kind: :hubspot,
    source_ref: "hubspot:123456:789",
    campaign_id: @campaign_id,
    company: %{domain: "orbit.example.org", name: "Orbit"},
    person: %{
      email: "kim.muller@orbit.example.org",
      first_name: "Kim",
      last_name: "Müller",
      title: "  VP   Operations "
    }
  }

  # {"agent_run_id":null,"campaign_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e","company":{"domain":"orbit.example.org","employee_count":null,"geography":null,"industry":null,"name":"Orbit","website_url":null},"original_lead_id":null,"person":{"email":"kim.muller@orbit.example.org","first_name":"Kim","last_name":"Müller","timezone":null,"title":"VP Operations"},"readmit":false,"source_kind":"hubspot","source_ref":"hubspot:123456:789","tenant_id":"0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d","v":"c3-admission-input/1"}
  @hubspot_doc %{
    "v" => "c3-admission-input/1",
    "tenant_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c0d",
    "campaign_id" => "0192a6c4-3b1e-7f21-9c3d-5e6f7a8b9c1e",
    "source_kind" => "hubspot",
    "source_ref" => "hubspot:123456:789",
    "readmit" => false,
    "agent_run_id" => nil,
    "original_lead_id" => nil,
    "company" => %{
      "domain" => "orbit.example.org",
      "name" => "Orbit",
      "website_url" => nil,
      "industry" => nil,
      "employee_count" => nil,
      "geography" => nil
    },
    "person" => %{
      "email" => "kim.muller@orbit.example.org",
      "first_name" => "Kim",
      "last_name" => "Müller",
      "title" => "VP Operations",
      "timezone" => nil
    }
  }
  @hubspot_sha "b9e2edea090921a888a4893b6e0ac480b4faad532f34cdf0c58da06ab185ca25"

  @vectors [
    {"manual, every field", @manual_full_input, @manual_full_doc, @manual_full_sha},
    {"manual, minimal, readmit", @manual_minimal_input, @manual_minimal_doc, @manual_minimal_sha},
    {"agent_found", @agent_found_input, @agent_found_doc, @agent_found_sha},
    {"csv", @csv_input, @csv_doc, @csv_sha},
    {"hubspot", @hubspot_input, @hubspot_doc, @hubspot_sha}
  ]

  @doc_keys ~w(agent_run_id campaign_id company original_lead_id person readmit source_kind
               source_ref tenant_id v)
  @company_keys ~w(domain employee_count geography industry name website_url)
  @person_keys ~w(email first_name last_name timezone title)

  describe "T-G1 hash vectors" do
    test "T-G1 normalize/2 builds the pinned v1 document for each vector" do
      present!(@input, :normalize, 2)

      for {label, input, doc, _sha} <- @vectors do
        assert call(@input, :normalize, [input, @tenant_id]) == {:ok, doc},
               "C3-02: normalized document of #{label}"
      end
    end

    test "T-G1 sha256/1 is the pinned lowercase hex sha256 of the canonical encoding" do
      present!(@input, :sha256, 1)

      for {label, _input, doc, sha} <- @vectors do
        assert call(@input, :sha256, [doc]) == sha, "C3-02: input_sha256 of #{label}"
        # The pins agree with main's encoder over the literal document.
        assert hex(:crypto.hash(:sha256, Canonical.encode!(doc))) == sha
      end
    end

    test "T-G1 every document has exactly the v1 keys, absent values null" do
      present!(@input, :normalize, 2)

      for {label, input, _doc, _sha} <- @vectors do
        result = call(@input, :normalize, [input, @tenant_id])
        assert match?({:ok, %{}}, result), "C3-02: #{label} must normalize"
        {:ok, doc} = result
        assert doc |> Map.keys() |> Enum.sort() == @doc_keys
        assert doc["company"] |> Map.keys() |> Enum.sort() == @company_keys
        assert doc["person"] |> Map.keys() |> Enum.sort() == @person_keys
        assert doc["v"] == "c3-admission-input/1"
      end
    end

    test "T-G1 equivalent submissions hash equal; a changed value hashes differently" do
      present!(@input, :normalize, 2)
      present!(@input, :sha256, 1)

      equivalent =
        @manual_full_input
        |> put_in([:company, :domain], "acme-freight.test")
        |> put_in([:company, :name], "Acme Freight Logistics")
        |> put_in([:company, :geography], nil)
        |> put_in([:person, :email], "JO.DOE@acme-freight.test")
        |> put_in([:person, :first_name], "Renée")
        |> put_in([:person, :last_name], " Doe Smith ")
        |> put_in([:person, :title], nil)
        |> Map.put(:readmit, false)

      assert digest(equivalent, @tenant_id) == @manual_full_sha
      assert digest(@manual_full_input, String.downcase(@tenant_id)) == @manual_full_sha

      changed = [
        put_in(@manual_full_input, [:person, :first_name], "Renee"),
        put_in(@manual_full_input, [:company, :website_url], "https://acme-freight.test/about"),
        put_in(@manual_full_input, [:company, :employee_count], 121),
        put_in(@manual_full_input, [:company, :domain], "sales.acme-freight.test"),
        Map.put(@manual_full_input, :readmit, true)
      ]

      for input <- changed do
        refute digest(input, @tenant_id) == @manual_full_sha
      end

      refute digest(@manual_full_input, Ecto.UUID.generate()) == @manual_full_sha
    end

    test "T-G1 invalid input is refused naming the field only" do
      present!(@input, :normalize, 2)

      refused = [
        {put_in(@manual_full_input, [:company, :domain], "www.www.acme-freight.test"), :domain},
        {put_in(@manual_full_input, [:company, :domain], "www.test"), :domain},
        {put_in(@manual_full_input, [:company, :domain], "acme-freight.test.."), :domain},
        {put_in(@manual_full_input, [:person, :first_name], <<0xFF, 0xFE>>), :first_name},
        {put_in(@manual_full_input, [:company, :employee_count], -1), :employee_count},
        {update_in(@manual_full_input, [:person], &Map.delete(&1, :email)), :email}
      ]

      for {input, field} <- refused do
        assert call(@input, :normalize, [input, @tenant_id]) == {:error, {:invalid, [field]}},
               "C3-02: #{field} must be refused"
      end
    end
  end

  describe "T-G2 stored hash = replay key" do
    setup do
      tenant = bootstrap!()
      admin = human(:admin, tenant)
      campaign = SalesFixtures.active_campaign!(tenant)
      SettingsFixtures.save_offering!(admin)
      %{tenant: tenant, admin: admin, campaign: campaign}
    end

    test "T-G2 the stored input_sha256 is the v1 hash and the key a replay matches", ctx do
      present!(@sdr, :admit_lead, 2)
      present!(@input, :sha256, 1)
      definitions!(ctx.tenant)
      n = SalesFixtures.unique()
      ref = "manual:#{Ecto.UUID.generate()}"
      domain = "replay-#{n}.test"

      input = %{
        source_kind: :manual,
        source_ref: ref,
        campaign_id: String.upcase(ctx.campaign.id),
        company: %{domain: "WWW.#{domain}.", name: "  Replay   Co #{n} "},
        person: %{email: " Ann.#{n}@#{domain} ", first_name: "Ann", last_name: "Lee"}
      }

      expected = %{
        "v" => "c3-admission-input/1",
        "tenant_id" => ctx.tenant.id,
        "campaign_id" => ctx.campaign.id,
        "source_kind" => "manual",
        "source_ref" => ref,
        "readmit" => false,
        "agent_run_id" => nil,
        "original_lead_id" => nil,
        "company" => %{
          "domain" => domain,
          "name" => "Replay Co #{n}",
          "website_url" => nil,
          "industry" => nil,
          "employee_count" => nil,
          "geography" => nil
        },
        "person" => %{
          "email" => "ann.#{n}@#{domain}",
          "first_name" => "Ann",
          "last_name" => "Lee",
          "title" => nil,
          "timezone" => nil
        }
      }

      sha = hex(:crypto.hash(:sha256, Canonical.encode!(expected)))
      first = admitted!(input, ctx.admin)
      assert first.admission.input_sha256 == sha
      assert call(@input, :sha256, [expected]) == sha
      assert stored_sha(first.admission.id) == sha

      equivalent =
        input
        |> Map.put(:campaign_id, ctx.campaign.id)
        |> put_in([:company, :domain], domain)
        |> put_in([:company, :name], "Replay Co #{n}")
        |> put_in([:person, :email], "ANN.#{n}@#{String.upcase(domain)}")

      for replay_input <- [input, equivalent] do
        result = call(@sdr, :admit_lead, [replay_input, [actor: ctx.admin]])
        assert match?({:ok, %{replayed?: true}}, result), "C3-02: replay: #{short(result)}"
        {:ok, replay} = result
        assert replay.admission.id == first.admission.id
        assert replay.admission.input_sha256 == sha
      end

      assert stored_sha(first.admission.id) == sha
      assert admissions_for(ref) == 1
    end
  end

  ## Guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp digest(input, tenant_id) do
    result = call(@input, :normalize, [input, tenant_id])
    assert match?({:ok, %{}}, result), "C3-02: normalize: #{short(result)}"
    {:ok, doc} = result
    call(@input, :sha256, [doc])
  end

  defp definitions!(tenant) do
    result = call(@sdr, :bootstrap_definitions, [tenant.id])
    assert match?({:ok, _}, result), "C3-02: bootstrap_definitions/1: #{short(result)}"
    {:ok, definition} = result
    definition
  end

  defp admitted!(input, actor) do
    result = call(@sdr, :admit_lead, [input, [actor: actor]])
    assert match?({:ok, %{outcome: :admitted}}, result), "C3-02: admit_lead: #{short(result)}"
    {:ok, value} = result
    value
  end

  defp stored_sha(admission_id) do
    assert Code.ensure_loaded?(@admission), "C3-02: #{inspect(@admission)} is not available"

    %{rows: [[sha]]} =
      Repo.query!("SELECT input_sha256 FROM lead_admissions WHERE id = $1", [
        Ecto.UUID.dump!(admission_id)
      ])

    sha
  end

  defp admissions_for(ref) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM lead_admissions WHERE source_ref = $1", [ref])

    n
  end

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)
end
