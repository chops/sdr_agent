defmodule SdrAgent.AI.ModelProfiles do
  @moduledoc """
  The closed registry of reviewed model profiles (R0-03; ADR-0004 R0
  amendment, item 2; R0 readiness packet, entity ModelProfile).

  A profile is a reviewed entry in code, never persisted and never loaded at
  runtime: `id`, `adapter` (the provider module that runs it), `cli_alias`
  (the `--model` value), `resolved_model` (the model id the per-call init
  attestation must report), `cli_version` (the one reviewed Claude CLI
  version) and `witness_disposition` (`:reconciled | :captured_inferred`;
  both real profiles are `:captured_inferred` until R0-07 promotes a tuple).

  | id                   | adapter     | alias    | resolved model      |
  |----------------------|-------------|----------|---------------------|
  | `:fake`              | `Fake`      | —        | `fake-qualifier`    |
  | `:claude_cli_opus`   | `ClaudeCLI` | `opus`   | `claude-opus-5-5`   |
  | `:claude_cli_sonnet` | `ClaudeCLI` | `sonnet` | `claude-sonnet-5-5` |

  There is no free-text model: lookups take an exact registry id (an atom)
  and refuse anything else (`:unknown_profile`) — a string, an alias or a
  resolved model id included — without creating atoms. `:fake` is never a
  real profile (never grant-checked, never a desired real profile).

  Adding a profile, or changing an alias, resolved model or the CLI version,
  is a reviewed code change with its own proof (ADR-0004 R0 amendment,
  items 1-2). Grants, allocations and invocations read their profile sets
  from here (`real_ids/0`, `ids/0`).
  """

  alias SdrAgent.AI.ModelProfiles.Profile
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake

  # The one pinned, reviewed Claude CLI version (R0-02 pin; ADR-0004 R0
  # amendment, item 1). A pin bump changes it here, in a reviewed PR.
  @cli_version "2.1.291"
  @default_real :claude_cli_opus

  @profiles [
    %Profile{id: :fake, adapter: Fake, resolved_model: "fake-qualifier"},
    %Profile{
      id: :claude_cli_opus,
      adapter: ClaudeCLI,
      cli_alias: "opus",
      resolved_model: "claude-opus-5-5",
      cli_version: @cli_version,
      witness_disposition: :captured_inferred
    },
    %Profile{
      id: :claude_cli_sonnet,
      adapter: ClaudeCLI,
      cli_alias: "sonnet",
      resolved_model: "claude-sonnet-5-5",
      cli_version: @cli_version,
      witness_disposition: :captured_inferred
    }
  ]

  @ids Enum.map(@profiles, & &1.id)
  @real_ids for profile <- @profiles, profile.id != :fake, do: profile.id
  @by_id Map.new(@profiles, &{&1.id, &1})

  @doc "Every reviewed profile, in registry order."
  @spec all() :: [Profile.t()]
  def all, do: @profiles

  @doc "Every profile id: `[:fake, :claude_cli_opus, :claude_cli_sonnet]`."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "The real (grant-checked) profile ids: every id but `:fake`."
  @spec real_ids() :: [atom()]
  def real_ids, do: @real_ids

  @doc "The reviewed Claude CLI version every real profile runs on."
  @spec cli_version() :: String.t()
  def cli_version, do: @cli_version

  @doc """
  The real profile a model server runs when nothing else is chosen (the
  default desired profile, ADR-0004 R0 amendment, item 3).
  """
  @spec default_real() :: atom()
  def default_real, do: @default_real

  @doc "The profile with exactly this id, or `{:error, :unknown_profile}`."
  @spec fetch(term()) :: {:ok, Profile.t()} | {:error, :unknown_profile}
  def fetch(id) when is_atom(id) and is_map_key(@by_id, id), do: {:ok, Map.fetch!(@by_id, id)}
  def fetch(_id), do: {:error, :unknown_profile}

  @doc """
  The real profile with exactly this id: `{:error, :not_a_real_profile}` for
  `:fake`, `{:error, :unknown_profile}` for anything not in the registry.
  """
  @spec fetch_real(term()) ::
          {:ok, Profile.t()} | {:error, :unknown_profile | :not_a_real_profile}
  def fetch_real(:fake), do: {:error, :not_a_real_profile}
  def fetch_real(id), do: fetch(id)

  @doc "Whether `id` is exactly a real profile id."
  @spec real?(term()) :: boolean()
  def real?(id), do: is_atom(id) and id in @real_ids
end
