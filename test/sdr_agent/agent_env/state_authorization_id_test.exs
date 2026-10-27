defmodule SdrAgent.AgentEnv.StateAuthorizationIdTest do
  @moduledoc """
  C2* S1 PR-A, Codex GREEN-1 review `1adda407` M1: `authorization_id` in the
  agent environment's state files is an S2 registry id, not a UUID.

  The accepted S2 registry (S2 plan r1 OQ1; `SdrAgent.AgentEnv.Registry` at
  `a208a05a`, its `id?/1`) uses the closed id pattern
  `\\A[a-z0-9][a-z0-9.-]{0,63}\\z`: one lowercase letter or digit, then up
  to 63 lowercase letters, digits, dots or dashes. So `State.read/2`
  accepts exactly those ids, and nothing else, as the `authorization_id`
  of all three shapes that carry one: `authorization.claim.json`,
  `authorization.json` and the `provision` receipt
  `instance.<nonce>.provision.exit`; and
  `OperationSnapshot.authorization/1` projects a final authorization whose
  id is a registry id. A lowercase UUID matches the pattern and stays
  valid; an uppercase one does not. `tenant_id`, `grant_id` and `event_id`
  stay UUIDs, and every other rule (closed keys, canonical bytes, nonce
  and digest shapes, receipt consistency) is unchanged.

  RED: `State` validates `authorization_id` as a UUID, so a valid non-UUID
  registry id is `{:invalid, :value}` in every shape and the snapshot
  cannot project it (intended assertion failures), and an uppercase UUID
  is accepted (an intended assertion failure of the boundary rows). The
  other boundary and preservation rows pass at RED.

  Hermetic: SQL sandbox, physical roots under `tmp/agent-env-roots`.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @state SdrAgent.AgentEnv.State
  @snapshot SdrAgent.AgentEnv.OperationSnapshot

  # Valid before and after M1, so the preservation rows discriminate at RED.
  @uuid_id "550e8400-e29b-41d4-a716-446655440000"

  # Ids the registry pattern accepts (S2 registry_test's `test-synthetic-1`
  # first); the last is a lowercase UUID, which the pattern also accepts.
  @valid_ids [
    "test-synthetic-1",
    "a",
    "0",
    "agentenv-1.grant-2",
    "x.y-z",
    "trailing.",
    "trailing-",
    "a" <> String.duplicate("b", 63),
    "550e8400-e29b-41d4-a716-446655440000"
  ]

  # Ids the pattern refuses: empty; uppercase (including an uppercase
  # UUID); a leading dot or dash; 65 characters; characters outside the
  # class; a trailing newline; and non-strings.
  @invalid_ids [
    {"empty", ""},
    {"uppercase", "Test-synthetic-1"},
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

  # The three shapes that carry an `authorization_id`, as {name, contents}.
  defp shapes(id, overrides \\ %{}) do
    nonce = Fx.nonce()

    [
      {:claim,
       %{
         "authorization_id" => id,
         "authorization_sha256" => Fx.hex(32),
         "binding_sha256" => Fx.hex(32),
         "nonce" => Fx.nonce(),
         "claimed_at" => DateTime.utc_now()
       }},
      {:authorization,
       %{
         "authorization_id" => id,
         "authorization_sha256" => Fx.hex(32),
         "binding_sha256" => Fx.hex(32),
         "grant_id" => Ecto.UUID.generate(),
         "revision" => 1,
         "event_id" => Ecto.UUID.generate(),
         "nonce" => Fx.nonce()
       }},
      {{:receipt, nonce, :provision},
       %{
         "nonce" => nonce,
         "step" => "provision",
         "completed_at" => DateTime.utc_now(),
         "authorization_id" => id,
         "grant_id" => Ecto.UUID.generate(),
         "event_id" => Ecto.UUID.generate()
       }}
    ]
    |> Enum.map(fn {name, contents} -> {name, Map.merge(contents, overrides)} end)
  end

  defp label({:receipt, _nonce, step}), do: "the #{step} receipt"
  defp label(name), do: inspect(name)

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
    %{authorized | sha256: Fx.file_sha256!(root, :authorization)}
  end

  ## State.read/2

  describe "State.read/2: registry-pattern authorization ids" do
    for id <- @valid_ids do
      @id id

      test "#{inspect(id)} is a valid authorization_id in the claim, final file and provision receipt",
           ctx do
        for {name, contents} <- shapes(@id) do
          sha256 = Fx.write_state!(ctx.root, name, contents)

          assert {:valid, ^sha256, data} = read(ctx.root, name),
                 "C2* S1 M1: #{label(name)} with the registry id #{inspect(@id)} must be valid"

          assert data["authorization_id"] == @id
        end
      end
    end

    for {label, id} <- @invalid_ids do
      @id id

      test "#{label} (#{inspect(id)}) is not a valid authorization_id in any shape", ctx do
        for {name, contents} <- shapes(@id) do
          Fx.write_state!(ctx.root, name, contents)

          assert read(ctx.root, name) == {:invalid, :value},
                 "C2* S1 M1: #{label(name)} with #{inspect(@id)} must be invalid"
        end
      end
    end

    test "grant_id and event_id stay UUIDs: a registry-pattern id there is invalid", ctx do
      for field <- ["grant_id", "event_id"],
          {name, contents} <- shapes(@uuid_id),
          Map.has_key?(contents, field) do
        Fx.write_state!(ctx.root, name, Map.put(contents, field, "test-synthetic-1"))

        assert read(ctx.root, name) == {:invalid, :value},
               "C2* S1 M1: #{label(name)}'s #{field} must stay a UUID"
      end
    end

    test "the other rules are unchanged: keys, canonical bytes, nonce, digests, receipt step",
         ctx do
      for {name, contents} <- shapes(@uuid_id) do
        cases = [
          extra_key: Canonical.encode!(Map.put(contents, "extra", 1)),
          missing_key: Canonical.encode!(Map.delete(contents, "authorization_id")),
          trailing_newline: Canonical.encode!(contents) <> "\n",
          short_nonce: Canonical.encode!(Map.put(contents, "nonce", Fx.hex(8)))
        ]

        for {case_label, bytes} <- cases do
          Fx.write_state!(ctx.root, name, bytes)

          assert {:invalid, _reason} = read(ctx.root, name),
                 "C2* S1 M1: #{label(name)} #{case_label} must stay invalid"
        end
      end

      [{:claim, claim}, {:authorization, final}, {receipt, provision}] = shapes(@uuid_id)

      for {name, contents} <- [
            {:claim, Map.put(claim, "binding_sha256", "AB" <> Fx.hex(31))},
            {:authorization, Map.put(final, "authorization_sha256", Fx.hex(16))},
            {:authorization, Map.put(final, "revision", 2)},
            {receipt, Map.put(provision, "step", "probe")}
          ] do
        Fx.write_state!(ctx.root, name, contents)
        assert read(ctx.root, name) == {:invalid, :value}, "C2* S1 M1: #{label(name)}"
      end
    end
  end

  ## The snapshot's authorization projection

  describe "OperationSnapshot.authorization/1" do
    test "projects a final authorization whose id is a registry id", ctx do
      run_env!(ctx.root)
      authorized = authorized_as!(ctx.root, "test-synthetic-1")
      snapshot = sample!()
      data = authorized.data
      file_sha256 = authorized.sha256

      assert apply(@snapshot, :authorization, [snapshot]) ==
               {:ok,
                %{
                  sha256: file_sha256,
                  authorization_sha256: data["authorization_sha256"],
                  authorization_id: "test-synthetic-1",
                  binding_sha256: data["binding_sha256"],
                  grant_id: data["grant_id"],
                  revision: 1,
                  event_id: data["event_id"],
                  nonce: data["nonce"]
                }},
             "C2* S1 M1: the snapshot must project a registry-id authorization"
    end

    test "an id outside the pattern is never projected", ctx do
      run_env!(ctx.root)

      for {label, id} <- [
            {"uppercase", "Test-synthetic-1"},
            {"leading dash", "-grant"},
            {"empty", ""}
          ] do
        authorized_as!(ctx.root, id)
        snapshot = sample!()

        assert apply(@snapshot, :authorization, [snapshot]) == {:error, :authorization_invalid},
               "C2* S1 M1: #{label}"
      end
    end
  end
end
