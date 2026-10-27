defmodule SdrAgent.DemoExceptionFixtures do
  @moduledoc """
  The C2* demo-exception test harness (S3 plan r2 §8 harness H2 and the
  common setup; Codex S4 ruling 76afb32e, Rulings 1 and 2). It is test
  support only and is usable only together with S3's finalizer
  implementation (GREEN-3): before it, `demo_invocation!/3` raises,
  because no demo-exception release can be decided.

  `demo_env!/1` builds, in the calling `async: false` test:

    * the demo-seeded singleton tenant (`SdrAgent.Demo.Seed.run/0`), so the
      five `:qualify` fixture leads, their seeder creation events and their
      reserved-name accounts and contacts exist;
    * the calling process's clock frozen inside the policy window
      (default `2026-10-28T12:00:00.000000Z`, option `now:`);
    * the selector (`config :sdr_agent, SdrAgent.Agents.DemoException,
      selector: "c2star-demo-v4/1"`; option `selector: false` leaves it
      unset);
    * the synthetic agent environment through the test double
      `SdrAgent.Test.DemoExceptionSource`: a `spend_ready` `agentenv-1`
      attestation of the tenant whose authorization names the test-only
      authorization id, the current `entry_sha256` and the test grant; a
      read-performing `live_binding?/2` (one plain identity read of the live
      database, never a constant answer; S4 Ruling 2); the authorization
      lookup; and `delegated_grant?/2` true exactly for the test grant;
    * exactly one real-model call grant, owner-form, bounded (option
      `attempts:`, default 40, at most 200), whose window and single
      allocation fund the policy window. No other grant is created, so the
      reservations it funds are this grant's (`demo_invocation!/3` asserts
      it);
    * the v3 Opus allowlist entry only (the v4 promotion stays missing),
      the result gate's short test wait, a trusted witness store root, and
      an operated assignment run on the first fixture lead (option
      `lead_id:`; `usage_origin:` passes through).

  Every Application env it changes is restored in `on_exit`, and the store
  root is removed. The frozen clock is the calling test process's own
  state (`SdrAgent.Clock.freeze/1`), discarded with that process; servers
  that follow it (`clock_from:`) stop with the test. `put_source!/2`
  changes one double answer for the rest of the test.

  `demo_invocation!/3` creates a completed generation-2 ClaudeCLI
  invocation of the run, a REC primary v4 link of it whose evidence is a
  fresh positive v4 match, and the receipt the reconciler would return for
  it, then decides the release through the real finalizer
  (`ResultGate.finalize/4`) only. There is no raw insert and no forged
  authority result. `constructed!/3` returns the same parts without
  finalizing, for refusal tests.
  """

  import ExUnit.Assertions, only: [assert: 2]
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import SdrAgent.AuditCase, only: [bootstrap!: 0, digest: 1, system_actor: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.DemoException.Attestation
  alias SdrAgent.Agents.DemoException.Authorization
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Seed
  alias SdrAgent.GateFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Test.DemoExceptionSource

  @selector "c2star-demo-v4/1"
  @authorization_id "test-only-authorization-1"
  @lead_id "019b8eac-1180-74d8-9f38-54127081d946"
  @now ~U[2026-10-28 12:00:00.000000Z]
  @window {~U[2026-10-27 06:00:00.000000Z], ~U[2026-11-01 06:00:00.000000Z]}
  @max_attempts 200
  @v4 "claude-message-json/4+prompt-builder/1"
  @emitted ["method_not_enabled", "cli_injected_context"]
  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.294",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }
  @restored [
    SdrAgent.Agents.DemoException,
    SdrAgent.Test.DemoExceptionSource,
    SdrAgent.Agents.ResultGate,
    SdrAgent.Agents.Witness
  ]
  @binding_sql "SELECT /* demo-exception-binding */ current_database(), oid::bigint " <>
                 "FROM pg_database WHERE datname = current_database()"

  @doc "The selector value that names the entry."
  def selector, do: @selector

  @doc "The test-only authorization id the synthetic environment names."
  def authorization_id, do: @authorization_id

  @doc "The first `:qualify` fixture lead (the default run lead)."
  def lead_id, do: @lead_id

  @doc "The v3 Opus allowlist entry (`demo_env!/1` puts exactly it)."
  def v3_opus, do: @v3_opus

  @doc "The test-only v4 Opus entry (the promotion that must stay missing)."
  def v4_opus, do: %{@v3_opus | projection_version: @v4}

  @doc "The reason codes the reconciler emits for a fresh unpromoted v4 match."
  def emitted_codes, do: @emitted

  @doc "The SQL text marker of the double's live-binding read."
  def binding_marker, do: "demo-exception-binding"

  @doc "The synthetic environment (see the moduledoc). Returns the env map."
  def demo_env!(opts \\ []) do
    saved = Enum.map(@restored, &{&1, Application.fetch_env(:sdr_agent, &1)})
    on_exit(fn -> Enum.each(saved, &restore/1) end)

    {:ok, _summary} = Seed.run()
    tenant = bootstrap!()
    now = Keyword.get(opts, :now, @now)
    :ok = Clock.freeze(now)

    if Keyword.get(opts, :selector, true),
      do: Application.put_env(:sdr_agent, DemoException, selector: @selector),
      else: Application.delete_env(:sdr_agent, DemoException)

    # The entry digest covers the test authorization id, so it is computed
    # with the id in place.
    Application.put_env(:sdr_agent, DemoExceptionSource, authorization_id: @authorization_id)
    entry_sha256 = DemoException.entry_sha256()
    grant = grant!(tenant, Keyword.get(opts, :attempts, 40))
    [allocation] = grant.allocations
    binding = live_binding()

    attestation = %Attestation{
      generation: 1,
      observed_at: now,
      environment_id: "agentenv-1",
      level: :spend_ready,
      environment_binding_sha256: hex("synthetic environment.json"),
      tenant_id: tenant.id,
      authorization: %{id: @authorization_id, entry_sha256: entry_sha256, grant_id: grant.id}
    }

    {starts_at, expires_at} = @window

    authorization = %Authorization{
      id: @authorization_id,
      entry_sha256: entry_sha256,
      starts_at: starts_at,
      expires_at: expires_at
    }

    call_log = start_supervised!({Agent, fn -> [] end})

    Application.put_env(:sdr_agent, DemoExceptionSource,
      attestation: {:ok, attestation},
      live_binding?: fn att, tenant_id ->
        live_binding() == binding and att == attestation and tenant_id == tenant.id
      end,
      authorization: fn
        @authorization_id -> {:ok, authorization}
        _other -> :error
      end,
      delegated_grant?: fn row, auth -> row.id == grant.id and auth.id == @authorization_id end,
      authorization_id: @authorization_id,
      call_log: call_log
    )

    AgentsFixtures.put_allowlist!([@v3_opus])
    Application.put_env(:sdr_agent, ResultGate, wait_ms: 300, poll_ms: 25)
    root = GateFixtures.root!()
    on_exit(fn -> File.rm_rf!(root) end)

    run_opts =
      opts
      |> Keyword.take([:usage_origin])
      |> Keyword.put(:lead_id, Keyword.get(opts, :lead_id, @lead_id))

    %{run: run, agent: agent, operation: operation} =
      AgentsFixtures.operated_run(tenant, run_opts)

    %{
      tenant: tenant,
      now: now,
      run: run,
      agent: agent,
      operation: operation,
      root: root,
      grant: grant,
      allocation: allocation,
      attestation: attestation,
      authorization: authorization,
      entry_sha256: entry_sha256,
      binding: binding,
      call_log: call_log
    }
  end

  @doc "Replaces the double's answer for `callback` (or another seam key)."
  def put_source!(key, value) do
    config = Application.get_env(:sdr_agent, DemoExceptionSource, [])
    Application.put_env(:sdr_agent, DemoExceptionSource, Keyword.put(config, key, value))
  end

  @doc "The double's calls since the last `reset_calls!/1`: `[{callback, pid}]`."
  def calls(env), do: Agent.get(env.call_log, & &1)

  @doc "Empties the double's call log."
  def reset_calls!(env), do: Agent.update(env.call_log, fn _ -> [] end)

  @doc "The gate of `env`'s run (`ResultGate` `%{run_id, operation_id}`)."
  def gate(env), do: %{run_id: env.run.id, operation_id: env.run.operation_id}

  @doc """
  A completed invocation of `env`'s run with a fresh positive v4 primary
  link and its receipt, decided through `ResultGate.finalize/4`; returns
  `%{invocation, link, receipt, release, output}`. Raises unless the
  finalizer returns a `:demo_exception` release. `opts` as
  `constructed!/3`.
  """
  def demo_invocation!(env, purpose \\ :qualification, opts \\ []) do
    parts = constructed!(env, purpose, opts)
    result = ResultGate.finalize(parts.invocation, gate(env), {:ok, parts.receipt})

    assert match?({:released, %{disposition: :demo_exception}, _output}, result),
           "the finalizer did not decide a demo exception: #{inspect(result)}"

    {:released, release, output} = result
    Map.merge(parts, %{release: release, output: output})
  end

  @doc """
  A completed generation-2 ClaudeCLI invocation of `env`'s run for
  `purpose`, charged to `env`'s grant, plus a REC primary v4 link of it and
  the reconciler's receipt for that link; nothing is finalized. Returns
  `%{invocation, link, receipt}`.

  Options: `evidence:` merges over the positive v4 evidence; `link:`
  merges over the link attributes; `completion:` merges over the
  completion; `profile:` reserves another real profile (default
  `:claude_cli_opus`); `complete_at:` freezes the calling process's
  clock at that instant after the reservation and before the completion
  (it stays frozen there); `link?: false` writes no link (the receipt then
  names none).
  """
  def constructed!(env, purpose \\ :qualification, opts \\ []) do
    invocation = completed!(env, purpose, opts)

    assert invocation.grant_id == env.grant.id,
           "the call was not charged to the demo test grant: #{inspect(invocation.grant_id)}"

    if Keyword.get(opts, :link?, true) do
      link = link!(invocation, opts)
      codes = link.evidence["reason_codes"] || []
      receipt = %{status: :inferred, link_id: link.id, cause_id: nil, codes: codes}
      %{invocation: invocation, link: link, receipt: receipt}
    else
      receipt = %{status: :unwitnessed, link_id: nil, cause_id: nil, codes: []}
      %{invocation: invocation, link: nil, receipt: receipt}
    end
  end

  @doc """
  The positive v4 primary evidence of `invocation`'s fresh unpromoted v4
  match, as the reconciler writes it, merged with `overrides`.
  """
  def v4_evidence(invocation, overrides \\ %{}) do
    hex_of = &(&1 && Base.encode16(&1, case: :lower))

    %{
      "witness_schema" => 1,
      "proxy_version" => "0.2.0",
      "cli_version" => invocation.provider_version,
      "route" => "/anthropic/v1/messages",
      "http_method" => "POST",
      "http_status" => 200,
      "outcome" => "complete",
      "started_at" => "2026-10-28T11:59:50.000000Z",
      "completed_at" => "2026-10-28T11:59:58.000000Z",
      "request_bytes_seen" => 18_432,
      "response_bytes_seen" => 4_096,
      "request_capture_complete" => true,
      "response_capture_complete" => true,
      "stream_complete" => true,
      "classification" => "primary",
      "projection_version" => @v4,
      "projections_inapplicable" => ["v2"],
      "app_request_sha256" => hex_of.(invocation.request_sha256),
      "app_response_sha256" => hex_of.(invocation.response_sha256),
      "projected_request_sha256" => hex("request projection"),
      "observed_request_projection_sha256" => hex("request projection"),
      "projected_response_sha256" => hex("response projection"),
      "observed_response_projection_sha256" => hex("response projection"),
      "inventory_sha256" => hex("inventory"),
      "reason_codes" => @emitted,
      "model_id" => invocation.model_id,
      "profile_id" => Atom.to_string(invocation.profile_id),
      "reminder_count" => 1,
      "reminder_sha256s" => [hex("reminder")],
      "reminder_bytes" => [64],
      "trailing_system_count" => 1,
      "trailing_system_sha256s" => [hex("trailing system")],
      "trailing_system_bytes" => [28],
      "request_extras_sha256" => hex("request extras"),
      "request_fields" => ["thinking_present", "output_config_present"],
      "trailing_output_config" => ["present"],
      "response_layout" => "reasoning_then_text",
      "response_thinking_count" => 1,
      "response_redacted_thinking_count" => 0
    }
    |> Map.merge(overrides)
  end

  @doc "Lowercase hex SHA-256 of `label`."
  def hex(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)

  defp completed!(env, purpose, opts) do
    profile = Keyword.get(opts, :profile, :claude_cli_opus)
    {:ok, profile} = ModelProfiles.fetch_real(profile)
    key = "demo-#{purpose}-#{System.unique_integer([:positive])}"

    attrs =
      key
      |> AgentsFixtures.model_attrs()
      |> Map.merge(ClaudeCLI.provenance(profile))
      |> Map.put(:purpose, purpose)

    completion =
      Map.merge(AgentsFixtures.completion(), Map.new(Keyword.get(opts, :completion, %{})))

    {:ok, reserved} =
      SdrAgent.AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(env.run, attrs, actor: env.agent)
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: env.agent)

    case Keyword.get(opts, :complete_at) do
      nil -> :ok
      %DateTime{} = at -> :ok = Clock.freeze(at)
    end

    {:ok, done} = Agents.complete_model_invocation(sent, completion, actor: env.agent)
    done
  end

  defp link!(invocation, opts) do
    rec = system_actor(:reconciler, %{id: invocation.tenant_id})

    attrs =
      %{
        model_invocation_id: invocation.id,
        proxy_record_ref: Ash.UUIDv7.generate(),
        proxy_request_sha256: digest("raw request"),
        proxy_response_sha256: digest("raw response"),
        link_status: :inferred,
        method: :propagated_id,
        evidence: v4_evidence(invocation, Map.new(Keyword.get(opts, :evidence, %{})))
      }
      |> Map.merge(Map.new(Keyword.get(opts, :link, %{})))

    {:ok, link} = Agents.link_wire_witness(attrs, actor: rec)
    link
  end

  defp grant!(tenant, attempts) when is_integer(attempts) and attempts in 1..@max_attempts do
    {starts_at, expires_at} = @window

    AgentsFixtures.grant!(tenant, %{
      name: "G-DEMO-TEST",
      purpose: "Synthetic C2* demo-exception test calls",
      profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
      total_attempts: attempts,
      starts_at: starts_at,
      expires_at: expires_at,
      allocations: [
        %{
          key: :daily_use,
          applies_to: ModelCallAllocation.buckets(),
          attempts: attempts
        }
      ]
    })
  end

  # The read-performing synthetic adapter's one plain identity read: the
  # live database's name and oid (no lock clause, no file I/O).
  defp live_binding do
    %{rows: [[name, oid]]} = Repo.query!(@binding_sql)
    {name, oid}
  end

  defp restore({key, {:ok, value}}), do: Application.put_env(:sdr_agent, key, value)
  defp restore({key, :error}), do: Application.delete_env(:sdr_agent, key)
end
