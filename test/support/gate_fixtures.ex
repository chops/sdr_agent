defmodule SdrAgent.GateFixtures do
  @moduledoc """
  R0-07 slice C fixtures: a completed generation-2 ClaudeCLI invocation made
  through the facade with the hermetic fake CLI playing shim and stand-in
  proxy store (`test/support/fake_claude_cli.exs`, mode `witness`), and a
  capture of the SQL a process sends (lock-order regressions). No real
  model call is made.
  """

  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI

  @fake Path.expand("fake_claude_cli.exs", __DIR__)
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @locks ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/

  @doc """
  Calls the fake CLI through `ModelProvider.complete/2` for `run` as
  `agent`, writing the exchange of `variant` (`"cli_shape_v3"` matches,
  `"cli_shape_v3_mismatch"` mismatches, `"none"` writes no exchange) under
  `root`; returns the completed invocation.
  """
  def call_model!(%{run: run, agent: agent, root: root}, variant) do
    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        test_launcher: true,
        command_args: [@fake, "witness", root, variant]
      )

    id = "gate-#{variant}-#{System.unique_integer([:positive])}"

    audit =
      id
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    # R0-07 slice B: reservation and launch are admitted only for the call
    # itself (`SdrAgent.AdmissionFixtures.admitting/1`); the test's own
    # allowlist governs the gate's reconciliation afterwards.
    {:ok, result} =
      SdrAgent.AdmissionFixtures.admitting(fn ->
        ModelProvider.complete(
          %{
            id: id,
            run: run,
            actor: agent,
            operation: "model.complete",
            prompt: "Qualify the fixture lead #{variant} (#{id})",
            schema: @schema,
            audit: audit
          },
          provider: ClaudeCLI,
          provider_options: [server: server]
        )
      end)

    GenServer.stop(server)
    result.invocation
  end

  @doc "A fresh, trusted stand-in witness store root (removed on test exit by the caller)."
  def root! do
    root = SdrAgent.Test.WitnessRoot.mkdir!("gate")
    File.mkdir_p!(root)
    root
  end

  @doc "Runs `fun`; returns `{result, sql}` — every statement this process sent."
  def capture(fun) do
    handler = "gate-sql-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if self() == me, do: send(me, {:gate_sql, meta.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(acc) do
    receive do
      {:gate_sql, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Whether `sql` carries a row-lock clause."
  def lock?(sql), do: sql =~ @locks

  @doc "Whether `sql` locks `table` (quoted name) with `mode` (e.g. `\"FOR SHARE\"`)."
  def locks?(sql, table, mode), do: sql =~ ~s("#{table}") and sql =~ mode

  @doc "Index of the first statement satisfying `predicate`, or nil."
  def index(queries, predicate), do: Enum.find_index(queries, predicate)
end
