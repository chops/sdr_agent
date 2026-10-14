defmodule SdrAgent.Inbox.Cursor do
  @moduledoc "Scope-bound, signed global keyset continuation for the fixed C1 producer set."

  @version "c1-inbox/1"
  @salt "c1-inbox-cursor/1"

  @doc "The nonsensitive fixed filter/producer-set fingerprint of a current actor."
  def scope(actor), do: {@version, actor.tenant_id, actor.id, :email_and_live_failures}

  @doc "Sign the last returned sort key, never the last fetched candidate."
  def encode(actor, key, secret), do: Phoenix.Token.sign(secret, @salt, {scope(actor), key})

  @doc "Reject malformed, altered, expired, cross-user or cross-version continuations."
  def decode(nil, _actor, _secret), do: {:ok, nil}

  def decode(cursor, actor, secret) when is_binary(cursor) and byte_size(cursor) <= 4_096 do
    expected = scope(actor)

    with {:ok, {^expected, key}} <-
           Phoenix.Token.verify(secret, @salt, cursor, max_age: 86_400),
         true <- valid_key?(key) do
      {:ok, key}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def decode(_, _, _), do: {:error, :invalid_input}

  @doc "Stable ordering: priority, oldest source instant, producer, source UUID."
  def key(priority, time, producer, id),
    do: {priority, DateTime.to_unix(time, :microsecond), producer, id}

  defp valid_key?({priority, instant, producer, id}) do
    priority in [0, 1] and is_integer(instant) and
      producer in ["operations_failures", "outreach_drafts"] and
      match?({:ok, _}, DateTime.from_unix(instant, :microsecond)) and
      match?({:ok, _}, Ecto.UUID.cast(id))
  end

  defp valid_key?(_), do: false
end
