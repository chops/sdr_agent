defmodule SdrAgent.Prototype.BootCheckProductionBranchTest do
  @moduledoc """
  Codex 422c47dc must-fix R1: in the build without the prototype authority
  (the production build), `SdrAgent.Prototype.BootCheck` refuses every
  switch other than `:off` with `:switch_outside_dev`. It does so before it
  looks at the switch's shape or reads the binding table, at `check/1`,
  `verify!/1`, `verify!/0` and the child. `:off` keeps the ordinary row and
  the binding refusal.

  The subject is a twin compiled in this VM from the exact bytes of
  `lib/sdr_agent/prototype/boot_check.ex`. Only the module name is
  rewritten, and `:prototype_authority_compiled` and `:prototype_test_seams`
  are false for that one compile. This is branch coverage of the source, not
  the production artifact: the `:external` prod-artifact proof is still owed
  separately.
  """
  use SdrAgent.PrototypeCase, async: false

  @source "lib/sdr_agent/prototype/boot_check.ex"
  @subject "SdrAgent.Prototype.BootCheck"
  @twin SdrAgent.Prototype.BootCheckProductionTwin
  @refusal SdrAgent.Prototype.BootCheckProductionTwin.RefusalError
  @flags [:prototype_authority_compiled, :prototype_test_seams]

  setup_all do
    compile_twin!()
    :ok
  end

  # Compiles the twin with both prototype flags false, then restores them.
  # Construction checks: every subject name is rewritten, the compile emits
  # no diagnostic, it defines exactly the twin and its refusal, and the twin
  # names no authority module.
  defp compile_twin! do
    source = File.read!(@source)
    twin_source = String.replace(source, @subject, inspect(@twin))

    assert twin_source =~ "defmodule #{inspect(@twin)} do"
    assert twin_source =~ "defmodule #{inspect(@refusal)} do"
    refute twin_source =~ ~r/SdrAgent\.Prototype\.BootCheck(?!ProductionTwin)/

    previous = Map.new(@flags, &{&1, Application.fetch_env(:sdr_agent, &1)})

    {modules, diagnostics} =
      try do
        Enum.each(@flags, &Application.put_env(:sdr_agent, &1, false))

        Code.with_diagnostics(fn ->
          Code.compile_string(twin_source, "boot_check_production_twin.ex")
        end)
      after
        Enum.each(previous, fn
          {flag, {:ok, value}} -> Application.put_env(:sdr_agent, flag, value)
          {flag, :error} -> Application.delete_env(:sdr_agent, flag)
        end)
      end

    assert diagnostics == [], "the twin compile emitted #{inspect(diagnostics)}"
    assert Enum.sort(Enum.map(modules, &elem(&1, 0))) == Enum.sort([@twin, @refusal])

    {@twin, binary} = List.keyfind(modules, @twin, 0)
    {:ok, {@twin, [atoms: atoms]}} = :beam_lib.chunks(binary, [:atoms])

    authority =
      for {_index, atom} <- atoms,
          String.starts_with?(Atom.to_string(atom), "Elixir.SdrAgent.Prototype.Authority"),
          do: atom

    assert authority == [], "the twin names #{inspect(authority)}"
  end

  defp unbound_switch,
    do: %{policy_id: "d237-prototype/1", instance_id: Ecto.UUID.generate()}

  defp malformed_switches do
    [
      :on,
      "on",
      nil,
      %{},
      %{policy_id: "d237-prototype/1"},
      %{policy_id: "d237-prototype/2", instance_id: Ecto.UUID.generate()},
      %{policy_id: "d237-prototype/1", instance_id: "not-a-uuid"},
      Map.put(unbound_switch(), :extra, true)
    ]
  end

  # The twin is compiled at run time, so it is called through captures (no
  # undefined-module compile warning).
  defp check(switch), do: Function.capture(@twin, :check, 1).(switch)
  defp verify!(opts), do: Function.capture(@twin, :verify!, 1).(opts)
  defp verify!, do: Function.capture(@twin, :verify!, 0).()
  defp start_link(arg), do: Function.capture(@twin, :start_link, 1).(arg)

  @doc false
  def handle_query(_event, _measurements, metadata, pid),
    do: send(pid, {:binding_query, metadata[:source]})

  # The sources of the Repo queries `fun` issues in this process.
  defp query_sources(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:sdr_agent, :repo, :query], &__MODULE__.handle_query/4, self())

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(sources) do
    receive do
      {:binding_query, source} -> drain([source | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  describe "check/1, any switch other than :off" do
    test "a malformed switch is :switch_outside_dev, never :switch_invalid" do
      for switch <- malformed_switches() do
        result = check(switch)

        assert result == {:error, :switch_outside_dev},
               "#{inspect(switch)} gave #{inspect(result)}"
      end
    end

    test "a well-shaped switch with no binding is :switch_outside_dev, never :binding_absent" do
      assert check(unbound_switch()) == {:error, :switch_outside_dev}
    end

    test "no switch other than :off reads the binding table; :off does (control)" do
      {result, sources} = query_sources(fn -> check(:off) end)
      assert result == {:ok, :ordinary}

      assert "prototype_database_bindings" in sources,
             "prerequisite: the :off read was not observed, sources #{inspect(sources)}"

      for switch <- [unbound_switch() | malformed_switches()] do
        {result, sources} = query_sources(fn -> check(switch) end)

        assert sources == [],
               "#{inspect(switch)} issued Repo queries with sources #{inspect(sources)}"

        assert result == {:error, :switch_outside_dev},
               "#{inspect(switch)} gave #{inspect(result)}"
      end
    end

    test "a well-shaped switch with one binding row is :switch_outside_dev (control)" do
      fx = bound!(enter_runtime: false)
      switch = PrototypeFixtures.switch(fx)
      assert match?(%{policy_id: _, instance_id: _}, switch), "switch/1: #{inspect(switch)}"
      assert check(switch) == {:error, :switch_outside_dev}
    end
  end

  describe "check/1, :off (control: unchanged)" do
    test "no binding is ordinary; one binding is :binding_without_switch" do
      assert check(:off) == {:ok, :ordinary}
      bound!(enter_runtime: false)
      assert check(:off) == {:error, :binding_without_switch}
    end
  end

  describe "verify! and the child" do
    test "verify!/1 raises :switch_outside_dev for a malformed and for an unbound switch" do
      for switch <- [%{policy_id: "d237-prototype/1"}, unbound_switch()] do
        error = assert_raise @refusal, fn -> verify!(switch: switch) end
        assert error.code == :switch_outside_dev, "#{inspect(switch)} raised #{error.code}"
      end
    end

    test "verify!/0 on a configured malformed switch raises :switch_outside_dev" do
      previous = Application.fetch_env(:sdr_agent, SdrAgent.Prototype)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, SdrAgent.Prototype, value)
          :error -> Application.delete_env(:sdr_agent, SdrAgent.Prototype)
        end
      end)

      Application.put_env(:sdr_agent, SdrAgent.Prototype,
        switch: %{policy_id: "d237-prototype/1"}
      )

      error = assert_raise @refusal, fn -> verify!() end
      assert error.code == :switch_outside_dev
    end

    test "the child returns {:error, :switch_outside_dev} for an unbound switch, :ignore for :off" do
      assert start_link(switch: unbound_switch()) == {:error, :switch_outside_dev}
      assert start_link(switch: :off) == :ignore
    end
  end
end
