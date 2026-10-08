defmodule SdrAgent.Audit.Provenance do
  @moduledoc """
  Collects the build and runtime provenance referenced by every AuditEvent
  (ADR-0002 "Provenance snapshot"; S2 row ProvenanceSnapshot).

  Collected once per VM and cached:

    * `git_sha` / `git_dirty` — from `git` in the working directory at boot
      (`"unknown"` / `false` when git or the repository is unavailable);
    * `mix_lock_sha256` — of `mix.lock`, fixed at compile time;
    * OTP, ERTS, Elixir and application versions;
    * `config_sha256` — canonical hash of the `:sdr_agent` application
      environment with secret-looking keys redacted;
    * `schema_version` — the newest migration timestamp shipped in `priv`;
    * `canonicalization_version` and the `snapshot_sha256` over all of them.
  """

  alias SdrAgent.Audit.Canonical

  @mix_lock_path Path.expand("../../../mix.lock", __DIR__)
  @external_resource @mix_lock_path
  @mix_lock_sha256 :crypto.hash(:sha256, File.read!(@mix_lock_path))
  @cache_key {__MODULE__, :current}
  @redacted ~r/(password|secret|token|salt|private|credential|key_base|signing)/i

  @doc "Provenance attributes for this VM (cached)."
  @spec current() :: map()
  def current do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        attrs = collect()
        :persistent_term.put(@cache_key, attrs)
        attrs

      attrs ->
        attrs
    end
  end

  @doc "Collects provenance attributes without caching."
  @spec collect() :: map()
  def collect do
    {git_sha, git_dirty} = git()

    attrs = %{
      git_sha: git_sha,
      git_dirty: git_dirty,
      mix_lock_sha256: @mix_lock_sha256,
      otp_release: to_string(:erlang.system_info(:otp_release)),
      erts_version: to_string(:erlang.system_info(:version)),
      elixir_version: System.version(),
      app_version: to_string(Application.spec(:sdr_agent, :vsn) || "unknown"),
      config_sha256: config_sha256(),
      canonicalization_version: Canonical.version(),
      schema_version: schema_version()
    }

    Map.put(attrs, :snapshot_sha256, Canonical.sha256(hex_binaries(attrs)))
  end

  @doc "Canonical SHA-256 of the redacted `:sdr_agent` application environment."
  @spec config_sha256() :: binary()
  def config_sha256 do
    :sdr_agent
    |> Application.get_all_env()
    |> redact()
    |> Canonical.sha256()
  end

  defp git do
    # No parent secret reaches git (SdrAgent.ChildEnv).
    opts = [stderr_to_stdout: true, env: SdrAgent.ChildEnv.cmd([])]

    with {sha, 0} <- System.cmd("git", ["rev-parse", "HEAD"], opts),
         sha = String.trim(sha),
         true <- sha =~ ~r/\A[0-9a-f]{40}\z/,
         {status, 0} <- System.cmd("git", ["status", "--porcelain"], opts) do
      {sha, String.trim(status) != ""}
    else
      _ -> {"unknown", false}
    end
  rescue
    ErlangError -> {"unknown", false}
  end

  defp schema_version do
    :sdr_agent
    |> Application.app_dir("priv/repo/migrations")
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.slice(0, 14)))
    |> Enum.filter(&(&1 =~ ~r/\A\d{14}\z/))
    |> Enum.max(fn -> "00000000000000" end)
  end

  defp hex_binaries(attrs) do
    Map.new(attrs, fn
      {key, value} when key in [:mix_lock_sha256, :config_sha256] ->
        {key, Base.encode16(value, case: :lower)}

      pair ->
        pair
    end)
  end

  defp redact(term) when is_list(term) do
    if term != [] and Keyword.keyword?(term) do
      term |> Map.new() |> redact()
    else
      Enum.map(term, &redact/1)
    end
  end

  defp redact(%_{} = struct), do: inspect(struct)

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      name = key_name(key)
      if name =~ @redacted, do: {name, "[REDACTED]"}, else: {name, redact(value)}
    end)
  end

  defp redact(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> redact()
  defp redact(value) when is_atom(value) or is_number(value), do: value

  defp redact(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode16(value, case: :lower)
  end

  defp redact(value), do: inspect(value)

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: inspect(key)
end
