defmodule SdrAgent.Prototype.FacadeTest do
  @moduledoc """
  IF-1 facade (interfaces r6): the ordinary-runtime refusals every caller
  handles, and in prototype runtime the exact boot snapshot, compiled
  entries and assurance block.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Binding

  @label "UNVERIFIED (PROTOTYPE)"
  # The published amendment interior (2c8ab98, BEGIN-newline convention, 54769 bytes).
  @text_sha256 "99a2869ea7501eeeb4615137f23f830de5ddabc2ac746ae6638fbc6fafde9ac0"

  @policy_entry %{
    database: "sdr_agent_prototype",
    dataset_class: :real_prototype,
    identity: %{provider: :claude_cli, ledger_generation: 2, profile_ids: [:claude_cli_opus]},
    usage_origins: [:assignment],
    purposes: [:qualification, :evidence_extraction, :outreach_proposal],
    witness_mode: :absent,
    funding_id: "d237-funding/1",
    max_contacts: 3,
    label: @label,
    acceptance_ref: "D-249",
    text_sha256: @text_sha256
  }

  @funding_entry %{
    total_attempts: 50,
    starts_at: ~U[2026-10-28 02:38:32.000000Z],
    expires_at: ~U[2026-11-07 07:00:00.000000Z],
    profile_ids: [:claude_cli_opus],
    funded_scope: [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}],
    allocations: [%{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 50}],
    decision_refs: ["D-238", "D-239", "D-243"]
  }

  describe "ordinary runtime" do
    test "the runtime is ordinary and the label is the constant" do
      assert Prototype.runtime() == :ordinary
      assert Prototype.label() == @label
    end

    test "every authority function refuses with :not_prototype_runtime" do
      refusals = [
        binding: Prototype.binding(),
        check_live: Prototype.check_live(),
        assurance: Prototype.assurance(),
        policy_entry: Prototype.policy_entry(),
        funding_entry: Prototype.funding_entry(),
        enter_session: Prototype.enter_session(:claude_code, "session-ordinary-1"),
        operator_actor: Prototype.operator_actor(Ecto.UUID.generate())
      ]

      for {name, result} <- refusals do
        assert result == {:error, :not_prototype_runtime},
               "#{name} in ordinary runtime returned #{inspect(result)}"
      end
    end

    test "no actor is an operator" do
      forged = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: nil}
      refute Prototype.operator?(forged)
      refute Prototype.operator?(nil)
    end
  end

  describe "prototype runtime" do
    test "binding/0 is the boot snapshot of the bound row, exactly" do
      fx = bound!()
      assert {:ok, %Binding{} = snapshot} = Prototype.binding()
      assert snapshot == fx.snapshot
      assert snapshot.id == fx.binding.id
      assert snapshot.tenant_id == fx.tenant.id
      assert snapshot.operator_user_id == fx.anchor.id
      assert snapshot.auditor_user_id == nil
      assert snapshot.dataset_class == "real_prototype"
      assert snapshot.policy_id == "d237-prototype/1"
      assert snapshot.funding_id == "d237-funding/1"
      assert snapshot.witness_mode == "absent"
      assert snapshot.database == "sdr_agent_prototype"
      assert is_integer(snapshot.database_oid) and snapshot.database_oid > 0
      assert is_integer(snapshot.system_identifier)
      assert Prototype.runtime() == :prototype
    end

    test "the compiled entries are exact and the binding records the policy digest" do
      fx = bound!()
      assert Prototype.policy_entry() == {:ok, @policy_entry}
      assert Prototype.funding_entry() == {:ok, @funding_entry}

      digest = Base.encode16(SdrAgent.Audit.Canonical.sha256(@policy_entry), case: :lower)
      assert fx.snapshot.policy_entry_sha256 == digest
    end

    test "assurance/0 is the IF-5 block" do
      fx = bound!()
      {:ok, entry} = Prototype.policy_entry()
      digest = Base.encode16(SdrAgent.Audit.Canonical.sha256(entry), case: :lower)

      assert Prototype.assurance() ==
               {:ok,
                %{
                  "label" => @label,
                  "policy_id" => "d237-prototype/1",
                  "entry_sha256" => digest,
                  "instance_id" => fx.snapshot.instance_id,
                  "dataset_class" => "real_prototype"
                }}
    end
  end
end
