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

  GREEN-1 stage (D-237 S3; Codex a322d6d9): `eligibility/4`, `select/4`,
  `eligible_rows/3` and `import_plan/4` are implemented. `read/2` and
  `parse/1` still return `{:error, :not_implemented}`: they wait for S1's
  `SdrAgent.Prototype.BoundedJson` (the byte, UTF-8, duplicate-key, depth,
  key-set and text rules) and their own review.
  """

  alias SdrAgent.Prototype.SpotcheckManifest

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

  @doc "Reads the dossier at `path` once, by its full sha256, and parses it."
  @spec read(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(_path, _sha256), do: red({:error, :not_implemented})

  @doc "Parses and validates dossier bytes; see the moduledoc."
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(_bin), do: red({:error, :not_implemented})

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

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
