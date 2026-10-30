defmodule SdrAgent.MacAgent.Config do
  @moduledoc """
  Private settings for the outbound-only Mac worker (ADR-0024).

  The operator supplies a private JSON file, never a token argument. Only
  HTTPS origins, reviewed model profiles and the locally pinned executable
  are accepted. This module never opens the subscription CLI's login files.
  Inspection deliberately excludes all settings, including the bearer token.
  """

  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable

  @derive {Inspect, only: []}
  @enforce_keys [:base_url, :token, :executable, :journal_dir, :pins]
  defstruct @enforce_keys

  @keys ~w(base_url token executable journal_dir profile_id)

  @doc "Load a regular, owner-only settings file (at most 16 KiB)."
  def load(path) when is_binary(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and Bitwise.band(stat.mode, 0o777) == 0o600,
         true <- stat.size <= 16_384,
         {:ok, bytes} <- File.read(path),
         {:ok, settings} <- Jason.decode(bytes) do
      new(settings)
    else
      _ -> {:error, :unsafe_config_file}
    end
  end

  def load(_), do: {:error, :unsafe_config_file}

  @doc "Validate the closed settings and verify the executable without launching it."
  def new(settings) when is_map(settings) do
    with true <- Enum.sort(Map.keys(settings)) == Enum.sort(@keys),
         true <- Enum.all?(@keys, &is_binary(settings[&1])),
         true <- valid_url?(settings["base_url"]),
         true <- Regex.match?(~r/\A[!-~]{16,4096}\z/, settings["token"]),
         true <- absolute?(settings["journal_dir"]),
         {:ok, profile} <- profile(settings["profile_id"]) do
      build(settings, profile)
    else
      _ -> {:error, :invalid_config}
    end
  end

  def new(_), do: {:error, :invalid_config}

  @doc "Recheck current executable bytes/version against this enrollment's frozen pins."
  def verify(%__MODULE__{} = config) do
    if PinnedExecutable.verify(config.executable) == :ok and
         PinnedExecutable.version_bound?() and
         PinnedExecutable.identity().sha256 == config.pins["executable_sha256"] and
         PinnedExecutable.identity().version == config.pins["cli_version"],
       do: :ok,
       else: {:error, :invalid_pin}
  end

  @doc "Resolve a string against the closed registry without creating atoms."
  def profile(id) do
    case Enum.find(ModelProfiles.real_ids(), &(Atom.to_string(&1) == id)) do
      nil -> {:error, :unknown_profile}
      atom -> ModelProfiles.fetch_real(atom)
    end
  end

  defp build(settings, profile) do
    if PinnedExecutable.verify(settings["executable"]) == :ok and
         PinnedExecutable.version_bound?() do
      {:ok,
       %__MODULE__{
         base_url: String.trim_trailing(settings["base_url"], "/"),
         token: settings["token"],
         executable: settings["executable"],
         journal_dir: settings["journal_dir"],
         pins: %{
           "profile_id" => Atom.to_string(profile.id),
           "model_id" => profile.resolved_model,
           "cli_version" => profile.cli_version,
           "executable_sha256" => PinnedExecutable.identity().sha256
         }
       }}
    else
      {:error, :invalid_pin}
    end
  end

  defp valid_url?(url) do
    case URI.new(url) do
      {:ok,
       %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil}} ->
        is_binary(host) and host != "" and path in [nil, "", "/"]

      _ ->
        false
    end
  end

  defp absolute?(path), do: Path.type(path) == :absolute and Path.expand(path) == path
end
