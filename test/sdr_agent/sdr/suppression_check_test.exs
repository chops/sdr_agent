defmodule SdrAgent.SDR.SuppressionCheckTest do
  @moduledoc """
  Suppression safety fix, defect B (plan r3 §4, §6 B1–B8): the agent's
  suppression gate configuration fails closed. `SuppressionCheck.impl/0`
  returns `{:ok, module}` only for a configured, loadable module that
  exports `check/2` and declares the behaviour. An absent key is
  `{:error, {:suppression_check, :missing}}`; anything else — nil,
  non-modules, unloadable atoms, modules without `check/2` or without the
  behaviour, and the deleted legacy `NoStore` atom whether or not a module
  of that name is loaded (F3) — is `{:error, {:suppression_check,
  :invalid}}`. The error carries only the fixed tag, never the configured
  value. Every test restores the exact previous value or absence of the key.
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.SDR.SuppressionCheck

  @key :suppression_check
  @missing {:error, {:suppression_check, :missing}}
  @invalid {:error, {:suppression_check, :invalid}}
  @legacy SdrAgent.SDR.SuppressionCheck.NoStore

  defmodule BehaviourStub do
    @moduledoc false
    @behaviour SdrAgent.SDR.SuppressionCheck

    @impl true
    def check(_email, _context), do: {:ok, :not_suppressed, %{"store" => "stub"}}
  end

  defmodule BehaviourlessCheck do
    @moduledoc false
    def check(_email, _context), do: {:ok, :not_suppressed, %{"store" => "stub"}}
  end

  defmodule NoCheckFunction do
    @moduledoc false
    def unrelated, do: :ok
  end

  # Exact restoration (plan §6): the previous `fetch_env` value or absence
  # is captured and its restoration registered before the change.
  defp configure!(value), do: change_env!(&Application.put_env(:sdr_agent, &1, value))
  defp remove_key!, do: change_env!(&Application.delete_env(:sdr_agent, &1))

  defp change_env!(change) do
    previous = Application.fetch_env(:sdr_agent, @key)
    on_exit(fn -> restore_env(previous) end)
    change.(@key)
  end

  defp restore_env({:ok, value}), do: Application.put_env(:sdr_agent, @key, value)
  defp restore_env(:error), do: Application.delete_env(:sdr_agent, @key)

  defp behaviours(module) do
    module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  test "B1: an absent key is {:error, {:suppression_check, :missing}}" do
    remove_key!()
    assert Application.fetch_env(:sdr_agent, @key) == :error

    assert SuppressionCheck.impl() == @missing
  end

  test "B2: nil is {:error, {:suppression_check, :invalid}}" do
    configure!(nil)
    assert Application.fetch_env(:sdr_agent, @key) == {:ok, nil}

    assert SuppressionCheck.impl() == @invalid
  end

  test "B3: booleans, a binary, an integer, a tuple, a list and a map are invalid; the error holds no configured value" do
    for value <- [
          true,
          false,
          "SdrAgent.SDR.SuppressionCheck.Store",
          42,
          {:ok, SuppressionCheck.Store},
          [SuppressionCheck.Store],
          %{module: SuppressionCheck.Store}
        ] do
      configure!(value)
      assert SuppressionCheck.impl() == @invalid, "configured #{inspect(value)}"
    end
  end

  test "B4: an unloadable atom is invalid" do
    unloadable =
      :"Elixir.SdrAgent.SDR.SuppressionCheck.Unloadable#{System.unique_integer([:positive])}"

    refute Code.ensure_loaded?(unloadable)
    configure!(unloadable)

    assert SuppressionCheck.impl() == @invalid
  end

  test "B5: a loaded module without check/2 is invalid" do
    assert Code.ensure_loaded?(NoCheckFunction)
    refute function_exported?(NoCheckFunction, :check, 2)
    configure!(NoCheckFunction)

    assert SuppressionCheck.impl() == @invalid
  end

  test "B6: a module exporting check/2 without declaring the behaviour is invalid" do
    assert Code.ensure_loaded?(BehaviourlessCheck)
    assert function_exported?(BehaviourlessCheck, :check, 2)
    refute SuppressionCheck in behaviours(BehaviourlessCheck)
    configure!(BehaviourlessCheck)

    assert SuppressionCheck.impl() == @invalid
  end

  test "B7(i): the legacy NoStore atom is invalid, and the exclusion loads nothing (fresh VM)" do
    configure!(@legacy)
    loaded_before? = :erlang.module_loaded(@legacy)

    assert SuppressionCheck.impl() == @invalid

    refute :erlang.module_loaded(@legacy) and not loaded_before?,
           "the legacy exclusion loaded #{inspect(@legacy)}"
  end

  test "B7(ii): the legacy NoStore atom is invalid even when a module of that name is loaded (F3)" do
    configure!(@legacy)
    origin = ensure_legacy_loaded!(@legacy)
    assert Code.ensure_loaded?(@legacy), "the loaded-legacy case needs #{inspect(@legacy)} loaded"
    assert function_exported?(@legacy, :check, 2), inspect(origin)
    assert SuppressionCheck in behaviours(@legacy), inspect(origin)

    assert SuppressionCheck.impl() == @invalid
  end

  test "B8: Store and a behaviour-declaring stub are {:ok, module}" do
    configure!(SuppressionCheck.Store)
    assert SuppressionCheck.impl() == {:ok, SuppressionCheck.Store}

    configure!(BehaviourStub)
    assert SuppressionCheck.impl() == {:ok, BehaviourStub}
  end

  # F3 (plan §5; Codex r3 ruling): a VM that still has the legacy module
  # loaded. Genuine legacy code that is already loadable (the pre-fix
  # build) is exercised as it is — never overwritten, purged or deleted.
  # Only when no such code exists is a synthetic behaviour-declaring module
  # of that name created here, in this test VM only, with its disposal
  # registered before it is created.
  defp ensure_legacy_loaded!(module) do
    if Code.ensure_loaded?(module) do
      :genuine
    else
      on_exit(fn -> dispose_synthetic!(module) end)

      {:module, ^module, _binary, _result} =
        Module.create(module, synthetic_legacy_body(), Macro.Env.location(__ENV__))

      :synthetic
    end
  end

  defp synthetic_legacy_body do
    quote do
      @moduledoc false
      @behaviour SdrAgent.SDR.SuppressionCheck

      @impl true
      def check(_email, _context), do: {:ok, :not_suppressed, %{"store" => "none"}}
    end
  end

  # Checked, non-forcing disposal of the synthetic module this test created:
  # purge any old code, retire the current code, purge it. A step that
  # cannot complete (a process lingering in the code) is reported, never
  # forced; the module is then left for the owner to inspect.
  defp dispose_synthetic!(module) do
    purged_old? = :code.soft_purge(module)
    retired? = purged_old? and :code.delete(module)
    purged_current? = retired? and :code.soft_purge(module)

    unless purged_old? and retired? and purged_current? do
      raise "F3 cleanup of #{inspect(module)} did not complete " <>
              "(soft_purge: #{purged_old?}, delete: #{retired?}, soft_purge: #{purged_current?}); " <>
              "not forced"
    end

    :ok
  end
end
