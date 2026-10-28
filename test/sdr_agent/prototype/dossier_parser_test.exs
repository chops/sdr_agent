defmodule SdrAgent.Prototype.DossierParserTest do
  @moduledoc """
  IF-6 dossier parser (interfaces r6; plan r7 section 6 "Dossier / import /
  evidence"): the whole file is refused, value-free, on any schema, shape,
  text, URL, label, basis, fact or contact cross-rule violation. Synthetic
  `.test` fixtures of the exact `sdr-agent.prototype-dossier` v1 schema
  (`SdrAgent.DossierFixtures`); never a private file. Pure: no database, no
  network.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.DossierParser

  @marker "ZZQMARKERZZ"

  defp parse(dossier), do: DossierParser.parse(F.encode(dossier))

  defp refused!(result, path, rule) do
    assert result == {:error, {path, rule}},
           "expected the refusal {#{inspect(path)}, #{inspect(rule)}}, got #{inspect(result)}"

    refute inspect(result) =~ @marker, "the refusal echoed a value"
  end

  # A refusal whose rule belongs to the shared BoundedJson layer (S1): the
  # shape is {path, rule} and no value is echoed.
  defp bounded_refusal!(result) do
    assert match?({:error, {path, rule}} when is_binary(path) and is_atom(rule), result),
           "expected a value-free {path, rule} refusal, got #{inspect(result)}"

    refute inspect(result) =~ @marker, "the refusal echoed a value"
  end

  defp c(i \\ 1, overrides \\ %{}), do: F.company(i, overrides)

  describe "a valid dossier" do
    test "parses, with every company in file order" do
      assert match?(
               {:ok,
                %{
                  "schema_version" => 1,
                  "companies" => [%{"row_id" => "row-1"}, %{"row_id" => "row-2"}]
                }},
               parse(F.dossier([c(1), c(2)]))
             )
    end

    test "a company-only row (contact null, no_named_person) is representable" do
      row = c(2, %{"importable" => false, "skip_reason" => "no_named_person", "contact" => nil})

      assert match?(
               {:ok, %{"companies" => [_, %{"contact" => nil}]}},
               parse(F.dossier([c(1), row]))
             )
    end

    test "unflagged rows keep their declared skip reasons" do
      rows =
        for {reason, i} <- Enum.with_index(~w(role_mailbox link_unconfirmed not_selected), 2) do
          c(i, %{"importable" => false, "skip_reason" => reason})
          |> F.put(
            ["contact", "email_kind"],
            if(reason == "role_mailbox", do: "role_mailbox", else: "personal_work")
          )
        end

      assert match?({:ok, %{"companies" => [_, _, _, _]}}, parse(F.dossier([c(1) | rows])))
    end

    test "LF and TAB are allowed in why_fit and excerpts" do
      row =
        c(1)
        |> Map.put("why_fit", "Line one.\n\tLine two.")
        |> F.put(["facts", 2, "excerpt"], "We build routing software\nfor freight brokers.")

      assert match?({:ok, _}, parse(F.dossier([row])))
    end
  end

  describe "schema and shape" do
    test "a wrong schema or schema_version is refused" do
      refused!(
        parse(Map.put(F.dossier(), "schema", "sdr-agent.prototype-dossier-" <> @marker)),
        "schema",
        :schema
      )

      refused!(
        parse(Map.put(F.dossier(), "schema_version", 2)),
        "schema_version",
        :schema_version
      )
    end

    test "a missing or extra key is refused without naming the key" do
      refused!(parse(F.dossier([Map.delete(c(), "why_fit")])), "companies[0]", :missing_key)
      refused!(parse(F.dossier([Map.put(c(), @marker, 1)])), "companies[0]", :unknown_key)

      refused!(
        parse(F.dossier([F.update(c(), ["contact"], &Map.put(&1, @marker, nil))])),
        "companies[0].contact",
        :unknown_key
      )

      refused!(
        parse(F.dossier([F.update(c(), ["contact", "evidence"], &Map.put(&1, "phone", nil))])),
        "companies[0].contact.evidence",
        :unknown_key
      )
    end

    test "a null where the schema shows none is refused" do
      refused!(parse(F.dossier([Map.put(c(), "name", nil)])), "companies[0].name", :null)

      refused!(
        parse(F.dossier([F.put(c(), ["contact", "role"], nil)])),
        "companies[0].contact.role",
        :null
      )

      refused!(
        parse(F.dossier([F.put(c(), ["contact", "evidence", "name"], nil)])),
        "companies[0].contact.evidence.name",
        :null
      )
    end

    test "a closed enum outside its set is refused" do
      refused!(
        parse(F.dossier([F.put(c(), ["contact", "classification"], "verified")])),
        "companies[0].contact.classification",
        :enum
      )

      refused!(
        parse(F.dossier([F.put(c(), ["facts", 0, "kind"], "rumour")])),
        "companies[0].facts[0].kind",
        :enum
      )

      refused!(
        parse(F.dossier([F.put(c(), ["sources", 0, "source_type"], "blog")])),
        "companies[0].sources[0].source_type",
        :enum
      )
    end

    test "more than 15 companies is refused" do
      refused!(parse(F.dossier(for i <- 1..16, do: c(i))), "companies", :count)
    end

    test "a repeated JSON key is refused at any depth, value-free" do
      bin = F.encode(F.dossier())

      top =
        String.replace(bin, ~s("schema_version":1), ~s("schema_version":1,"schema_version":1),
          global: false
        )

      bounded_refusal!(DossierParser.parse(top))

      nested =
        String.replace(
          bin,
          ~s("confidence":"high"),
          ~s("confidence":"high","confidence":"#{@marker}"),
          global: false
        )

      assert nested != bin
      bounded_refusal!(DossierParser.parse(nested))
    end

    test "invalid UTF-8 is refused" do
      bin =
        String.replace(F.encode(F.dossier()), "Head of Growth", <<"Head of ", 0xFF, 0xFE>>,
          global: false
        )

      bounded_refusal!(DossierParser.parse(bin))
    end

    test "a nested container deeper than the schema's depth 7 is refused" do
      dir = F.scratch_dir!()
      artifact = F.artifact!(dir, "page.txt", "Jordan Testperson: jordan@acme1.test")
      deep = F.put(c(), ["contact", "evidence", "email", "artifact"], artifact)
      result = parse(F.dossier([deep]))
      assert match?({:ok, _}, result), "the depth-7 artifact was refused: #{inspect(result)}"

      deeper =
        F.put(deep, ["contact", "evidence", "email", "artifact", "sha256"], [artifact["sha256"]])

      bounded_refusal!(parse(F.dossier([deeper])))
    end
  end

  describe "reading the file" do
    test "read/2 reads by full sha256 and refuses another digest or an oversized file" do
      dir = F.scratch_dir!()
      bin = F.encode(F.dossier())
      path = F.write!(dir, "dossier.json", bin)

      assert match?({:ok, %{"companies" => [_]}}, DossierParser.read(path, F.sha256(bin)))
      bounded_refusal!(DossierParser.read(path, F.sha256(bin <> " ")))

      big = bin <> String.duplicate(" ", 262_144 - byte_size(bin) + 1)
      big_path = F.write!(dir, "big.json", big)
      bounded_refusal!(DossierParser.read(big_path, F.sha256(big)))
    end
  end

  describe "text rule" do
    test "a control character is refused in a single-line field and outside the multiline fields" do
      assert {:error, {"companies[0].name", _rule}} =
               parse(F.dossier([Map.put(c(), "name", "Acme\nLabs")]))

      assert {:error, {"companies[0].contact.role", _rule}} =
               parse(F.dossier([F.put(c(), ["contact", "role"], "Head\u0007of Growth")]))

      assert {:error, {"companies[0].facts[0].text", _rule}} =
               parse(F.dossier([F.put(c(), ["facts", 0, "text"], "Acme \u202Ehas 24 people.")]))

      assert {:error, {"companies[0].why_fit", _rule}} =
               parse(F.dossier([Map.put(c(), "why_fit", "C1 control \u0085 here")]))
    end

    test "length bounds count characters" do
      assert {:error, {"companies[0].name", _rule}} =
               parse(F.dossier([Map.put(c(), "name", String.duplicate("é", 121))]))

      assert match?(
               {:ok, _},
               parse(F.dossier([Map.put(c(), "name", String.duplicate("é", 120))]))
             )
    end
  end

  describe "uniqueness and references" do
    test "a duplicate row_id, domain, source_id or fact_id is refused" do
      refused!(
        parse(F.dossier([c(1), Map.put(c(2), "row_id", "row-1")])),
        "companies[1].row_id",
        :duplicate
      )

      dup_domain =
        c(2)
        |> Map.put("domain", "acme1.test")
        |> Map.put("sources", c(1)["sources"])
        |> Map.put("contact", c(1)["contact"])

      refused!(parse(F.dossier([c(1), dup_domain])), "companies[1].domain", :duplicate)

      refused!(
        parse(F.dossier([F.put(c(), ["sources", 1, "source_id"], "s1")])),
        "companies[0].sources[1].source_id",
        :duplicate
      )

      refused!(
        parse(F.dossier([F.put(c(), ["facts", 1, "fact_id"], "f1")])),
        "companies[0].facts[1].fact_id",
        :duplicate
      )
    end

    test "an unknown source_id in a fact or a claim is refused" do
      refused!(
        parse(F.dossier([F.put(c(), ["facts", 0, "source_id"], "s9")])),
        "companies[0].facts[0].source_id",
        :unknown_source
      )

      refused!(
        parse(F.dossier([F.put(c(), ["contact", "evidence", "email", "source_id"], "s9")])),
        "companies[0].contact.evidence.email.source_id",
        :unknown_source
      )
    end
  end

  describe "URLs" do
    test "only https URLs without userinfo, query, fragment, port, IP literal or reserved host" do
      for url <- [
            "http://acme1.test/team",
            "https://user:#{@marker}@acme1.test/team",
            "https://acme1.test/team?#{@marker}=1",
            "https://acme1.test/team##{@marker}",
            "https://acme1.test:8443/team",
            "https://192.0.2.10/team",
            "https://[2001:db8::1]/team",
            "https://localhost/team",
            "https://intranet.local/team",
            "https://wiki.internal/team",
            "ftp://acme1.test/team",
            "acme1.test/team",
            # Ruling R3: an explicit default port, case and trailing-dot
            # variants, single-label and encoded hosts, backslashes.
            "https://acme1.test:443/team",
            "https://acme1.test./team",
            "https://LOCALHOST/team",
            "https://Intranet.LOCAL/team",
            "https://wiki.internal./team",
            "https://intranet/team",
            "https://acme%31.test/team",
            "https://acme1.test\\@#{@marker}.test/team",
            "https://svc.arpa/team",
            "https://hidden.onion/team",
            "https://name.alt/team",
            "https://x.invalid/team",
            "https://127.1/team"
          ] do
        refused!(
          parse(F.dossier([F.put(c(), ["sources", 0, "original_url"], url)])),
          "companies[0].sources[0].original_url",
          :unsafe_url
        )
      end

      refused!(
        parse(
          F.dossier([F.put(c(), ["sources", 1, "final_url"], "https://www.acme1.test/about?x=1")])
        ),
        "companies[0].sources[1].final_url",
        :unsafe_url
      )
    end

    test "a company domain must be a lower-case public host (ruling R3)" do
      for domain <-
            ~w(Acme1.test acme1.test. localhost acme.local acme.internal acme1 192.0.2.1 acme_1.test) do
        refused!(
          parse(F.dossier([Map.put(c(), "domain", domain)])),
          "companies[0].domain",
          :format
        )
      end
    end

    test "the RFC 2606 test names are admitted only by the compile-time test build (source check)" do
      # Not proof of the production build: the production-artifact test is.
      source = File.read!("lib/sdr_agent/prototype/dossier_parser.ex")
      assert source =~ "Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)"
      assert source =~ ~r/if @test_seams do/
      refute source =~ ~r/allow_reserved|System\.get_env|Application\.get_env/
    end

    test "a redirected source keeps distinct original and final URLs" do
      row = F.put(c(), ["sources", 1, "original_url"], "https://acme1.test/about-us")
      assert match?({:ok, _}, parse(F.dossier([row])))
    end
  end

  describe "honest source labels" do
    test "a company-host source labelled anything but company_site is refused" do
      for type <- ~w(person_authored attributed_third_party directory third_party) do
        refused!(
          parse(F.dossier([F.put(c(), ["sources", 1, "source_type"], type)])),
          "companies[0].sources[1].source_type",
          :mislabelled
        )
      end
    end

    test "a non-company host labelled company_site is refused" do
      row =
        c()
        |> F.put(["sources", 1, "original_url"], "https://acme1-fans.test/about")
        |> F.put(["sources", 1, "final_url"], "https://acme1-fans.test/about")

      refused!(parse(F.dossier([row])), "companies[0].sources[1].source_type", :mislabelled)
    end
  end

  describe "claim bases and attribution" do
    defp with_source(row, source), do: Map.update!(row, "sources", &(&1 ++ [source]))

    test "a basis must match its source type" do
      refused!(
        parse(
          F.dossier([F.put(c(), ["contact", "evidence", "role", "basis"], "person_authored")])
        ),
        "companies[0].contact.evidence.role.basis",
        :basis
      )
    end

    test "a directory source never supports a contact claim" do
      row =
        c()
        |> with_source(F.source("s3", "https://people-directory.test/acme1", "directory"))
        |> F.put(
          ["contact", "evidence", "email"],
          F.claim("s3", "third_party_report", nil, "Jordan Testperson: jordan@acme1.test")
        )

      refused!(parse(F.dossier([row])), "companies[0].contact.evidence.email.basis", :basis)

      row =
        F.put(
          row,
          ["contact", "evidence", "email"],
          F.claim("s3", "company_published", nil, "Jordan Testperson: jordan@acme1.test")
        )

      refused!(parse(F.dossier([row])), "companies[0].contact.evidence.email.basis", :basis)
    end

    test "third_party_report supports name and role only, never email" do
      row =
        c()
        |> with_source(F.source("s3", "https://news.test/acme1-profile", "third_party"))
        |> F.put(
          ["contact", "evidence", "role"],
          F.claim("s3", "third_party_report", nil, "Jordan Testperson, Head of Growth")
        )

      assert match?({:ok, _}, parse(F.dossier([row])))

      row =
        F.put(
          row,
          ["contact", "evidence", "email"],
          F.claim("s3", "third_party_report", nil, "Jordan Testperson: jordan@acme1.test")
        )

      refused!(parse(F.dossier([row])), "companies[0].contact.evidence.email.basis", :basis)
    end

    test "person_authored and attributed_post need an attribution excerpt that contains the name" do
      row =
        with_source(c(), F.source("s3", "https://jordan-writes.test/about", "person_authored"))

      ok =
        F.put(
          row,
          ["contact", "evidence", "role"],
          F.claim(
            "s3",
            "person_authored",
            "About Jordan Testperson",
            "Jordan Testperson, Head of Growth"
          )
        )

      assert match?({:ok, _}, parse(F.dossier([ok])))

      missing =
        F.put(
          row,
          ["contact", "evidence", "role"],
          F.claim("s3", "person_authored", nil, "Jordan Testperson, Head of Growth")
        )

      refused!(
        parse(F.dossier([missing])),
        "companies[0].contact.evidence.role.attribution_excerpt",
        :attribution
      )

      post = with_source(c(), F.source("s3", "https://news.test/post", "attributed_third_party"))

      lacks =
        F.put(
          post,
          ["contact", "evidence", "role"],
          F.claim(
            "s3",
            "attributed_post",
            "By the Acme 1 team #{@marker}",
            "Jordan Testperson, Head of Growth"
          )
        )

      refused!(
        parse(F.dossier([lacks])),
        "companies[0].contact.evidence.role.attribution_excerpt",
        :attribution
      )
    end

    test "company_published and third_party_report carry no attribution excerpt" do
      row =
        F.put(c(), ["contact", "evidence", "name", "attribution_excerpt"], "By Jordan Testperson")

      refused!(
        parse(F.dossier([row])),
        "companies[0].contact.evidence.name.attribution_excerpt",
        :attribution
      )
    end

    test "a claim with neither an excerpt nor an artifact is refused" do
      refused!(
        parse(F.dossier([F.put(c(), ["contact", "evidence", "name", "excerpt"], nil)])),
        "companies[0].contact.evidence.name",
        :claim_evidence
      )
    end
  end

  describe "facts" do
    test "a quote's excerpt equals its text" do
      refused!(
        parse(
          F.dossier([F.put(c(), ["facts", 0, "excerpt"], "Acme 1 has a team of 25 people.")])
        ),
        "companies[0].facts[0].excerpt",
        :quote_excerpt
      )

      refused!(
        parse(F.dossier([F.put(c(), ["facts", 0, "excerpt"], nil)])),
        "companies[0].facts[0].excerpt",
        :quote_excerpt
      )
    end

    test "an inference has no source, excerpt or topic" do
      for {key, value} <- [
            {"source_id", "s1"},
            {"excerpt", "Probably needs outbound help soon."},
            {"topic", "size"}
          ] do
        refused!(
          parse(F.dossier([F.put(c(), ["facts", 3, key], value)])),
          "companies[0].facts[3]",
          :inference
        )
      end
    end

    test "an excerpt needs a source" do
      refused!(
        parse(F.dossier([F.put(c(), ["facts", 2, "source_id"], nil)])),
        "companies[0].facts[2].source_id",
        :null
      )
    end

    test "a topic fact needs a non-null excerpt" do
      refused!(
        parse(F.dossier([F.put(c(), ["facts", 1, "excerpt"], nil)])),
        "companies[0].facts[1]",
        :topic
      )
    end

    test "a statement dated after the dossier was generated is refused" do
      refused!(
        parse(F.dossier([F.put(c(), ["facts", 0, "stated_on"], "2026-10-28")])),
        "companies[0].facts[0].stated_on",
        :future_date
      )
    end

    test "a malformed date is refused" do
      refused!(
        parse(F.dossier([F.put(c(), ["facts", 0, "stated_on"], "2026-02-30")])),
        "companies[0].facts[0].stated_on",
        :format
      )

      refused!(
        parse(F.dossier([F.put(c(), ["sources", 0, "retrieved_on"], "26-10-2026")])),
        "companies[0].sources[0].retrieved_on",
        :format
      )
    end
  end

  describe "contact cross rules" do
    test "the email host equals the company domain exactly" do
      refused!(
        parse(F.dossier([F.put(c(), ["contact", "email"], "jordan@other.test")])),
        "companies[0].contact.email",
        :email_host
      )

      refused!(
        parse(F.dossier([F.put(c(), ["contact", "email"], "jordan@mail.acme1.test")])),
        "companies[0].contact.email",
        :email_host
      )
    end

    test "email is null exactly when email_kind is unavailable" do
      unflagged = c(1, %{"importable" => false, "skip_reason" => "email_unavailable"})

      no_email =
        unflagged
        |> F.put(["contact", "email"], nil)
        |> F.put(["contact", "evidence", "email"], nil)

      assert match?(
               {:ok, _},
               parse(F.dossier([F.put(no_email, ["contact", "email_kind"], "unavailable")]))
             )

      refused!(parse(F.dossier([no_email])), "companies[0].contact.email", :email_kind)

      refused!(
        parse(F.dossier([F.put(unflagged, ["contact", "email_kind"], "unavailable")])),
        "companies[0].contact.email",
        :email_kind
      )
    end

    test "evidence.email is null exactly when email is null" do
      unflagged = c(1, %{"importable" => false, "skip_reason" => "email_unavailable"})

      refused!(
        parse(F.dossier([F.put(unflagged, ["contact", "evidence", "email"], nil)])),
        "companies[0].contact.evidence.email",
        :evidence_email
      )

      refused!(
        parse(
          F.dossier([
            unflagged
            |> F.put(["contact", "email"], nil)
            |> F.put(["contact", "email_kind"], "unavailable")
          ])
        ),
        "companies[0].contact.evidence.email",
        :evidence_email
      )
    end

    test "the name has 2 to 4 tokens" do
      refused!(
        parse(F.dossier([F.put(c(), ["contact", "name"], "Jordan")])),
        "companies[0].contact.name",
        :name_tokens
      )

      refused!(
        parse(F.dossier([F.put(c(), ["contact", "name"], "A B C D E")])),
        "companies[0].contact.name",
        :name_tokens
      )
    end

    test "importable is true exactly when skip_reason is null" do
      refused!(
        parse(F.dossier([Map.put(c(), "skip_reason", "not_selected")])),
        "companies[0].skip_reason",
        :importable_flag
      )

      refused!(
        parse(F.dossier([Map.put(c(), "importable", false)])),
        "companies[0].skip_reason",
        :importable_flag
      )
    end

    test "contact is null only for no_named_person" do
      row = c(1, %{"importable" => false, "skip_reason" => "role_mailbox", "contact" => nil})
      refused!(parse(F.dossier([row])), "companies[0].contact", :contact_null)
    end
  end
end
