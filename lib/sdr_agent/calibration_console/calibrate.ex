if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.CalibrationConsole.Calibrate do
    @moduledoc """
    The calibration evidence document of one calibration call (R0-07 slice E,
    d3c; packet 8.14.8, entity/action PASS at 623e7db).

    `document/1` is pure. It takes the snapshots the command gathered outside
    any database lock and builds the `r0-calibration-evidence/1` document
    that `SdrAgent.CalibrationConsole.Evidence.publish/3` takes:

      * `invocation` and `run`: the fresh committed rows (the run must be the
        invocation's own);
      * `tuple`: the candidate the invocation's original reservation event
        recorded (`SdrAgent.Agents.Admission.Gate.recorded_tuple/1`);
      * `gate`: `ResultGate.await/3`'s own `{:ok | :timeout, receipt}`, or nil
        on the unlaunched path (no await);
      * `link`: the receipt's own link (`receipt.link_id`), or nil when the
        receipt names none;
      * `attestation`: the server's init attestation after the call, or nil;
      * `output`: the parsed output read through the scoped calibration read,
        nil only when the row has none;
      * `observed_at`: the one clock read after the await.

    The outcome and the evaluated and attested fields are
    `SdrAgent.CalibrationConsole.Outcome.classify/1` of those snapshots. The
    document names only the receipt's own link, with its evidence hash and
    its validated `inventory_sha256`. Digests are lowercase hex and times are
    microsecond-precision UTC. No prompt, response, output or error text
    enters it.

    It exists only in test-seam builds (packet 8.14.1): a non-seam build has
    neither the module nor the `calibrate` subcommand path.

    Inconsistent snapshots (a link the receipt does not name, a named link
    that was not read, a link of another invocation, a run that is not the
    invocation's, an own link without a lowercase hex inventory digest) are
    `{:error, :evidence_input_invalid}`: a hard stop, never a nil field.
    """

    alias SdrAgent.Audit.Canonical
    alias SdrAgent.CalibrationConsole.Outcome
    alias SdrAgent.CalibrationConsole.Prompt

    @schema "r0-calibration-evidence/1"
    @sha256 ~r/\A[0-9a-f]{64}\z/
    @invalid {:error, :evidence_input_invalid}

    @doc "The evidence document of the gathered snapshots (see the moduledoc)."
    def document(
          %{
            invocation: invocation,
            run: %{id: run_id},
            tuple: %{} = tuple,
            gate: gate,
            link: link,
            attestation: attestation,
            output: output,
            observed_at: %DateTime{} = observed_at
          } = _snapshot
        ) do
      with true <- run_id == invocation.agent_run_id,
           {:ok, link} <- own_link(link, gate, invocation),
           {:ok, inventory} <- inventory(link) do
        outcome =
          Outcome.classify(%{
            invocation: invocation,
            attestation: attestation,
            gate: gate || {:ok, %{status: :skipped}},
            link: link,
            candidate: tuple
          })

        {:ok,
         %{
           schema: @schema,
           canonicalization: Canonical.version(),
           invocation_id: invocation.id,
           run_id: run_id,
           tenant_id: invocation.tenant_id,
           profile_id: to_string(invocation.profile_id),
           candidate: Map.new(tuple, fn {key, value} -> {key, to_string(value)} end),
           evaluated_projection_version: outcome.evaluated_projection_version,
           evaluated_method: outcome.evaluated_method,
           outcome: outcome.outcome,
           links: links(link),
           inventory_sha256: inventory,
           prompt: ref(Prompt.prompt_ref()),
           output_schema: ref(Prompt.schema_ref()),
           attested_cli_version: outcome.attested_cli_version,
           attested_model_id: outcome.attested_model_id,
           invocation_status: to_string(invocation.status),
           validation_status: to_string(invocation.validation_status),
           output_sha256: output && hex(Canonical.sha256(output)),
           reserved_at: usec(invocation.reserved_at),
           sent_at: usec(invocation.sent_at),
           completed_at: usec(invocation.completed_at),
           observed_at: usec(observed_at)
         }}
      else
        _inconsistent -> @invalid
      end
    end

    def document(_snapshot), do: @invalid

    # The receipt's own link of this invocation, read when the receipt names
    # one; nil only when it names none.
    defp own_link(nil, nil, _invocation), do: {:ok, nil}

    defp own_link(link, {_kind, %{} = receipt}, invocation) do
      case {Map.get(receipt, :link_id), link} do
        {nil, nil} ->
          {:ok, nil}

        {id, %{id: id, model_invocation_id: own}} when is_binary(id) and own == invocation.id ->
          {:ok, link}

        _inconsistent ->
          :error
      end
    end

    defp own_link(_link, _gate, _invocation), do: :error

    defp inventory(nil), do: {:ok, nil}

    defp inventory(%{evidence: %{"inventory_sha256" => digest}}) when is_binary(digest) do
      if digest =~ @sha256, do: {:ok, digest}, else: :error
    end

    defp inventory(_link), do: :error

    defp links(nil), do: []
    defp links(link), do: [%{id: link.id, evidence_sha256: hex(Canonical.sha256(link.evidence))}]

    defp ref(ref), do: %{id: ref.id, version: ref.version, sha256: hex(ref.sha256)}

    defp usec(nil), do: nil

    defp usec(%DateTime{microsecond: {microsecond, _precision}} = time),
      do: %{time | microsecond: {microsecond, 6}}

    defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  end
end
