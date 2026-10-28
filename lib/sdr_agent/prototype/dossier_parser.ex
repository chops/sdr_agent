defmodule SdrAgent.Prototype.DossierParser do
  @moduledoc """
  The bounded parser of the D-237 prospect dossier `sdr-agent.prototype-dossier`
  version 1 and its importable rule (interfaces r6 IF-6, contact-source ruling
  B, rulings 4-6; Codex S3 RED-1 rulings R1-R4). Built on
  `SdrAgent.Prototype.BoundedJson`; it never touches the network and never
  evaluates its input.

  - `read/2` reads the file once by its full sha256 (at most 256 KiB) and
    `parse/1` decodes it (container depth at most 7, duplicate keys refused at
    any depth before any conversion) and checks the exact key sets, the closed
    enums, the text rule, the URL rule, the honest source labels, the claim
    bases and attributions, the fact rules, the contact cross rules and, for
    every flagged row, importable rule 1 (a person, a personal work address,
    no conflict). It returns the decoded map unchanged.
  - `eligibility/4` applies the whole importable rule to one row against the
    parsed spot-check manifest (`SdrAgent.Prototype.SpotcheckManifest`) and
    the retained artifacts; `select/4` refuses a selection of more than 3
    rows, an unknown or repeated row, or any row that is not eligible, before
    any write; `eligible_rows/3` lists the eligible flagged rows in file order
    (an empty list: none qualify, reported, never weakened).
  - `import_plan/4` maps one selected row to the values the import writes:
    the account, the person contact, the entry labels, the three claim
    records, the sources holding verified excerpts only, and the targeting
    notes.
  - **The whole input first (R2).** Every public import entry
    (`eligibility/4`, `select/4`, `eligible_rows/3`, `import_plan/4`) first
    applies the importable rule to EVERY flagged row, in file order: any
    flagged row that fails it refuses the input, whichever rows are
    selected. A flagged row is never treated as an unflagged skip.
  - **Hosts (R3).** https only; no userinfo, explicit port (`:443`
    included), query, fragment, IP literal, single-label, trailing-dot,
    upper-case, encoded or special-use host (`localhost`, `.local`,
    `.internal`, `.invalid`, `.arpa`, `.onion`, `.alt`). The RFC 2606 names
    (`.test`, `.example`, `example.com/.net/.org`) are refused too, except
    in the hermetic test build (`:claude_cli_test_seams`, fixed at compile
    time), where the synthetic fixtures use them; no runtime flag or caller
    option admits them.

  **The importable rule of a flagged row**, in order:
  1. a person contact with `email_kind: "personal_work"`, an address and no
     conflict (`:role_mailbox`, `:email_unavailable`, `:other_person_source`,
     `:source_conflict`);
  2. every artifact a claim names is valid (`:artifact_invalid` at the
     claim's `artifact` path);
  3. no spot-check result of the row is `conflict` (`:source_conflict`);
  4. one result per claim and per fact with an excerpt, checked email first
     (a missing email, role or other result is `:link_unconfirmed`,
     `:role_unconfirmed` or `:insufficient_source`);
  5. the email claim: the address and the name inside one literal UTF-8
     byte window of at most 300 bytes of its excerpt or its artifact's bytes
     (a mechanical bound only), and `verified` with `person_address_linked`
     (`:link_unconfirmed`);
  6. the role claim: the name and the role verbatim, and `verified` with
     `person_role_current` (`:role_unconfirmed`);
  7. the name claim `verified`; a verified quote or fact with an excerpt on a
     `company_site` source (`:insufficient_source`);
  8. no `stated_on` after the date of its check (the date in `checked_at`'s
     own offset; `:future_date` at the fact's `stated_on`), then one verified
     `size` fact marked `company_size_stated` and one verified `location`
     fact marked `company_location_stated`, each with an excerpt and
     `2025-10-28 ≤ stated_on` (`:insufficient_source`).

  A flagged row failing the rule refuses the input (`{:error, {"companies[i]",
  reason}}`); an unflagged row is `{:not_importable, skip_reason}`.

  **Source content (R1).** A source's content is its verified excerpt strings,
  verbatim, in dossier fact order, joined by exactly two LF bytes: no kind or
  fact-id label, no other page's text. Kind and fact id stay in the plan's
  `excerpts` list. Those bytes are what the import stores as the source's
  Payload and what the evidence path reads.

  Every refusal is `{:error, {path, rule}}` with a fixed schema path with
  indices (for example `companies[0].contact.evidence.email`) and a rule
  atom; no value is ever echoed.

  `read/2` and `parse/1` rely on `SdrAgent.Prototype.BoundedJson` (S1) for the
  byte, UTF-8, duplicate-key, depth, key-set and text rules.
  """

  alias SdrAgent.Prototype.BoundedJson
  alias SdrAgent.Prototype.DossierParser.Rules
  alias SdrAgent.Prototype.SpotcheckManifest

  @max_bytes 262_144
  # Every key of the schema, so a duplicate-key or depth refusal keeps its
  # schema path (S1 BoundedJson `known_keys:`).
  @known_keys ~w(schema schema_version generated_at sources_policy companies row_id name domain why_fit importable skip_reason sources facts contact source_id original_url final_url source_type retrieved_on retrieved_at fact_id kind topic stated_on text excerpt role email email_kind classification confidence conflict evidence basis attribution_excerpt artifact file sha256)
  @max_depth 7
  @max_rows 3
  @window_bytes 300
  @floor ~D[2025-10-28]

  @skip_reasons %{
    "no_named_person" => :no_named_person,
    "role_mailbox" => :role_mailbox,
    "email_unavailable" => :email_unavailable,
    "link_unconfirmed" => :link_unconfirmed,
    "role_unconfirmed" => :role_unconfirmed,
    "source_conflict" => :source_conflict,
    "insufficient_source" => :insufficient_source,
    "not_selected" => :not_selected
  }
  @email_bases ["company_published", "person_authored", "attributed_post"]
  @claim_fields ["name", "role", "email"]
  @email_kinds %{"personal_work" => :personal_work}
  @classifications %{"unverified" => :unverified}
  @confidences %{"high" => :high, "medium" => :medium, "low" => :low}

  @typedoc "A refusal: a fixed schema path and a rule atom; never a value."
  @type refusal :: {:error, {String.t(), atom()}}

  @doc "Reads the dossier at `path` once (S1 `BoundedJson.read_file/3`), by its full sha256, and parses it."
  @spec read(Path.t(), String.t()) :: {:ok, map()} | refusal()
  def read(path, sha256) when is_binary(path) and is_binary(sha256) do
    with {:ok, bin} <- BoundedJson.read_file(path, sha256, @max_bytes), do: parse(bin)
  end

  @doc "Parses and validates dossier bytes; see the moduledoc."
  @spec parse(binary()) :: {:ok, map()} | refusal()
  def parse(bin) when is_binary(bin) do
    with {:ok, doc} <-
           BoundedJson.decode(bin,
             max_bytes: @max_bytes,
             max_depth: @max_depth,
             known_keys: @known_keys
           ),
         :ok <- Rules.validate(doc) do
      {:ok, doc}
    end
  end

  @doc "`:eligible` or `{:not_importable, reason}` for `row_id`, or a refusal of the input."
  @spec eligibility(map(), map(), String.t(), Path.t()) ::
          :eligible | {:not_importable, atom()} | refusal()
  def eligibility(dossier, manifest, row_id, artifacts_dir) do
    with :ok <- flagged_rows(dossier, manifest, artifacts_dir) do
      case find_row(dossier, row_id) do
        {index, row} -> row_eligibility(index, row, manifest.results, artifacts_dir)
        nil -> {:error, {"row_id", :unknown_row}}
      end
    end
  end

  @doc "The selected rows, in selection order, when every one is eligible."
  @spec select(map(), map(), [String.t()], Path.t()) :: {:ok, [map()]} | refusal()
  def select(dossier, manifest, row_ids, artifacts_dir) when is_list(row_ids) do
    with :ok <- check_selection(dossier, row_ids),
         :ok <- flagged_rows(dossier, manifest, artifacts_dir) do
      collect(row_ids, &selected_row(dossier, &1))
    end
  end

  @doc "The ids of the flagged rows, in file order, once every one is eligible (`[]`: none qualify)."
  @spec eligible_rows(map(), map(), Path.t()) :: {:ok, [String.t()]} | refusal()
  def eligible_rows(dossier, manifest, artifacts_dir) do
    with :ok <- flagged_rows(dossier, manifest, artifacts_dir) do
      {:ok, for(row <- dossier["companies"], row["importable"] == true, do: row["row_id"])}
    end
  end

  @doc """
  The import values of one flagged row of a fully valid input:
  `%{row_id:, account:, contact:, entry:, claims:, sources:, notes:}`; see
  the moduledoc and interfaces r6 IF-6 "Mapping" and "Tables".
  """
  @spec import_plan(map(), map(), String.t(), Path.t()) :: {:ok, map()} | refusal()
  def import_plan(dossier, manifest, row_id, artifacts_dir) do
    with :ok <- flagged_rows(dossier, manifest, artifacts_dir) do
      case find_row(dossier, row_id) do
        nil ->
          {:error, {"row_id", :unknown_row}}

        {_index, %{"importable" => true} = row} ->
          {:ok, plan(row, row_results(manifest.results, row_id))}

        {index, row} ->
          {:error, {company(index), skip_reason(row)}}
      end
    end
  end

  # R2: every flagged row, in file order, passes the whole importable rule.
  defp flagged_rows(dossier, manifest, dir) do
    dossier["companies"]
    |> Enum.with_index()
    |> Enum.filter(fn {row, _index} -> row["importable"] == true end)
    |> Enum.find_value(:ok, fn {row, index} ->
      flagged_error(index, row, manifest.results, dir)
    end)
  end

  defp flagged_error(index, row, results, dir) do
    case row_eligibility(index, row, results, dir) do
      :eligible -> nil
      {:error, _} = error -> error
    end
  end

  defp selected_row(dossier, row_id) do
    case find_row(dossier, row_id) do
      {_index, %{"importable" => true} = row} -> {:ok, row}
      {index, row} -> {:error, {company(index), skip_reason(row)}}
    end
  end

  defp skip_reason(row), do: Map.get(@skip_reasons, row["skip_reason"], :not_selected)

  # {:ok, values} in input order, or the first error.
  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  ## Selection

  defp check_selection(_dossier, row_ids) when row_ids == [] or length(row_ids) > @max_rows,
    do: {:error, {"rows", :count}}

  defp check_selection(dossier, row_ids) do
    row_ids
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {row_id, k}, seen ->
      cond do
        not is_binary(row_id) or find_row(dossier, row_id) == nil ->
          {:halt, {:error, {"rows[#{k}]", :unknown_row}}}

        MapSet.member?(seen, row_id) ->
          {:halt, {:error, {"rows[#{k}]", :duplicate}}}

        true ->
          {:cont, MapSet.put(seen, row_id)}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  defp find_row(dossier, row_id) do
    dossier["companies"]
    |> Enum.with_index()
    |> Enum.find_value(fn {row, index} -> if row["row_id"] == row_id, do: {index, row} end)
  end

  ## The importable rule of one row

  defp row_eligibility(_index, %{"importable" => false} = row, _results, _dir),
    do: {:not_importable, Map.get(@skip_reasons, row["skip_reason"], :not_selected)}

  defp row_eligibility(index, row, all_results, dir) do
    results = row_results(all_results, row["row_id"])

    with :ok <- rule_contact(row),
         {:ok, artifacts} <- rule_artifacts(index, row, dir),
         :ok <- rule_no_conflict(results),
         :ok <- rule_complete(row, results),
         :ok <- rule_email(row, results, artifacts),
         :ok <- rule_role(row, results, artifacts),
         :ok <- rule_name(results),
         :ok <- rule_usable(row, results),
         :ok <- rule_future(index, row, results),
         :ok <- rule_qualification_inputs(row, results) do
      :eligible
    else
      {:error, {_path, _rule}} = error -> error
      reason when is_atom(reason) -> {:error, {company(index), reason}}
    end
  end

  defp row_results(results, row_id),
    do: for({{^row_id, item}, result} <- results, into: %{}, do: {item, result})

  @doc false
  # Importable rule 1, shared with `parse/1` for every flagged row.
  def rule_contact(%{"contact" => nil}), do: :no_named_person

  def rule_contact(%{"contact" => contact}) do
    cond do
      contact["email_kind"] == "role_mailbox" -> :role_mailbox
      contact["email_kind"] != "personal_work" or contact["email"] == nil -> :email_unavailable
      contact["conflict"] == "other_person_source" -> :other_person_source
      contact["conflict"] != nil -> :source_conflict
      true -> :ok
    end
  end

  defp rule_artifacts(index, row, dir) do
    with {:ok, pairs} <- collect(@claim_fields, &claim_artifact(index, row, &1, dir)) do
      {:ok, for({field, bytes} <- pairs, bytes != nil, into: %{}, do: {field, bytes})}
    end
  end

  defp claim_artifact(index, row, field, dir) do
    with ref when ref != nil <- get_in(row, ["contact", "evidence", field, "artifact"]),
         {:ok, bytes} <- SpotcheckManifest.artifact(dir, ref) do
      {:ok, {field, bytes}}
    else
      nil ->
        {:ok, {field, nil}}

      {:error, _} ->
        {:error, {"#{company(index)}.contact.evidence.#{field}.artifact", :artifact_invalid}}
    end
  end

  defp rule_no_conflict(results) do
    if Enum.any?(results, fn {_item, r} -> r["result"] == "conflict" end),
      do: :source_conflict,
      else: :ok
  end

  defp rule_complete(row, results) do
    claims =
      for field <- ["email", "role", "name"],
          get_in(row, ["contact", "evidence", field]) != nil do
        {"claim:#{field}", missing_reason(field)}
      end

    facts =
      for f <- row["facts"],
          f["excerpt"] != nil,
          do: {"fact:#{f["fact_id"]}", :insufficient_source}

    case Enum.find(claims ++ facts, fn {item, _} -> not Map.has_key?(results, item) end) do
      nil -> :ok
      {_item, reason} -> reason
    end
  end

  defp missing_reason("email"), do: :link_unconfirmed
  defp missing_reason("role"), do: :role_unconfirmed
  defp missing_reason("name"), do: :insufficient_source

  defp rule_email(row, results, artifacts) do
    %{"name" => name, "email" => email} = row["contact"]
    claim = row["contact"]["evidence"]["email"]

    if claim["basis"] in @email_bases and
         Enum.any?(claim_bytes(claim, artifacts["email"]), &linked?(&1, name, email)) and
         marked?(results["claim:email"], "person_address_linked"),
       do: :ok,
       else: :link_unconfirmed
  end

  defp rule_role(row, results, artifacts) do
    %{"name" => name, "role" => role} = row["contact"]
    claim = row["contact"]["evidence"]["role"]

    if Enum.any?(
         claim_bytes(claim, artifacts["role"]),
         &(contains?(&1, name) and contains?(&1, role))
       ) and
         marked?(results["claim:role"], "person_role_current"),
       do: :ok,
       else: :role_unconfirmed
  end

  defp rule_name(results),
    do: if(verified?(results["claim:name"]), do: :ok, else: :insufficient_source)

  defp rule_usable(row, results) do
    company_sites =
      for s <- row["sources"],
          s["source_type"] == "company_site",
          into: MapSet.new(),
          do: s["source_id"]

    usable? =
      Enum.any?(row["facts"], fn f ->
        f["kind"] in ["quote", "fact"] and f["excerpt"] not in [nil, ""] and
          MapSet.member?(company_sites, f["source_id"]) and
          verified?(results["fact:#{f["fact_id"]}"])
      end)

    if usable?, do: :ok, else: :insufficient_source
  end

  defp rule_future(index, row, results) do
    row["facts"]
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {fact, j} ->
      with stated when is_binary(stated) <- fact["stated_on"],
           %{"checked_at" => checked_at} <- results["fact:#{fact["fact_id"]}"],
           {:ok, stated_on} <- Date.from_iso8601(stated),
           {:ok, check_date} <- local_date(checked_at),
           :gt <- Date.compare(stated_on, check_date) do
        {:error, {"#{company(index)}.facts[#{j}].stated_on", :future_date}}
      else
        _ -> nil
      end
    end)
  end

  defp rule_qualification_inputs(row, results) do
    if stated?(row, results, "size", "company_size_stated") and
         stated?(row, results, "location", "company_location_stated"),
       do: :ok,
       else: :insufficient_source
  end

  defp stated?(row, results, topic, relation) do
    Enum.any?(row["facts"], fn f ->
      result = results["fact:#{f["fact_id"]}"]

      f["topic"] == topic and f["excerpt"] not in [nil, ""] and marked?(result, relation) and
        fresh?(f["stated_on"], result)
    end)
  end

  defp fresh?(stated, %{"checked_at" => checked_at}) when is_binary(stated) do
    with {:ok, stated_on} <- Date.from_iso8601(stated),
         {:ok, check_date} <- local_date(checked_at) do
      Date.compare(stated_on, @floor) != :lt and Date.compare(stated_on, check_date) != :gt
    else
      _ -> false
    end
  end

  defp fresh?(_stated, _result), do: false

  # The calendar date of an RFC 3339 time in its own offset.
  defp local_date(<<date::binary-size(10), "T", _rest::binary>>), do: Date.from_iso8601(date)
  defp local_date(_other), do: :error

  defp verified?(%{"result" => "verified"}), do: true
  defp verified?(_result), do: false

  defp marked?(%{"result" => "verified", "relation" => relation}, relation), do: true
  defp marked?(_result, _relation), do: false

  defp claim_bytes(claim, artifact_bytes),
    do: Enum.reject([claim["excerpt"], artifact_bytes], &is_nil/1)

  defp contains?(bytes, part), do: :binary.match(bytes, part) != :nomatch

  # Ruling 4: some occurrence of the name and some occurrence of the address
  # fit one literal byte window of at most 300 bytes, from the first byte of
  # whichever comes first to the last byte of the other. A mechanical bound
  # only; the person-to-address relation is the spot-check's mark.
  @doc false
  def linked?(bytes, name, email)
      when is_binary(bytes) and is_binary(name) and is_binary(email) do
    names = :binary.matches(bytes, name)
    emails = :binary.matches(bytes, email)

    Enum.any?(names, fn {n, nl} ->
      Enum.any?(emails, fn {e, el} -> max(n + nl, e + el) - min(n, e) <= @window_bytes end)
    end)
  end

  ## The import plan

  defp plan(row, results) do
    contact = row["contact"]
    [first | rest] = String.split(contact["name"])

    %{
      row_id: row["row_id"],
      account: %{
        name: row["name"],
        domain: row["domain"],
        website_url:
          Enum.find_value(row["sources"], fn s ->
            if s["source_type"] == "company_site", do: s["final_url"]
          end)
      },
      contact: %{
        first_name: first,
        last_name: Enum.join(rest, " "),
        title: contact["role"],
        email: contact["email"] |> String.trim() |> String.downcase()
      },
      entry: %{
        email_kind: Map.fetch!(@email_kinds, contact["email_kind"]),
        contact_classification: Map.fetch!(@classifications, contact["classification"]),
        contact_confidence: Map.fetch!(@confidences, contact["confidence"])
      },
      claims: Enum.map(@claim_fields, &claim_record(row, &1, results)),
      sources: plan_sources(row, results),
      notes: notes(row, results)
    }
  end

  defp claim_record(row, field, results) do
    claim = row["contact"]["evidence"][field]
    source = Enum.find(row["sources"], &(&1["source_id"] == claim["source_id"]))
    result = results["claim:#{field}"] || %{}

    %{
      "field" => field,
      "source_id" => claim["source_id"],
      "source_type" => source["source_type"],
      "basis" => claim["basis"],
      "attribution_excerpt" => claim["attribution_excerpt"],
      "original_url" => source["original_url"],
      "final_url" => source["final_url"],
      "excerpt" => claim["excerpt"],
      "artifact_sha256" => get_in(claim, ["artifact", "sha256"]),
      "checked_at" => result["checked_at"],
      "result" => result["result"],
      "relation" => result["relation"]
    }
  end

  defp plan_sources(row, results) do
    for source <- row["sources"],
        facts = verified_facts(row, results, source["source_id"]),
        facts != [] do
      excerpts =
        for f <- facts,
            do: %{"fact_id" => f["fact_id"], "kind" => f["kind"], "excerpt" => f["excerpt"]}

      %{
        source_id: source["source_id"],
        original_url: source["original_url"],
        final_url: source["final_url"],
        source_type: source["source_type"],
        retrieved_on: Date.from_iso8601!(source["retrieved_on"]),
        checked_at:
          facts
          |> Enum.map(&utc_usec!(results["fact:#{&1["fact_id"]}"]["checked_at"]))
          |> Enum.max(DateTime),
        excerpts: excerpts,
        content: source_content(excerpts)
      }
    end
  end

  defp verified_facts(row, results, source_id) do
    Enum.filter(row["facts"], fn f ->
      f["source_id"] == source_id and f["kind"] in ["quote", "fact"] and f["excerpt"] != nil and
        verified?(results["fact:#{f["fact_id"]}"])
    end)
  end

  @doc "The content bytes of one source (R1): its verified excerpt strings, verbatim, joined by two LF bytes."
  @spec source_content([map()]) :: binary()
  def source_content(excerpts), do: Enum.map_join(excerpts, "\n\n", & &1["excerpt"])

  defp notes(row, results) do
    %{
      "why_fit" => row["why_fit"],
      "inferences" => for(f <- row["facts"], f["kind"] == "inference", do: f["text"]),
      "unconfirmed" =>
        for f <- row["facts"],
            f["kind"] != "inference",
            not (f["excerpt"] != nil and verified?(results["fact:#{f["fact_id"]}"])) do
          %{"fact_id" => f["fact_id"], "kind" => f["kind"], "text" => f["text"]}
        end
    }
  end

  defp utc_usec!(rfc3339) do
    {:ok, dt, _offset} = DateTime.from_iso8601(rfc3339)
    {us, _precision} = dt.microsecond
    %{dt | microsecond: {us, 6}}
  end

  defp company(index), do: "companies[#{index}]"
