defmodule SdrAgent.SDR.Admission.Input do
  @moduledoc """
  The lead admission's input, version 1 (C3-02; packet sections 4.1, 4.3
  and 5.2): validation and normalization into the hashed document, and its
  hash. Pure: no database, no log, no span.

  `normalize(input, tenant_id)` returns `{:ok, doc}` or
  `{:error, {:invalid, [field]}}` naming the first refused leaf field and
  never its value. `doc` has string keys and always every v1 key (absent
  values `nil`):

    * `v` = `"c3-admission-input/1"`; `tenant_id`, `campaign_id`,
      `agent_run_id` (agent_found only, else `nil`) as lowercase hyphenated
      uuids; `original_lead_id` = `nil` (a referral is not admitted here);
      `source_kind` (string); `source_ref` exactly as given; `readmit`
      (boolean, default `false`);
    * `company`: `domain` (`SdrAgent.Sales.Domain.canonical/1`, the company
      identity), `name`, `website_url`, `industry`, `employee_count`
      (integer ≥ 0) and `geography`;
    * `person`: `email` (trimmed, lowercased), `first_name`, `last_name`,
      `title` and `timezone` (as given, an IANA name).

  Normalization order (packet section 5.2): reject non-UTF-8; Unicode NFC;
  trim; collapse internal whitespace runs to one space in `name`,
  `first_name`, `last_name`, `title`, `industry` and `geography`; empty
  string to `nil`; then the domain through `company/1`, the email
  lowercased, `website_url` trimmed only, `timezone` as given; uuids
  lowercased. A uuid is accepted only in its 36-character textual form
  (any case); a raw binary is refused. An email is accepted only when the
  identity keys can represent it (exactly one `@`, non-empty parts, no
  whitespace or control character, `Normalize.key_value/2`), so a refused
  one is this step's `{:invalid, [:email]}`, never a later key failure.

  Also checked here, before any lock (packet section 4.1 step 3): the kind
  (`manual`, `csv`, `hubspot`, `agent_found`), the per-kind `source_ref`
  grammar (≤ 120, ids only, lowercase uuids), the embedded discovery run id
  (agent_found: `agent_run_id` is required and equals the ref's run
  segment; any other kind refuses `agent_run_id`), `readmit` (accepted only
  for `manual`; its mere presence for another kind is refused, packet
  section 4.3) and a required domain and email. Names required for a new
  company or person are checked by the admission once it knows (they are
  in the document either way).

  `sha256(doc)` = lowercase hex `sha256(SdrAgent.Audit.Canonical.encode(doc))`.
  """

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Sales.Domain
  alias SdrAgent.Sales.LocalTime

  @version "c3-admission-input/1"
  @kinds [:manual, :csv, :hubspot, :agent_found]
  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @refs %{
    manual: ~r/\Amanual:#{@uuid}\z/,
    csv: ~r/\Acsv:#{@uuid}:[1-9][0-9]*\z/,
    hubspot: ~r/\Ahubspot:[0-9]+:[0-9]+\z/,
    agent_found: ~r/\Aagent_found:(#{@uuid}):#{@uuid}\z/
  }
  # Exactly one `@`, non-empty parts, no whitespace or control character:
  # the identity-key email representation (`Normalize.key_value/2`).
  @email ~r/\A[^\s\p{Cc}@]+@[^\s\p{Cc}@]+\z/u
  # A textual uuid only (36 characters; any case, lowercased).
  @textual_uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @zone ~r/^(UTC|Etc\/UTC|[A-Z][A-Za-z_-]+(\/[A-Za-z0-9_+-]+){1,2})$/

  @type doc :: %{String.t() => term()}

  @doc "The admission kinds this module accepts."
  def kinds, do: @kinds

  @doc "Validates and normalizes `input` for `tenant_id` (see the moduledoc)."
  @spec normalize(map(), String.t()) :: {:ok, doc()} | {:error, {:invalid, [atom()]}}
  def normalize(input, tenant_id) when is_map(input) do
    with {:ok, tenant_id} <- uuid(tenant_id, :tenant_id),
         {:ok, kind} <- kind(Map.get(input, :source_kind)),
         {:ok, ref} <- ref(kind, Map.get(input, :source_ref)),
         {:ok, campaign_id} <- uuid(Map.get(input, :campaign_id), :campaign_id),
         {:ok, readmit} <- readmit(kind, input),
         {:ok, agent_run_id} <- agent_run_id(kind, ref, Map.get(input, :agent_run_id)),
         {:ok, company} <- company(Map.get(input, :company)),
         {:ok, person} <- person(Map.get(input, :person)) do
      {:ok,
       %{
         "v" => @version,
         "tenant_id" => tenant_id,
         "campaign_id" => campaign_id,
         "source_kind" => Atom.to_string(kind),
         "source_ref" => ref,
         "readmit" => readmit,
         "agent_run_id" => agent_run_id,
         "original_lead_id" => nil,
         "company" => company,
         "person" => person
       }}
    else
      {:error, field} -> {:error, {:invalid, [field]}}
    end
  end

  def normalize(_input, _tenant_id), do: {:error, {:invalid, [:source_kind]}}

  @doc "The lowercase hex sha256 of the canonical encoding of `doc`."
  @spec sha256(doc()) :: String.t()
  def sha256(doc), do: doc |> Canonical.sha256() |> Base.encode16(case: :lower)

  ## Top level

  defp kind(kind) when kind in @kinds, do: {:ok, kind}
  defp kind(_other), do: {:error, :source_kind}

  defp ref(kind, ref) when is_binary(ref) do
    if byte_size(ref) <= 120 and String.valid?(ref) and Regex.match?(Map.fetch!(@refs, kind), ref),
      do: {:ok, ref},
      else: {:error, :source_ref}
  end

  defp ref(_kind, _ref), do: {:error, :source_ref}

  defp readmit(:manual, input) do
    case Map.get(input, :readmit, false) do
      flag when is_boolean(flag) -> {:ok, flag}
      _other -> {:error, :readmit}
    end
  end

  defp readmit(_kind, input),
    do: if(Map.has_key?(input, :readmit), do: {:error, :readmit}, else: {:ok, false})

  defp agent_run_id(:agent_found, ref, raw) do
    [_ref, embedded] = Regex.run(@refs.agent_found, ref)

    case uuid(raw, :agent_run_id) do
      {:ok, ^embedded} -> {:ok, embedded}
      _missing_or_other -> {:error, :agent_run_id}
    end
  end

  defp agent_run_id(_kind, _ref, nil), do: {:ok, nil}
  defp agent_run_id(_kind, _ref, _raw), do: {:error, :agent_run_id}

  # Codex fb5166a G4-2: the textual form only, never a raw 16-byte binary
  # (which `Ecto.UUID.cast/1` would also accept).
  defp uuid(raw, field) when is_binary(raw) and byte_size(raw) == 36 do
    if String.valid?(raw) and Regex.match?(@textual_uuid, raw),
      do: {:ok, String.downcase(raw)},
      else: {:error, field}
  end

  defp uuid(_raw, field), do: {:error, field}

  ## Company and person

  defp company(company) when is_map(company) do
    with {:ok, domain} <- domain(Map.get(company, :domain)),
         {:ok, name} <- text(Map.get(company, :name), :name, true),
         {:ok, website_url} <- text(Map.get(company, :website_url), :website_url, false),
         {:ok, industry} <- text(Map.get(company, :industry), :industry, true),
         {:ok, employee_count} <- employee_count(Map.get(company, :employee_count)),
         {:ok, geography} <- text(Map.get(company, :geography), :geography, true) do
      {:ok,
       %{
         "domain" => domain,
         "name" => name,
         "website_url" => website_url,
         "industry" => industry,
         "employee_count" => employee_count,
         "geography" => geography
       }}
    end
  end

  defp company(_company), do: {:error, :domain}

  defp person(person) when is_map(person) do
    with {:ok, email} <- email(Map.get(person, :email)),
         {:ok, first_name} <- text(Map.get(person, :first_name), :first_name, true),
         {:ok, last_name} <- text(Map.get(person, :last_name), :last_name, true),
         {:ok, title} <- text(Map.get(person, :title), :title, true),
         {:ok, timezone} <- timezone(Map.get(person, :timezone)) do
      {:ok,
       %{
         "email" => email,
         "first_name" => first_name,
         "last_name" => last_name,
         "title" => title,
         "timezone" => timezone
       }}
    end
  end

  defp person(_person), do: {:error, :email}

  defp domain(raw) do
    with {:ok, value} when is_binary(value) <- text(raw, :domain, false),
         {:ok, domain} <- Domain.canonical(value) do
      {:ok, domain}
    else
      _invalid -> {:error, :domain}
    end
  end

  defp email(raw) do
    with {:ok, value} when is_binary(value) <- text(raw, :email, false),
         value = String.downcase(value),
         true <- Regex.match?(@email, value) do
      {:ok, value}
    else
      _invalid -> {:error, :email}
    end
  end

  defp timezone(raw) do
    case text(raw, :timezone, false) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, zone} ->
        if Regex.match?(@zone, zone) and LocalTime.valid_zone?(zone),
          do: {:ok, zone},
          else: {:error, :timezone}

      error ->
        error
    end
  end

  defp employee_count(nil), do: {:ok, nil}
  defp employee_count(count) when is_integer(count) and count >= 0, do: {:ok, count}
  defp employee_count(_count), do: {:error, :employee_count}

  # Steps (1)-(5) of the normalization order for one text leaf.
  defp text(nil, _field, _collapse?), do: {:ok, nil}

  defp text(value, field, collapse?) when is_binary(value) do
    if String.valid?(value) do
      value = value |> :unicode.characters_to_nfc_binary() |> String.trim()
      value = if collapse?, do: String.replace(value, ~r/\s+/u, " "), else: value
      {:ok, if(value == "", do: nil, else: value)}
    else
      {:error, field}
    end
  end

  defp text(_value, field, _collapse?), do: {:error, field}
end
