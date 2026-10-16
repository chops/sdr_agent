defmodule SdrAgentWeb.SettingsLive.Form do
  @moduledoc """
  The staged settings editor's form data (C4-01b, `docs/product/c4/readiness.md`
  sections 3.3, 3.5, 3.6 and 12; the C9-05 `SdrAgentWeb.GrantForm` pattern):
  browser params of `SdrAgentWeb.SettingsLive` to and from the content shapes
  of `SdrAgent.Agents.create_settings_revision/2`.

    * `kind/1` maps a browser kind to one of the five kinds through a fixed
      whitelist; `normalize/2` keeps only the whitelisted fields of that kind
      (and `note`), as strings, with offering items keyed by their numeric
      row index. No atom is ever created from a param, and any other shape
      is dropped rather than crashing the page.
    * `params_for/2` fills the form from the setting in effect;
      `content/2` and `note/1` build the domain input from the params
      (whole-number strings become integers, anything else stays as typed
      for the content rules to refuse).
    * `check/4` applies the domain's own content rules
      (`SdrAgent.Agents.RunSettings.ContentRules.input/1`) before the review
      step, so a review shows only content the rules accept; the
      confirmation is still decided by the domain.
    * `raised/2` names the limit fields raised above the value in effect,
      each needing the admin's confirmation; `confirmed/2` maps the ticked
      boxes onto that held set.
    * `errors_by_field/2` and `message/2` turn `{field, rule}` refusals into
      operator-safe text shown next to the field. A message names the field
      and the rule, never the submitted value.

  All of this text is settings content: it lives under the `settings_content`
  param key (filtered by `config :phoenix, :filter_parameters`) and is never
  logged (`SettingsLive` uses `log: false`).
  """

  alias SdrAgent.Agents.RunSettings.ContentRules
  alias SdrAgent.Agents.RunSettings.Safeguards

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]
  @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})

  # The item kinds and research depths the content rules accept (section 3.2);
  # offered as select options and sent to the domain as strings.
  @item_kinds ~w(feature use_case outcome limit proof_point)
  @depths ~w(standard)
  @item_fields ~w(id kind text)

  @index ~r/\A\d{1,3}\z/
  @integer ~r/\A\s*-?\d+\s*\z/

  @doc "The five settings kinds, in packet order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The kind named by a browser param, or nil (never a new atom)."
  @spec kind(term()) :: atom() | nil
  def kind(name) when is_binary(name), do: Map.get(@kind_names, name)
  def kind(_name), do: nil

  @doc "The offering item kinds offered by the form."
  @spec item_kinds() :: [String.t()]
  def item_kinds, do: @item_kinds

  @doc "The research depths offered by the form."
  @spec depths() :: [String.t()]
  def depths, do: @depths

  @doc "The twelve limit field names as strings, in packet order."
  @spec limit_names() :: [String.t()]
  def limit_names, do: Enum.map(Safeguards.limit_fields(), &Atom.to_string/1)

  @doc "The plain form fields of `kind` (strings; offering items aside), without `note`."
  @spec fields(atom()) :: [String.t()]
  def fields(:offering_profile), do: ~w(name summary audience)
  def fields(:booking_link), do: ~w(url)
  def fields(:writing_guide), do: ~w(text)
  def fields(:research_brief), do: ~w(guidance depth)
  def fields(:operational_limits), do: limit_names()

  @doc "Form params of `kind` filled from `content` (a revision's or default's), or empty."
  @spec params_for(atom(), map() | nil) :: map()
  def params_for(kind, content) do
    base =
      Map.new(fields(kind), fn field -> {field, text_of(value(content, field))} end)

    base = Map.put(base, "note", "")

    if kind == :offering_profile,
      do: Map.put(base, "items", items_for(content)),
      else: base
  end

  defp items_for(nil), do: %{"0" => empty_item()}

  defp items_for(content) do
    case value(content, "items") do
      [_ | _] = items ->
        items
        |> Enum.with_index()
        |> Map.new(fn {item, index} ->
          {Integer.to_string(index), Map.new(@item_fields, &{&1, text_of(value(item, &1))})}
        end)

      _none ->
        %{"0" => empty_item()}
    end
  end

  defp empty_item, do: %{"id" => "", "kind" => hd(@item_kinds), "text" => ""}

  @doc """
  The whitelisted string params of `kind` from a raw `settings_content`
  map; nil for any other shape (the event is then ignored).
  """
  @spec normalize(atom(), term()) :: map() | nil
  def normalize(kind, raw) when is_map(raw) do
    base = Map.new(fields(kind) ++ ["note"], fn field -> {field, string(Map.get(raw, field))} end)

    if kind == :offering_profile,
      do: Map.put(base, "items", normalize_items(Map.get(raw, "items"))),
      else: base
  end

  def normalize(_kind, _raw), do: nil

  defp normalize_items(items) when is_map(items) do
    for {index, item} <- items, is_binary(index), index =~ @index, is_map(item), into: %{} do
      {index, Map.new(@item_fields, &{&1, string(Map.get(item, &1))})}
    end
  end

  defp normalize_items(_items), do: %{}

  @doc "The params with one more, empty offering item row."
  @spec add_item(map()) :: map()
  def add_item(params) do
    items = Map.get(params, "items", %{})
    next = items |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)
    Map.put(params, "items", Map.put(items, Integer.to_string(next + 1), empty_item()))
  end

  @doc "The params without offering item row `index` (an existing row only)."
  @spec remove_item(map(), term()) :: map()
  def remove_item(params, index) when is_binary(index) do
    items = Map.get(params, "items", %{})

    if Map.has_key?(items, index),
      do: Map.put(params, "items", Map.delete(items, index)),
      else: params
  end

  def remove_item(params, _index), do: params

  @doc "The offering item rows of `params` as `[{index, row}]`, in row order."
  @spec item_rows(map()) :: [{String.t(), map()}]
  def item_rows(params) do
    params
    |> Map.get("items", %{})
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
  end

  @doc """
  The atom-keyed content input of `kind` for the domain, from `params`.
  Text is passed as typed (the domain trims it); a whole-number string of a
  limit becomes an integer, anything else stays as typed so the content
  rules refuse it; an empty field is absent (`nil`).
  """
  @spec content(atom(), map()) :: map()
  def content(:offering_profile, params) do
    %{
      name: blank_nil(params["name"]),
      summary: blank_nil(params["summary"]),
      audience: params["audience"] || "",
      items:
        for {_index, row} <- item_rows(params) do
          %{id: row["id"], kind: blank_nil(row["kind"]), text: blank_nil(row["text"])}
        end
    }
  end

  def content(:booking_link, params), do: %{url: blank_nil(params["url"])}
  def content(:writing_guide, params), do: %{text: blank_nil(params["text"])}

  def content(:research_brief, params),
    do: %{guidance: blank_nil(params["guidance"]), depth: blank_nil(params["depth"])}

  def content(:operational_limits, params) do
    Map.new(Safeguards.limit_fields(), fn field ->
      {field, integer(params[Atom.to_string(field)])}
    end)
  end

  @doc "The revision note of `params`: nil when blank."
  @spec note(map()) :: String.t() | nil
  def note(params), do: blank_nil(params["note"])

  @doc """
  The domain's content rules on the staged save: `:ok`, or `{:error,
  [{field, rule}]}` (no value is ever echoed).
  """
  @spec check(atom(), map(), String.t() | nil, non_neg_integer()) ::
          :ok | {:error, [{atom(), atom()}]}
  def check(kind, content, note, expected_number) do
    ContentRules.input(%{
      kind: kind,
      content: content,
      note: note,
      expected_number: expected_number,
      confirm_raised: []
    })
  end

  @doc "The limit fields of `content` raised above `in_effect`, in packet order."
  @spec raised(map(), map()) :: [atom()]
  def raised(content, in_effect) do
    for field <- Safeguards.limit_fields(),
        is_integer(content[field]) and content[field] > Map.fetch!(in_effect, field),
        do: field
  end

  @doc """
  The held raised fields whose box the admin ticked (`confirm_raised[]`);
  anything else in the params is ignored.
  """
  @spec confirmed(term(), [atom()]) :: [atom()]
  def confirmed(ticked, raised) when is_list(ticked) do
    names = for name <- ticked, is_binary(name), do: name
    Enum.filter(raised, &(Atom.to_string(&1) in names))
  end

  def confirmed(_ticked, _raised), do: []

  @doc """
  The refusals of `kind` grouped by the form field they are shown next to:
  `%{field => [message]}`. Offering item refusals are shown at `items`;
  anything that names no form field is shown at `base`.
  """
  @spec errors_by_field(atom(), [{atom(), atom()}]) :: %{String.t() => [String.t()]}
  def errors_by_field(kind, errors) do
    shown = fields(kind) ++ ["note", "confirm_raised"]

    errors
    |> Enum.map(fn {field, rule} ->
      name = to_string(field)

      target =
        cond do
          kind == :offering_profile and name in ["items" | @item_fields] -> "items"
          name in shown -> name
          true -> "base"
        end

      {target, message(field, rule)}
    end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "An operator-safe message for refusal `rule` of `field` (never the value)."
  @spec message(atom(), atom()) :: String.t()
  def message(:research_max_source_chars, :cross_field),
    do: "must not exceed the total source characters"

  def message(:research_max_model_calls, :cross_field),
    do: "must not exceed the run's model calls"

  def message(:research_target_seconds, :cross_field),
    do: "must not exceed the research job limit"

  def message(:confirm_raised, _rule),
    do: "Confirm each raised limit by ticking it in the review before saving."

  def message(_field, rule), do: rule_message(rule)

  @rules %{
    required: "is required",
    too_short: "is too short",
    too_long: "is too long",
    not_text: "must be text",
    invalid_utf8: "is not valid text",
    control_character: "contains a control character (only newlines and tabs are allowed)",
    secret_shaped:
      "looks like a secret (a key, token or credential) and was refused; settings must hold none",
    out_of_range: "is outside the allowed range",
    not_an_integer: "must be a whole number",
    not_allowed: "is not one of the allowed values",
    unknown_field: "holds a field this setting does not have",
    alias_conflict: "was given twice",
    count: "needs between 1 and 30 items",
    not_a_list: "must be a list of items",
    not_a_map: "is not in the expected shape",
    duplicate_id: "item ids must be unique",
    id_format: "item ids use lowercase letters, digits, _ and -, at most 40 characters",
    too_large: "is larger than the 16 KiB a profile may hold",
    not_https: "must be an https link",
    not_a_url: "is not a link",
    no_host: "must name a host",
    ip_literal: "must name a host, not an IP address",
    local_host: "must not be a local host",
    host_not_qualified: "must name a full host name",
    userinfo: "must not contain a user name or password",
    port: "must not name a port other than 443",
    whitespace_or_control: "must not contain spaces or control characters",
    guard_refused: "names a host that is not allowed while only synthetic data is permitted",
    mismatch: "does not match the raised limits",
    invalid: "is invalid"
  }

  defp rule_message(rule), do: Map.get(@rules, rule, "is invalid")

  defp value(nil, _field), do: nil

  defp value(content, field) when is_map(content) do
    case Enum.find(Map.keys(content), &(to_string(&1) == field)) do
      nil -> nil
      key -> Map.get(content, key)
    end
  end

  defp text_of(nil), do: ""
  defp text_of(value) when is_binary(value), do: value
  defp text_of(value) when is_integer(value) or is_atom(value), do: to_string(value)
  defp text_of(_value), do: ""

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp blank_nil(nil), do: nil

  defp blank_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp integer(nil), do: nil

  defp integer(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> nil
      value =~ @integer -> value |> String.trim() |> String.to_integer()
      true -> value
    end
  end
end
