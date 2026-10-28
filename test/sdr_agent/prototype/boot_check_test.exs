defmodule SdrAgent.Prototype.BootCheckTest do
  @moduledoc """
  IF-2 boot check (interfaces r6; amendment item 2 "Boot"): the five switch
  rows, every "exact" condition, the fixed refusal codes, and the
  supervision child failing the start.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.BootCheck

  # Restores one application env key after the test.
  defp put_env!(key, value) do
    previous = Application.fetch_env(:sdr_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:sdr_agent, key, v)
        :error -> Application.delete_env(:sdr_agent, key)
      end
    end)

    Application.put_env(:sdr_agent, key, value)
  end

  defp switch!(fx) do
    switch = PrototypeFixtures.switch(fx)
    assert match?(%{policy_id: _, instance_id: _}, switch), "switch/1: #{inspect(switch)}"
    switch
  end

  describe "the five rows" do
    test "off with no binding is ordinary" do
      assert BootCheck.check(:off) == {:ok, :ordinary}
    end

    test "on with an exact binding and no store root is prototype, with the row's snapshot" do
      fx = bound!(enter_runtime: false)
      assert BootCheck.check(switch!(fx)) == {:ok, :prototype, fx.snapshot}
    end

    test "on with an exact binding and a store root refuses" do
      fx = bound!(enter_runtime: false)

      put_env!(SdrAgent.Agents.Witness,
        store_root: "/private/tmp/d237-test-store",
        reconciled_methods: []
      )

      assert BootCheck.check(switch!(fx)) == {:error, :witness_store_configured}
    end

    test "on with no binding refuses" do
      switch = %{policy_id: "d237-prototype/1", instance_id: Ecto.UUID.generate()}
      assert BootCheck.check(switch) == {:error, :binding_absent}
    end

    test "off with a binding refuses" do
      bound!(enter_runtime: false)
      assert BootCheck.check(:off) == {:error, :binding_without_switch}
    end
  end

  describe "exactness" do
    test "a wrong policy id or instance refuses" do
      fx = bound!(enter_runtime: false)
      switch = switch!(fx)

      assert BootCheck.check(%{switch | policy_id: "d237-prototype/2"}) ==
               {:error, :switch_invalid}

      assert BootCheck.check(%{switch | instance_id: Ecto.UUID.generate()}) ==
               {:error, :instance_mismatch}
    end

    test "a row whose policy digest is not the compiled entry's refuses" do
      fx = bound!(enter_runtime: false)

      tamper!(
        "UPDATE prototype_database_bindings SET policy_entry_sha256 = $1 WHERE id = $2",
        [String.duplicate("f", 64), Ecto.UUID.dump!(fx.binding.id)]
      )

      assert BootCheck.check(switch!(fx)) == {:error, :policy_mismatch}
    end

    test "a live database name, oid or system identifier differing from the row refuses" do
      fx = bound!(enter_runtime: false)

      for overrides <- [%{database: "sdr_agent_dev"}, %{database_oid: 1}, %{system_identifier: 9}] do
        assert PrototypeFixtures.put_live_identity(overrides) == :ok

        assert BootCheck.check(switch!(fx)) == {:error, :database_mismatch},
               "live identity #{inspect(overrides)} was accepted"
      end

      assert PrototypeFixtures.put_live_identity(:raise) == :ok
      assert BootCheck.check(switch!(fx)) == {:error, :live_identity_unavailable}
    end

    test "users other than the anchor and the one bound auditor refuse" do
      fx = bound!(enter_runtime: false, auditor: true)
      assert BootCheck.check(switch!(fx)) == {:ok, :prototype, fx.snapshot}
      new_human(:auditor, fx.tenant)
      assert BootCheck.check(switch!(fx)) == {:error, :users_not_exact}
    end

    test "a third user refuses" do
      fx = bound!(enter_runtime: false)
      new_human(:reviewer, fx.tenant)
      assert BootCheck.check(switch!(fx)) == {:error, :users_not_exact}
    end

    test "the NoStore suppression check refuses" do
      fx = bound!(enter_runtime: false)
      put_env!(:suppression_check, SdrAgent.SDR.SuppressionCheck.NoStore)
      assert BootCheck.check(switch!(fx)) == {:error, :suppression_not_store}
    end

    test "an agent-environment (C2*) configuration with the switch refuses" do
      fx = bound!(enter_runtime: false)
      put_env!(SdrAgent.AgentEnv, mode: :check)
      assert BootCheck.check(switch!(fx)) == {:error, :agent_env_configured}
    end
  end

  describe "the users rule (G2)" do
    test "the anchor turned into a password-bearing user refuses (labelled synthetic tamper)" do
      fx = bound!(enter_runtime: false)

      # SYNTHETIC TAMPER (a DBA simulation, triggers off): the users CHECK
      # (role = agent_operator) = (hashed_password IS NULL) makes a credential
      # on the agent_operator anchor unrepresentable, so the anchor must also
      # change role to carry one. Not reachable through any action.
      tamper!(
        "UPDATE users SET role = 'admin', hashed_password =  WHERE id = ",
        ["synthetic-test-hash-not-a-credential", Ecto.UUID.dump!(fx.anchor.id)]
      )

      assert BootCheck.check(switch!(fx)) == {:error, :users_not_exact}
    end
  end

  # G1 (Codex 23b4603a): the runtime is fixed once. In a test-seam build the
  # fix is the calling process's TestSeam state: nil is unfixed, :ordinary
  # is a fixed ordinary runtime, {:prototype, snapshot} a fixed prototype.
  describe "write-once runtime transitions (G1)" do
    alias SdrAgent.Prototype.Authority.TestSeam

    defp state, do: TestSeam.lookup({SdrAgent.Prototype, :runtime})

    defp verify(switch) do
      BootCheck.verify!(switch: switch)
    rescue
      error in SdrAgent.Prototype.BootCheck.Refusal -> {:refused, error.code}
    end

    defp fabricated_snapshot do
      fields = Map.new(SdrAgent.Prototype.Binding.fields(), &{&1, nil})
      struct!(SdrAgent.Prototype.Binding, %{fields | id: Ecto.UUID.generate()})
    end

    test "unfixed: the exact switch fixes prototype; the same snapshot again is idempotent" do
      fx = bound!(enter_runtime: false)
      assert TestSeam.clear() == :ok
      assert state() == nil

      assert verify(switch!(fx)) == :ok
      assert SdrAgent.Prototype.runtime() == :prototype
      assert SdrAgent.Prototype.binding() == {:ok, fx.snapshot}

      assert verify(switch!(fx)) == :ok
      assert SdrAgent.Prototype.binding() == {:ok, fx.snapshot}
    end

    test "an initial refusal mutates nothing" do
      fx = bound!(enter_runtime: false)
      assert TestSeam.clear() == :ok
      wrong = %{switch!(fx) | instance_id: Ecto.UUID.generate()}

      assert verify(wrong) == {:refused, :instance_mismatch}
      assert state() == nil, "an initial refusal fixed #{inspect(state())}"
      assert verify(switch!(fx)) == :ok
    end

    test "after a prototype fix, a refused check or a different prototype never resets or rebinds" do
      fx = bound!(enter_runtime: false)
      assert TestSeam.clear() == :ok
      assert verify(switch!(fx)) == :ok

      wrong = %{switch!(fx) | instance_id: Ecto.UUID.generate()}
      assert verify(wrong) == {:refused, :instance_mismatch}
      assert SdrAgent.Prototype.binding() == {:ok, fx.snapshot}

      other = %{fx.snapshot | id: Ecto.UUID.generate()}
      assert TestSeam.enter_runtime(other) == :ok
      assert verify(switch!(fx)) == {:refused, :binding_not_exact}
      assert SdrAgent.Prototype.binding() == {:ok, other}
    end

    test "a check returning ordinary after a prototype fix refuses and keeps the prototype" do
      snapshot = fabricated_snapshot()
      assert TestSeam.enter_runtime(snapshot) == :ok

      assert verify(:off) == {:refused, :binding_not_exact}
      assert SdrAgent.Prototype.runtime() == :prototype
      assert SdrAgent.Prototype.binding() == {:ok, snapshot}
    end

    test "a fixed ordinary runtime never promotes" do
      assert TestSeam.clear() == :ok
      assert verify(:off) == :ok
      assert state() == :ordinary, "the ordinary verify fixed #{inspect(state())}"

      fx = bound!(enter_runtime: false)
      assert verify(switch!(fx)) == {:refused, :binding_not_exact}
      assert SdrAgent.Prototype.runtime() == :ordinary
    end
  end

  describe "verify!/0 and the child" do
    test "the BootCheck child starts after the Repo and before the provider, Oban and the endpoint (structural)" do
      children = SdrAgent.Application.children()

      position = fn wanted ->
        Enum.find_index(children, fn
          {module, _arg} -> module == wanted
          module -> module == wanted
        end)
      end

      boot = position.(BootCheck)
      assert is_integer(boot), "no BootCheck child in #{inspect(children)}"
      assert position.(SdrAgent.Repo) < boot
      assert boot < position.(Oban)
      assert boot < position.(SdrAgentWeb.Endpoint)

      for child <- SdrAgent.AI.ModelProvider.Runtime.children() do
        assert boot < Enum.find_index(children, &(&1 == child))
      end
    end

    test "the refusal codes are the closed boot set" do
      assert Enum.sort(BootCheck.reasons()) ==
               Enum.sort([
                 :switch_invalid,
                 :switch_outside_dev,
                 :agent_env_configured,
                 :binding_absent,
                 :binding_without_switch,
                 :binding_not_exact,
                 :instance_mismatch,
                 :policy_mismatch,
                 :database_mismatch,
                 :live_identity_unavailable,
                 :witness_store_configured,
                 :suppression_not_store,
                 :users_not_exact
               ])
    end

    test "the child returns {:error, code} for a refused switch, which fails a supervisor start" do
      switch = %{policy_id: "d237-prototype/1", instance_id: Ecto.UUID.generate()}
      assert BootCheck.start_link(switch: switch) == {:error, :binding_absent}

      result = Supervisor.start_link([{BootCheck, switch: switch}], strategy: :one_for_one)
      assert match?({:error, _}, result), "a refusing child started: #{inspect(result)}"
    end

    test "the child is :ignore for an ordinary start" do
      assert BootCheck.start_link(switch: :off) == :ignore
    end

    test "verify!/0 raises one fixed code and holds no value" do
      error =
        try do
          BootCheck.verify!(switch: %{policy_id: "d237-prototype/1", instance_id: "not-a-uuid"})
          :no_raise
        rescue
          e in SdrAgent.Prototype.BootCheck.Refusal -> e
        end

      assert match?(%SdrAgent.Prototype.BootCheck.Refusal{code: :switch_invalid}, error),
             "verify!/1 did not raise :switch_invalid: #{inspect(error)}"

      assert Exception.message(error) == "prototype boot refused: switch_invalid"
    end
  end
end
