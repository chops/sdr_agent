defmodule SdrAgent.AdmissionFixtures do
  @moduledoc """
  R0-07 slice B test configuration (packet rows B2, B3, B5): a real
  (generation-2 ClaudeCLI) call is admitted only when the result gate is
  active, the witness store root is trusted and the call's exact runtime
  identity is on the shipped allowlist. The test environment ships an empty
  allowlist and no store root, so every such call is refused by default.

  `admit_tuples!/1` configures exactly that: exact six-key entries into the
  runtime `reconciled_methods` and a fresh trusted store root. It changes
  configuration, never a call's inputs, so there is no ordinary-call
  admission seam. Every caller is `async: false`; the previous
  configuration is restored on exit, after the test's supervised servers
  and processes have stopped (ExUnit stops them before `on_exit` callbacks
  run) and after the test's Oban jobs are drained by the test itself.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Test.WitnessRoot

  @witness SdrAgent.Agents.Witness
  @gate_seam SdrAgent.Agents.Admission.Gate

  @doc """
  The exact six-key entry for the reviewed real profile `profile_id` and
  `projection` (default: the v1 projection of the synthetic release links,
  `AgentsFixtures.release_projection/0`).
  """
  def entry(profile_id \\ :claude_cli_opus, projection \\ Projection.version()) do
    {:ok, profile} = ModelProfiles.fetch_real(profile_id)

    %{
      provider: :claude_cli,
      cli_version: profile.cli_version,
      profile_id: profile.id,
      model_id: profile.resolved_model,
      projection_version: projection,
      method: :propagated_id
    }
  end

  @doc """
  Admits real calls in this test: `entries:` (default: `entry/2` for both
  real profiles) become the runtime allowlist and `root:` (default: a fresh
  trusted root) the store root. Returns `%{entries:, root:}`.
  """
  def admit_tuples!(opts \\ []) do
    entries =
      Keyword.get_lazy(opts, :entries, fn -> Enum.map(ModelProfiles.real_ids(), &entry/1) end)

    root = Keyword.get_lazy(opts, :root, &fresh_root!/0)
    previous = Application.get_env(:sdr_agent, @witness, [])

    Application.put_env(
      :sdr_agent,
      @witness,
      previous |> Keyword.put(:reconciled_methods, entries) |> Keyword.put(:store_root, root)
    )

    on_exit(fn -> Application.put_env(:sdr_agent, @witness, previous) end)
    %{entries: entries, root: root}
  end

  @doc """
  Runs `fun` with real calls admitted only for its duration: the default
  `entry/2`s are added to the current allowlist (kept otherwise) and, when
  no store root is configured, a fresh trusted root is set; the exact
  previous configuration is restored when `fun` returns or raises. For
  fixtures whose tests reconcile against their own allowlist: the added
  entries never reach a reconciliation that runs after `fun`. `fun` must
  not leave background work that reserves or launches after it returns.
  """
  def admitting(fun) when is_function(fun, 0) do
    previous = Application.get_env(:sdr_agent, @witness, [])
    current = Keyword.get(previous, :reconciled_methods, [])
    added = Enum.reject(Enum.map(ModelProfiles.real_ids(), &entry/1), &(&1 in current))

    {root, cleanup} =
      case Keyword.get(previous, :store_root) do
        nil ->
          root = WitnessRoot.mkdir!("admitting-#{System.os_time()}-#{:rand.uniform(1_000_000)}")
          {root, fn -> File.rm_rf(root) end}

        root ->
          {root, fn -> :ok end}
      end

    Application.put_env(
      :sdr_agent,
      @witness,
      previous
      |> Keyword.put(:reconciled_methods, current ++ added)
      |> Keyword.put(:store_root, root)
    )

    try do
      fun.()
    after
      Application.put_env(:sdr_agent, @witness, previous)
      cleanup.()
    end
  end

  # Unique across test runs (leftover roots of an earlier run stay on disk
  # until removed here).
  defp fresh_root! do
    root = WitnessRoot.mkdir!("admit-#{System.os_time()}-#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  @doc "Replaces the runtime allowlist with `entries` (the store root is kept)."
  def put_entries!(entries), do: put_witness!(:reconciled_methods, entries)

  @doc "Replaces the configured store root with `root` (nil unsets it)."
  def put_root!(root), do: put_witness!(:store_root, root)

  defp put_witness!(key, value) do
    config = Application.get_env(:sdr_agent, @witness, [])
    Application.put_env(:sdr_agent, @witness, Keyword.put(config, key, value))
  end

  @doc """
  The test-seam calibration admission marker (R0-07 slice B, row B4) for
  `profile_id` (default Opus) under its `entry/2`: the `calibration:`
  option a `:proof` run's reservation needs.
  """
  def calibration(profile_id \\ :claude_cli_opus),
    do: SdrAgent.Agents.Checks.CalibrationAdmission.context(profile_id, entry(profile_id))

  @doc """
  The refuse-only result-gate seam (row B3; test-seam builds only): makes
  the gate inactive for this test. Nothing can make an inactive gate active.
  """
  def gate_inactive! do
    Application.put_env(:sdr_agent, @gate_seam, force_inactive: true)
    on_exit(fn -> Application.delete_env(:sdr_agent, @gate_seam) end)
    :ok
  end
end
