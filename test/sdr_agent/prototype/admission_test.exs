defmodule SdrAgent.Prototype.AdmissionTest do
  @moduledoc """
  IF-4 admission (interfaces r6; amendment item 4; Codex P1/A1), D-237
  slice S2: the partitioned admission path and the reservation's recorded
  `prototype_authority`.

  - **P1, the purpose reaches the gate.** `Gate.admit_reservation/4` takes
    the call (`%{profile_id:, purpose:}`) as its second argument; its one
    lib caller is `admission.ex:347`. The ordinary path is unchanged: an
    unset store still refuses, a trusted store and a promoted tuple still
    admit.
  - **The gate refusal `:prototype_not_authorized`** is an admission reason
    (a `provider_error` Failure; the run stops `:model_not_admitted`).
  - **The authority travels only in the admission context.**
    `AdmissionContext` carries `prototype_authority` from `Admission.admit/5`
    to `:reserve`'s `AdmissionCharge`, nil when none was admitted, and a
    caller-supplied `prototype_authority` on `:reserve` is Forbidden, and on
    the domain entry path (`Agents.reserve_model_invocation/3`; ClaudeCLI
    with atom or string keys, and the Fake) it is refused before any
    reservation, reservation event or budget change (Codex 339c8e8d,
    ruling 3: refused, not ignored).

  The prototype-runtime cases (scope, witness mode, binding, proof run and
  the recorded 14 keys) follow once S1's runtime fixtures are GREEN.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures

  @call %{profile_id: :claude_cli_opus, purpose: :qualification}

  # The 14 keys of IF-4's recorded authority (values are synthetic here).
  @authority_keys ~w(policy_id entry_sha256 funding_id binding_id instance_id tenant_id
                     operator_user_id dataset_class profile_id purpose grant_id
                     grant_revision allocation_id witness_mode)

  defp authority do
    Map.new(@authority_keys, &{&1, "synthetic-#{&1}"})
  end

  defp ordinary_run do
    %{id: Ecto.UUID.generate(), tenant_id: Ecto.UUID.generate(), usage_origin: :assignment}
  end

  # The gate's answer, or the exception it raised, as a value to assert on.
  defp attempt(fun) do
    fun.()
  rescue
    error -> {:raised, error.__struct__}
  end

  # The shape of a reservation result, without its content.
  defp outcome({:error, %Ash.Error.Forbidden{}}), do: :forbidden
  defp outcome({:error, %{__struct__: error}}), do: {:error, error}
  defp outcome({:ok, %ModelInvocation{provider: provider}}), do: {:reserved, provider}
  defp outcome(other), do: {:other, other}

  defp charge(extra) do
    %{
      grant_id: Ecto.UUID.generate(),
      allocation_id: Ecto.UUID.generate(),
      reserved_at: SdrAgent.Clock.utc_now(),
      calibration_tuple: nil
    }
    |> Map.merge(extra)
    |> AdmissionContext.context()
    |> AdmissionContext.charge()
  end

  describe "ordinary runtime: the purpose reaches Gate.admit_reservation (P1)" do
    test "the call map is the gate's second argument; an unset store refuses" do
      result =
        attempt(fn ->
          Gate.admit_reservation(ordinary_run(), @call, %{root: nil, trusted?: false}, nil)
        end)

      assert result == {:error, :witness_store_untrusted, :store_unset},
             "the gate did not take the call #{inspect(@call)}: #{inspect(result)}"
    end

    test "a trusted store and a promoted tuple still admit the call (ordinary path unchanged)" do
      AdmissionFixtures.admit_tuples!()

      result =
        attempt(fn ->
          Gate.admit_reservation(ordinary_run(), @call, Gate.observe_store(), nil)
        end)

      assert result == {:ok, nil}, "the ordinary admission changed: #{inspect(result)}"
    end
  end

  describe "the prototype gate refusal" do
    test ":prototype_not_authorized is an admission reason (a provider_error Failure)" do
      assert :prototype_not_authorized in Gate.reasons(),
             "Gate.reasons/0 lacks :prototype_not_authorized: #{inspect(Gate.reasons())}"

      assert Admission.admission_reason?(:prototype_not_authorized)
    end
  end

  describe "the recorded authority travels only in the admission context" do
    test "AdmissionContext carries prototype_authority to :reserve's change" do
      recorded = authority()
      charge = charge(%{prototype_authority: recorded})

      assert Map.get(charge, :prototype_authority) == recorded,
             "the admission context dropped prototype_authority: #{inspect(charge)}"
    end

    test "a charge admitted without one reads prototype_authority as nil" do
      charge = charge(%{})

      assert Map.fetch(charge, :prototype_authority) == {:ok, nil},
             "the charge has no prototype_authority default: #{inspect(charge)}"
    end

    test "a caller-supplied prototype_authority on :reserve is Forbidden" do
      tenant = bootstrap!()
      %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
      n = System.unique_integer([:positive])

      {:ok, seed} =
        Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs("seed-#{n}"),
          actor: agent
        )

      attrs =
        "direct-#{n}"
        |> AgentsFixtures.model_attrs()
        |> Map.drop([:request])
        |> Map.merge(%{
          agent_run_id: run.id,
          sequence_in_run: 100 + n,
          request_sha256: seed.request_sha256,
          profile_id: :fake,
          prototype_authority: authority()
        })

      result =
        ModelInvocation
        |> Ash.Changeset.for_create(:reserve, attrs, actor: agent)
        |> Ash.create()

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "a caller-supplied prototype_authority was not Forbidden: #{inspect(result)}"
    end

    test "a caller-supplied prototype_authority is refused on the domain path before any effect" do
      # Codex 339c8e8d ruling 3: refused (not ignored) before any
      # reservation, reservation event or charge, for ClaudeCLI and the
      # Fake, atom- or string-keyed.
      tenant = bootstrap!()
      AgentsFixtures.grant!(tenant)
      %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
      n = System.unique_integer([:positive])

      cases = [
        claude_atom:
          Map.put(AgentsFixtures.claude_attrs("forged-#{n}-1"), :prototype_authority, authority()),
        claude_string:
          "forged-#{n}-2"
          |> AgentsFixtures.claude_attrs()
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
          |> Map.put("prototype_authority", authority()),
        fake_atom:
          Map.put(AgentsFixtures.model_attrs("forged-#{n}-3"), :prototype_authority, authority())
      ]

      # Every case runs before any assertion, so each one's outcome is evidence.
      outcomes =
        for {label, attrs} <- cases do
          result =
            AdmissionFixtures.admitting(fn ->
              Agents.reserve_model_invocation(run, attrs, actor: agent)
            end)

          {label, outcome(result)}
        end

      assert Enum.all?(outcomes, fn {_label, outcome} -> outcome == :forbidden end),
             "not every caller-supplied prototype_authority was refused: #{inspect(outcomes)}"

      assert {:ok, []} = Agents.list_model_invocations(run.id, actor: agent)
      assert events_of_type(tenant, "model.invocation.reserved") == []
      {:ok, reread} = Agents.get_run(run.id, actor: agent)
      assert reread.budget.model_calls_reserved == run.budget.model_calls_reserved
    end
  end
end
