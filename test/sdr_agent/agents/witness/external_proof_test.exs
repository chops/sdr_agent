defmodule SdrAgent.Agents.Witness.ExternalProofTest do
  @moduledoc """
  S12d real proof (plan R3/P5/P8; ADR-0005): ONE budgeted, synthetic
  ClaudeCLI call through the deployed `llm-proxy-shim` and proxy, recorded
  as a normal ModelInvocation, then reconciled read-only against the real
  proxy witness store under a test-only exact allowlist entry.

  Excluded by default (`:external`). Run explicitly with
  `SDR_WITNESS_PROOF_STORE=<proxy blob dir>` and
  `SDR_WITNESS_PROOF_OUT=<evidence.json>`. Writes metadata only — record
  ids, routes, outcomes, completeness flags, raw and projection digests,
  versions and statuses; never bodies, headers or account identifiers.
  """
  use SdrAgent.AuditCase, async: false

  @moduletag :external
  @moduletag timeout: 300_000

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)

  test "one real ClaudeCLI call is witnessed and reconciled exactly" do
    root = System.fetch_env!("SDR_WITNESS_PROOF_STORE")
    out = System.fetch_env!("SDR_WITNESS_PROOF_OUT")

    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    {:ok, server} = ClaudeCLI.start_link([])

    audit =
      "s12d-proof"
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    assert {:ok, result} =
             ModelProvider.complete(
               %{
                 id: "s12d-proof-#{System.unique_integer([:positive])}",
                 run: run,
                 actor: agent,
                 operation: "model.complete",
                 prompt:
                   "Synthetic test fixture. The company Acme Example (acme.example) is a " <>
                     "fictional 40-person software firm. Answer with answer \"qualified\" " <>
                     "and score 42.",
                 schema: @schema,
                 audit: audit
               },
               provider: ClaudeCLI,
               provider_options: [server: server]
             )

    invocation = result.invocation
    inventory = await_terminal(root, invocation.id)

    entry = %{
      provider: :claude_cli,
      cli_version: invocation.provider_version,
      projection_version: Projection.version(),
      method: :propagated_id
    }

    reconciled = Witness.reconcile(invocation.id, actor: rec, store_root: root, methods: [entry])
    {:ok, links} = Agents.current_wire_witness_links(invocation.id, actor: rec)
    {:ok, status} = Agents.witness_status(invocation.id, actor: rec)

    evidence = %{
      "generated_by" => "test/sdr_agent/agents/witness/external_proof_test.exs",
      "model_invocation_id" => invocation.id,
      "provider" => to_string(invocation.provider),
      "attested_cli_version" => invocation.provider_version,
      "model_id" => invocation.model_id,
      "prompt_builder" => invocation.model_catalog_entry["prompt_builder"],
      "projection_version" => Projection.version(),
      "test_only_allowlist_entry" =>
        Map.new(entry, fn {k, v} -> {to_string(k), to_string(v)} end),
      "inventory" => inventory_summary(inventory),
      "reconcile_result" => summary(reconciled),
      "witness_status" => to_string(status),
      "current_links" =>
        Enum.map(links, fn link ->
          %{
            "proxy_record_ref" => link.proxy_record_ref,
            "link_status" => to_string(link.link_status),
            "method" => to_string(link.method),
            "proxy_request_sha256" => hex_or_nil(link.proxy_request_sha256),
            "proxy_response_sha256" => hex_or_nil(link.proxy_response_sha256),
            "evidence" => link.evidence
          }
        end)
    }

    encoded = Jason.encode!(evidence, pretty: true)
    refute encoded =~ ~r/user_[0-9a-f]{16,}/, "account-id-shaped value in evidence"
    File.write!(out, encoded)
  end

  defp await_terminal(root, invocation_id, attempts \\ 50) do
    case Store.inventory(root, invocation_id) do
      {:ok, %{exchanges: exchanges} = inventory} when exchanges != [] ->
        if Enum.all?(exchanges, &(&1.state == :terminal)) or attempts == 0,
          do: inventory,
          else: retry(root, invocation_id, attempts)

      other ->
        if attempts == 0, do: other, else: retry(root, invocation_id, attempts)
    end
  end

  defp retry(root, invocation_id, attempts) do
    Process.sleep(200)
    await_terminal(root, invocation_id, attempts - 1)
  end

  defp inventory_summary({:error, reason}), do: %{"error" => to_string(reason)}

  defp inventory_summary(%{exchanges: exchanges}) do
    Enum.map(exchanges, fn %{record_id: id, state: state, record: record} ->
      record
      |> Map.take(~w(schema_version proxy_version route method outcome http_status
                     request_bytes_seen response_bytes_seen request_capture_complete
                     response_capture_complete stream_complete response_content_encoding
                     request_sha256 response_sha256 started_at completed_at))
      |> Map.merge(%{"record_id" => id, "state" => to_string(state)})
    end)
  end

  defp summary({:ok, %{status: status, attention: attention}}),
    do: %{"status" => to_string(status), "attention" => attention}

  defp summary({:ok, %{status: status}}), do: %{"status" => to_string(status)}
  defp summary({:error, reason}), do: %{"error" => inspect(reason, limit: 5)}

  defp hex_or_nil(nil), do: nil
  defp hex_or_nil(bin), do: hex(bin)
end
