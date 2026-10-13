defmodule SdrAgent.AI.ProfileProvenanceTest do
  @moduledoc """
  R0-03 (REQ-R0-2, REQ-R0-3): a ClaudeCLI call is reserved, charged and
  recorded under the profile of the server that runs it — its `profile_id`,
  alias, resolved model id and CLI version — and a grant that does not list
  that profile admits nothing.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    # R0-07 slice B: real calls are admitted only with a promoted tuple and
    # a trusted store (`SdrAgent.AdmissionFixtures`).
    SdrAgent.AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, run: run, agent: agent}
  end

  test "each profile's calls record its own profile id, alias, model and version", ctx do
    AgentsFixtures.grant!(ctx.tenant)

    for {profile, model_alias, resolved} <- [
          {:claude_cli_opus, "opus", "claude-opus-5-5"},
          {:claude_cli_sonnet, "sonnet", "claude-sonnet-5-5"}
        ] do
      server = server!(profile)
      assert {:ok, result} = complete(ctx, "prov-#{profile}", server)

      invocation = result.invocation
      assert invocation.status == :completed
      assert invocation.profile_id == profile
      assert invocation.model_id == resolved
      assert invocation.provider_version == "2.1.294"
      assert invocation.model_catalog_entry["alias"] == model_alias
      assert invocation.model_catalog_entry["resolved_id"] == resolved
      GenServer.stop(server)
    end

    {:ok, invocations} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    assert Enum.map(invocations, & &1.profile_id) == [:claude_cli_opus, :claude_cli_sonnet]
  end

  test "a grant for Opus only admits nothing for a Sonnet server", ctx do
    AgentsFixtures.grant!(ctx.tenant, %{profile_ids: [:claude_cli_opus]})
    server = server!(:claude_cli_sonnet)

    assert {:error, %Refused{reason: :no_eligible_grant}} =
             complete(ctx, "sonnet-refused", server)

    assert {:ok, []} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
  end

  defp server!(profile) do
    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        test_launcher: true,
        command_args: [@fake, "ready"],
        profile: profile
      )

    server
  end

  defp complete(ctx, id, server) do
    audit =
      id
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

    ModelProvider.complete(
      %{
        id: id,
        run: ctx.run,
        actor: ctx.agent,
        operation: "model.complete",
        prompt: "Qualify the fixture lead",
        schema: @schema,
        audit: audit
      },
      provider: ClaudeCLI,
      provider_options: [server: server]
    )
  end
end
