defmodule SdrAgent.Agents.DemoException do
  @moduledoc """
  The one closed C2* demo-exception policy entry, `c2star-demo-v4/1`
  (ADR-0005 C2* amendment items 1 and 2, accepted under D-223; S3 plan r2
  §4 and §6).

  `entry/0` is a plain map of exactly the item 1 fields: the environment
  (`agentenv-1`), the outer technical window (2026-10-27T06:00:00Z
  inclusive to 2026-11-01T06:00:00Z exclusive), the reviewed identity, the
  v4 projection and method, the funded usage origin and purposes, the five
  `:qualify` fixture leads, the authorization id, the label and the
  acceptance reference. `entry_sha256/0` is the lowercase hex SHA-256 of its
  `sdr-canonical-json/1` encoding. There is no wildcard and no
  runtime-supplied field.

  The shipped `authorization_id` is nil: no owner caps exist, so nothing is
  eligible. The shipped source (`source/0`) is
  `SdrAgent.Agents.DemoException.Unattested`, so no agent environment is
  ever attested either. Neither is configurable in dev or prod.

  `effective_window/3` intersects the policy window and the environment end
  with one funded call's authorization, grant and allocation.

  Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): while
  `config :sdr_agent, SdrAgent.Test.DemoExceptionSource` is set, `source/0`
  is that test double, and its `:authorization_id` (a string, when set)
  replaces the entry's nil `authorization_id`. Both branches, and
  `__test_seam_source__/0` and `__test_seam_authorization_id__/0`, are
  compiled out of every other build.
  """

  alias SdrAgent.Agents.DemoException.Authorization
  alias SdrAgent.Agents.DemoException.Unattested
  alias SdrAgent.Audit.Canonical

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @source Unattested
  @label "demo exception - v4 not independently calibrated"
  @environment_end ~U[2026-11-01 06:00:00.000000Z]

  @entry %{
    environment_id: "agentenv-1",
    starts_at: ~U[2026-10-27 06:00:00.000000Z],
    expires_at: ~U[2026-11-01 06:00:00.000000Z],
    identity: %{
      provider: :claude_cli,
      cli_version: "2.1.294",
      profile_id: :claude_cli_opus,
      model_id: "claude-opus-5-5",
      prompt_builder: "prompt-builder/1",
      ledger_generation: 2
    },
    projection_version: "claude-message-json/4+prompt-builder/1",
    method: :propagated_id,
    usage_origins: [:assignment],
    purposes: [:qualification, :evidence_extraction, :outreach_proposal],
    lead_ids: [
      "019b8eac-1180-74d8-9f38-54127081d946",
      "019b8eac-1180-7c3d-a4ad-c369e27a97f1",
      "019b8eac-1180-761c-9fad-f113afaa661b",
      "019b8eac-1180-7ac2-81bb-c970986aa7be",
      "019b8eac-1180-742a-89d2-cc1ca61efd6a"
    ],
    authorization_id: nil,
    label: @label,
    acceptance_ref: "D-223"
  }

  @entry_doc """
  The compiled policy entry: exactly the ADR-0005 C2* item 1 fields.
  `authorization_id` is nil in shipped code.
  """

  @source_doc """
  The Source the demo exception reads the agent environment through
  (`SdrAgent.Agents.DemoException.Source`). Hard-coded to
  `SdrAgent.Agents.DemoException.Unattested`.
  """

  @doc "The fixed label of every demo-exception record and exception-derived draft."
  @spec label() :: String.t()
  def label, do: @label

  @doc "Lowercase hex SHA-256 of `entry/0`'s `sdr-canonical-json/1` encoding."
  @spec entry_sha256() :: String.t()
  def entry_sha256, do: entry() |> Canonical.sha256() |> Base.encode16(case: :lower)

  if @test_seams do
    @doc @entry_doc
    @spec entry() :: map()
    def entry, do: %{@entry | authorization_id: __test_seam_authorization_id__()}

    @doc @source_doc
    @spec source() :: module()
    def source, do: __test_seam_source__() || @source

    @doc false
    def __test_seam_source__ do
      if seam_config(), do: SdrAgent.Test.DemoExceptionSource, else: nil
    end

    @doc false
    def __test_seam_authorization_id__ do
      case Keyword.get(seam_config() || [], :authorization_id) do
        id when is_binary(id) or is_nil(id) -> id
        other -> raise ArgumentError, "test authorization_id must be a string: #{inspect(other)}"
      end
    end

    defp seam_config, do: Application.get_env(:sdr_agent, SdrAgent.Test.DemoExceptionSource)
  else
    @doc @entry_doc
    @spec entry() :: map()
    def entry, do: @entry

    @doc @source_doc
    @spec source() :: module()
    def source, do: @source
  end

  @doc """
  The effective window `{starts_at, expires_at}` of one funded call (ADR-0005
  C2* item 2): the latest of the policy start, the authorization start, the
  grant's `starts_at` and the allocation's `available_from`; the earliest of
  the policy expiry, the environment end (2026-11-01T06:00:00Z), the
  authorization expiry, the grant's `expires_at` and the allocation's
  `available_until`. Only an unset allocation bound is ignored; every other
  bound must be a `DateTime`.
  """
  @spec effective_window(map(), map(), Authorization.t()) :: {DateTime.t(), DateTime.t()}
  def effective_window(
        %{starts_at: %DateTime{} = grant_start, expires_at: %DateTime{} = grant_end},
        %{available_from: from, available_until: until},
        %Authorization{starts_at: %DateTime{} = auth_start, expires_at: %DateTime{} = auth_end}
      ) do
    starts = optional([@entry.starts_at, auth_start, grant_start], from)
    ends = optional([@entry.expires_at, @environment_end, auth_end, grant_end], until)
    {Enum.max(starts, DateTime), Enum.min(ends, DateTime)}
  end

  defp optional(bounds, nil), do: bounds
  defp optional(bounds, %DateTime{} = bound), do: [bound | bounds]

  @policy_id "c2star-demo-v4/1"
  @refusal_codes [
    :exception_off,
    :environment_unattested,
    :outside_window,
    :scope_mismatch,
    :identity_mismatch,
    :output_invalid,
    :promotion_gap_not_v4,
    :link_not_eligible,
    :invocation_not_clean
  ]

  @doc "The policy id, `c2star-demo-v4/1` (the selector value that names the entry)."
  @spec policy_id() :: String.t()
  def policy_id, do: @policy_id

  @doc """
  The closed refusal codes of a withheld release while the selector is on,
  in evaluation order (ADR-0005 C2* item 5; OQ7).
  """
  @spec refusal_codes() :: [atom()]
  def refusal_codes, do: @refusal_codes

  @doc """
  Whether the selector names the entry (`config :sdr_agent,
  SdrAgent.Agents.DemoException, selector: "c2star-demo-v4/1"`, set only by
  `config/runtime.exs` in `dev`). The selector alone makes nothing eligible.
  """
  @spec selected?() :: boolean()
  def selected? do
    :sdr_agent
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:selector)
    |> Kernel.==(@policy_id)
  end

  @doc "Whether the entry is inert: it names no authorization (shipped: nil)."
  @spec inert?() :: boolean()
  def inert?, do: is_nil(entry().authorization_id)

  @doc """
  The Source's `attestation/0` (`source/0`). Every consumer reads the Source
  through these four functions; they dispatch dynamically, so a build whose
  Source is the constant `Unattested` keeps its callers' other branches
  type-checked rather than pruned.
  """
  @spec attestation() :: {:ok, SdrAgent.Agents.DemoException.Attestation.t()} | :none
  def attestation, do: dispatch(:attestation, [])

  @doc "The Source's `live_binding?/2` (see `attestation/0`)."
  @spec live_binding?(struct(), Ecto.UUID.t()) :: boolean()
  def live_binding?(attestation, tenant_id),
    do: dispatch(:live_binding?, [attestation, tenant_id])

  @doc "The Source's `authorization/1` (see `attestation/0`)."
  @spec authorization(String.t()) :: {:ok, Authorization.t()} | :error
  def authorization(id), do: dispatch(:authorization, [id])

  @doc "The Source's `delegated_grant?/2` (see `attestation/0`)."
  @spec delegated_grant?(struct(), Authorization.t()) :: boolean()
  def delegated_grant?(grant, authorization),
    do: dispatch(:delegated_grant?, [grant, authorization])

  defp dispatch(callback, args), do: apply(source(), callback, args)
end
