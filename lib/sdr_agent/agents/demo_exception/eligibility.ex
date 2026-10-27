defmodule SdrAgent.Agents.DemoException.Eligibility do
  @moduledoc """
  Pure eligibility steps of the C2* demo exception (ADR-0005 C2* amendment
  item 4; S3 plan r2 §6). This slice provides E4 only.

  `e4/2`, the positive v4 comparison, on the receipt's primary link of a
  ModelInvocation. It is `:ok` only when every one of these holds, and
  `{:refused, :link_not_eligible}` otherwise (the OQ7 code for E4):

    * the link is the invocation's, `:inferred` and `:propagated_id`;
    * `WitnessEvidence.validate/1` accepts the full evidence unchanged and
      `WitnessEvidence.validate_claim/1` returns `:ok` for it;
    * the extracted group (the evidence restricted to the v3 context-group
      keys plus the R keys present) passes `WitnessEvidence.exact_v4_group?/1`.
      The helper is never applied to the full evidence;
    * the evidence is a primary v4 claim with `projections_inapplicable`
      `["v2"]`, layout `reasoning_then_text`, and integer block counts 0..4
      totalling 1..4;
    * the ordinary release's identity check passes (it mirrors the
      `ReleaseDecision` check, `release_decision.ex:344-350`);
    * all four projection digests are present lowercase hex-64 values and
      each projected digest equals its observed one. An absent digest never
      matches another absent one;
    * the capture is complete: outcome `complete`, HTTP 200, both captures
      complete, the stream complete, and a reviewed proxy version
      (`SdrAgent.Agents.Witness.proxy_versions/0`);
    * the reason codes, compared as a set on a copy, have no duplicate and
      are exactly {`method_not_enabled`} or {`method_not_enabled`,
      `cli_injected_context`}. Persisted order is irrelevant and the
      evidence is never sorted, rewritten or repaired.

  That the link is the invocation's single current primary link, with no
  successor, needs the current links; it belongs to the full evaluation,
  not to this function.
  """

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.WitnessEvidence

  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"
  @r_keys ~w(response_layout response_thinking_count response_redacted_thinking_count)
  @counts ~w(response_thinking_count response_redacted_thinking_count)
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @digest_pairs [
    {"projected_request_sha256", "observed_request_projection_sha256"},
    {"projected_response_sha256", "observed_response_projection_sha256"}
  ]
  @code_sets [
    MapSet.new(["method_not_enabled"]),
    MapSet.new(["method_not_enabled", "cli_injected_context"])
  ]

  @doc """
  E4, the positive v4 comparison, for `link` (the receipt's primary link)
  of `invocation`: `:ok` or `{:refused, :link_not_eligible}`.
  """
  @spec e4(struct(), struct()) :: :ok | {:refused, :link_not_eligible}
  def e4(%WireWitnessLink{} = link, %ModelInvocation{} = invocation) do
    evidence = link.evidence

    # In order, stopping at the first false: later checks read evidence keys
    # only after the contract check has proved the evidence a valid map.
    checks = [
      fn -> link_of?(link, invocation) end,
      fn -> contract?(evidence) end,
      fn -> claim?(evidence) end,
      fn -> same_identity?(invocation, evidence) end,
      fn -> digests?(evidence) end,
      fn -> complete?(evidence) end,
      fn -> codes?(evidence["reason_codes"]) end
    ]

    if Enum.all?(checks, & &1.()), do: :ok, else: {:refused, :link_not_eligible}
  end

  defp link_of?(link, invocation) do
    link.model_invocation_id == invocation.id and link.link_status == :inferred and
      link.method == :propagated_id
  end

  # The full evidence validates unchanged, its claim holds, and the extracted
  # group (never the full map) is exactly the v4 group.
  defp contract?(evidence) when is_map(evidence) do
    WitnessEvidence.validate(evidence) == {:ok, evidence} and
      WitnessEvidence.validate_claim(evidence) == :ok and
      WitnessEvidence.exact_v4_group?(extracted(evidence))
  end

  defp contract?(_evidence), do: false

  defp extracted(evidence) do
    Map.take(
      evidence,
      WitnessEvidence.context_group(@v3) ++ Enum.filter(@r_keys, &Map.has_key?(evidence, &1))
    )
  end

  defp claim?(evidence) do
    counts = Enum.map(@counts, &evidence[&1])

    evidence["classification"] == "primary" and evidence["projection_version"] == @v4 and
      evidence["projections_inapplicable"] == ["v2"] and
      evidence["response_layout"] == "reasoning_then_text" and
      Enum.all?(counts, &(is_integer(&1) and &1 in 0..4)) and Enum.sum(counts) in 1..4
  end

  # The ordinary release's identity check (release_decision.ex:344-350).
  defp same_identity?(invocation, evidence) do
    WitnessEvidence.check_identity(invocation, evidence) == :ok and
      map_size(WitnessEvidence.identity(invocation)) == 2 and
      evidence["cli_version"] == invocation.provider_version and
      evidence["app_request_sha256"] == hex(invocation.request_sha256) and
      evidence["app_response_sha256"] == hex(invocation.response_sha256)
  end

  defp digests?(evidence) do
    Enum.all?(@digest_pairs, fn {projected, observed} ->
      hex64?(evidence[projected]) and evidence[projected] == evidence[observed]
    end)
  end

  defp hex64?(value), do: is_binary(value) and Regex.match?(@hex64, value)

  defp complete?(evidence) do
    evidence["outcome"] == "complete" and evidence["http_status"] == 200 and
      evidence["request_capture_complete"] == true and
      evidence["response_capture_complete"] == true and evidence["stream_complete"] == true and
      evidence["proxy_version"] in Witness.proxy_versions()
  end

  # A comparison copy only: the persisted list is never sorted or repaired.
  defp codes?(codes) when is_list(codes),
    do: codes == Enum.uniq(codes) and MapSet.new(codes) in @code_sets

  defp codes?(_codes), do: false

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
