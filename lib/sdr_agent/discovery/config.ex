defmodule SdrAgent.Discovery.Config do
  @moduledoc """
  Server-only discovery configuration (ADR-0027). Production always uses the
  fixed Exa client and runtime secret. Fake clients and timing overrides exist
  only in builds with the existing hermetic test seams compiled in.
  """

  @doc "Whether explicit discovery activation is configured."
  def enabled?, do: Application.get_env(:sdr_agent, :prospect_search_enabled, false) == true

  @doc "Whether a usable server credential is present, without disclosing it."
  def ready?, do: enabled?() and valid_key?(key())

  defp valid_key?(key) when is_binary(key) and byte_size(key) in 1..4096,
    do:
      String.valid?(key) and String.trim(key) != "" and
        not String.contains?(key, ["\r", "\n", <<0>>])

  defp valid_key?(_), do: false

  if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
    @doc false
    def key, do: Application.get_env(:sdr_agent, :prospect_search_test_key)
    @doc false
    def client,
      do: Application.get_env(:sdr_agent, :prospect_search_client, SdrAgent.Discovery.ExaClient)

    @doc false
    def cooldown, do: Application.get_env(:sdr_agent, :prospect_search_cooldown_ms, 5000)
    @doc false
    def timeout, do: Application.get_env(:sdr_agent, :prospect_search_timeout_ms, 30_000)
  else
    @doc false
    def key, do: System.get_env("EXA_API_KEY")
    @doc false
    def client, do: SdrAgent.Discovery.ExaClient
    @doc false
    def cooldown, do: 5000
    @doc false
    def timeout, do: 30_000
  end
end
