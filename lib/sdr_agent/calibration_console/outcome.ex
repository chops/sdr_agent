defmodule SdrAgent.CalibrationConsole.Outcome do
  @moduledoc """
  The closed outcome of one calibration call (R0-07 slice E, row R11-4;
  harness round 13, entity PASS at 094caa86), mapped from typed results
  only. It is a pure function: it authenticates nothing the caller passes
  and promotes nothing.

  `classify/1` takes `invocation` (the committed row: `id`, `status`,
  `error`, `sent_at`), `attestation` (the server's init attestation after
  this call, `SdrAgent.AI.ModelProvider.ClaudeCLI.attestation/1`), `gate`
  (`{:ok | :timeout, receipt}` of the one bounded reconciliation), `link`
  (the primary link the receipt names, or nil) and `candidate` (the
  six-key entry). Precedence:

    1. `launch_failed` — no launch is proven: `sent_at` is nil, or the call
       failed after `sent` with a known deterministic no-spawn reason
       (C9-03: `launch_failed`, `provider_queue_timeout`). An `unknown`
       call or any other failure is never called unlaunched.
    2. `init_drift` — no valid init of the candidate's identity was
       observed: a drifted or missing attestation, or one naming another
       model or CLI version.
    3. `timeout` — the bounded observation timed out.
    4. `unreadable` — the store was unconfigured (`:skipped`) or unreadable
       (a `store_*` code).
    5. From the receipt and its link: `ambiguous` (several or unclassified
       exchanges), `unsupported`, `mismatch` (the invocation, or its link,
       mismatched), `missing` (no usable link), `projection_differs` (the
       evaluated projection or method is not the candidate's),
       `not_enabled` (the candidate tuple, inferred with
       `method_not_enabled`), and `match` only when the whole invocation is
       reconciled and the receipt's own link of this invocation is
       reconciled under the candidate's exact projection and method.

  A link the receipt does not name, or of another invocation, is ignored.
  The evaluated projection and method come from the used link (nil without
  one) and are recorded even when they differ; the attested CLI version and
  model are recorded only for a valid init, and never copied from the
  candidate.
  """

  @values ~w(match mismatch projection_differs not_enabled unsupported ambiguous missing
             timeout unreadable init_drift launch_failed)
  @no_spawn ["launch_failed", "provider_queue_timeout"]
  @ambiguous ["multiple_primary_exchanges", "unclassified_exchange"]
  @unsupported ~w(proxy_version_unsupported content_encoding_unsupported evidence_contract_invalid)

  @doc "The closed outcome set, in its documented order."
  def values, do: @values

  @doc "See the moduledoc."
  def classify(%{invocation: invocation, attestation: attestation, gate: gate} = input) do
    candidate = Map.fetch!(input, :candidate)
    link = own_link(Map.get(input, :link), gate, invocation)
    init = init(attestation, candidate)

    outcome =
      cond do
        unlaunched?(invocation) -> "launch_failed"
        init == :drift -> "init_drift"
        match?({:timeout, _receipt}, gate) -> "timeout"
        unreadable?(gate) -> "unreadable"
        true -> observed(receipt(gate), link, candidate)
      end

    {version, model} = if init == :drift, do: {nil, nil}, else: init

    %{
      outcome: outcome,
      evaluated_projection_version: link && link.evidence["projection_version"],
      evaluated_method: link && to_string(link.method),
      attested_cli_version: version,
      attested_model_id: model
    }
  end

  # The receipt's own primary link of this invocation, or nil.
  defp own_link(%{id: id, model_invocation_id: invocation_id} = link, {_kind, receipt}, %{
         id: invocation_id
       })
       when is_binary(id) do
    if Map.get(receipt, :link_id) == id, do: link
  end

  defp own_link(_link, _gate, _invocation), do: nil

  defp unlaunched?(%{sent_at: nil}), do: true

  defp unlaunched?(%{status: :failed, error: %{"kind" => "provider_error", "reason" => reason}}),
    do: reason in @no_spawn

  defp unlaunched?(_invocation), do: false

  defp init(%{status: :attested, model: model, version: version}, candidate)
       when is_binary(model) and is_binary(version) do
    if model == candidate.model_id and version == candidate.cli_version,
      do: {version, model},
      else: :drift
  end

  defp init(_missing_or_drifted, _candidate), do: :drift

  defp unreadable?({:ok, %{status: :skipped}}), do: true
  defp unreadable?({_kind, receipt}), do: Enum.any?(codes(receipt), &(&1 =~ ~r/\Astore_/))

  defp receipt({_kind, receipt}), do: receipt

  # The receipt's codes and status first (they describe the whole
  # invocation), then its own link.
  defp observed(receipt, link, candidate) do
    codes = codes(receipt)
    status = Map.get(receipt, :status)

    cond do
      Enum.any?(codes, &(&1 in @ambiguous)) -> "ambiguous"
      Enum.any?(codes, &(&1 in @unsupported)) -> "unsupported"
      status == :mismatch -> "mismatch"
      is_nil(link) -> "missing"
      true -> linked(status, codes, link, candidate)
    end
  end

  defp linked(status, codes, link, candidate) do
    cond do
      not candidate_tuple?(link, candidate) -> "projection_differs"
      "method_not_enabled" in codes -> "not_enabled"
      status == :reconciled and link.link_status == :reconciled -> "match"
      link.link_status == :mismatch -> "mismatch"
      true -> "missing"
    end
  end

  defp candidate_tuple?(link, candidate) do
    link.evidence["projection_version"] == candidate.projection_version and
      link.method == candidate.method
  end

  defp codes(receipt), do: Map.get(receipt, :codes) || []
end
