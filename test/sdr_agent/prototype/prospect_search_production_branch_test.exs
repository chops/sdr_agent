defmodule SdrAgent.Prototype.ProspectSearchProductionBranchTest do
  @moduledoc "Ordinary-build source control; no authority or egress can be activated by runtime input."
  use ExUnit.Case, async: false

  @twin SdrAgent.Prototype.ProspectSearchProductionTwin

  setup_all do
    source = File.read!("lib/sdr_agent/prototype/prospect_search.ex")

    source =
      String.replace(
        source,
        "defmodule SdrAgent.Prototype.ProspectSearch do",
        "defmodule #{inspect(@twin)} do"
      )

    previous = Application.fetch_env(:sdr_agent, :prototype_authority_compiled)

    modules =
      try do
        Application.put_env(:sdr_agent, :prototype_authority_compiled, false)
        Code.compile_string(source, "prospect_search_production_twin.ex")
      after
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, :prototype_authority_compiled, value)
          :error -> Application.delete_env(:sdr_agent, :prototype_authority_compiled)
        end
      end

    assert [{@twin, binary}] = modules
    %{binary: binary}
  end

  test "ordinary facade is constant refusal for every entry" do
    for actor <- [nil, %{}, %{id: "forged", role: :reviewer, tenant_id: "forged"}] do
      refute Function.capture(@twin, :authorized?, 1).(actor)
      refute Function.capture(@twin, :available?, 1).(actor)

      assert Function.capture(@twin, :start, 2).(actor, %{kind: :company, query: "x"}) ==
               {:error, :forbidden}

      assert Function.capture(@twin, :cancel, 2).(actor, "id") == {:error, :forbidden}

      assert Function.capture(@twin, :company_context, 3).(actor, %{}, %{}) ==
               {:error, :forbidden}
    end
  end

  test "ordinary facade beam cannot reference persistence, authority or transport", ctx do
    assert {:ok, {@twin, [imports: imports, atoms: atoms]}} =
             :beam_lib.chunks(ctx.binary, [:imports, :atoms])

    names =
      Enum.map(imports, fn {mod, _, _} -> Atom.to_string(mod) end) ++
        Enum.map(atoms, fn {_, atom} -> Atom.to_string(atom) end)

    for prefix <- [
          "Elixir.SdrAgent.Discovery",
          "Elixir.SdrAgent.Repo",
          "Elixir.SdrAgent.Audit",
          "Elixir.SdrAgent.Prototype.Authority"
        ] do
      refute Enum.any?(names, &String.starts_with?(&1, prefix))
    end
  end
end
