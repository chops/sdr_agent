defmodule SdrAgent.AgentsFixtures do
  @moduledoc "Builders for Agents-domain rows created through the domain API."

  import SdrAgent.AuditCase, only: [system_actor: 2, digest: 1, human: 2]

  @doc """
  Registers a definition and starts a run for it; returns the rows and the
  agent actor. A business-origin run (the default `:assignment`) needs a
  saved offering profile (C4-R8): one is saved first when the tenant has
  none (`ensure_offering!/2`).
  """
  def running_run(tenant, opts \\ []) do
    agent = system_actor(:agent_runtime, tenant)
    definition = definition!(tenant)
    ensure_offering!(tenant, opts)

    {:ok, run} =
      SdrAgent.Agents.create_run(run_attrs(definition, opts), actor: agent)

    {:ok, run} = SdrAgent.Agents.start_run(run, actor: agent)
    %{run: run, agent: agent, definition: definition}
  end

  @doc """
  Like `running_run/2`, but the run owns a running `research_lead`
  Operation (as an assignment run does), so a result-gate cause can carry
  its `operation_id` (R0-07 slice C). Option `oban_job_id:` binds the
  Operation to that job id (e.g. one that no longer exists, so the
  stale-run sweeper can recover the run). Returns `%{run, agent, operation}`.
  """
  def operated_run(tenant, opts \\ []) do
    agent = system_actor(:agent_runtime, tenant)
    definition = definition!(tenant)
    ensure_offering!(tenant, opts)
    key = "gate-run:#{System.unique_integer([:positive])}"

    {:ok, operation} =
      SdrAgent.Operations.create_operation(
        %{
          kind: :research_lead,
          queue: :research,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: Ecto.UUID.generate(),
          idempotency_key: key,
          correlation_id: Ecto.UUID.generate(),
          max_attempts: 1,
          oban_job_id: Keyword.get(opts, :oban_job_id)
        },
        actor: agent
      )

    {:ok, operation} = SdrAgent.Operations.start_operation(operation, actor: agent)
    attrs = definition |> run_attrs(opts) |> Map.put(:operation_id, operation.id)
    {:ok, run} = SdrAgent.Agents.create_run(attrs, actor: agent)
    {:ok, run} = SdrAgent.Agents.start_run(run, actor: agent)
    %{run: run, agent: agent, operation: operation, definition: definition}
  end

  @doc """
  C4-R8: saves the synthetic offering profile of the C4 fixtures
  (`SdrAgent.SettingsFixtures.content/1`) through the domain API, as the
  test's admin, when `tenant` has none and the run's `usage_origin` (default
  `:assignment`) requires one. Per-test, explicit; completeness and
  no-settings tests do not use it.
  """
  def ensure_offering!(tenant, opts \\ []) do
    origin = Keyword.get(opts, :usage_origin, :assignment)
    required = Map.get(SdrAgent.Agents.RunSettings.completeness(), origin, [])

    if :offering_profile in required and
         SdrAgent.SettingsFixtures.latest_number(tenant.id, :offering_profile) == 0 do
      SdrAgent.SettingsFixtures.save_offering!(human(:admin, tenant))
    end

    :ok
  end

  @doc "Registers (or returns) the fixture agent definition."
  def definition!(tenant) do
    {:ok, definition} =
      SdrAgent.Agents.register_definition(
        %{
          name: "SDRAgent",
          version: 1,
          module: "SdrAgent.SDRAgent",
          definition: %{
            "allowed_actions" => [%{"module" => "Research", "version" => "1"}],
            "model_policy" => %{"provider" => "fake", "max_model_calls_per_run" => 20}
          }
        },
        actor: system_actor(:kernel, tenant)
      )

    definition
  end

  @doc """
  Attributes for a queued run. Option `lead_id:` names the run's lead
  (default: a fresh random id, which names no lead row).
  """
  def run_attrs(definition, opts \\ []) do
    %{
      agent_definition_id: definition.id,
      lead_id: Keyword.get_lazy(opts, :lead_id, &Ecto.UUID.generate/0),
      trigger_signal_type: "sdr.lead.assigned",
      trigger_signal_id: "sig-#{System.unique_integer([:positive])}",
      correlation_id: Ecto.UUID.generate(),
      phase: :research,
      usage_origin: Keyword.get(opts, :usage_origin, :assignment),
      max_tool_calls: Keyword.get(opts, :max_tool_calls, 10),
      max_model_calls: Keyword.get(opts, :max_model_calls, 20)
    }
  end

  @doc "Attributes for a model invocation reservation."
  def model_attrs(idempotency_key) do
    %{
      purpose: :qualification,
      provider: :fake,
      provider_version: "0.0.0",
      model_id: "fake-qualifier",
      model_catalog_entry: %{"id" => "fake-qualifier", "context_window" => 8000},
      account_mode_ref: "fake:none",
      data_control_setting: "synthetic-only",
      parameters: %{"temperature" => 0},
      prompt_template_id: "qualify_lead",
      prompt_template_version: "1",
      prompt_template_sha256: digest("prompt"),
      output_schema_id: "qualification_result",
      output_schema_version: "1",
      output_schema_sha256: digest("schema"),
      request: ~s({"jsonrpc":"2.0","method":"turn","params":{"input":"qualify"}}),
      idempotency_key: idempotency_key
    }
  end

  @doc "Attributes completing a model invocation with a valid parsed output."
  def completion do
    %{
      response: ~s({"jsonrpc":"2.0","result":{"qualified":true,"score":82}}),
      parsed_output: %{"qualified" => true, "score" => 82, "criteria" => %{"industry" => "pass"}},
      validation_status: :valid,
      validation_errors: [],
      usage: %{input_tokens: 120, output_tokens: 30, plan_calls: 1},
      latency_ms: 42
    }
  end

  @doc """
  `attrs` reserved under `provider`, with that provider's model profile
  (C9): `:claude_cli_opus` for ClaudeCLI (reserving it needs an eligible
  grant, `grant!/2`); the Fake records `:fake` itself.
  """
  def with_provider(attrs, :claude_cli),
    do: Map.merge(attrs, %{provider: :claude_cli, profile_id: :claude_cli_opus})

  def with_provider(attrs, provider), do: Map.put(attrs, :provider, provider)

  @doc """
  Attributes for a ClaudeCLI (real-provider) reservation: `model_attrs/1`
  with the reviewed ClaudeCLI provenance. Reserving it needs an eligible
  grant (`grant!/2`).
  """
  def claude_attrs(idempotency_key) do
    idempotency_key
    |> model_attrs()
    |> Map.merge(SdrAgent.AI.ModelProvider.ClaudeCLI.provenance())
  end

  @doc """
  A completed generation-2 ClaudeCLI invocation of `run` (Opus profile,
  reviewed provenance) with `completion` (default `completion/0`). The
  tenant needs an eligible grant (`grant!/2`).
  """
  def claude_completed!(run, agent, key, completion \\ completion()) do
    # R0-07 slice B: the reservation is admitted only for its own duration
    # (`SdrAgent.AdmissionFixtures.admitting/1`), so the test's allowlist
    # governs every later reconciliation.
    {:ok, reserved} =
      SdrAgent.AdmissionFixtures.admitting(fn ->
        SdrAgent.Agents.reserve_model_invocation(run, claude_attrs(key), actor: agent)
      end)

    {:ok, sent} = SdrAgent.Agents.mark_model_invocation_sent(reserved, actor: agent)
    {:ok, done} = SdrAgent.Agents.complete_model_invocation(sent, completion, actor: agent)
    done
  end

  @doc """
  Like `claude_completed!/4`, for a `:proof` run: the calibration call is
  reserved with the test-seam calibration admission authority for the
  Opus profile (`SdrAgent.AdmissionFixtures.calibration/0`; R0-07 slice B,
  row B4), which a `:proof` run needs.
  """
  def proof_completed!(run, agent, key, completion \\ completion()) do
    {:ok, reserved} =
      SdrAgent.AdmissionFixtures.admitting(fn ->
        SdrAgent.Agents.reserve_model_invocation(run, claude_attrs(key),
          actor: agent,
          calibration: SdrAgent.AdmissionFixtures.calibration()
        )
      end)

    {:ok, sent} = SdrAgent.Agents.mark_model_invocation_sent(reserved, actor: agent)
    {:ok, done} = SdrAgent.Agents.complete_model_invocation(sent, completion, actor: agent)
    done
  end

  @doc "The projection version of the synthetic links below (`release_entry/0`)."
  def release_projection, do: "claude-message-json/1+prompt-builder/1"

  @doc """
  The exact six-key allowlist entry (R0-07) naming the identity of
  `claude_completed!/4` invocations and `reconciled_link!/3` links. The test
  environment ships an empty allowlist; tests that release put this entry.
  """
  def release_entry do
    provenance = SdrAgent.AI.ModelProvider.ClaudeCLI.provenance()

    %{
      provider: :claude_cli,
      cli_version: provenance.provider_version,
      profile_id: provenance.profile_id,
      model_id: provenance.model_id,
      projection_version: release_projection(),
      method: :propagated_id
    }
  end

  @doc """
  Puts `entries` (default `[release_entry()]`) as the runtime witness
  allowlist and returns the previous configuration (restore it on exit).
  """
  def put_allowlist!(entries \\ [release_entry()]) do
    previous = Application.get_env(:sdr_agent, SdrAgent.Agents.Witness, [])

    Application.put_env(
      :sdr_agent,
      SdrAgent.Agents.Witness,
      Keyword.put(previous, :reconciled_methods, entries)
    )

    previous
  end

  @doc """
  Records, as REC, a primary witness link of `invocation` (default
  `:reconciled`) whose evidence names the invocation's own identity.
  `overrides` replace link attributes; `evidence` overrides are merged.
  """
  def reconciled_link!(invocation, rec, overrides \\ %{}) do
    {:ok, link} = SdrAgent.Agents.link_wire_witness(link_attrs(invocation, overrides), actor: rec)
    link
  end

  @doc "Link attributes for `reconciled_link!/3`."
  def link_attrs(invocation, overrides \\ %{}) do
    overrides = Map.new(overrides)
    {evidence, overrides} = Map.pop(overrides, :evidence, %{})

    Map.merge(
      %{
        model_invocation_id: invocation.id,
        proxy_record_ref: Ash.UUIDv7.generate(),
        proxy_request_sha256: digest("raw request"),
        proxy_response_sha256: digest("raw response"),
        link_status: :reconciled,
        method: :propagated_id,
        evidence: Map.merge(link_evidence(invocation), evidence)
      },
      overrides
    )
  end

  defp link_evidence(invocation) do
    hex = &(&1 && Base.encode16(&1, case: :lower))

    %{
      "witness_schema" => 1,
      "proxy_version" => "0.2.0",
      "cli_version" => invocation.provider_version,
      "route" => "/anthropic/v1/messages",
      "http_method" => "POST",
      "http_status" => 200,
      "outcome" => "complete",
      "classification" => "primary",
      "projection_version" => release_projection(),
      "app_request_sha256" => hex.(invocation.request_sha256),
      "app_response_sha256" => hex.(invocation.response_sha256),
      "reason_codes" => []
    }
    |> Map.merge(identity_evidence(invocation))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # R0-07 item 7: a gated parent's evidence names its model and profile.
  defp identity_evidence(%{ledger_generation: 2, provider: :claude_cli} = invocation),
    do: %{
      "model_id" => invocation.model_id,
      "profile_id" => Atom.to_string(invocation.profile_id)
    }

  defp identity_evidence(_invocation), do: %{}

  @doc """
  Creates, as the tenant's admin, an active real-model call grant (C9) wide
  enough for synthetic ClaudeCLI tests: both profiles, a window around any
  frozen test clock, and one allocation funding every usage bucket.
  `overrides` replace grant terms (including `:allocations`); `admin` (an
  active admin `SdrAgent.Accounts.User`) defaults to a new test admin.
  """
  def grant!(tenant, overrides \\ %{}, admin \\ nil) do
    attrs =
      Map.merge(
        %{
          name: "G-TEST",
          purpose: "Synthetic test calls",
          profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
          total_attempts: 1_000,
          starts_at: ~U[2000-01-01 00:00:00.000000Z],
          expires_at: ~U[2100-01-01 00:00:00.000000Z],
          allocations: [
            %{
              key: :daily_use,
              applies_to: SdrAgent.Agents.ModelCallAllocation.buckets(),
              attempts: 1_000
            }
          ]
        },
        Map.new(overrides)
      )

    {:ok, grant} = SdrAgent.Agents.create_grant(attrs, actor: admin || human(:admin, tenant))
    grant
  end
end
