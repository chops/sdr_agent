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

    Only a genuine observation builds a document: a sent call needs the
    await's own `{:ok | :timeout, receipt}`, and a nil `gate` is only the
    unlaunched path (`sent_at` nil), whose `launch_failed` outcome is built
    without evaluation or attestation and without inventing a receipt.

    Inconsistent or malformed snapshots are `{:error,
    :evidence_input_invalid}`, a hard stop, never a nil field or an
    exception: an error or unknown observation tag, a malformed receipt, a
    sent call without an observation or an unlaunched one with one, a link
    the receipt does not name, a named link that was not read, a link of
    another invocation, a run that is not the invocation's, an own link
    without a lowercase hex inventory digest, a candidate that is not
    exactly the six-key entry, a row or observation time that is not UTC,
    or an output that is not a JSON object canonical encoding accepts.
    """

    alias SdrAgent.Audit.Canonical
    alias SdrAgent.CalibrationConsole.Outcome
    alias SdrAgent.CalibrationConsole.Prompt

    @schema "r0-calibration-evidence/1"
    @sha256 ~r/\A[0-9a-f]{64}\z/
    @invalid {:error, :evidence_input_invalid}
    @tuple_names [:provider, :profile_id, :method]
    # The states ResultGate/Witness receipts and their links carry.
    @receipt_statuses [:skipped, :unwitnessed, :inferred, :reconciled, :mismatch]
    @link_statuses [:inferred, :reconciled, :mismatch]
    @methods [:time_window, :propagated_id]
    @tuple_strings [:cli_version, :model_id, :projection_version]

    @doc "The evidence document of the gathered snapshots (see the moduledoc)."
    def document(
          %{
            invocation: invocation,
            run: run,
            tuple: tuple,
            gate: gate,
            link: link,
            attestation: attestation,
            output: output,
            observed_at: observed_at
          } = _snapshot
        ) do
      with true <- invocation?(invocation) and tuple?(tuple) and utc?(observed_at),
           %{id: run_id} when run_id == invocation.agent_run_id <- run,
           {:ok, observation} <- observation(invocation, gate),
           {:ok, link} <- own_link(link, observation, invocation),
           {:ok, inventory} <- inventory(link),
           {:ok, links} <- links(link),
           {:ok, output_sha256} <- output_sha256(output) do
        outcome = classify(observation, invocation, attestation, link, tuple)

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
           links: links,
           inventory_sha256: inventory,
           prompt: ref(Prompt.prompt_ref()),
           output_schema: ref(Prompt.schema_ref()),
           attested_cli_version: outcome.attested_cli_version,
           attested_model_id: outcome.attested_model_id,
           invocation_status: to_string(invocation.status),
           validation_status: to_string(invocation.validation_status),
           output_sha256: output_sha256,
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

    ## The snapshots' shapes

    defp invocation?(%{
           id: id,
           agent_run_id: run_id,
           tenant_id: tenant_id,
           profile_id: profile_id,
           status: status,
           validation_status: validation_status,
           reserved_at: reserved_at,
           sent_at: sent_at,
           completed_at: completed_at
         }) do
      Enum.all?([id, run_id, tenant_id], &is_binary/1) and
        Enum.all?([profile_id, status, validation_status], &name?/1) and utc?(reserved_at) and
        Enum.all?([sent_at, completed_at], &(is_nil(&1) or utc?(&1)))
    end

    defp invocation?(_invocation), do: false

    # Exactly the six-key entry: names for the provider, profile and
    # method, strings for the rest.
    defp tuple?(%{} = tuple) when map_size(tuple) == 6 do
      Enum.all?(@tuple_names, &name?(Map.get(tuple, &1))) and
        Enum.all?(@tuple_strings, &is_binary(Map.get(tuple, &1)))
    end

    defp tuple?(_tuple), do: false

    defp name?(value), do: is_atom(value) and value not in [nil, true, false]

    # A well-formed UTC DateTime: zero offsets, an integer microsecond with
    # a precision of at most 6, and fields ISO 8601 formatting accepts.
    defp utc?(
           %DateTime{
             time_zone: "Etc/UTC",
             utc_offset: 0,
             std_offset: 0,
             microsecond: {microsecond, precision}
           } = time
         )
         when is_integer(microsecond) and microsecond in 0..999_999 and precision in 0..6,
         do: formattable?(time)

    defp utc?(_time), do: false

    # Formatting is pure; a value it cannot format is invalid input,
    # contained here and nowhere else.
    defp formattable?(time) do
      match?({:ok, _time, 0}, DateTime.from_iso8601(DateTime.to_iso8601(time)))
    rescue
      _unformattable -> false
    end

    ## The observation

    # A sent call is observed only through the await's own `{:ok |
    # :timeout, receipt}`; an unlaunched one (`sent_at` nil) had no await.
    # Nothing else is an observation, and none is ever invented.
    defp observation(%{sent_at: nil}, nil), do: {:ok, :unlaunched}

    defp observation(%{sent_at: %DateTime{}}, {kind, receipt} = gate)
         when kind in [:ok, :timeout] do
      if receipt?(receipt), do: {:ok, gate}, else: :error
    end

    defp observation(_invocation, _gate), do: :error

    defp receipt?(%{status: status, link_id: link_id, cause_id: cause_id, codes: codes})
         when is_list(codes) do
      status in @receipt_statuses and
        Enum.all?([link_id, cause_id], &(is_nil(&1) or is_binary(&1))) and
        Enum.all?(codes, &is_binary/1)
    end

    defp receipt?(_receipt), do: false

    # The unlaunched outcome is built here, not classified from an invented
    # receipt: no evaluation and no attestation (packet 8.14.8).
    defp classify(:unlaunched, _invocation, _attestation, _link, _tuple),
      do: %{
        outcome: "launch_failed",
        evaluated_projection_version: nil,
        evaluated_method: nil,
        attested_cli_version: nil,
        attested_model_id: nil
      }

    defp classify(gate, invocation, attestation, link, tuple) do
      Outcome.classify(%{
        invocation: invocation,
        attestation: attestation,
        gate: gate,
        link: link,
        candidate: tuple
      })
    end

    # The receipt's own link of this invocation, read when the receipt names
    # one; nil only when it names none (and always on the unlaunched path).
    defp own_link(nil, :unlaunched, _invocation), do: {:ok, nil}
    defp own_link(nil, {_kind, %{link_id: nil}}, _invocation), do: {:ok, nil}

    defp own_link(
           %{id: id, model_invocation_id: own, link_status: status, method: method} = link,
           {_kind, %{link_id: id}},
           invocation
         )
         when is_binary(id) and own == invocation.id and status in @link_statuses and
                method in @methods,
         do: {:ok, link}

    defp own_link(_link, _observation, _invocation), do: :error

    defp inventory(nil), do: {:ok, nil}

    defp inventory(%{evidence: %{"inventory_sha256" => digest}}) when is_binary(digest) do
      if digest =~ @sha256, do: {:ok, digest}, else: :error
    end

    defp inventory(_link), do: :error

    defp links(nil), do: {:ok, []}

    defp links(%{id: id, evidence: %{} = evidence}) do
      with {:ok, digest} <- canonical_sha256(evidence),
           do: {:ok, [%{id: id, evidence_sha256: digest}]}
    end

    # The commitment to the parsed output (a JSON object), nil without one.
    defp output_sha256(nil), do: {:ok, nil}

    defp output_sha256(%{} = output) when not is_struct(output),
      do: canonical_sha256(output)

    defp output_sha256(_output), do: :error

    # Canonical encoding is pure; a value it cannot encode is invalid input,
    # contained here and nowhere else.
    defp canonical_sha256(value) do
      {:ok, hex(Canonical.sha256(value))}
    rescue
      _unencodable -> :error
    end

    defp ref(ref), do: %{id: ref.id, version: ref.version, sha256: hex(ref.sha256)}

    defp usec(nil), do: nil

    defp usec(%DateTime{microsecond: {microsecond, _precision}} = time),
      do: %{time | microsecond: {microsecond, 6}}

    defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  end
end
