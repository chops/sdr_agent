defmodule SdrAgent.Inbox.Command do
  @moduledoc """
  Pure, closed Home command value validation. Accepts typed atom-keyed
  backend requests only; it never casts browser parameters, resolves an
  actor, queries a source or dispatches an arbitrary action.
  """

  @binding [:draft_revision_id, :content_sha256, :recipient_email, :channel]
  @actions [:approve_capture, :edit_draft, :reject_draft, :retry_run]
  @digest ~r/\A[0-9a-f]{64}\z/

  @doc "Validate exact keys and types without dropping aliases or adding authority."
  def parse(
        %{
          action_id: action,
          source_id: source,
          item_id: item,
          expected_freshness_token: token,
          args: args
        } = command
      )
      when map_size(command) == 5 and action in @actions do
    if not is_struct(command) and uuid?(source) and digest?(item) and digest?(token) and
         arguments?(action, args),
       do: {:ok, command},
       else: error(:invalid_input)
  end

  def parse(_), do: error(:invalid_input)

  @doc "A closed content-free command refusal; details are fixed internal codes."
  def error(reason, details \\ %{}), do: {:error, Map.put(details, :reason, reason)}

  defp arguments?(:approve_capture, args),
    do: fields?(args, @binding, []) and binding?(args)

  defp arguments?(:edit_draft, args) do
    fields?(args, @binding ++ [:subject, :body_text], [:angle, :cta]) and
      binding?(args) and text?(args.subject) and text?(args.body_text) and
      optional_text?(Map.get(args, :angle)) and optional_text?(Map.get(args, :cta))
  end

  defp arguments?(:reject_draft, args),
    do: fields?(args, @binding ++ [:reason], []) and binding?(args) and text?(args.reason)

  defp arguments?(:retry_run, args),
    do: fields?(args, [:confirm], []) and args.confirm == true

  defp fields?(args, required, optional) when is_map(args) and not is_struct(args) do
    Enum.all?(required, &Map.has_key?(args, &1)) and
      Enum.all?(Map.keys(args), &(&1 in required or &1 in optional))
  end

  defp fields?(_, _, _), do: false

  defp binding?(args),
    do:
      uuid?(args.draft_revision_id) and digest?(args.content_sha256) and
        text?(args.recipient_email) and args.channel == :email

  defp uuid?(value) when is_binary(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false

  defp digest?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@digest, value)

  defp digest?(_), do: false
  defp text?(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: is_binary(value) and String.valid?(value)
end
