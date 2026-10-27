defmodule SdrAgent.Agents.DemoException.BasisTest do
  @moduledoc """
  C2* slice S3 RED-1, the closed basis `c2star-basis/1` (plan r2 §2 AC8,
  §6 `basis.ex`, §8; accepted design r4, ADR-0005 C2* amendment item 8 and
  every positive and negative case of draft §4).

  Interface pinned here. The plan names `validate/2` and `sha256_hex/1` but
  not their argument shapes:

    * `Basis.validate(basis, expected) :: :ok | {:error, term()}`. `basis`
      is the JSON-native map (string keys; string, integer and boolean
      values; timestamps rendered `YYYY-MM-DDTHH:MM:SS.ffffffZ`), the form
      `build/1` returns and the jsonb column reloads. `expected` holds the
      values the basis is cross-checked against: the record's `decided_at`
      and `exception_expires_at` columns, and the policy entry's
      `entry_sha256` and `acceptance_ref`. A new decision passes the
      compiled entry's values. Because they are passed in, the replay path
      can validate a stored basis against its recorded policy section
      instead of today's entry (binding correction 5).
    * `Basis.sha256_hex(basis)` is the lowercase hex SHA-256 of the basis's
      `sdr-canonical-json/1` encoding.

  Every refusal list first asserts that the unmutated base validates, so a
  refusal cannot pass because the base itself is invalid. Mutations keep
  the other rules satisfied where they can: a malformed digest pair changes
  both members, a malformed `entry_sha256` or `acceptance_ref` is also the
  expected value, and a malformed timestamp keeps its instant.

  `funding.authorization_id` is a synthetic test id; no production
  authorization or cap value is used. It must equal the entry's
  authorization, but that is decision authority's check (E1 and use
  authority), not this schema check, so `expected` does not carry it. The
  size cases make the 8192-byte bound reachable by lengthening that id:
  exactly 8192 bytes validates and 8193 is refused.

  RED report labels: `control: ...` passes now and after GREEN; every other
  test fails on its guard (structural: `Basis` is absent at this head).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.Canonical

  @basis SdrAgent.Agents.DemoException.Basis

  @v4 "claude-message-json/4+prompt-builder/1"
  @objects ~w(policy environment funding invocation identity evidence eligibility window)
  @digest_pairs [
    {"projected_request_sha256", "observed_request_projection_sha256"},
    {"projected_response_sha256", "observed_response_projection_sha256"}
  ]
  @single_digests [
    ["policy", "entry_sha256"],
    ["environment", "binding_sha256"],
    ["funding", "authorization_sha256"]
  ]
  @uuid_paths [
    ["environment", "tenant_id"],
    ["funding", "grant_id"],
    ["funding", "allocation_id"],
    ["invocation", "id"],
    ["invocation", "run_id"],
    ["invocation", "lead_id"]
  ]
  @window_keys ~w(starts_at effective_expires_at decided_at)

  @entry_sha256 :crypto.hash(:sha256, "c2star test entry") |> Base.encode16(case: :lower)
  @authorization_id "test-only-authorization-1"
  @tenant_id "019b8eac-0aaa-7bbb-8ccc-0000000000d1"
  @grant_id "019b8eac-0aaa-7bbb-8ccc-0000000000d2"
  @allocation_id "019b8eac-0aaa-7bbb-8ccc-0000000000d3"
  @invocation_id "019b8eac-0aaa-7bbb-8ccc-0000000000d4"
  @run_id "019b8eac-0aaa-7bbb-8ccc-0000000000d5"
  # The first `:qualify` fixture lead (`Fixtures.leads/0`).
  @lead_id "019b8eac-1180-74d8-9f38-54127081d946"

  @starts_at ~U[2026-10-27 06:00:00.000000Z]
  @expires_at ~U[2026-11-01 06:00:00.000000Z]
  @decided_at ~U[2026-10-28 12:00:00.000000Z]

  ## Fixtures

  # A complete, valid basis. Options: :purpose, :reason_codes, :counts,
  # :current_link_ids, :authorization_id.
  defp basis(opts \\ []) do
    {thinking, redacted} = Keyword.get(opts, :counts, {1, 0})

    %{
      "schema" => "c2star-basis/1",
      "policy" => %{
        "id" => "c2star-demo-v4/1",
        "entry_sha256" => @entry_sha256,
        "acceptance_ref" => "D-223"
      },
      "environment" => %{
        "id" => "agentenv-1",
        "binding_sha256" => hex("environment binding"),
        "tenant_id" => @tenant_id
      },
      "funding" => %{
        "authorization_id" => Keyword.get(opts, :authorization_id, @authorization_id),
        "authorization_sha256" => hex("authorization registry entry"),
        "grant_id" => @grant_id,
        "allocation_id" => @allocation_id
      },
      "invocation" => %{
        "id" => @invocation_id,
        "run_id" => @run_id,
        "lead_id" => @lead_id,
        "usage_origin" => "assignment",
        "purpose" => Keyword.get(opts, :purpose, "qualification")
      },
      "identity" => %{
        "provider" => "claude_cli",
        "cli_version" => "2.1.294",
        "profile_id" => "claude_cli_opus",
        "model_id" => "claude-opus-5-5",
        "prompt_builder" => "prompt-builder/1",
        "ledger_generation" => 2
      },
      "evidence" => %{
        "link_id" => link_id(1),
        "projection_version" => @v4,
        "method" => "propagated_id",
        "response_layout" => "reasoning_then_text",
        "response_thinking_count" => thinking,
        "response_redacted_thinking_count" => redacted,
        "reason_codes" =>
          Keyword.get(opts, :reason_codes, ["cli_injected_context", "method_not_enabled"]),
        "projected_request_sha256" => hex("request projection"),
        "observed_request_projection_sha256" => hex("request projection"),
        "projected_response_sha256" => hex("response projection"),
        "observed_response_projection_sha256" => hex("response projection"),
        "current_link_ids" => Keyword.get(opts, :current_link_ids, [link_id(1), link_id(2)])
      },
      "eligibility" => %{"v3_allowlisted" => true, "v4_allowlisted" => false},
      "window" => %{
        "starts_at" => stamp(@starts_at),
        "effective_expires_at" => stamp(@expires_at),
        "decided_at" => stamp(@decided_at)
      }
    }
  end

  defp expected(overrides \\ []) do
    Map.merge(
      %{
        decided_at: @decided_at,
        exception_expires_at: @expires_at,
        entry_sha256: @entry_sha256,
        acceptance_ref: "D-223"
      },
      Map.new(overrides)
    )
  end

  # Sorted lowercase canonical UUIDs; link_id(1) is the primary link.
  defp link_id(n) do
    suffix = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "019b8eac-2000-7000-8000-" <> suffix
  end

  defp link_ids(count), do: Enum.map(1..count, &link_id/1)

  # A basis with 64 link ids whose canonical encoding is exactly `target`
  # bytes, reached by lengthening the (synthetic) authorization id.
  defp sized(target) do
    prefix = "test-only-authorization-"
    pad = target - encoded_size(basis(current_link_ids: link_ids(64), authorization_id: prefix))

    basis(
      current_link_ids: link_ids(64),
      authorization_id: prefix <> String.duplicate("a", pad)
    )
  end

  defp leaf_paths(basis) do
    [["schema"] | for(object <- @objects, key <- Map.keys(basis[object]), do: [object, key])]
  end

  defp delete(basis, path), do: basis |> pop_in(path) |> elem(1)

  defp evidence(basis, key, value), do: put_in(basis, ["evidence", key], value)

  defp window(basis, key, %DateTime{} = at), do: put_in(basis, ["window", key], stamp(at))

  defp stamp(%DateTime{} = at), do: Canonical.normalize(at)

  defp hex(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)

  defp encoded_size(basis), do: byte_size(Canonical.encode!(basis))

  defp us(%DateTime{} = at, delta), do: DateTime.add(at, delta, :microsecond)

  ## Assertions

  defp implemented!(function, arity) do
    assert Code.ensure_loaded?(@basis) and function_exported?(@basis, function, arity),
           "C2* S3: #{inspect(@basis)}.#{function}/#{arity} is not implemented"
  end

  defp validate(basis, expected), do: call(:validate, [basis, expected])

  defp sha256_hex(basis), do: call(:sha256_hex, [basis])

  # Called dynamically: the module is absent at the RED head.
  defp call(function, args), do: apply(@basis, function, args)

  defp assert_valid(cases) do
    implemented!(:validate, 2)

    for {label, basis, expected} <- normalize(cases) do
      result = validate(basis, expected)
      assert result == :ok, "#{label}: must validate; got #{inspect(result)}"
    end
  end

  defp assert_refused(cases) do
    implemented!(:validate, 2)
    base = validate(basis(), expected())
    assert base == :ok, "the unmutated base must validate first; got #{inspect(base)}"

    for {label, basis, expected} <- normalize(cases) do
      result = validate(basis, expected)
      assert match?({:error, _}, result), "#{label}: must be refused; got #{inspect(result)}"
    end
  end

  defp normalize(cases) do
    Enum.map(cases, fn
      {label, basis} -> {label, basis, expected()}
      {label, basis, expected} -> {label, basis, expected}
    end)
  end

  ## Tests

  test "control: the basis fixtures are canonical JSON and the size fixtures are exact" do
    assert encoded_size(basis()) < 8192
    assert encoded_size(basis(current_link_ids: link_ids(64))) <= 8192
    assert encoded_size(sized(8192)) == 8192
    assert encoded_size(sized(8193)) == 8193
    assert basis()["window"]["decided_at"] == "2026-10-28T12:00:00.000000Z"
    assert length(Enum.uniq(link_ids(65))) == 65 and link_ids(65) == Enum.sort(link_ids(65))
  end

  describe "positive (draft r4 §4)" do
    test "a complete basis for each purpose validates" do
      cases =
        for purpose <- ~w(qualification evidence_extraction outreach_proposal),
            do: {purpose, basis(purpose: purpose)}

      assert_valid(cases)
    end

    test "a basis with and without cli_injected_context validates" do
      assert_valid([
        {"with cli_injected_context",
         basis(reason_codes: ["cli_injected_context", "method_not_enabled"])},
        {"without cli_injected_context", basis(reason_codes: ["method_not_enabled"])}
      ])
    end

    test "thinking/redacted count pairs (1,0), (0,1), (2,2) and (4,0) validate" do
      cases =
        for counts <- [{1, 0}, {0, 1}, {2, 2}, {4, 0}],
            do: {inspect(counts), basis(counts: counts)}

      assert_valid(cases)
    end

    test "64 current_link_ids validate within 8192 bytes, as does exactly 8192 bytes" do
      assert_valid([
        {"64 current_link_ids", basis(current_link_ids: link_ids(64))},
        {"exactly 8192 bytes", sized(8192)}
      ])
    end

    test "window boundaries: starts_at equal to decided_at; decided_at just before the end" do
      just_before = us(@expires_at, -1)

      assert_valid([
        {"starts_at == decided_at", window(basis(), "starts_at", @decided_at)},
        {"decided_at one microsecond before effective_expires_at",
         window(basis(), "decided_at", just_before), expected(decided_at: just_before)}
      ])
    end
  end

  describe "sha256_hex/1" do
    test "is the lowercase hex SHA-256 of the sdr-canonical-json/1 encoding" do
      bases = [basis(), basis(purpose: "outreach_proposal"), sized(8192)]

      implemented!(:sha256_hex, 1)

      for basis <- bases do
        digest = sha256_hex(basis)

        assert digest ==
                 :crypto.hash(:sha256, Canonical.encode!(basis)) |> Base.encode16(case: :lower)
      end

      refute sha256_hex(basis()) == sha256_hex(basis(purpose: "outreach_proposal"))
    end
  end

  describe "negative (draft r4 §4): refused before insert, never truncated or repaired" do
    test "a missing key at any level" do
      base = basis()

      cases =
        for(key <- Map.keys(base), do: {"missing #{key}", Map.delete(base, key)}) ++
          for(
            path <- leaf_paths(base),
            path != ["schema"],
            do: {"missing #{Enum.join(path, ".")}", delete(base, path)}
          )

      assert_refused(cases)
    end

    test "an extra key at any level" do
      base = basis()

      cases = [
        {"extra top-level key", Map.put(base, "extra", "x")}
        | for(
            object <- @objects,
            do: {"extra #{object} key", put_in(base, [object, "extra"], "x")}
          )
      ]

      assert_refused(cases)
    end

    test "a NULL value, an object that is not a map, and a basis that is not a map" do
      base = basis()

      cases =
        for(
          path <- leaf_paths(base),
          do: {"null #{Enum.join(path, ".")}", put_in(base, path, nil)}
        ) ++
          for(object <- @objects, do: {"null #{object}", Map.put(base, object, nil)}) ++
          for(object <- @objects, do: {"#{object} as a list", Map.put(base, object, [])}) ++
          [{"nil basis", nil}, {"list basis", []}, {"string basis", "c2star-basis/1"}]

      assert_refused(cases)
    end

    test "a wrong literal" do
      base = basis()

      cases =
        for {path, value} <- [
              {["schema"], "c2star-basis/2"},
              {["policy", "id"], "c2star-demo-v4/2"},
              {["environment", "id"], "agentenv-2"},
              {["identity", "provider"], "fake"},
              {["identity", "cli_version"], "2.1.295"},
              {["identity", "profile_id"], "claude_cli_sonnet"},
              {["identity", "model_id"], "claude-sonnet-5-5"},
              {["identity", "prompt_builder"], "prompt-builder/2"},
              {["identity", "ledger_generation"], 1},
              {["identity", "ledger_generation"], "2"},
              {["evidence", "projection_version"], "claude-message-json/3+prompt-builder/1"},
              {["evidence", "method"], "time_window"},
              {["evidence", "response_layout"], "reasoning_overflow"},
              {["invocation", "usage_origin"], "proof"},
              {["invocation", "purpose"], "reply_classification"},
              {["eligibility", "v3_allowlisted"], false},
              {["eligibility", "v4_allowlisted"], true},
              {["eligibility", "v3_allowlisted"], "true"}
            ],
            do: {"#{Enum.join(path, ".")} = #{inspect(value)}", put_in(base, path, value)}

      assert_refused(cases)
    end

    test "an uppercase, short or long digest" do
      base = basis()

      forms = [
        {"uppercase", &String.upcase/1},
        {"short", &String.slice(&1, 0, 63)},
        {"long", &(&1 <> "0")}
      ]

      singles =
        for path <- @single_digests, {form, fun} <- forms do
          value = fun.(get_in(base, path))
          label = "#{form} #{Enum.join(path, ".")}"
          basis = put_in(base, path, value)

          # The expected entry digest is the malformed one too, so only the
          # format rule can refuse it.
          if path == ["policy", "entry_sha256"],
            do: {label, basis, expected(entry_sha256: value)},
            else: {label, basis}
        end

      pairs =
        for {left, right} <- @digest_pairs, {form, fun} <- forms do
          value = fun.(base["evidence"][left])
          {"#{form} #{left} pair", base |> evidence(left, value) |> evidence(right, value)}
        end

      assert_refused(singles ++ pairs)
    end

    test "a non-canonical UUID" do
      base = basis()

      forms = [
        {"uppercase", &String.upcase/1},
        {"unhyphenated", &String.replace(&1, "-", "")},
        {"braced", &"{#{&1}}"}
      ]

      fields =
        for path <- @uuid_paths,
            {form, fun} <- forms,
            do: {"#{form} #{Enum.join(path, ".")}", put_in(base, path, fun.(get_in(base, path)))}

      links =
        for {form, fun} <- forms do
          primary = fun.(link_id(1))

          [
            {"#{form} evidence.link_id (also in current_link_ids)",
             base
             |> evidence("link_id", primary)
             |> evidence("current_link_ids", Enum.sort([primary, link_id(2)]))},
            {"#{form} element of current_link_ids",
             evidence(base, "current_link_ids", Enum.sort([link_id(1), fun.(link_id(2))]))}
          ]
        end

      assert_refused(fields ++ List.flatten(links))
    end

    test "a timestamp without exactly six fraction digits and a trailing Z" do
      base = basis()

      forms = [
        {"three fraction digits", &String.replace(&1, ".000000Z", ".000Z")},
        {"no fraction", &String.replace(&1, ".000000Z", "Z")},
        {"seven fraction digits", &String.replace(&1, ".000000Z", ".0000000Z")},
        {"+00:00 offset", &String.replace(&1, "Z", "+00:00")},
        {"no zone", &String.replace_suffix(&1, "Z", "")},
        {"lowercase z", &String.replace_suffix(&1, "Z", "z")}
      ]

      cases =
        for key <- @window_keys,
            {form, fun} <- forms,
            do:
              {"#{form} window.#{key}", put_in(base, ["window", key], fun.(base["window"][key]))}

      assert_refused(cases)
    end

    test "block counts outside 0..4, or summing to 0 or 5" do
      cases =
        for counts <- [{0, 0}, {4, 1}, {1, 4}, {2, 3}, {5, 0}, {-1, 2}, {"1", 0}],
            do: {"counts #{inspect(counts)}", basis(counts: counts)}

      assert_refused(cases)
    end

    test "unsorted, duplicated or non-closed reason_codes" do
      cases =
        for codes <- [
              ["method_not_enabled", "cli_injected_context"],
              ["method_not_enabled", "method_not_enabled"],
              ["cli_injected_context", "cli_injected_context", "method_not_enabled"],
              ["cli_injected_context"],
              [],
              ["cli_injected_context", "method_not_enabled", "stale_observation"],
              "method_not_enabled"
            ],
            do: {"reason_codes #{inspect(codes)}", basis(reason_codes: codes)}

      assert_refused(cases)
    end

    test "unsorted, duplicated, incomplete, empty or 65 current_link_ids" do
      cases =
        for {label, ids} <- [
              {"unsorted", [link_id(2), link_id(1)]},
              {"duplicated", [link_id(1), link_id(1), link_id(2)]},
              {"missing link_id", [link_id(2)]},
              {"empty", []},
              {"65 ids", link_ids(65)}
            ],
            do: {"current_link_ids #{label}", basis(current_link_ids: ids)}

      assert_refused(cases)
    end

    test "an unequal digest pair" do
      base = basis()

      assert_refused([
        {"request pair",
         evidence(base, "observed_request_projection_sha256", hex("another request"))},
        {"response pair",
         evidence(base, "observed_response_projection_sha256", hex("another response"))}
      ])
    end

    test "decided_at at or after effective_expires_at, or starts_at after decided_at" do
      after_end = us(@expires_at, 1)

      assert_refused([
        {"decided_at == effective_expires_at", window(basis(), "decided_at", @expires_at),
         expected(decided_at: @expires_at)},
        {"decided_at after effective_expires_at", window(basis(), "decided_at", after_end),
         expected(decided_at: after_end)},
        {"starts_at after decided_at", window(basis(), "starts_at", us(@decided_at, 1))}
      ])
    end

    test "effective_expires_at or decided_at different from the record's columns" do
      assert_refused([
        {"exception_expires_at column differs", basis(),
         expected(exception_expires_at: us(@expires_at, -1))},
        {"decided_at column differs", basis(), expected(decided_at: us(@decided_at, 1))}
      ])
    end

    test "acceptance_ref or entry_sha256 different from the entry, or a malformed acceptance_ref" do
      base = basis()

      formats =
        for ref <- ["D-22", "D-12345", "d-223", "D223"],
            do:
              {"acceptance_ref #{inspect(ref)}", put_in(base, ["policy", "acceptance_ref"], ref),
               expected(acceptance_ref: ref)}

      assert_refused([
        {"acceptance_ref differs from the entry", base, expected(acceptance_ref: "D-224")},
        {"entry_sha256 differs from the entry", base,
         expected(entry_sha256: hex("another entry"))}
        | formats
      ])
    end

    test "a canonical encoding above 8192 bytes" do
      assert_refused([{"8193 bytes", sized(8193)}])
    end
  end
end
