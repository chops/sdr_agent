defmodule SdrAgent.Agents.RunSettings.ContentRules do
  @moduledoc """
  The content rules of run settings text (C4, `docs/product/c4/readiness.md`
  sections 3.5 and 12, C4-R12, C4-R13), applied to the raw input before
  surrounding whitespace is trimmed, so a forbidden control character or a
  secret-shaped value at an edge is refused, never trimmed away.

    * `text/1` — valid UTF-8; no control character other than newline and
      tab; not secret-shaped.
    * `secret_shaped?/1` — the raw value would be changed by
      `SdrAgent.Operations.Redactor.redact/1` (credential patterns, secret
      key/value pairs, long hexadecimal or base64-like runs), exactly as
      packet section 3.5 states; nothing is shortened or exempted first.
    * `booking_url/1` — the static rules of a booking link: `https` only, a
      host name, no user info, no IP literal, `localhost` or `.local`, port
      absent or 443, no control or whitespace character, at most 2,048 bytes,
      not secret-shaped. The real-data guard is applied separately, at save
      and at every use (`SdrAgent.Agents.RunSettings.booking_host_usable?/1`).

  `validate/2` checks a whole content input of one kind against these rules
  and the field limits of section 3.2 before Ash casts it, so an invalid
  input never reaches an embedded resource action (whose error and span
  status would print the value). Each refusal is `{field, rule}`; no
  message ever carries the value.
  """

  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Operations.Redactor

  @item_kinds [:feature, :use_case, :outcome, :limit, :proof_point]
  @depths [:standard]
  @item_id ~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/
  @max_profile_bytes 16 * 1024
  @cross_field [
    {:research_max_source_chars, :research_max_total_source_chars},
    {:research_max_model_calls, :run_max_model_calls},
    {:research_target_seconds, :research_job_limit_seconds}
  ]

  @max_url_bytes 2_048
  # Control characters other than newline (0x0A) and tab (0x09), C0 and C1.
  @forbidden_controls ~r/[\x{00}-\x{08}\x{0B}-\x{1F}\x{7F}-\x{9F}]/u
  @url_forbidden ~r/[\x{00}-\x{20}\x{7F}-\x{A0}\x{2028}\x{2029}]/u

  @doc """
  `:ok`, or `{:error, [{field, rule}]}` for the content input of `kind`
  (atom-keyed, as section 12 rules; string keys are accepted too). Text is
  checked raw, then trimmed and length-checked in characters.
  """
  @spec validate(atom(), map()) :: :ok | {:error, [{atom(), atom()}]}
  def validate(kind, content) when is_map(content) do
    case Enum.reverse(errors(kind, content)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(kind, _content), do: {:error, [{kind, :not_a_map}]}

  defp errors(:offering_profile, content) do
    []
    |> text(content, :name, 1, 120)
    |> text(content, :summary, 1, 1_500)
    |> text(content, :audience, 0, 1_500, optional: true)
    |> items(content)
    |> unknown(content, [:name, :summary, :audience, :items])
    |> profile_size(content)
  end

  defp errors(:booking_link, content) do
    errors =
      case get(content, :url) do
        url when is_binary(url) ->
          with {:ok, uri} <- booking_url(url),
               true <- RunSettings.booking_host_usable?(uri.host) || {:error, :guard_refused} do
            []
          else
            {:error, rule} -> [{:url, rule}]
          end

        nil ->
          [{:url, :required}]

        _other ->
          [{:url, :not_text}]
      end

    unknown(errors, content, [:url])
  end

  defp errors(:writing_guide, content),
    do: [] |> text(content, :text, 1, 6_000) |> unknown(content, [:text])

  defp errors(:research_brief, content) do
    []
    |> text(content, :guidance, 1, 12_000)
    |> one_of(content, :depth, @depths)
    |> unknown(content, [:guidance, :depth])
  end

  defp errors(:operational_limits, content) do
    errors =
      Enum.reduce(Safeguards.limit_rules(), [], fn {field, %{min: min, max: max}}, acc ->
        case get(content, field) do
          value when is_integer(value) and value >= min and value <= max -> acc
          value when is_integer(value) -> [{field, :out_of_range} | acc]
          nil -> [{field, :required} | acc]
          _other -> [{field, :not_an_integer} | acc]
        end
      end)

    errors = if errors == [], do: cross_field(content), else: errors
    unknown(errors, content, Safeguards.limit_fields())
  end

  defp errors(kind, _content), do: [{kind, :unknown_kind}]

  defp cross_field(content) do
    for {small, large} <- @cross_field, get(content, small) > get(content, large) do
      {small, :cross_field}
    end
  end

  defp text(errors, content, field, min, max, opts \\ []) do
    case get(content, field) do
      raw when is_binary(raw) ->
        with :ok <- text(raw),
             :ok <- text_length(String.trim(raw), min, max, opts) do
          errors
        else
          {:error, rule} -> [{field, rule} | errors]
        end

      nil ->
        if opts[:optional], do: errors, else: [{field, :required} | errors]

      _other ->
        [{field, :not_text} | errors]
    end
  end

  defp text_length("", _min, _max, opts),
    do: if(opts[:optional], do: :ok, else: {:error, :required})

  defp text_length(text, min, max, _opts) do
    case String.length(text) do
      n when n < min -> {:error, :too_short}
      n when n > max -> {:error, :too_long}
      _n -> :ok
    end
  end

  defp items(errors, content) do
    case get(content, :items) do
      items when is_list(items) and items != [] and length(items) <= 30 ->
        item_errors(items) ++ errors

      items when is_list(items) ->
        [{:items, :count} | errors]

      nil ->
        [{:items, :required} | errors]

      _other ->
        [{:items, :not_a_list} | errors]
    end
  end

  defp item_errors(items) do
    ids = Enum.map(items, &(is_map(&1) && get(&1, :id)))
    unique? = length(ids) == length(Enum.uniq(ids))

    case Enum.flat_map(items, &item/1) do
      [] when not unique? -> [{:items, :duplicate_id}]
      errors -> Enum.reverse(errors)
    end
  end

  defp item(item) when is_map(item) do
    id =
      case get(item, :id) do
        id when is_binary(id) -> if id =~ @item_id, do: [], else: [{:id, :id_format}]
        _other -> [{:id, :id_format}]
      end

    []
    |> text(item, :text, 1, 400)
    |> one_of(item, :kind, @item_kinds)
    |> unknown(item, [:id, :kind, :text])
    |> Kernel.++(id)
  end

  defp item(_item), do: [{:items, :not_a_map}]

  defp one_of(errors, content, field, allowed) do
    value = get(content, field)

    if value in allowed or (is_binary(value) and value in Enum.map(allowed, &Atom.to_string/1)),
      do: errors,
      else: [{field, :not_allowed} | errors]
  end

  defp unknown(errors, content, fields) do
    allowed = fields ++ Enum.map(fields, &Atom.to_string/1)

    if Enum.all?(Map.keys(content), &(&1 in allowed)),
      do: errors,
      else: [{:content, :unknown_field} | errors]
  end

  # The canonical encoding of the trimmed profile (section 3.2: ≤ 16 KiB).
  defp profile_size([], content) do
    trimmed =
      Map.new([:name, :summary, :audience, :items], fn field ->
        {field, trim_value(get(content, field))}
      end)

    case Canonical.encode(trimmed) do
      {:ok, bytes} when byte_size(bytes) <= @max_profile_bytes -> []
      _too_large -> [{:items, :too_large}]
    end
  end

  defp profile_size(errors, _content), do: errors

  defp trim_value(value) when is_binary(value), do: String.trim(value)
  defp trim_value(list) when is_list(list), do: Enum.map(list, &trim_value/1)
  defp trim_value(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, trim_value(v)} end)
  defp trim_value(value), do: value

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  @doc """
  `:ok`, or `{:error, [{field, rule}]}` for the whole input of a settings
  save (`SdrAgent.Agents.create_settings_revision/2`), checked before any
  Ash cast: `kind` one of the five kinds, `content` a map valid for it
  (`validate/2`), `note` nil or settings text of at most 200 characters,
  `expected_number` a whole number ≥ 0, and `confirm_raised` a list of
  distinct limit field names (atoms, or strings matching one; never a new
  atom), empty for a kind other than `:operational_limits`.
  """
  @spec input(map()) :: :ok | {:error, [{atom(), atom()}]}
  def input(attrs) when is_map(attrs) do
    kind = Map.get(attrs, :kind)

    errors =
      kind_errors(kind) ++
        content_errors(kind, Map.get(attrs, :content)) ++
        note_errors(Map.get(attrs, :note)) ++
        number_errors(Map.get(attrs, :expected_number)) ++
        confirm_errors(kind, Map.get(attrs, :confirm_raised))

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  The limit field names of `confirm_raised` as atoms (strings matched
  against the known names; never a new atom).
  """
  @spec confirm_names(term()) :: [atom()]
  def confirm_names(nil), do: []
  def confirm_names(list) when is_list(list), do: Enum.map(list, &limit_name/1)

  @doc """
  An embedded settings struct as plain input (public attributes only), so it
  is validated again like any other input; other terms are unchanged.
  """
  @spec plain(term()) :: term()
  def plain(%module{} = struct) do
    if Ash.Resource.Info.resource?(module) do
      module
      |> Ash.Resource.Info.public_attributes()
      |> Map.new(&{&1.name, plain(Map.get(struct, &1.name))})
    else
      struct
    end
  end

  def plain(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, plain(value)} end)
  def plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  def plain(other), do: other

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]

  defp kind_errors(kind) when kind in @kinds, do: []
  defp kind_errors(_kind), do: [{:kind, :not_allowed}]

  defp content_errors(kind, content) when kind in @kinds and is_map(content) do
    with {:ok, content} <- canonical(kind, plain(content)),
         :ok <- validate(kind, content) do
      []
    else
      {:error, errors} -> errors
    end
  end

  defp content_errors(kind, _content) when kind in @kinds, do: [{:content, :not_a_map}]
  defp content_errors(_kind, _content), do: []

  defp note_errors(nil), do: []

  defp note_errors(note) when is_binary(note) do
    case text([], %{note: note}, :note, 0, 200, optional: true) do
      [] -> []
      errors -> errors
    end
  end

  defp note_errors(_note), do: [{:note, :not_text}]

  defp number_errors(n) when is_integer(n) and n >= 0, do: []
  defp number_errors(_n), do: [{:expected_number, :invalid}]

  defp confirm_errors(_kind, nil), do: []

  defp confirm_errors(kind, list) when is_list(list) do
    names = Enum.map(list, &limit_name/1)

    cond do
      :unknown in names -> [{:confirm_raised, :unknown}]
      length(Enum.uniq(names)) != length(names) -> [{:confirm_raised, :duplicate}]
      kind != :operational_limits and names != [] -> [{:confirm_raised, :not_limits}]
      true -> []
    end
  end

  defp confirm_errors(_kind, _other), do: [{:confirm_raised, :not_a_list}]

  defp limit_name(name) when is_atom(name) do
    if name in Safeguards.limit_fields(), do: name, else: :unknown
  end

  defp limit_name(name) when is_binary(name),
    do: Enum.find(Safeguards.limit_fields(), :unknown, &(Atom.to_string(&1) == name))

  defp limit_name(_name), do: :unknown

  @content_fields %{
    offering_profile: [:name, :summary, :audience, :items],
    booking_link: [:url],
    writing_guide: [:text],
    research_brief: [:guidance, :depth],
    operational_limits: Safeguards.limit_fields()
  }
  @item_fields [:id, :kind, :text]

  @doc """
  The one representation of a content input that is both validated and cast:
  every known field under its atom key, recursively through offering items.
  A field given under both its atom and its string key is refused
  (`{field, :alias_conflict}`), whatever the two values are, so validation
  and the Ash cast can never see different values; neither value is echoed.
  Unknown keys are kept, for `validate/2` to refuse. `{:ok, content}` or
  `{:error, [{field, rule}]}`.
  """
  @spec canonical(atom(), term()) :: {:ok, term()} | {:error, [{atom(), atom()}]}
  def canonical(kind, content) when is_map(content) do
    with {:ok, content} <- keyed(content, Map.get(@content_fields, kind, [])) do
      canonical_items(kind, content)
    end
  end

  def canonical(_kind, content), do: {:ok, content}

  defp canonical_items(:offering_profile, %{items: items} = content) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn
      item, {:ok, acc} when is_map(item) ->
        case keyed(item, @item_fields) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          error -> {:halt, error}
        end

      item, {:ok, acc} ->
        {:cont, {:ok, [item | acc]}}
    end)
    |> case do
      {:ok, items} -> {:ok, %{content | items: Enum.reverse(items)}}
      error -> error
    end
  end

  defp canonical_items(_kind, content), do: {:ok, content}

  defp keyed(map, fields) do
    conflicts =
      for field <- fields,
          Map.has_key?(map, field) and Map.has_key?(map, Atom.to_string(field)),
          do: {field, :alias_conflict}

    if conflicts == [] do
      {:ok,
       Map.new(map, fn {key, value} ->
         case Enum.find(fields, &(Atom.to_string(&1) == key)) do
           nil -> {key, value}
           field -> {field, value}
         end
       end)}
    else
      {:error, conflicts}
    end
  end

  @doc "`:ok` or `{:error, rule}` for settings text (before trimming)."
  @spec text(String.t()) :: :ok | {:error, atom()}
  def text(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      Regex.match?(@forbidden_controls, value) -> {:error, :control_character}
      secret_shaped?(value) -> {:error, :secret_shaped}
      true -> :ok
    end
  end

  @doc "Whether `value` holds a secret-shaped substring (see the moduledoc)."
  @spec secret_shaped?(String.t()) :: boolean()
  def secret_shaped?(value) when is_binary(value) do
    Redactor.redact(value) != value
  end

  @doc "`{:ok, %URI{}}` or `{:error, rule}` for a booking link (static rules)."
  @spec booking_url(String.t()) :: {:ok, URI.t()} | {:error, atom()}
  def booking_url(url) when is_binary(url) do
    with :ok <- url_text(url),
         {:ok, uri} <- parse(url),
         :ok <- https(uri),
         :ok <- host(uri),
         :ok <- no_userinfo(uri),
         :ok <- port(uri) do
      {:ok, uri}
    end
  end

  defp url_text(url) do
    cond do
      byte_size(url) > @max_url_bytes -> {:error, :too_long}
      not String.valid?(url) -> {:error, :invalid_utf8}
      Regex.match?(@url_forbidden, url) -> {:error, :whitespace_or_control}
      secret_shaped?(url) -> {:error, :secret_shaped}
      true -> :ok
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, :not_a_url}
    end
  end

  defp https(%URI{scheme: "https"}), do: :ok
  defp https(_uri), do: {:error, :not_https}

  defp host(%URI{host: host}) when is_binary(host) and host != "" do
    host = String.downcase(host)

    cond do
      ip_literal?(host) -> {:error, :ip_literal}
      host == "localhost" or String.ends_with?(host, ".localhost") -> {:error, :local_host}
      host == "local" or String.ends_with?(host, ".local") -> {:error, :local_host}
      not String.contains?(host, ".") -> {:error, :host_not_qualified}
      true -> :ok
    end
  end

  defp host(_uri), do: {:error, :no_host}

  defp ip_literal?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp no_userinfo(%URI{userinfo: nil}), do: :ok
  defp no_userinfo(_uri), do: {:error, :userinfo}

  # URI.new/1 fills the scheme's default port (443) when none is given.
  defp port(%URI{port: 443}), do: :ok
  defp port(_uri), do: {:error, :port}
end
