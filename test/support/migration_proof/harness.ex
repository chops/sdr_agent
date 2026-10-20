defmodule SdrAgent.MigrationProof.Harness do
  @moduledoc """
  Lifecycle of the C3-02 additive migration proof
  (`SdrAgent.Sales.AdditiveMigrationProofTest`): the migration
  `20261020053346_c3_02_admission_additive` really dispatches
  `SdrAgent.Sales.AdmissionPrechecks.run!/1` and then
  `SdrAgent.Sales.CutoverFence.run!/1` before its index, column, table or
  row changes (after `CREATE FUNCTION sdr_canonical_domain(text)` in the
  same transaction), and an abort persists no DDL, schema or row change. It
  follows `SdrAgent.RestartProof.Harness`.

  `prove/1` claims resources, runs the children and cleans up:

    1. claims a temporary folder with `File.mkdir/1` (an existing folder is
       refused) and writes the plan there: fresh ids, tenants and synthetic
       `.test` values for the rows the phases write;
    2. claims the database by creating it in a child (`claim.exs`), which
       validates the resolved target (`sdr_agent_test_mp<hex>`, localhost,
       port 5520, the test build) first. An existing database is refused
       and never migrated or dropped;
    3. runs the phases of `step.exs`, each in a fresh BEAM without the
       application: `before` (migrate up to, excluding, the additive
       migration), `prechecks`, `fence` and `clean` (see the script);
    4. cleans up only what it claimed: it drops the database through
       `drop.exs`, which validates the target again, then removes the
       folder.

  **When cleanup is skipped:** if any child's end can't be confirmed (a
  timeout whose kill isn't confirmed), nothing is cleaned up. The result is
  an error naming what is left behind.

  **When the result is an error:** any failed step or failed cleanup makes
  the result `{:error, _}`, so it can't pass.

  **The runner is injectable**, with the outcomes of
  `SdrAgent.RestartProof.Harness`, so the lifecycle is tested without a
  real database; `port_runner/4` is that harness's bounded real runner.
  """

  alias SdrAgent.RestartProof.Harness, as: Bounded

  @database ~r/\Asdr_agent_test_mp[0-9a-f]{10}\z/
  @scripts Path.expand(".", __DIR__)
  @claim_refused 3
  @version 20_261_020_053_346
  @phases [:before, :prechecks, :fence, :clean]

  @doc "The names a claimed database may have."
  def database_pattern, do: @database

  @doc "The additive migration's version."
  def version, do: @version

  @doc "The `step.exs` phases, in order."
  def phases, do: @phases

  @doc "The real runner (`SdrAgent.RestartProof.Harness.port_runner/4`)."
  defdelegate port_runner(executable, suffix, root, deadline), to: Bounded

  @doc """
  Runs the proof. Options: `:suffix`, `:tmp_root`, `:runner`. Returns
  `{:ok, %{plan:, results:, outputs:}}` (results and child outputs by phase)
  or `{:error, _}`.
  """
  def prove(opts) do
    suffix = Keyword.fetch!(opts, :suffix)
    database = "sdr_agent_test" <> suffix
    runner = Keyword.fetch!(opts, :runner)
    tmp = Path.join(Keyword.fetch!(opts, :tmp_root), "sdr-migration-proof" <> suffix)

    with {:target, true} <- {:target, Regex.match?(@database, database)},
         {:tmp, :ok} <- {:tmp, File.mkdir(tmp)} do
      owned = %{tmp: tmp, database: nil}
      plan = plan(database)
      plan_path = Path.join(tmp, "plan.json")
      File.write!(plan_path, JSON.encode!(plan))
      {outcome, owned} = run_owned(database, tmp, plan, plan_path, runner, owned)
      finish(outcome, owned, database, runner)
    else
      {:target, false} -> {:error, {:invalid_target, database}}
      {:tmp, {:error, reason}} -> {:error, {:tmp_not_claimed, tmp, reason}}
    end
  end

  defp plan(database) do
    token = hex(5)

    %{
      "database" => database,
      "token_collision" => "mpcol" <> token,
      "token_fence" => "mpfence" <> token,
      "collision_tenant_id" => Ecto.UUID.generate(),
      "fence_tenant_id" => Ecto.UUID.generate(),
      "collision_www_id" => Ecto.UUID.generate(),
      "collision_plain_id" => Ecto.UUID.generate(),
      "fence_account_id" => Ecto.UUID.generate(),
      "contact_id" => Ecto.UUID.generate(),
      "lead_id" => Ecto.UUID.generate(),
      "suppression_id" => Ecto.UUID.generate(),
      "collision_www_domain" => "www.mpcol#{token}.test",
      "collision_plain_domain" => "mpcol#{token}.test",
      "fence_domain" => "mpfence#{token}.test",
      "email" => "proof.contact@mpfence#{token}.test"
    }
  end

  defp run_owned(database, tmp, plan, plan_path, runner, owned) do
    case runner.(:claim, script("claim.exs", [database])) do
      {:ok, _} ->
        owned = %{owned | database: database}
        {phases(database, tmp, plan, plan_path, runner), owned}

      {:exit, @claim_refused, out} ->
        {{:error, {:database_not_claimed, out}}, owned}

      other ->
        # The claim may or may not have created the database: not owned,
        # never dropped; an unconfirmed child also stops all cleanup.
        {{:error, {:claim_failed, other}}, Map.put(owned, :unconfirmed, unconfirmed?(other))}
    end
  end

  defp phases(database, tmp, plan, plan_path, runner) do
    initial = {:ok, %{plan: plan, results: %{}, outputs: %{}}}

    Enum.reduce_while(@phases, initial, fn phase, {:ok, acc} ->
      out = Path.join(tmp, "#{phase}.json")
      args = script("step.exs", [database, Atom.to_string(phase), plan_path, out])

      case run_phase(runner, phase, args, out) do
        {:ok, result, output} ->
          results = Map.put(acc.results, phase, result)
          outputs = Map.put(acc.outputs, phase, output)
          {:cont, {:ok, %{acc | results: results, outputs: outputs}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp run_phase(runner, phase, args, out) do
    case runner.(phase, args) do
      {:ok, output} ->
        with {:ok, result} <- read_json(out), do: {:ok, result, output}

      {:timeout, _, _} = timeout ->
        {:error, {:step_timeout, timeout}}

      other ->
        {:error, {phase, other}}
    end
  end

  defp finish(outcome, owned, database, runner) do
    if Map.get(owned, :unconfirmed, false) or unconfirmed?(outcome) do
      {:error, {:cleanup_skipped_unconfirmed_child, outcome, owned}}
    else
      case cleanup(owned, database, runner) do
        :ok -> outcome
        {:error, reason} -> {:error, {:cleanup_failed, reason, outcome}}
      end
    end
  end

  defp cleanup(owned, database, runner) do
    dropped =
      case owned.database do
        nil -> :ok
        ^database -> drop(database, runner)
      end

    with :ok <- dropped do
      case File.rm_rf(owned.tmp) do
        {:ok, _} -> :ok
        {:error, reason, path} -> {:error, {:tmp_not_removed, path, reason}}
      end
    end
  end

  defp drop(database, runner) do
    case runner.(:drop, script("drop.exs", [database])) do
      {:ok, _} -> :ok
      other -> {:error, {:drop, other}}
    end
  end

  defp unconfirmed?({:timeout, :unconfirmed, _}), do: true
  defp unconfirmed?({:error, {:step_timeout, {:timeout, :unconfirmed, _}}}), do: true
  defp unconfirmed?(_), do: false

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- JSON.decode(body) do
      {:ok, json}
    else
      error -> {:error, {:unreadable_result, path, error}}
    end
  end

  defp script(name, args),
    do: ["run", "--no-start", "--no-compile", "--no-deps-check", Path.join(@scripts, name) | args]

  defp hex(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)
end
