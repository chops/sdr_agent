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

  `admission_window/4` is the admission guard (item 3) for one real call. It
  applies at reservation and at launch while the selector is on, with the
  provider startup timeout of `provider_timeout_ms/1`.

  Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): while
  `config :sdr_agent, SdrAgent.Test.DemoExceptionSource` is set, `source/0`
  is that test double, and its `:authorization_id` (a string, when set)
  replaces the entry's nil `authorization_id`. Both branches, and
  `__test_seam_source__/0` and `__test_seam_authorization_id__/0`, are
  compiled out of every other build.
  """

  require Ash.Query

  alias SdrAgent.Agents.DemoException.Authorization
  alias SdrAgent.Agents.DemoException.Unattested
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

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

  @fallback_timeout_ms 240_000
  @min_timeout_ms 1_000
  @launch_margin_ms 60_000

  @doc """
  The admission guard (ADR-0005 C2* item 3; AC11) for one real ClaudeCLI
  call at `now`. `grant` and `allocation` are the call's own: selected at
  reservation, or charged at launch. T is `provider_timeout_ms(server)` for
  the ClaudeCLI `server` (a name or pid) whose startup timeout bounds the
  call.

  With the selector off it returns `:ok` and reads nothing. With the
  selector on it returns `:ok` only when `effective_starts_at ≤ now <
  effective_expires_at − (T + ResultGate.wait_ms() + 60_000 ms)`, over
  `effective_window/3`. Otherwise it returns `{:error, check}`:

    * `:authorization_unavailable`: the entry names no authorization, or
      the Source has no well-formed one registered for it;
    * `:not_started`;
    * `:launch_margin`.

  It reads only the entry's authorization id and the Source's
  `authorization/1` registry lookup. It is a scheduling guard, not an
  authority check: it consults no attestation, live binding or delegation,
  and a delegated grant is no exemption (Codex 64240c0f rulings 2 and 3).
  It takes no lock and does no I/O.
  """
  @spec admission_window(map(), map(), DateTime.t(), atom() | pid()) ::
          :ok | {:error, :authorization_unavailable | :not_started | :launch_margin}
  def admission_window(grant, allocation, %DateTime{} = now, server) do
    if selected?(), do: window_check(grant, allocation, now, server), else: :ok
  end

  defp window_check(grant, allocation, now, server) do
    with {:ok, authorization} <- registered_authorization() do
      {starts_at, expires_at} = effective_window(grant, allocation, authorization)
      margin = provider_timeout_ms(server) + ResultGate.wait_ms() + @launch_margin_ms
      last = DateTime.add(expires_at, -margin, :millisecond)

      cond do
        DateTime.compare(starts_at, now) == :gt -> {:error, :not_started}
        DateTime.compare(now, last) != :lt -> {:error, :launch_margin}
        true -> :ok
      end
    end
  end

  # The shipped entry names no authorization (a constant nil outside test
  # builds), so it is tested through `inert?/0`, never by a guard on the id
  # that the dev build's type checker would prove unmatchable. The Source's
  # answer must be that authorization, with its window bounds.
  defp registered_authorization do
    if inert?(),
      do: {:error, :authorization_unavailable},
      else: lookup_authorization(entry().authorization_id)
  end

  defp lookup_authorization(id) do
    case authorization(id) do
      {:ok, %Authorization{id: ^id, starts_at: %DateTime{}, expires_at: %DateTime{}} = found} ->
        {:ok, found}

      _unavailable ->
        {:error, :authorization_unavailable}
    end
  end

  @doc """
  The provider startup timeout T (ms) of the admission guard (OQ10): the
  validated `:timeout` that the ClaudeCLI `server` (a name or pid) actually
  runs, as it published it (`ClaudeCLI.effective_timeout/1`). A server
  started without `:timeout` runs, and so publishes, the module's 120_000.

  With no running server, T is the configured `:timeout` (`config
  :sdr_agent, SdrAgent.AI.ModelProvider.ClaudeCLI`, the value
  `Runtime.server_options/1` passes the app's server), when it is an
  integer of at least 1000 (the server's own rule). Otherwise it is
  240_000; the no-server fallback is never the module's 120_000.

  It never messages the server, and no caller option can lower it.
  """
  @spec provider_timeout_ms(atom() | pid()) :: pos_integer()
  def provider_timeout_ms(server) do
    case ClaudeCLI.effective_timeout(server) do
      timeout when is_integer(timeout) -> timeout
      nil -> configured_timeout_ms()
    end
  end

  defp configured_timeout_ms do
    case :sdr_agent |> Application.get_env(ClaudeCLI, []) |> Keyword.get(:timeout) do
      timeout when is_integer(timeout) and timeout >= @min_timeout_ms -> timeout
      _unset_or_invalid -> @fallback_timeout_ms
    end
  end

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
    selector = :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:selector)
    selector == @policy_id
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

  @doc """
  Present use authority of an existing demo-exception `release` of
  `invocation` at `now` (S3 plan r2 §4.2; ADR-0005 C2* item 2 "Use
  authority"): `:ok`, or the first `{:error, code}` in this order:
  `:not_demo_exception`, `:invocation_mismatch`, `:exception_off`,
  `:entry_changed`, `:environment_unattested`, `:binding_drift`,
  `:expired`, `:grant_revoked`, `:mismatch`, `:critical_cause`.

  The binding is compared with the RECORDED basis (tenant, environment
  binding digest, authorization id and entry digest), then the Source's
  live binding read is made. Its other reads are plain, in the release's
  tenant: the funding grant by id, the invocation's links (current and
  superseded) and its critical `reconciliation_required` Failures (any
  status). It takes no lock clause, does no file I/O, writes nothing and
  never registers or observes a snapshot, so it is safe inside a
  transaction and under the chain head. With no active registration only
  `attestation/0` is consulted and nothing is read.
  """
  @spec use_authority(struct(), struct(), DateTime.t()) :: :ok | {:error, atom()}
  def use_authority(release, invocation, %DateTime{} = now) do
    basis = if is_map(release.exception_basis), do: release.exception_basis, else: %{}

    with :ok <- check(release.disposition == :demo_exception, :not_demo_exception),
         :ok <-
           check(
             release.model_invocation_id == invocation.id and
               release.tenant_id == invocation.tenant_id,
             :invocation_mismatch
           ),
         :ok <- check(selected?(), :exception_off),
         :ok <- check(entry_sha256() == get_in(basis, ["policy", "entry_sha256"]), :entry_changed),
         {:ok, attestation} <- attested(),
         :ok <- bound(attestation, release, basis),
         :ok <- check(DateTime.compare(now, release.exception_expires_at) == :lt, :expired),
         :ok <- check(grant_active?(release.tenant_id, basis), :grant_revoked),
         :ok <- check(not mismatch?(invocation), :mismatch) do
      check(not critical?(invocation), :critical_cause)
    end
  end

  defp check(true, _error), do: :ok
  defp check(_false, error), do: {:error, error}

  defp attested do
    case attestation() do
      {:ok, %{level: :spend_ready, environment_id: "agentenv-1"} = attestation} ->
        {:ok, attestation}

      _none_or_other ->
        {:error, :environment_unattested}
    end
  end

  defp bound(attestation, release, basis) do
    recorded? =
      attestation.tenant_id == release.tenant_id and
        attestation.tenant_id == get_in(basis, ["environment", "tenant_id"]) and
        attestation.environment_binding_sha256 ==
          get_in(basis, ["environment", "binding_sha256"]) and
        match?(%{id: _, entry_sha256: _}, attestation.authorization) and
        attestation.authorization.id == get_in(basis, ["funding", "authorization_id"]) and
        attestation.authorization.entry_sha256 ==
          get_in(basis, ["funding", "authorization_sha256"])

    check(recorded? and live_binding?(attestation, release.tenant_id), :binding_drift)
  end

  defp grant_active?(tenant_id, basis) do
    grant_id = get_in(basis, ["funding", "grant_id"])

    is_binary(grant_id) and
      ModelCallGrant
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^grant_id and tenant_id == ^tenant_id and status == :active)
      |> Ash.exists?()
  end

  defp mismatch?(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        link_status == :mismatch
    )
    |> Ash.exists?()
  end

  defp critical?(invocation) do
    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and class == :reconciliation_required and
        severity == :critical and subject_resource == "SdrAgent.Agents.ModelInvocation" and
        subject_id == ^invocation.id
    )
    |> Ash.exists?()
  end
end
