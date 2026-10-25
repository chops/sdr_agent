defmodule SdrAgent.SDR.SuppressionCheck do
  @moduledoc """
  The deterministic suppression lookup the agent runs before working or
  enrolling a lead (S2: "enrollment checks of suppression are done by the
  orchestrating Jido action, which records a Decision"; spec §8: the model
  never decides legal suppression).

  The configured implementation (`config :sdr_agent, :suppression_check,
  Module`) is `SdrAgent.SDR.SuppressionCheck.Store`, which reads the S8
  Outreach store. There is no default and no fallback (D-206): `impl/0`
  fails closed on a missing or invalid configuration, so the gate
  (`SdrAgent.SDR.Support.suppression_gate/4`) records no verdict and the
  assignment fails. The S7 placeholder `NoStore` is deleted; its atom is
  refused as invalid even when a module of that name is loaded. The S8 send
  gate checks suppression again before every send regardless.
  """

  @callback check(email :: String.t(), context :: map()) ::
              {:ok, :suppressed | :not_suppressed, map()} | {:error, term()}

  # The deleted S7 placeholder: refused before anything is loaded.
  @legacy SdrAgent.SDR.SuppressionCheck.NoStore
  @invalid {:error, {:suppression_check, :invalid}}

  @doc """
  The configured implementation: `{:ok, module}` for a loadable module that
  exports `check/2` and declares this behaviour. Otherwise one of two fixed
  tags, never the configured value: `{:error, {:suppression_check,
  :missing}}` when the key is absent, and `{:error, {:suppression_check,
  :invalid}}` for `nil`, a boolean, a non-atom, an unloadable atom, a module
  without `check/2` or without the behaviour, and the legacy `NoStore` atom
  (refused first, without loading anything). This checks the configuration's
  shape only, not the implementation's correctness.
  """
  @spec impl() :: {:ok, module()} | {:error, {:suppression_check, :missing | :invalid}}
  def impl do
    case Application.fetch_env(:sdr_agent, :suppression_check) do
      :error -> {:error, {:suppression_check, :missing}}
      {:ok, @legacy} -> @invalid
      {:ok, module} when is_atom(module) and module not in [nil, true, false] -> validate(module)
      {:ok, _other} -> @invalid
    end
  end

  defp validate(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :check, 2) and
         behaviour?(module),
       do: {:ok, module},
       else: @invalid
  end

  defp behaviour?(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(__MODULE__)
  end
end
