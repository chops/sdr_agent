defmodule SdrAgent.Prototype.OwnerAllowanceTest do
  @moduledoc """
  D-269: the owner's 100 ADDITIONAL application-call attempts, independent
  of earlier consumption. These tests exercise the compiled entry, the
  receipt-bound worksheet, the real provisioning domain API and the actual
  admission ledger. No real model is launched.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.OwnerAllowanceFixtures, as: A
  alias SdrAgent.Prototype.Authority
  alias SdrAgent.PrototypeGateFixtures, as: G

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  setup do
    SdrAgent.Clock.freeze(~U[2026-10-30 17:00:00.000000Z])
    on_exit(&SdrAgent.Clock.unfreeze/0)
    :ok
  end

  test "the funding entry is exactly 100 additional attempts starting at the owner receipt" do
    entry = Authority.funding_entry()
    assert entry.total_attempts == 100
    assert entry.starts_at == ~U[2026-10-30 15:05:40.000000Z]
    assert entry.expires_at == ~U[2026-11-07 07:00:00.000000Z]

    assert entry.allocations == [
             %{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 100}
           ]

    assert entry.decision_refs == ["D-238", "D-239", "D-243", "D-269"]
  end

  test "the exact fresh owner receipt funds 100 without any historical count assertion" do
    root = PrototypeFixtures.scratch_dir!()
    worksheet = A.worksheet(root)
    bytes = Jason.encode!(worksheet)
    assert sha(A.receipt()) == A.receipt_sha256()
    refute Map.has_key?(worksheet, "routes")
    refute Map.has_key?(worksheet, "previous_bindings")

    assert Authority.check_worksheet(bytes, sha(bytes), root) ==
             {:ok, %{sha256: sha(bytes), remaining: 100}}
  end

  test "the operator provisions the new 100 allowance through the real domain API" do
    fx = bound!()
    root = PrototypeFixtures.scratch_dir!()
    bytes = root |> A.worksheet() |> Jason.encode!()

    result =
      Agents.provision_prototype_grant(
        %{worksheet: bytes, worksheet_sha256: sha(bytes)},
        actor: fx.actor,
        evidence_root: root
      )

    assert match?({:ok, %SdrAgent.Agents.ModelCallGrant{}}, result), inspect(result)
    {:ok, grant} = result
    assert grant.name == "d237-funding/1"
    assert grant.total_attempts == 100
    assert grant.starts_at == ~U[2026-10-30 15:05:40.000000Z]
    assert grant.created_by_id == fx.anchor.id
    assert grant.per_utc_day_attempts == nil
  end

  test "100 attempts including failed and uncertain stay charged; 101st refuses and replay cannot reset" do
    fx = G.prototype!()

    for batch <- 1..5 do
      run = G.run!(fx)

      for offset <- 1..20 do
        ordinal = (batch - 1) * 20 + offset
        result = G.reserve(fx, run)

        assert match?({:ok, %ModelInvocation{}}, result),
               "attempt #{ordinal} must fit the owner100 allowance: #{inspect(result)}"

        {:ok, invocation} = result

        case ordinal do
          1 ->
            assert {:ok, %{status: :failed}} =
                     Agents.fail_model_invocation(
                       invocation,
                       %{error: %{"reason" => "synthetic owner100 failure"}},
                       actor: fx.agent
                     )

          2 ->
            assert {:ok, %{status: :sent} = sent} = G.launch(fx, invocation)

            assert {:ok, %{status: :unknown}} =
                     Agents.mark_model_invocation_unknown(sent, actor: fx.agent)

          _reserved ->
            :ok
        end
      end
    end

    assert charged(fx) == 100

    assert {:error, %Refused{stage: :reservation, reason: {:budget_exhausted, :grant}}} =
             G.reserve(fx, G.run!(fx))

    # The wrapper may replay the existing grant, but never mint/reset it.
    replay = G.provision!(fx)
    assert replay.id == fx.grant.id
    assert replay.total_attempts == 100
    assert charged(fx) == 100
    assert length(events_of_type(fx.tenant, "model.grant.provisioned")) == 1

    assert {:error, %Refused{reason: {:budget_exhausted, :grant}}} =
             G.reserve(fx, G.run!(fx))

    assert charged(fx) == 100
  end

  test "a new release basis accepts the new reviewed funding window" do
    fx = G.prototype!()
    run = G.run!(fx)
    invocation = G.completed!(fx, run)

    funding = %{
      Authority.funding_entry()
      | total_attempts: 100,
        starts_at: ~U[2026-10-30 15:05:40.000000Z],
        allocations: [%{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 100}],
        decision_refs: ["D-238", "D-239", "D-243", "D-269"]
    }

    facts = %{
      snapshot: fx.snapshot,
      entry: Authority.policy_entry(),
      funding: funding,
      invocation: invocation,
      run: run,
      grant: fx.grant,
      decided_at: SdrAgent.Clock.utc_now()
    }

    assert {:ok, basis, digest} = SdrAgent.Prototype.Basis.build(facts)
    assert basis["window"]["starts_at"] == "2026-10-30T15:05:40.000000Z"
    assert :ok = SdrAgent.Prototype.Basis.verify_new(%{basis: basis, basis_sha256: digest}, facts)
  end

  defp charged(fx) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^fx.grant.id)
    |> Ash.count!(actor: fx.agent)
  end
end