end

defmodule SdrAgent.Prototype.DossierParser.Rules do
  @moduledoc false
  # The schema and cross-field rules of `sdr-agent.prototype-dossier` v1
  # (interfaces r6 IF-6), applied to the decoded map, plus the value helpers
  # (text, URL, host, date, time) shared with SpotcheckManifest and SeedDir.
  # Every function returns :ok or {:error, {path, rule}}; no value is echoed.

  alias SdrAgent.Prototype.BoundedJson
  alias SdrAgent.Prototype.DossierParser

  @schema "sdr-agent.prototype-dossier"
  @top_keys ["schema", "schema_version", "generated_at", "sources_policy", "companies"]
  @company_keys ~w(row_id name domain why_fit importable skip_reason sources facts contact)
  @source_keys ~w(source_id original_url final_url source_type retrieved_on retrieved_at)
  @fact_keys ~w(fact_id kind topic stated_on text source_id excerpt)
  @contact_keys ~w(name role email email_kind classification confidence conflict evidence)
  @evidence_keys ~w(name role email)
  @claim_keys ~w(source_id basis attribution_excerpt excerpt artifact)
  @artifact_keys ~w(file sha256)

  @skip_reasons ~w(no_named_person role_mailbox email_unavailable link_unconfirmed role_unconfirmed source_conflict insufficient_source not_selected)
  @source_types ~w(company_site person_authored attributed_third_party directory third_party)
  @fact_kinds ~w(quote fact inference)
  @topics ~w(size location industry)
  @email_kinds ~w(personal_work role_mailbox unavailable)
  @confidences ~w(high medium low)
  @conflicts ~w(address_link_mismatch other_person_source other)
  @basis_source %{
    "company_published" => "company_site",
    "person_authored" => "person_authored",
    "attributed_post" => "attributed_third_party",
    "third_party_report" => "third_party"
  }

  @row_id ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @source_id ~r/\A s[0-9]{1,2}\z/x
  @fact_id ~r/\A f[0-9]{1,2}\z/x
  @artifact_file ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @email_local ~r/\A[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]{1,64}\z/
  @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @host ~r/\A(?=.{1,253}\z)#{@label}(?:\.#{@label})+\z/
  @reserved_tlds ~w(localhost local internal invalid arpa onion alt)
  @rfc2606_tlds ~w(test example)
  @rfc2606_domains ~w(example.com example.net example.org)
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @rfc3339 ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\z/
  @date ~r/\A\d{4}-\d{2}-\d{2}\z/
  @max_url_bytes 2048

  ## The dossier

  def validate(doc) do
    with :ok <- keys(doc, @top_keys, []),
         :ok <- equal(doc["schema"], @schema, "schema", :schema),
         :ok <- version(doc["schema_version"]),
         :ok <- time(doc["generated_at"], "generated_at"),
         :ok <- text(doc["sources_policy"], "sources_policy", 1, 2000),
         :ok <- list(doc["companies"], "companies", 1, 15) do
      generated_on = local_date!(doc["generated_at"])
      companies(doc["companies"], generated_on)
    end
  end

  defp version(1), do: :ok
  defp version(_other), do: {:error, {"schema_version", :schema_version}}

  defp companies(companies, generated_on) do
    companies
    |> Enum.with_index()
    |> Enum.reduce_while({MapSet.new(), MapSet.new()}, fn {company, i}, {ids, domains} ->
      p = "companies[#{i}]"

      with :ok <- company(company, i, generated_on),
           :ok <- unique(company["row_id"], ids, "#{p}.row_id"),
           :ok <- unique(company["domain"], domains, "#{p}.domain") do
        {:cont, {MapSet.put(ids, company["row_id"]), MapSet.put(domains, company["domain"])}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _sets -> :ok
    end
  end

  defp company(c, i, generated_on) do
    p = "companies[#{i}]"

    with :ok <- keys(c, @company_keys, ["companies", i]),
         :ok <- pattern(c["row_id"], @row_id, "#{p}.row_id"),
         :ok <- text(c["name"], "#{p}.name", 1, 120),
         :ok <- domain(c["domain"], "#{p}.domain"),
         :ok <- text(c["why_fit"], "#{p}.why_fit", 1, 600, true),
         :ok <- boolean(c["importable"], "#{p}.importable"),
         :ok <- optional_enum(c["skip_reason"], @skip_reasons, "#{p}.skip_reason"),
         {:ok, sources} <- sources(c["sources"], p, c["domain"]),
         :ok <- facts(c["facts"], p, sources, generated_on),
         :ok <- optional(c["contact"], &contact(&1, "#{p}.contact", c["domain"], sources)),
         :ok <- flag(c, p) do
      flagged(c, p)
    end
  end

  defp flag(c, p) do
    cond do
      c["importable"] != (c["skip_reason"] == nil) ->
        {:error, {"#{p}.skip_reason", :importable_flag}}

      c["contact"] == nil and c["skip_reason"] != "no_named_person" ->
        {:error, {"#{p}.contact", :contact_null}}

      true ->
        :ok
    end
  end

  # Importable rule 1 for a flagged row; the rest needs the manifest.
  defp flagged(%{"importable" => true} = c, p) do
    case DossierParser.rule_contact(c) do
      :ok -> :ok
      reason -> {:error, {p, reason}}
    end
  end

  defp flagged(_c, _p), do: :ok

  defp sources(sources, p, domain) do
    with :ok <- list(sources, "#{p}.sources", 1, 10) do
      sources
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, &add_source(&1, &2, p, domain))
    end
  end

  defp add_source({s, k}, {:ok, acc}, p, domain) do
    sp = "#{p}.sources[#{k}]"

    with :ok <- source(s, sp, domain),
         :ok <- unique(s["source_id"], acc, "#{sp}.source_id") do
      {:cont, {:ok, Map.put(acc, s["source_id"], s)}}
    else
      error -> {:halt, error}
    end
  end

  defp source(s, sp, domain) do
    with :ok <- keys(s, @source_keys, segments(sp)),
         :ok <- pattern(s["source_id"], @source_id, "#{sp}.source_id"),
         :ok <- url(s["original_url"], "#{sp}.original_url"),
         :ok <- url(s["final_url"], "#{sp}.final_url"),
         :ok <- enum(s["source_type"], @source_types, "#{sp}.source_type"),
         :ok <- label(s, sp, domain),
         :ok <- date(s["retrieved_on"], "#{sp}.retrieved_on") do
      optional(s["retrieved_at"], &time(&1, "#{sp}.retrieved_at"))
    end
  end

  # Ruling 5: only the host is mechanical. A company host carries only
  # company_site; another host never does.
  defp label(s, sp, domain) do
    company_host? = company_host?(host!(s["final_url"]), domain)

    if company_host? == (s["source_type"] == "company_site"),
      do: :ok,
      else: {:error, {"#{sp}.source_type", :mislabelled}}
  end

  defp facts(facts, p, sources, generated_on) do
    with :ok <- list(facts, "#{p}.facts", 1, 10) do
      facts
      |> Enum.with_index()
      |> Enum.reduce_while(MapSet.new(), &add_fact(&1, &2, p, sources, generated_on))
      |> case do
        {:error, _} = error -> error
        _ids -> :ok
      end
    end
  end

  defp add_fact({f, j}, ids, p, sources, generated_on) do
    fp = "#{p}.facts[#{j}]"

    with :ok <- fact(f, fp, sources, generated_on),
         :ok <- unique(f["fact_id"], ids, "#{fp}.fact_id") do
      {:cont, MapSet.put(ids, f["fact_id"])}
    else
      error -> {:halt, error}
    end
  end

  defp fact(f, fp, sources, generated_on) do
    with :ok <- keys(f, @fact_keys, segments(fp)),
         :ok <- pattern(f["fact_id"], @fact_id, "#{fp}.fact_id"),
         :ok <- enum(f["kind"], @fact_kinds, "#{fp}.kind"),
         :ok <- optional_enum(f["topic"], @topics, "#{fp}.topic"),
         :ok <- optional(f["stated_on"], &not_after(&1, generated_on, "#{fp}.stated_on")),
         :ok <- text(f["text"], "#{fp}.text", 1, 600, true),
         :ok <- optional(f["source_id"], &known_source(&1, sources, "#{fp}.source_id")),
         :ok <- optional(f["excerpt"], &text(&1, "#{fp}.excerpt", 1, 600, true)) do
      fact_kind(f, fp)
    end
  end

  defp fact_kind(%{"kind" => "inference"} = f, fp) do
    if f["source_id"] == nil and f["excerpt"] == nil and f["topic"] == nil,
      do: :ok,
      else: {:error, {fp, :inference}}
  end

  defp fact_kind(f, fp) do
    cond do
      f["kind"] == "quote" and (f["excerpt"] == nil or f["excerpt"] != f["text"]) ->
        {:error, {"#{fp}.excerpt", :quote_excerpt}}

      f["excerpt"] != nil and f["source_id"] == nil ->
        {:error, {"#{fp}.source_id", :null}}

      f["topic"] != nil and f["excerpt"] == nil ->
        {:error, {fp, :topic}}

      true ->
        :ok
    end
  end

  defp contact(ct, cp, domain, sources) do
    with :ok <- keys(ct, @contact_keys, segments(cp)),
         :ok <- name(ct["name"], "#{cp}.name"),
         :ok <- text(ct["role"], "#{cp}.role", 1, 120),
         :ok <- optional(ct["email"], &email(&1, "#{cp}.email", domain)),
         :ok <- enum(ct["email_kind"], @email_kinds, "#{cp}.email_kind"),
         :ok <- enum(ct["classification"], ["unverified"], "#{cp}.classification"),
         :ok <- enum(ct["confidence"], @confidences, "#{cp}.confidence"),
         :ok <- optional_enum(ct["conflict"], @conflicts, "#{cp}.conflict"),
         :ok <-
           iff(ct["email"] == nil, ct["email_kind"] == "unavailable", "#{cp}.email", :email_kind) do
      evidence(ct, "#{cp}.evidence", sources)
    end
  end

  defp evidence(ct, ep, sources) do
    ev = ct["evidence"]

    with :ok <- keys(ev, @evidence_keys, segments(ep)),
         :ok <- present(ev["name"], "#{ep}.name"),
         :ok <- present(ev["role"], "#{ep}.role"),
         :ok <- iff(ev["email"] == nil, ct["email"] == nil, "#{ep}.email", :evidence_email),
         :ok <- claim(ev["name"], "#{ep}.name", "name", ct["name"], sources),
         :ok <- claim(ev["role"], "#{ep}.role", "role", ct["name"], sources) do
      optional(ev["email"], &claim(&1, "#{ep}.email", "email", ct["name"], sources))
    end
  end

  defp claim(claim, cp, field, name, sources) do
    with :ok <- keys(claim, @claim_keys, segments(cp)),
         :ok <- present(claim["source_id"], "#{cp}.source_id"),
         :ok <- known_source(claim["source_id"], sources, "#{cp}.source_id"),
         :ok <- enum(claim["basis"], Map.keys(@basis_source), "#{cp}.basis"),
         :ok <- basis(claim, field, sources, "#{cp}.basis"),
         :ok <-
           optional(
             claim["attribution_excerpt"],
             &text(&1, "#{cp}.attribution_excerpt", 1, 200, true)
           ),
         :ok <- attribution(claim, name, "#{cp}.attribution_excerpt"),
         :ok <- optional(claim["excerpt"], &text(&1, "#{cp}.excerpt", 1, 300, true)),
         :ok <- optional(claim["artifact"], &artifact(&1, "#{cp}.artifact")) do
      if claim["excerpt"] == nil and claim["artifact"] == nil,
        do: {:error, {cp, :claim_evidence}},
        else: :ok
    end
  end

  # A basis matches exactly one source type; no basis matches `directory`;
  # third_party_report never supports the email.
  defp basis(claim, field, sources, bp) do
    source_type = sources[claim["source_id"]]["source_type"]

    if Map.fetch!(@basis_source, claim["basis"]) == source_type and
         not (field == "email" and claim["basis"] == "third_party_report"),
       do: :ok,
       else: {:error, {bp, :basis}}
  end

  defp attribution(%{"basis" => basis, "attribution_excerpt" => excerpt}, name, ap)
       when basis in ["person_authored", "attributed_post"] do
    if is_binary(excerpt) and :binary.match(excerpt, name) != :nomatch,
      do: :ok,
      else: {:error, {ap, :attribution}}
  end

  defp attribution(%{"attribution_excerpt" => nil}, _name, _ap), do: :ok
  defp attribution(_claim, _name, ap), do: {:error, {ap, :attribution}}

  defp artifact(a, ap) do
    with :ok <- keys(a, @artifact_keys, segments(ap)),
         :ok <- pattern(a["file"], @artifact_file, "#{ap}.file") do
      pattern(a["sha256"], @hex64, "#{ap}.sha256")
    end
  end

  defp name(value, np) do
    with :ok <- text(value, np, 1, 120) do
      tokens = String.split(value, " ")

      if length(tokens) in 2..4 and Enum.all?(tokens, &(&1 != "")),
        do: :ok,
        else: {:error, {np, :name_tokens}}
    end
  end

  defp email(value, ep, domain) do
    with :ok <- text(value, ep, 3, 254) do
      value |> String.split("@") |> email_parts(ep, domain)
    end
  end

  defp email_parts([local, host], ep, domain) do
    cond do
      not Regex.match?(@email_local, local) or not Regex.match?(@host, String.downcase(host)) ->
        {:error, {ep, :format}}

      String.downcase(host) != domain ->
        {:error, {ep, :email_host}}

      true ->
        :ok
    end
  end

  defp email_parts(_parts, ep, _domain), do: {:error, {ep, :format}}

  defp known_source(id, sources, sp) do
    if is_binary(id) and Map.has_key?(sources, id), do: :ok, else: {:error, {sp, :unknown_source}}
  end

  defp not_after(value, generated_on, dp) do
    with :ok <- date(value, dp) do
      if Date.compare(Date.from_iso8601!(value), generated_on) == :gt,
        do: {:error, {dp, :future_date}},
        else: :ok
    end
  end

  ## Shared value helpers (also used by SpotcheckManifest and SeedDir)

  @doc false
  def keys(map, keys, segs) when is_map(map), do: BoundedJson.exact_keys(map, keys, segs)

  def keys(nil, _keys, segs), do: {:error, {path(segs), :null}}
  def keys(_other, _keys, segs), do: {:error, {path(segs), :type}}

  @doc false
  def text(value, p, min, max, multiline \\ false)
  def text(nil, p, _min, _max, _multiline), do: {:error, {p, :null}}

  def text(value, p, min, max, multiline) when is_binary(value) do
    case BoundedJson.check_text(value, min: min, max: max, multiline: multiline) do
      :ok -> :ok
      {:error, rule} -> {:error, {p, rule}}
    end
  end

  def text(_value, p, _min, _max, _multiline), do: {:error, {p, :type}}

  @doc false
  def list(nil, p, _min, _max), do: {:error, {p, :null}}

  def list(value, p, min, max) when is_list(value) do
    if length(value) in min..max, do: :ok, else: {:error, {p, :count}}
  end

  def list(_value, p, _min, _max), do: {:error, {p, :type}}

  @doc false
  def enum(nil, _values, p), do: {:error, {p, :null}}
  def enum(value, values, p), do: if(value in values, do: :ok, else: {:error, {p, :enum}})

  defp optional_enum(nil, _values, _p), do: :ok
  defp optional_enum(value, values, p), do: enum(value, values, p)

  @doc false
  def pattern(nil, _re, p), do: {:error, {p, :null}}

  def pattern(value, re, p) when is_binary(value),
    do: if(Regex.match?(re, value), do: :ok, else: {:error, {p, :format}})

  def pattern(_value, _re, p), do: {:error, {p, :type}}

  defp boolean(value, _p) when is_boolean(value), do: :ok
  defp boolean(nil, p), do: {:error, {p, :null}}
  defp boolean(_value, p), do: {:error, {p, :type}}

  defp present(nil, p), do: {:error, {p, :null}}
  defp present(_value, _p), do: :ok

  defp optional(nil, _fun), do: :ok
  defp optional(value, fun), do: fun.(value)

  defp equal(value, value, _p, _rule), do: :ok
  defp equal(_value, _expected, p, rule), do: {:error, {p, rule}}

  defp iff(a, b, p, rule), do: if(a == b, do: :ok, else: {:error, {p, rule}})

  defp unique(value, %MapSet{} = seen, p),
    do: if(MapSet.member?(seen, value), do: {:error, {p, :duplicate}}, else: :ok)

  defp unique(value, %{} = seen, p),
    do: if(Map.has_key?(seen, value), do: {:error, {p, :duplicate}}, else: :ok)

  @doc false
  # An RFC 3339 time with an offset (Z or ±hh:mm).
  def time(nil, p), do: {:error, {p, :null}}

  def time(value, p) when is_binary(value) do
    with true <- Regex.match?(@rfc3339, value),
         {:ok, _dt, _offset} <- DateTime.from_iso8601(value) do
      :ok
    else
      _ -> {:error, {p, :format}}
    end
  end

  def time(_value, p), do: {:error, {p, :type}}

  @doc false
  def date(nil, p), do: {:error, {p, :null}}

  def date(value, p) when is_binary(value) do
    with true <- Regex.match?(@date, value), {:ok, _date} <- Date.from_iso8601(value) do
      :ok
    else
      _ -> {:error, {p, :format}}
    end
  end

  def date(_value, p), do: {:error, {p, :type}}

  @doc false
  def local_date!(<<date::binary-size(10), "T", _::binary>>), do: Date.from_iso8601!(date)

  @doc false
  # https only; no userinfo, port, query, fragment, IP literal or reserved host.
  def url(nil, p), do: {:error, {p, :null}}

  def url(value, p) when is_binary(value) do
    if safe_url?(value), do: :ok, else: {:error, {p, :unsafe_url}}
  end

  def url(_value, p), do: {:error, {p, :type}}

  defp safe_url?(value) do
    with true <- byte_size(value) <= @max_url_bytes,
         "https://" <> rest <- value,
         [authority | _] <- String.split(rest, ["/"], parts: 2),
         false <- String.contains?(authority, [":", "@", "[", "]"]),
         {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}} <-
           URI.new(value),
         true <- is_binary(host) and host == authority and host == String.downcase(host) do
      public_host?(host)
    else
      _ -> false
    end
  end

  defp domain(value, p) do
    with :ok <- text(value, p, 1, 253) do
      if value == String.downcase(value) and public_host?(value),
        do: :ok,
        else: {:error, {p, :format}}
    end
  end

  @doc false
  # A lower-case host name of at least two labels that is not an IP literal,
  # not a special-use name, and not an RFC 2606 name outside the test build.
  def public_host?(host) do
    tld = host |> String.split(".") |> List.last()

    Regex.match?(@host, host) and
      :inet.parse_address(String.to_charlist(host)) == {:error, :einval} and
      not String.match?(tld, ~r/\A[0-9]+\z/) and tld not in @reserved_tlds and
      (not rfc2606?(host, tld) or rfc2606_admitted?())
  end

  defp rfc2606?(host, tld),
    do:
      tld in @rfc2606_tlds or
        Enum.any?(@rfc2606_domains, &(host == &1 or String.ends_with?(host, "." <> &1)))

  # The RFC 2606 names are the synthetic fixtures of the hermetic test build
  # only (Codex S3 RED-1 ruling R3): fixed at compile time, never a runtime
  # flag or caller option.
  if @test_seams do
    defp rfc2606_admitted?, do: true
  else
    defp rfc2606_admitted?, do: false
  end

  @doc false
  def host!(url), do: url |> URI.parse() |> Map.fetch!(:host) |> String.downcase()

  @doc false
  def company_host?(host, domain), do: host == domain or String.ends_with?(host, "." <> domain)

  @doc false
  # A schema path string from its segments, in the BoundedJson format.
  def path(segments) do
    Enum.reduce(segments, "", fn
      i, acc when is_integer(i) -> "#{acc}[#{i}]"
      key, "" -> key
      key, acc -> "#{acc}.#{key}"
    end)
  end

  # The segments of a path string built by this module.
  defp segments(p) do
    p
    |> String.split(".")
    |> Enum.flat_map(fn part ->
      case Regex.run(~r/\A([a-z_]+)((?:\[\d+\])*)\z/, part) do
        [_, key, ""] ->
          [key]

        [_, key, idx] ->
          [key | Regex.scan(~r/\d+/, idx) |> List.flatten() |> Enum.map(&String.to_integer/1)]
      end
    end)
  end
end
