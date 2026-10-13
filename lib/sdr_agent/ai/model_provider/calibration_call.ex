if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.AI.ModelProvider.CalibrationCall do
    @moduledoc """
    The authoritative target check of `SdrAgent.AI.ModelProvider.calibration_call/3`
    (R0-07 slice E, packet 8.14.3, d3b; entity PASS at 125102e). It exists
    only in test-seam builds.

    `target/3` re-reads the invocation and its run under the request's own
    actor (the tenant's `agent_runtime`; nothing is derived from row or
    request fields) and admits the call only when, before any provider
    side effect:

      * the invocation is `reserved` with no `sent_at`, a generation-2
        `:claude_cli` row of the private server's profile;
      * its run is the request's run: the actor tenant's `:running` `:proof`
        run with no Operation (`request.run`'s own fields are never
        trusted);
      * the request is the code-owned calibration input
        (`SdrAgent.CalibrationConsole.Prompt`), its stored body's SHA-256
        is the invocation's `request_sha256`, and the invocation's prompt
        and output schema references are the code-owned ones.

    It returns `{:ok, invocation, provenance}` or `:invalid`; a malformed
    request or an exception is `:invalid`, never a crash.
    """

    alias SdrAgent.Agents
    alias SdrAgent.AI.JsonSchema
    alias SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.ClaudeCLI
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.CalibrationConsole.Prompt

    @doc "`{:ok, invocation, provenance}` or `:invalid` (see the moduledoc)."
    def target(request, invocation_id, provider_options) do
      with %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant} = actor
           when is_binary(tenant) <- request.actor,
           true <- fixed_input?(request),
           {:ok, provenance} <- ClaudeCLI.prepare(request, provider_options),
           {:ok, invocation} <- Agents.get_model_invocation(invocation_id, actor: actor),
           {:ok, run} <- Agents.get_run(invocation.agent_run_id, actor: actor),
           true <- reserved?(invocation, provenance),
           true <- own_run?(run, request, tenant),
           true <- committed?(invocation, request) do
        {:ok, invocation, provenance}
      else
        _invalid -> :invalid
      end
    rescue
      _malformed -> :invalid
    end

    defp fixed_input?(request) do
      request.prompt === Prompt.render() and
        Canonical.encode!(JsonSchema.render(request.schema)) ===
          Canonical.encode!(Prompt.json_schema())
    end

    defp reserved?(invocation, provenance) do
      invocation.status == :reserved and is_nil(invocation.sent_at) and
        invocation.provider == :claude_cli and invocation.ledger_generation == 2 and
        invocation.profile_id == provenance.profile_id
    end

    defp own_run?(run, request, tenant) do
      run.id == request.run.id and run.tenant_id == tenant and run.status == :running and
        run.usage_origin == :proof and is_nil(run.operation_id)
    end

    defp committed?(invocation, request) do
      prompt = Prompt.prompt_ref()
      schema = Prompt.schema_ref()

      invocation.request_sha256 == :crypto.hash(:sha256, ModelProvider.request_body(request)) and
        {invocation.prompt_template_id, invocation.prompt_template_version,
         invocation.prompt_template_sha256} == {prompt.id, prompt.version, prompt.sha256} and
        {invocation.output_schema_id, invocation.output_schema_version,
         invocation.output_schema_sha256} == {schema.id, schema.version, schema.sha256}
    end
  end
end
