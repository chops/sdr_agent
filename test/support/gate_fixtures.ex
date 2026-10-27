defmodule SdrAgent.GateFixtures do
  @moduledoc """
  R0-07 slice C fixtures: a completed generation-2 ClaudeCLI invocation made
  through the facade with the hermetic fake CLI playing shim and stand-in
  proxy store (`test/support/fake_claude_cli.exs`, mode `witness`), and a
  capture of the SQL a process sends (lock-order regressions). No real
  model call is made.
  """

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations

  @fake Path.expand("fake_claude_cli.exs", __DIR__)
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @locks ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/

  @doc """
  Calls the fake CLI through `ModelProvider.complete/2` for `run` as
  `agent`, writing the exchange of `variant` (`"cli_shape_v3"` matches,
  `"cli_shape_v3_mismatch"` mismatches, `"none"` writes no exchange) under
  `root`; returns the completed invocation.

  Options (`call_model!/3`): `purpose:` replaces the reserved purpose
  (default `:qualification`); `clock_from: pid` makes the model server
  read that process's frozen clock (the test-seam `ClaudeCLI` option), so
  its launch admission sees the test's instant.
  """
  def call_model!(ctx, variant, opts \\ [])

  def call_model!(%{run: run, agent: agent, root: root}, variant, opts) do
    server_opts =
      [
        command: System.find_executable("elixir"),
        test_launcher: true,
        command_args: [@fake, "witness", root, variant]
      ] ++ Keyword.take(opts, [:clock_from])

    {:ok, server} = ClaudeCLI.start_link(server_opts)

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
      |> Map.merge(Map.new(Keyword.take(opts, [:purpose])))

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

  @doc """
  Opens, as REC, a `reconciliation_required` gate cause for `invocation`
  (`severity`, default `:warning`; `operation_id` when given).
  """
  def cause!(invocation, opts \\ []) do
    attrs = %{
      subject_resource: "SdrAgent.Agents.ModelInvocation",
      subject_id: invocation.id,
      class: :reconciliation_required,
      severity: Keyword.get(opts, :severity, :warning),
      message: "wire witness gate fixture #{System.unique_integer([:positive])}: needs review",
      retryable: false
    }

    attrs =
      case Keyword.get(opts, :operation_id) do
        nil -> attrs
        id -> Map.put(attrs, :operation_id, id)
      end

    rec = SdrAgent.Actor.system(:reconciler, invocation.tenant_id)
    {:ok, failure} = Operations.open_failure(attrs, actor: rec)
    failure
  end

  @doc """
  A finalizer stand-in's committed withheld release of `invocation` bound
  to `cause` (`reason`, default `:witness_missing`), decided as `agent`
  under Prelocked; no run stop.
  """
  def withhold!(invocation, agent, cause, reason \\ :witness_missing) do
    tenant_id = invocation.tenant_id

    {:ok, release} =
      Audit.transaction(fn ->
        {:ok, %{}} =
          ModelInvocation
          |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
          |> Ash.Query.filter(id == ^invocation.id)
          |> Ash.Query.lock("FOR SHARE")
          |> Ash.read_one()

        {:ok, _} = Kernel.lock_head(tenant_id)

        bindings = %{
          tenant_id: tenant_id,
          model_invocation_id: invocation.id,
          wire_witness_link_id: nil,
          receipt_id: cause.id
        }

        Prelocked.run(bindings, fn prelocked ->
          attrs = %{
            model_invocation_id: invocation.id,
            disposition: :withheld,
            reason: reason,
            gate_cause_id: cause.id,
            gate_classification: if(reason == :witness_mismatch, do: :mismatch, else: :inferred)
          }

          {:ok, release} = Agents.decide_result_release(attrs, actor: agent, prelocked: prelocked)
          release
        end)
      end)

    release
  end

  @doc """
  Records the gate's decision for `invocation` — a withheld release that
  binds no cause, decided as the agent runtime — so the scan may backfill
  it (row G3: an undecided generation-2 row is the gate's). Returns the
  invocation.
  """
  def decided!(invocation) do
    agent = SdrAgent.Actor.system(:agent_runtime, invocation.tenant_id)

    attrs = %{
      model_invocation_id: invocation.id,
      disposition: :withheld,
      reason: :witness_missing
    }

    {:ok, _release} = Agents.decide_result_release(attrs, actor: agent)
    invocation
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
