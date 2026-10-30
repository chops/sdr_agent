# D-237: the prototype basis exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Basis do
    @moduledoc """
    The `d237-basis/1` of a `released_unverified` decision (ADR-0005 D-237
    amendment item 6; interfaces r6 IF-4; release scope proposal r1 section
    3; Codex 3122b0d4 Q3/Q5; α correction r2 N1; boundary delta a7bbcac3).

    A pure module: no database, clock or process state is read here.

      * `encode/1` is the generic bounded canonical encoder. On plain data
        (maps with binary keys, proper lists, binaries, integers, booleans
        and nil) it returns `{:ok, bytes, sha256_hex}` for at most 8192
        `sdr-canonical-json/1` OUTPUT bytes (the SHA of exactly those
        bytes), and the value-free `{:error, :basis_invalid}` for anything
        `SdrAgent.Audit.Canonical.encode/1` refuses or for more bytes. It
        does NOT check the basis shape. Outside plain data, a raise inside
        Canonical (a malformed date, time or decimal, an improper list)
        propagates unchanged: no rescue, no non-raising claim, and no bound
        on the input's own size or work.
      * `build/1` makes the basis of a NEW decision from the server's facts
        (the boot snapshot, the compiled policy and funding entries, the
        stored invocation and run, the charged grant and the decision
        instant), then checks its complete shape and encodes it.
      * `verify_new/2` checks a supplied `%{basis:, basis_sha256:}`: its
        complete shape FIRST, then its encoding and digest, then byte
        equality with `build/1` of the facts (rebuild and compare; a
        supplied basis is only compared, never trusted).
      * `verify_historical/2` checks the ORIGINAL basis of an EXISTING
        `released_unverified` decision (b2c β; amendment item 6): its
        complete shape first, its encoding and recorded digest, then
        equality with the STORED facts only: the release row (its tenant,
        invocation and `decided_at`), the stored invocation and its run, and
        the one original reservation event's recorded authority. Never the
        current grant, revision, status, funding, window or policy
        configuration: `funding.sha256` and the window bounds are bound by
        the digest and the shape's fixed constants only.
      * `compare_existing/2` compares a requested basis with an existing
        release's original (both shape-checked and self-consistent first):
        `:replay` when body and digest are equal, `:conflict` for a valid,
        self-consistent, different request, otherwise
        `{:error, :basis_invalid}` (either side invalid or not
        self-consistent, e.g. a changed body carrying a copied digest).

    The shape check is total by construction (pattern and guard checks
    only): exactly the closed key set at every level, no null, the fixed
    constants (schema, assurance, label, policy and funding ids, the
    acceptance reference, the window bounds and the observation) and the
    leaf grammar (lowercase UUIDs, 64-hex digests, six-digit UTC
    timestamps, integers, non-empty strings). A list, tuple or struct leaf
    is rejected without being traversed, so a decision path never hands a
    compound value to the encoder.

    Producers and consumers (pinned by `ReleaseGuardTest` and the β
    partition probe): `build/1` is called only by
    `SdrAgent.Prototype.Release`, `verify_new/2` and `compare_existing/2`
    only by `SdrAgent.Agents.Changes.ReleaseDecision`, `verify_historical/2`
    only by `SdrAgent.Prototype.ReleasedScope`.
    """

    alias SdrAgent.Audit.Canonical

    @limit 8192

    @constants %{
      "schema" => "d237-basis/1",
      "assurance" => "unverified",
      "label" => "UNVERIFIED (PROTOTYPE)"
    }

    @grammar %{
      "policy" => %{"acceptance_ref" => :text, "entry_sha256" => :hex64, "id" => :text},
      "funding" => %{
        "allocation_id" => :uuid,
        "grant_id" => :uuid,
        "grant_revision" => :count,
        "id" => :text,
        "operator_user_id" => :uuid,
        "sha256" => :hex64
      },
      "prototype" => %{
        "binding_id" => :uuid,
        "database" => :text,
        "database_oid" => :positive,
        "dataset_class" => :text,
        "instance_id" => :uuid,
        "system_identifier" => :decimal,
        "tenant_id" => :uuid
      },
      "window" => %{"decided_at" => :stamp, "expires_at" => :stamp, "starts_at" => :stamp},
      "invocation" => %{
        "id" => :uuid,
        "lead_id" => :uuid,
        "output_schema_sha256" => :hex64,
        "purpose" => :text,
        "request_sha256" => :hex64,
        "response_sha256" => :hex64,
        "run_id" => :uuid,
        "usage_origin" => :text
      },
      "identity" => %{
        "cli_version" => :text,
        "ledger_generation" => :count,
        "model_id" => :text,
        "profile_id" => :text,
        "prompt_builder" => :text,
        "provider" => :text
      },
      "observation" => %{"classification" => :text, "witness_mode" => :text}
    }

    # Fixed leaves (compiled entries and the absent store), checked by shape.
    @fixed %{
      {"policy", "id"} => "d237-prototype/1",
      {"policy", "acceptance_ref"} => "D-249",
      {"funding", "id"} => "d237-funding/1",
      {"window", "starts_at"} => "2026-10-28T02:38:32.000000Z",
      {"window", "expires_at"} => "2026-11-07T07:00:00.000000Z",
      {"observation", "witness_mode"} => "absent",
      {"observation", "classification"} => "store_unconfigured",
      {"identity", "provider"} => "claude_cli"
    }

    @top_keys Enum.sort(Map.keys(@grammar) ++ Map.keys(@constants))

    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @hex64 ~r/\A[0-9a-f]{64}\z/
    @stamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
    @decimal ~r/\A-?[0-9]+\z/

    @typedoc "The server's facts of a new decision."
    @type facts :: %{
            snapshot: struct(),
            entry: map(),
            funding: map(),
            invocation: struct(),
            run: struct(),
            grant: struct(),
            decided_at: DateTime.t()
          }

    @typedoc "The stored facts of an existing decision (historical verification)."
    @type historical_facts :: %{
            release: struct(),
            invocation: struct(),
            run: struct(),
            recorded: map()
          }

    @typedoc "A supplied or recorded basis with its digest."
    @type supplied :: %{basis: term(), basis_sha256: term()}

    @doc """
    The generic bounded canonical encoder (see the moduledoc for its
    accepted domain and error boundary).
    """
    @spec encode(term()) :: {:ok, binary(), String.t()} | {:error, :basis_invalid}
    def encode(term) do
      case Canonical.encode(term) do
        {:ok, bytes} when byte_size(bytes) <= @limit -> {:ok, bytes, hex(sha(bytes))}
        _refused_or_oversize -> {:error, :basis_invalid}
      end
    end

    @doc """
    The basis of a new decision from `facts`, checked and encoded:
    `{:ok, basis, sha256_hex}` or `{:error, :basis_invalid}`.
    """
    @spec build(facts()) :: {:ok, map(), String.t()} | {:error, :basis_invalid}
    def build(facts) do
      basis = dictionary(facts)

      with :ok <- shape(basis),
           {:ok, _bytes, sha256} <- encode(basis) do
        {:ok, basis, sha256}
      end
    end

    @doc """
    `:ok` when the supplied `basis` has the complete shape, encodes within
    the bound, has exactly the supplied `basis_sha256`, and its canonical
    bytes equal those of the basis rebuilt from `facts`; otherwise
    `{:error, :basis_invalid}`.
    """
    @spec verify_new(map(), facts()) :: :ok | {:error, :basis_invalid}
    def verify_new(%{basis: basis, basis_sha256: sha256}, facts) when is_binary(sha256) do
      with :ok <- shape(basis),
           {:ok, bytes, ^sha256} <- encode(basis),
           {:ok, rebuilt, _rebuilt_sha256} <- build(facts),
           {:ok, ^bytes, _same} <- encode(rebuilt) do
        :ok
      else
        _invalid -> {:error, :basis_invalid}
      end
    end

    def verify_new(_supplied, _facts), do: {:error, :basis_invalid}

    @doc """
    `:ok` when the ORIGINAL `basis` of an existing `released_unverified`
    release has the complete shape, encodes within the bound with exactly
    the recorded `basis_sha256`, and equals the stored `facts` (the release
    row, the stored invocation and run, and the recorded reservation
    authority); otherwise `{:error, :basis_invalid}`. Pure: the caller
    reads the facts; nothing current is consulted.
    """
    @spec verify_historical(supplied(), historical_facts()) :: :ok | {:error, :basis_invalid}
    def verify_historical(%{basis: basis, basis_sha256: sha256}, facts) when is_binary(sha256) do
      with :ok <- shape(basis),
           {:ok, _bytes, ^sha256} <- encode(basis),
           true <- historical?(basis, facts) do
        :ok
      else
        _invalid -> {:error, :basis_invalid}
      end
    end

    def verify_historical(_original, _facts), do: {:error, :basis_invalid}

    @doc """
    Compares a `requested` basis with an existing release's `original`:
    `:replay` (identical body and digest), `:conflict` (a valid,
    self-consistent, different request) or `{:error, :basis_invalid}`
    (either side without the complete shape or not self-consistent).
    """
    @spec compare_existing(supplied(), supplied()) ::
            :replay | :conflict | {:error, :basis_invalid}
    def compare_existing(requested, original) do
      with {:ok, original_bytes} <- self_consistent(original),
           {:ok, requested_bytes} <- self_consistent(requested) do
        if requested_bytes == original_bytes, do: :replay, else: :conflict
      end
    end

    defp self_consistent(%{basis: basis, basis_sha256: sha256}) when is_binary(sha256) do
      with :ok <- shape(basis),
           {:ok, bytes, ^sha256} <- encode(basis) do
        {:ok, bytes}
      else
        _invalid -> {:error, :basis_invalid}
      end
    end

    defp self_consistent(_supplied), do: {:error, :basis_invalid}

    # Every stored-fact equality of amendment item 6 (beta packet r1 3.1).
    # The basis already has the complete shape, so every section is present.
    defp historical?(
           %{
             "funding" => funding,
             "policy" => policy,
             "prototype" => prototype,
             "observation" => observation,
             "window" => window
           } = basis,
           %{release: release, invocation: inv, run: run, recorded: %{} = recorded}
         ) do
      Enum.all?([
        release.disposition == :released_unverified,
        release.model_invocation_id == inv.id,
        release.tenant_id == inv.tenant_id,
        run.id == inv.agent_run_id,
        run.tenant_id == inv.tenant_id,
        basis["invocation"] == invocation_section(inv, run),
        basis["identity"] == identity_section(inv),
        funding["grant_id"] == inv.grant_id,
        funding["grant_id"] == recorded["grant_id"],
        funding["allocation_id"] == inv.allocation_id,
        funding["allocation_id"] == recorded["allocation_id"],
        funding["grant_revision"] == recorded["grant_revision"],
        funding["operator_user_id"] == recorded["operator_user_id"],
        funding["id"] == recorded["funding_id"],
        policy["id"] == recorded["policy_id"],
        policy["entry_sha256"] == recorded["entry_sha256"],
        prototype["binding_id"] == recorded["binding_id"],
        prototype["instance_id"] == recorded["instance_id"],
        prototype["dataset_class"] == recorded["dataset_class"],
        prototype["tenant_id"] == recorded["tenant_id"],
        prototype["tenant_id"] == release.tenant_id,
        observation["witness_mode"] == recorded["witness_mode"],
        basis["identity"]["profile_id"] == recorded["profile_id"],
        basis["invocation"]["purpose"] == recorded["purpose"],
        window["decided_at"] == stamp(release.decided_at)
      ])
    end

    defp historical?(_basis, _facts), do: false

    ## The dictionary (server facts only)

    defp dictionary(facts) do
      %{
        snapshot: s,
        entry: entry,
        funding: funding,
        invocation: inv,
        run: run,
        grant: grant,
        decided_at: decided_at
      } = facts

      %{
        "schema" => @constants["schema"],
        "policy" => %{
          "id" => s.policy_id,
          "acceptance_ref" => entry.acceptance_ref,
          "entry_sha256" => s.policy_entry_sha256
        },
        "funding" => %{
          "id" => s.funding_id,
          "sha256" => canonical_hex(funding),
          "grant_id" => grant.id,
          "grant_revision" => grant.revision,
          "allocation_id" => inv.allocation_id,
          "operator_user_id" => s.operator_user_id
        },
        "prototype" => %{
          "binding_id" => s.id,
          "instance_id" => s.instance_id,
          "tenant_id" => s.tenant_id,
          "dataset_class" => s.dataset_class,
          "database" => s.database,
          "database_oid" => s.database_oid,
          "system_identifier" => decimal(s.system_identifier)
        },
        "window" => %{
          "starts_at" => stamp(funding.starts_at),
          "expires_at" => stamp(funding.expires_at),
          "decided_at" => stamp(decided_at)
        },
        "invocation" => invocation_section(inv, run),
        "identity" => identity_section(inv),
        "observation" => %{"witness_mode" => "absent", "classification" => "store_unconfigured"},
        "assurance" => @constants["assurance"],
        "label" => @constants["label"]
      }
    end

    # The stored invocation and its run (new decisions and historical
    # verification alike).
    defp invocation_section(inv, run) do
      %{
        "id" => inv.id,
        "run_id" => inv.agent_run_id,
        "lead_id" => run.lead_id,
        "usage_origin" => name(run.usage_origin),
        "purpose" => name(inv.purpose),
        "request_sha256" => hex(inv.request_sha256),
        "response_sha256" => hex(inv.response_sha256),
        "output_schema_sha256" => hex(inv.output_schema_sha256)
      }
    end

    defp identity_section(inv) do
      %{
        "provider" => name(inv.provider),
        "cli_version" => inv.provider_version,
        "profile_id" => name(inv.profile_id),
        "model_id" => inv.model_id,
        "prompt_builder" => prompt_builder(inv.model_catalog_entry),
        "ledger_generation" => inv.ledger_generation
      }
    end

    defp canonical_hex(term) do
      case encode(term) do
        {:ok, _bytes, sha256} -> sha256
        {:error, :basis_invalid} -> nil
      end
    end

    defp stamp(%DateTime{time_zone: "Etc/UTC", microsecond: {micro, _precision}} = at),
      do: DateTime.to_iso8601(%{at | microsecond: {micro, 6}})

    defp stamp(_other), do: nil

    defp decimal(value) when is_integer(value), do: Integer.to_string(value)
    defp decimal(_other), do: nil

    defp name(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
      do: Atom.to_string(value)

    defp name(_other), do: nil

    defp prompt_builder(%{"prompt_builder" => builder}) when is_binary(builder), do: builder
    defp prompt_builder(_other), do: nil

    defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
    defp hex(_other), do: nil

    defp sha(bytes), do: :crypto.hash(:sha256, bytes)

    ## The complete shape (total: patterns and guards only)

    defp shape(basis) when is_map(basis) do
      if Enum.sort(Map.keys(basis)) == @top_keys and constants?(basis) and sections?(basis),
        do: :ok,
        else: {:error, :basis_invalid}
    end

    defp shape(_not_a_map), do: {:error, :basis_invalid}

    defp constants?(basis), do: Enum.all?(@constants, fn {key, value} -> basis[key] == value end)

    defp sections?(basis) do
      Enum.all?(@grammar, fn {section, leaves} ->
        section?(Map.get(basis, section), section, leaves)
      end)
    end

    defp section?(values, section, leaves) when is_map(values) do
      Enum.sort(Map.keys(values)) == Enum.sort(Map.keys(leaves)) and
        Enum.all?(leaves, fn {key, kind} ->
          value = Map.get(values, key)
          leaf?(kind, value) and fixed?({section, key}, value)
        end)
    end

    defp section?(_not_a_map, _section, _leaves), do: false

    # Both owner-reviewed starts remain valid historical shape constants.
    # New decisions still rebuild from their exact current funding facts;
    # historical verification never substitutes those current facts.
    defp fixed?({"window", "starts_at"}, value),
      do:
        value in [
          "2026-10-28T02:38:32.000000Z",
          "2026-10-30T15:05:40.000000Z"
        ]

    defp fixed?(path, value) do
      case Map.fetch(@fixed, path) do
        {:ok, fixed} -> value == fixed
        :error -> true
      end
    end

    defp leaf?(:count, value), do: is_integer(value) and value >= 0
    defp leaf?(:positive, value), do: is_integer(value) and value > 0
    defp leaf?(kind, value) when is_binary(value), do: text?(kind, value)
    defp leaf?(_kind, _value), do: false

    defp text?(kind, value) do
      String.valid?(value) and value != "" and
        case kind do
          :uuid -> Regex.match?(@uuid, value)
          :hex64 -> Regex.match?(@hex64, value)
          :stamp -> Regex.match?(@stamp, value)
          :decimal -> Regex.match?(@decimal, value)
          :text -> true
        end
    end
  end
end
