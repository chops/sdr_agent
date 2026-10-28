defmodule SdrAgent.Prototype.SeedDir do
  @moduledoc """
  The bounded reader of the D-237 GTM seed directory (interfaces r6 IF-7):
  one directory, mode 0700, holding exactly the four plain JSON files
  `offering_profile.json`, `writing_guide.json`, `campaign.json` and
  `provenance.json`, each a regular 0600 file of at most 64 KiB whose full
  sha256 equals its argument. Built on `SdrAgent.Prototype.BoundedJson`; it
  never evaluates its input and never touches the network.

  `read/2` checks:
  - the exact key sets of IF-7 (no class field; a provenance key inside the
    profile is an unknown key) and each file's depth bound (profile 3, guide
    1, campaign 4, provenance 5);
  - `provenance.json`: its `files` digests equal the three content files;
    every ref of `{profile.name, profile.summary, profile.audience, guide,
    campaign.icp, campaign.step} ∪ {item:<id>}` exactly once; each ref's
    class derived from the ref (claim, instruction, targeting); a claim ref
    is `public: true` with at least one `public_url` source and no
    `repo_path`; `public: true` means every source is `public_url`;
  - `campaign.json`: the criteria bounds (industries and geographies 1..5,
    personas and triggers 1..8, each string 1..400 characters, integer
    counts at least 0) and `sender_name` exactly `sender_name/0`;
  - the guide text contains `sender_name/0` byte for byte.

  Settings text (the profile, item and guide text, the step instructions) is
  checked by the settings content rules inside the seed actions, not here,
  and nothing is normalized before that check.

  It returns `{:ok, %{offering_profile:, writing_guide:, campaign:,
  provenance:, provenance_bytes:, sha256: %{…}}}`; a refusal is
  `{:error, {path, rule}}` with a `file:path` location, value-free.

  RED stage (D-237 S3): `sender_name/0` and `files/0` are the contract;
  `read/2` returns `{:error, :not_implemented}`.
  """

  @sender_name "the GTMscape team"
  @files ["offering_profile.json", "writing_guide.json", "campaign.json", "provenance.json"]

  @doc "The 17-byte sender name constant, compared byte for byte."
  @spec sender_name() :: String.t()
  def sender_name, do: @sender_name

  @doc "The four seed file names."
  @spec files() :: [String.t()]
  def files, do: @files

  @doc """
  Reads the seed directory `dir` against the four digests
  `%{offering_profile:, writing_guide:, campaign:, provenance:}`.
  """
  @spec read(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def read(_dir, _sha256s), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
