defmodule SdrAgent.Agents.RunSettings.Changes.ApplyContentRules do
  @moduledoc """
  Applies the settings content rules (C4, `docs/product/c4/readiness.md`
  sections 3.5 and 12, C4-R12, C4-R13) to fields cast as raw strings
  (`trim?: false, allow_empty?: true`), so that:

    * a forbidden control character or secret-shaped text is refused on the
      raw value, edges included — never trimmed away
      (`SdrAgent.Agents.RunSettings.ContentRules.text/1`);
    * the value is then trimmed (empty becomes nil) and its length checked
      in characters;
    * an item id must match `^[a-z0-9][a-z0-9_-]{0,39}$`;
    * a booking URL must pass `ContentRules.booking_url/1` and the real-data
      guard (`SdrAgent.Agents.RunSettings.booking_host_usable?/1`); it is
      stored exactly as given.

  Every refusal is an error on the field naming the rule, built without the
  value, so no Ash error, inspect output or span status carries settings
  text. Options: `text: [field: {min, max}]`, `ids: [field]`,
  `urls: [field]`.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Agents.RunSettings.ContentRules

  @item_id ~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> each(Keyword.get(opts, :text, []), &text/3)
    |> each(Keyword.get(opts, :ids, []), &id/3)
    |> each(Keyword.get(opts, :urls, []), &url/3)
  end

  defp each(changeset, fields, fun) do
    Enum.reduce(fields, changeset, fn
      {field, bounds}, acc -> fun.(acc, field, bounds)
      field, acc -> fun.(acc, field, nil)
    end)
  end

  defp text(changeset, field, {min, max}) do
    with raw when is_binary(raw) <- Ash.Changeset.get_attribute(changeset, field),
         :ok <- ContentRules.text(raw),
         trimmed = String.trim(raw),
         :ok <- length(trimmed, min, max) do
      value = if trimmed == "", do: nil, else: trimmed
      Ash.Changeset.force_change_attribute(changeset, field, value)
    else
      nil -> changeset
      {:error, rule} -> refuse(changeset, field, rule)
      _other -> refuse(changeset, field, :not_text)
    end
  end

  defp id(changeset, field, _bounds) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        changeset

      id when is_binary(id) ->
        if id =~ @item_id, do: changeset, else: refuse(changeset, field, :id_format)

      _other ->
        refuse(changeset, field, :id_format)
    end
  end

  defp url(changeset, field, _bounds) do
    with url when is_binary(url) <- Ash.Changeset.get_attribute(changeset, field),
         {:ok, uri} <- ContentRules.booking_url(url),
         true <- RunSettings.booking_host_usable?(uri.host) || {:error, :guard_refused} do
      changeset
    else
      nil -> changeset
      {:error, rule} -> refuse(changeset, field, rule)
      _other -> refuse(changeset, field, :not_a_url)
    end
  end

  # Empty is handled by the attribute's required check (nil).
  defp length("", _min, _max), do: :ok

  defp length(text, min, max) do
    case String.length(text) do
      n when n < min -> {:error, :too_short}
      n when n > max -> {:error, :too_long}
      _n -> :ok
    end
  end

  defp refuse(changeset, field, rule),
    do: Ash.Changeset.add_error(changeset, field: field, message: "violates %{rule}", rule: rule)
end
