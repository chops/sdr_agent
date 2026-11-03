defmodule SdrAgent.Prototype.OwnerIntakeProductionBranchTest do
  @moduledoc """
  The ordinary-build intake API remains present but refuses without touching
  persistence or prototype authority. A renamed twin compiles the exact source
  with the authority flag off, as in the existing BootCheck branch controls.
  This source-branch control does not replace ordinary production compilation.
  """
  use ExUnit.Case, async: false

  @subject SdrAgent.Prototype.OwnerIntake
  @twin SdrAgent.Prototype.OwnerIntakeProductionTwin

  setup_all do
    source = File.read!("lib/sdr_agent/prototype/owner_intake.ex")

    source =
      String.replace(
        source,
        "defmodule #{inspect(@subject)} do",
        "defmodule #{inspect(@twin)} do"
      )

    previous = Application.fetch_env(:sdr_agent, :prototype_authority_compiled)

    modules =
      try do
        Application.put_env(:sdr_agent, :prototype_authority_compiled, false)
        Code.compile_string(source, "owner_intake_production_twin.ex")
      after
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, :prototype_authority_compiled, value)
          :error -> Application.delete_env(:sdr_agent, :prototype_authority_compiled)
        end
      end

    assert [{@twin, binary}] = modules
    %{binary: binary}
  end

  test "all three ordinary API entries are refusal stubs" do
    assert Function.capture(@twin, :__info__, 1).(:functions) ==
             [commit: 3, preview: 2, valid_write_scope?: 2]

    for actor <- [nil, %{}, %{id: "forged", tenant_id: "forged", role: :admin}] do
      assert Function.capture(@twin, :preview, 2).(%{}, actor) == {:error, :forbidden}
      assert Function.capture(@twin, :commit, 3).(%{}, %{}, actor) == {:error, :forbidden}
      refute Function.capture(@twin, :valid_write_scope?, 2).(actor, %{})
    end
  end

  test "ordinary intake beam has no persistence or prototype-authority references", ctx do
    assert {:ok, {@twin, [imports: imports, atoms: atoms]}} =
             :beam_lib.chunks(ctx.binary, [:imports, :atoms])

    names =
      Enum.map(imports, fn {module, _, _} -> Atom.to_string(module) end) ++
        Enum.map(atoms, fn {_, atom} -> Atom.to_string(atom) end)

    for module <- [SdrAgent.Repo, SdrAgent.Audit.Kernel, SdrAgent.Audit.Guard, SdrAgent.Prototype] do
      refute Atom.to_string(module) in names,
             "ordinary intake references #{inspect(module)}"
    end

    refute Enum.any?(names, &String.starts_with?(&1, "Elixir.SdrAgent.Prototype.Authority"))
  end
end
