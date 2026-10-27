defmodule SdrAgent.AgentEnv.StateAuthorizationIdTest do
  @moduledoc """
  C2* S1 PR-A, Codex GREEN-1 review `1adda407` M1 and its RED review
  `0a71243f` (option 1, in principle): the identifiers in the agent
  environment's state files are validated as the text they are.

    * **`authorization_id` is an S2 registry id.** The accepted S2 registry
      (S2 plan r1 OQ1; `SdrAgent.AgentEnv.Registry` at `a208a05a`, `id?/1`)
      uses the closed pattern `\\A[a-z0-9][a-z0-9.-]{0,63}\\z`: one
      lowercase letter or digit, then up to 63 lowercase letters, digits,
      dots or dashes. `State.read/2` accepts exactly those ids, and nothing
      else, in all three shapes that carry one: `authorization.claim.json`,
      `authorization.json` and the `provision` receipt
      `instance.<nonce>.provision.exit`. `OperationSnapshot.authorization/1`
      projects a final authorization whose id is a registry id.
    * **`tenant_id`, `grant_id` and `event_id` are canonical UUID text:**
      the lowercase hyphenated form that `Ecto.UUID.cast/1` returns
      unchanged, of any version (generated v4 and v7 both pass). Uppercase
      UUID text and a 16-byte ASCII string (which `Ecto.UUID.cast/1` alone
      accepts as a raw UUID) are invalid, in `environment.json`'s and the
      probe receipt's `tenant_id`, and in the final file's and the
      provision receipt's `grant_id` and `event_id`.
    * Every other rule (closed keys, canonical bytes, nonce, digest,
      revision and receipt step) is unchanged.

  Each id and each field is exercised by its own test in each shape, so
  one failure never leaves another case unreached.

  Expected RED (to be confirmed by the run, not asserted here): State
  checks `authorization_id` and the three UUID fields with
  `Ecto.UUID.cast/1`, so each valid non-16-byte registry id is
  `{:invalid, :value}` in each shape and is not projected, and the 16-byte
  and uppercase-UUID texts are accepted, all as assertion failures. The
  controls pass at RED: `test-synthetic-1` (16 bytes, accepted today only
  through the raw-UUID path) and a lowercase UUID as authorization ids,
  generated canonical UUIDs in every UUID field, and the other boundary
  and preservation rows.

  Hermetic: SQL sandbox, physical roots under `tmp/agent-env-roots`.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @state SdrAgent.AgentEnv.State
  @snapshot SdrAgent.AgentEnv.OperationSnapshot

  # A lowercase UUID: a valid authorization id before and after M1, so the
  # preservation rows discriminate at RED.
  @uuid_id "550e8400-e29b-41d4-a716-446655440000"
  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @shapes [:claim, :authorization, :provision_receipt]

  # Valid registry ids: {label, id, kind}. `:discriminating` ids are
  # rejected by the current UUID check; `:control` ids pass it already.
  @valid_ids [
    {"one letter", "a", :discriminating},
    {"one digit", "0", :discriminating},
    {"dotted and dashed", "agentenv-1.grant-2", :discriminating},
    {"short dotted", "x.y-z", :discriminating},
    {"trailing dot", "trailing.", :discriminating},
    {"trailing dash", "trailing-", :discriminating},
    {"64 characters", "a" <> String.duplicate("b", 63), :discriminating},
    {"16-byte registry id", "test-synthetic-1", :control},
    {"lowercase uuid", @uuid_id, :control}
  ]

  # Ids the pattern refuses: {label, id}.
  @invalid_ids [
    {"empty", ""},
    {"uppercase 16-byte", "Test-synthetic-1"},
    {"all uppercase", "TEST"},
    {"uppercase uuid", "550E8400-E29B-41D4-A716-446655440000"},
    {"leading dot", ".grant"},
    {"leading dash", "-grant"},
    {"65 characters", "a" <> String.duplicate("b", 64)},
    {"underscore", "test_synthetic"},
    {"space", "test synthetic"},
    {"slash", "test/synthetic"},
    {"non-ascii", "tëst"},
    {"trailing newline", "test-synthetic-1\n"},
    {"integer", 1},
    {"null", nil},
    {"list", ["test-synthetic-1"]}
  ]

  # The State consumers of canonical UUID text: {shape, field}.
  @uuid_fields [
    {:environment, "tenant_id"},
    {:probe_receipt, "tenant_id"},
    {:authorization, "grant_id"},
    {:authorization, "event_id"},
    {:provision_receipt, "grant_id"},
    {:provision_receipt, "event_id"}
  ]

  setup do
    bootstrap!()
    root = Fx.root!("authorization-id")
    Fx.unconfigure!()
    %{root: root}
  end

  ## Helpers

  defp require!(module, functions) do
    assert Code.ensure_loaded?(module), "C2* S1 M1: #{inspect(module)} is not available"

    for {function, arity} <- functions do
      assert function_exported?(module, function, arity),
             "C2* S1 M1: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp read(root, name) do
    require!(@state, read: 2)
    apply(@state, :read, [root, name])
  end

  # `{state file name, contents}` of `shape`, every field valid, with
  # `fields` (string keys) overriding.
  defp shape(shape, fields \\ %{})

  defp shape(:claim, fields) do
    {:claim,
     Map.merge(
       %{
         "authorization_id" => @uuid_id,
         "authorization_sha256" => Fx.hex(32),
         "binding_sha256" => Fx.hex(32),
         "nonce" => Fx.nonce(),
         "claimed_at" => DateTime.utc_now()
       },
       fields
     )}
  end

  defp shape(:authorization, fields) do
    {:authorization,
     Map.merge(
       %{
         "authorization_id" => @uuid_id,
         "authorization_sha256" => Fx.hex(32),
         "binding_sha256" => Fx.hex(32),
         "grant_id" => Ecto.UUID.generate(),
         "revision" => 1,
         "event_id" => Ecto.UUID.generate(),
         "nonce" => Fx.nonce()
       },
       fields
     )}
  end

  defp shape(:provision_receipt, fields) do
    nonce = Fx.nonce()

    {{:receipt, nonce, :provision},
     Map.merge(
       %{
         "nonce" => nonce,
         "step" => "provision",
         "completed_at" => DateTime.utc_now(),
         "authorization_id" => @uuid_id,
         "grant_id" => Ecto.UUID.generate(),
         "event_id" => Ecto.UUID.generate()
       },
       fields
     )}
  end

  defp shape(:probe_receipt, fields) do
    nonce = Fx.nonce()

    {{:receipt, nonce, :probe},
     Map.merge(
       %{
         "nonce" => nonce,
         "step" => "probe",
         "completed_at" => DateTime.utc_now(),
         "tenant_id" => Ecto.UUID.generate()
       },
       fields
     )}
  end

  defp shape(:environment, fields) do
    {:environment,
     Map.merge(
       %{
         "environment_id" => "agentenv-1",
         "database" => "sdr_agent_agentenv",
         "database_oid" => 424_242,
         "tenant_id" => Ecto.UUID.generate(),
         "nonce" => Fx.nonce(),
         "created_at" => DateTime.utc_now()
       },
       fields
     )}
  end

  defp label({:receipt, _nonce, step}), do: "the #{step} receipt"
  defp label(name), do: inspect(name)

  # Writes `shape` with `fields` and asserts it reads back as valid, with
  # its digest and every overridden field unchanged.
  defp assert_valid(root, shape, fields, message) do
    {name, contents} = shape(shape, fields)
    sha256 = Fx.write_state!(root, name, contents)
    result = read(root, name)

    assert match?({:valid, ^sha256, %{}}, result),
           "C2* S1 M1: #{label(name)} #{message} must be valid: #{inspect(result)}"

    {:valid, ^sha256, data} = result

    for {field, value} <- fields do
      assert data[field] == value, "C2* S1 M1: #{label(name)}'s #{field} must read back unchanged"
    end
  end

  defp assert_invalid(root, shape, fields, message) do
    {name, contents} = shape(shape, fields)
    Fx.write_state!(root, name, contents)
    result = read(root, name)

    assert result == {:invalid, :value},
           "C2* S1 M1: #{label(name)} #{message} must be invalid: #{inspect(result)}"
  end

  defp run_env!(root) do
    bound = Fx.bound!(root, lease: :run)
    Fx.configure!(root, mode: :run, nonce: bound.nonce, step: :run)
    bound
  end

  defp sample! do
    require!(@snapshot, enter: 2, current: 0, authorization: 1)

    case apply(@snapshot, :enter, [:approve, fn -> apply(@snapshot, :current, []) end]) do
      {:ok, snapshot} -> snapshot
      other -> flunk("C2* S1: a top-level owner sampled no snapshot: #{inspect(other)}")
    end
  end

  # The authorization files bound to `root`'s environment, the claim and
  # the final file both naming `id`.
  defp authorized_as!(root, id) do
    authorized = Fx.authorized!(root, %{"authorization_id" => id})
    Fx.write_state!(root, :claim, Map.put(authorized.claim, "authorization_id", id))
    authorized
  end

  defp assert_projected(ctx, id) do
    run_env!(ctx.root)
    authorized = authorized_as!(ctx.root, id)
    data = authorized.data

    assert apply(@snapshot, :authorization, [sample!()]) ==
             {:ok,
              %{
                sha256: authorized.sha256,
                authorization_sha256: data["authorization_sha256"],
                authorization_id: id,
                binding_sha256: data["binding_sha256"],
                grant_id: data["grant_id"],
                revision: 1,
                event_id: data["event_id"],
                nonce: data["nonce"]
              }},
           "C2* S1 M1: the snapshot must project the registry-id authorization #{inspect(id)}"
  end

  ## authorization_id in each shape

  describe "State.read/2: valid registry ids, each shape on its own" do
    for {label, id, kind} <- @valid_ids, shape <- @shapes do
      @id id
      @shape shape

      test "#{kind}: #{label} (#{inspect(id)}) is a valid authorization_id in #{shape}", ctx do
        assert_valid(ctx.root, @shape, %{"authorization_id" => @id}, "with #{inspect(@id)}")
      end
    end
  end

  describe "State.read/2: ids outside the registry pattern, each shape on its own" do
    for {label, id} <- @invalid_ids, shape <- @shapes do
      @id id
      @shape shape

      test "#{label} (#{inspect(id)}) is not a valid authorization_id in #{shape}", ctx do
        assert_invalid(ctx.root, @shape, %{"authorization_id" => @id}, "with #{inspect(@id)}")
      end
    end
  end

  ## Canonical UUID text in each consumer

  describe "State.read/2: canonical lowercase UUID text, each field and shape on its own" do
    for {shape, field} <- @uuid_fields do
      @shape shape
      @field field

      test "#{shape} #{field}: a generated v4 UUID is valid", ctx do
        uuid = Ecto.UUID.generate()
        assert uuid =~ @canonical_uuid
        assert_valid(ctx.root, @shape, %{@field => uuid}, "with a v4 #{@field}")
      end

      test "#{shape} #{field}: a generated v7 UUID is valid", ctx do
        uuid = Ash.UUIDv7.generate()
        assert uuid =~ @canonical_uuid
        assert_valid(ctx.root, @shape, %{@field => uuid}, "with a v7 #{@field}")
      end

      test "#{shape} #{field}: a 16-byte ASCII non-UUID is invalid", ctx do
        assert byte_size("test-synthetic-1") == 16

        assert_invalid(
          ctx.root,
          @shape,
          %{@field => "test-synthetic-1"},
          "with a 16-byte #{@field}"
        )
      end

      test "#{shape} #{field}: uppercase UUID text is invalid", ctx do
        # The fixed, letter-bearing @uuid_id: a random UUID could be all digits
        # where uppercasing applies, and so stay canonical.
        uuid = String.upcase(@uuid_id)
        assert_invalid(ctx.root, @shape, %{@field => uuid}, "with an uppercase #{@field}")
      end

      test "#{shape} #{field}: malformed values stay invalid", ctx do
        uuid = Ecto.UUID.generate()

        for {kind, value} <- [
              null: nil,
              integer: 1,
              short: String.slice(uuid, 0, 35),
              long: uuid <> "0",
              unhyphenated: String.replace(uuid, "-", ""),
              not_hex: "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
              registry_id: "agentenv-1.grant-2"
            ] do
          assert_invalid(ctx.root, @shape, %{@field => value}, "with a #{kind} #{@field}")
        end
      end
    end
  end

  ## Unchanged rules

  describe "State.read/2: the other rules are unchanged" do
    for shape <- @shapes do
      @shape shape

      test "#{shape}: closed keys, canonical bytes and the nonce stay enforced", ctx do
        {name, contents} = shape(@shape)

        for {case_label, bytes} <- [
              extra_key: Canonical.encode!(Map.put(contents, "extra", 1)),
              missing_key: Canonical.encode!(Map.delete(contents, "authorization_id")),
              trailing_newline: Canonical.encode!(contents) <> "\n",
              short_nonce: Canonical.encode!(Map.put(contents, "nonce", Fx.hex(8)))
            ] do
          Fx.write_state!(ctx.root, name, bytes)
          result = read(ctx.root, name)

          assert match?({:invalid, _reason}, result),
                 "C2* S1 M1: #{label(name)} #{case_label} must stay invalid: #{inspect(result)}"
        end
      end
    end

    test "digests, the revision and the receipt step stay enforced", ctx do
      for {shape, fields} <- [
            {:claim, %{"binding_sha256" => "AB" <> Fx.hex(31)}},
            {:authorization, %{"authorization_sha256" => Fx.hex(16)}},
            {:authorization, %{"revision" => 2}},
            {:provision_receipt, %{"step" => "probe"}}
          ] do
        assert_invalid(ctx.root, shape, fields, "with #{inspect(fields)}")
      end
    end
  end

  ## The snapshot's authorization projection

  describe "OperationSnapshot.authorization/1" do
    test "discriminating: projects a registry-id authorization (agentenv-1.grant-2)", ctx do
      assert_projected(ctx, "agentenv-1.grant-2")
    end

    test "control: projects the 16-byte registry id test-synthetic-1", ctx do
      assert_projected(ctx, "test-synthetic-1")
    end

    for {label, id} <- [
          {"uppercase 16-byte", "Test-synthetic-1"},
          {"uppercase uuid", "550E8400-E29B-41D4-A716-446655440000"},
          {"leading dash", "-grant"},
          {"empty", ""}
        ] do
      @id id

      test "#{label} (#{inspect(id)}) is never projected", ctx do
        run_env!(ctx.root)
        authorized_as!(ctx.root, @id)

        assert apply(@snapshot, :authorization, [sample!()]) == {:error, :authorization_invalid},
               "C2* S1 M1: #{inspect(@id)} must not be projected"
      end
    end
  end
end
