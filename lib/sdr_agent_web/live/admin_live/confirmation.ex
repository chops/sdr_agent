defmodule SdrAgentWeb.AdminLive.Confirmation do
  @moduledoc """
  The operator's typed resolution confirmation (`STOPPED <switch id>`,
  R0-05 section 3), held opaquely wherever the admin page keeps it: the
  frozen review in the socket assigns and the attempt's task closure. Its
  `Inspect` implementation renders `#Confirmation<redacted>`, so crash
  reports and diagnostic representations of that state (a LiveView
  channel's `format_status/2` state at `:debug`, a task's closure) never
  carry the text.

  The text is unwrapped only by `reveal_attestation/1`, at the moment the
  domain call is built, so the exact frozen semantic identity — the
  operator's own text, never synthesized — is what is sent. This changes no
  logger configuration and disables no report.
  """

  @enforce_keys [:text]
  defstruct [:text]

  @type t :: %__MODULE__{text: String.t()}

  @doc "Wraps the operator's own text."
  @spec wrap(String.t()) :: t()
  def wrap(text) when is_binary(text), do: %__MODULE__{text: text}

  @doc "The attestation with its wrapped confirmation unwrapped, for the domain call only."
  @spec reveal_attestation(map()) :: map()
  def reveal_attestation(%{confirmation: %__MODULE__{text: text}} = attestation),
    do: %{attestation | confirmation: text}

  defimpl Inspect do
    def inspect(_confirmation, _opts), do: "#Confirmation<redacted>"
  end
end
