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
        tenant_id:, instance:, observer:}` (`observer` a local `{pid,
        ref}`, packet 8.14.2) and the request's actor is the tenant's
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

    `receipt/2` (packet 8.14.2, d3a) runs in the server after `Reaper.open`
    started the exempted call's process, before output collection. It
    proves this launch through the probe (a non-empty start identity, and a
    group of positive pids containing the root, which leads its own group)
    and sends the observer exactly one message from the server process,
    before the call's reply: `{:calibration_launched, ref, %{invocation_id:,
    server:, root_pid:, root_identity:, process_group_id:}}`, or
    `{:calibration_launch_unverified, ref, %{invocation_id:, server:,
    root_pid:, reason:}}` with no launch fields. It never signals or cleans
    anything up.

    The probe runs in a monitored, unlinked helper process (its exit or
    kill never reaches the server), bounded by the call's own `deadline`
    (monotonic ms) and a 2 s probe budget, and by the caller: a
    probe still running at the bound is killed and reported unverified
    (`:probe_timeout`, or `:caller_down` when the caller died meanwhile;
    a crashed probe is `:probe_failed`). A late probe result is discarded.
    It returns what the server does next: `:ok` to collect the output,
    `:expired` when the deadline has passed (queued output is never
    collected as a late success) or `:caller_down` (the caller's `DOWN`
    was consumed here).
    """

    alias SdrAgent.AI.JsonSchema
    alias SdrAgent.AI.ModelProvider
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.CalibrationConsole.Authority
    alias SdrAgent.CalibrationConsole.ProcessProbe
    alias SdrAgent.CalibrationConsole.Prompt

    @staged {:error, :real_model_staged}
    @keys [:authority, :instance, :observer, :run_id, :tenant_id]
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
           is_binary(calibration.instance) and calibration.instance =~ @instance and
           observer?(calibration.observer),
         do: {:ok, calibration},
         else: :error
    end

    defp calibration(_request), do: :error

    defp observer?({pid, ref}) when is_pid(pid) and is_reference(ref), do: node(pid) == node()
    defp observer?(_observer), do: false

    @doc """
    Sends the launch receipt for `os_pid` (see the moduledoc), bounded by
    `deadline` and the caller monitor `watch`: `:ok`, `:expired` or
    `:caller_down`.
    """
    def receipt(
          %{calibration: %{observer: {pid, ref}}, witness: witness},
          os_pid,
          deadline,
          watch
        ) do
      base = %{invocation_id: witness.model_invocation_id, server: self()}
      {proof, next} = bounded_proof(os_pid, deadline, watch)

      message =
        case proof do
          {:ok, identity} ->
            {:calibration_launched, ref,
             Map.merge(base, %{
               root_pid: os_pid,
               root_identity: identity,
               process_group_id: os_pid
             })}

          {:error, reason} ->
            {:calibration_launch_unverified, ref,
             Map.merge(base, %{root_pid: os_pid, reason: reason})}
        end

      send(pid, message)

      cond do
        next == :caller_down -> :caller_down
        System.monotonic_time(:millisecond) >= deadline -> :expired
        true -> :ok
      end
    end

    @probe_budget_ms 2_000

    # Not linked (Codex d3a@0a47a27): a probe that exits or is killed is
    # only its own DOWN, never the server's exit.
    defp bounded_proof(os_pid, deadline, watch) do
      server = self()
      tag = make_ref()
      {helper, monitor} = spawn_monitor(fn -> send(server, {tag, proof(os_pid)}) end)
      until = min(deadline, System.monotonic_time(:millisecond) + @probe_budget_ms)

      case await_proof(tag, monitor, watch, until) do
        {:done, result} ->
          {result, :ok}

        :caller_down ->
          stop_helper(helper, monitor, tag)
          {{:error, :caller_down}, :caller_down}

        :timeout ->
          stop_helper(helper, monitor, tag)
          {{:error, :probe_timeout}, :ok}
      end
    end

    defp await_proof(tag, monitor, watch, until) do
      receive do
        {^tag, result} ->
          Process.demonitor(monitor, [:flush])
          {:done, result}

        {:DOWN, ^monitor, :process, _helper, _reason} ->
          {:done, {:error, :probe_failed}}

        {:DOWN, ^watch, :process, _caller, _reason} ->
          :caller_down
      after
        max(until - System.monotonic_time(:millisecond), 0) -> :timeout
      end
    end

    # Kills the helper, then discards its DOWN and any late result.
    defp stop_helper(helper, monitor, tag) do
      Process.exit(helper, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^helper, _reason} -> :ok
      end

      receive do
        {^tag, _late} -> :ok
      after
        0 -> :ok
      end
    end

    defp proof(os_pid) do
      probe = Application.get_env(:sdr_agent, :calibration_launch_probe, ProcessProbe)

      with {:ok, identity} <- identity(probe.start_identity(os_pid)),
           :ok <- group(probe.group_members(os_pid), os_pid) do
        {:ok, identity}
      end
    rescue
      _probe_raised -> {:error, :probe_failed}
    end

    defp identity({:ok, identity}) when is_binary(identity) and identity != "",
      do: {:ok, identity}

    defp identity(:absent), do: {:error, :root_absent}
    defp identity(_unreadable), do: {:error, :identity_unreadable}

    defp group({:ok, members}, os_pid) when is_list(members) do
      if Enum.all?(members, &(is_integer(&1) and &1 > 0)) and os_pid in members,
        do: :ok,
        else: {:error, :group_unverified}
    end

    defp group(_unreadable, _os_pid), do: {:error, :group_unreadable}

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
