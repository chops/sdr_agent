if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.CalibrationExemption do
    @moduledoc """
    The staging exemption of a private ClaudeCLI server for one calibration
    call (R0-07 slice E, packet 8.13 A; entity PASS at b77426a). It exists
    only in test-seam builds: in every other build the module is not
    compiled and ClaudeCLI's staging gate is unchanged.

    `check/3` runs in the server process, after the pin check and before the
    call's own process or workspace exists. It admits the call only when:

      * the server is private: started without any `:name` and holding no
        registered name (the Runtime's server and every named one stay
        staged);
      * `request.calibration` is exactly `%{authority:, run_id:,
        tenant_id:, instance:}` and the request's actor is the tenant's
        `agent_runtime`;
      * the prompt and the rendered output schema are the code-owned
        calibration input (`SdrAgent.CalibrationConsole.Prompt`), whatever
        hashes an entry registered;
      * `SdrAgent.CalibrationConsole.Authority.consume/2` accepts the
        observed claims (caller, the witness's invocation id, the server's
        profile, the prompt and schema hashes) with the carried run, tenant
        and VM instance, consuming the entry.

    Every failure before the consume, a malformed request or an exception
    included, and an unavailable registry, is `{:error,
    :real_model_staged}` and leaves the entry unconsumed. On success it
    returns `{:ok, expected}`, the expectation the server passes to
    `Agents.admit_launch/3` as `calibration_launch:` (packet 8.13 B and C);
    the entry stays consumed whatever follows.
    """

    alias SdrAgent.AI.JsonSchema
    alias SdrAgent.AI.ModelProvider
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.CalibrationConsole.Authority
    alias SdrAgent.CalibrationConsole.Prompt

    @staged {:error, :real_model_staged}
    @keys [:authority, :instance, :run_id, :tenant_id]
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @instance ~r/\A[0-9a-f]{32}\z/

    @doc "`{:ok, expected}` or `{:error, :real_model_staged}` (see the moduledoc)."
    def check(server, request, caller) do
      with true <- private?(server),
           {:ok, calibration} <- calibration(request),
           {:ok, claims, expected} <- prepare(server, request, caller, calibration),
           :ok <- consume(calibration.authority, claims) do
        {:ok, expected}
      else
        _refused -> @staged
      end
    end

    defp private?(%{name: nil}) do
      Process.info(self(), :registered_name) == {:registered_name, []}
    end

    defp private?(_named), do: false

    defp calibration(%{
           calibration: %{authority: {Authority, key}} = calibration,
           actor: %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant_id}
         })
         when is_binary(key) do
      if Enum.sort(Map.keys(calibration)) == @keys and uuid?(calibration.run_id) and
           calibration.tenant_id == tenant_id and uuid?(tenant_id) and
           is_binary(calibration.instance) and calibration.instance =~ @instance,
         do: {:ok, calibration},
         else: :error
    end

    defp calibration(_request), do: :error

    # The fixed input, the observed claims and the launch expectation, all
    # computed before the consume: any malformed part refuses here.
    defp prepare(server, request, caller, calibration) do
      schema = Canonical.encode!(JsonSchema.render(request.schema))
      id = request.witness.model_invocation_id

      if request.prompt === Prompt.render() and schema === Canonical.encode!(Prompt.json_schema()) and
           uuid?(id) do
        claims = %{
          caller: caller,
          invocation_id: id,
          run_id: calibration.run_id,
          tenant_id: calibration.tenant_id,
          profile_id: server.profile.id,
          prompt_sha256: hex(:crypto.hash(:sha256, request.prompt)),
          schema_sha256: hex(:crypto.hash(:sha256, schema)),
          instance: calibration.instance
        }

        expected = %{
          run_id: calibration.run_id,
          tenant_id: calibration.tenant_id,
          request_sha256: :crypto.hash(:sha256, ModelProvider.request_body(request)),
          prompt_ref: Prompt.prompt_ref(),
          schema_ref: Prompt.schema_ref()
        }

        {:ok, claims, expected}
      else
        :error
      end
    rescue
      _malformed -> :error
    end

    # The registry may be absent, restarting or slow: every exit is staged.
    defp consume(ref, claims) do
      Authority.consume(ref, claims)
    catch
      :exit, _reason -> @staged
    end

    defp uuid?(value), do: is_binary(value) and value =~ @uuid
    defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  end
end
