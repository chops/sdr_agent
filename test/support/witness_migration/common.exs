# Shared by the projection v4 lineage migration campaign's child scripts
# (`SdrAgent.WitnessMigration.Harness`). Each script runs in its own fresh
# BEAM under `MIX_ENV=test`, against the one disposable database the parent
# campaign claimed.
defmodule SdrAgent.WitnessMigration do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo
  alias SdrAgent.WitnessMigration.Harness

  @v1 "claude-message-json/1+prompt-builder/1"
  @v2 "claude-message-json/2+prompt-builder/1"
  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"
  @statuses ~w(inferred reconciled mismatch)

  # Refuses anything but the owned disposable database on the devenv port,
  # the test build and the Fake provider, before any connection is opened.
  def validate_target!(database) do
    config = Application.fetch_env!(:sdr_agent, Repo)
    true = Regex.match?(Harness.database_pattern(), database)
    ^database = config[:database]
    "localhost" = config[:hostname]
    5520 = config[:port]
    :test = Mix.env()
    SdrAgent.AI.ModelProvider.Fake = Application.fetch_env!(:sdr_agent, :model_provider)
    config
  end

  # The probe's real connection (the application is started by `mix run`).
  def connect!(database) do
    validate_target!(database)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Heads committed once, by the first ("predecessor") probe, through the
  # domain APIs; later probes read their ids back.
  def fixtures!(path, label) do
    cond do
      File.exists?(path) ->
        path |> File.read!() |> JSON.decode!()

      label == "predecessor" ->
        fixtures = create_fixtures!()
        File.write!(path, JSON.encode!(fixtures))
        fixtures

      true ->
        raise "fixtures missing for probe #{label}"
    end
  end

  defp create_fixtures! do
    tenant = AuditCase.bootstrap!()
    admin = AuditCase.human(:admin, tenant)
    AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    invocation = AgentsFixtures.claude_completed!(run, agent, "witness-migration")
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)

    %{
      "v1_mismatch" => head!(invocation, rec, @v1, :mismatch),
      "v2_mismatch" => head!(invocation, rec, @v2, :mismatch),
      "v3_mismatch" => head!(invocation, rec, @v3, :mismatch),
      "v3_inferred" => head!(invocation, rec, @v3, :inferred)
    }
  end

  defp head!(invocation, rec, version, status) do
    {:ok, link} =
      Agents.link_wire_witness(
        %{
          model_invocation_id: invocation.id,
          proxy_record_ref: Ash.UUIDv7.generate(),
          link_status: status,
          method: :propagated_id,
          evidence: evidence(invocation, version)
        },
        actor: rec
      )

    link.id
  end

  defp evidence(invocation, version) do
    group = %{
      "reminder_count" => 0,
      "reminder_sha256s" => [],
      "reminder_bytes" => [],
      "trailing_system_count" => 0,
      "trailing_system_sha256s" => [],
      "trailing_system_bytes" => [],
      "request_extras_sha256" => String.duplicate("c3", 32),
      "request_fields" => []
    }

    base =
      invocation
      |> WitnessEvidence.identity()
      |> Map.merge(%{
        "witness_schema" => 1,
        "classification" => "primary",
        "projection_version" => version,
        "reason_codes" => ["propagated_id_match"]
      })

    case version do
      @v1 -> base
      @v2 -> Map.merge(base, group)
      @v3 -> base |> Map.merge(group) |> Map.put("trailing_output_config", [])
    end
  end

  # Each check: one raw successor of a committed head (triggers on), always
  # rolled back. "permitted" or "refused:<postgres code>".
  def checks(fixtures) do
    v4_on_mismatch =
      for head <- ~w(v1_mismatch v2_mismatch v3_mismatch), status <- @statuses do
        {"v4_#{status}_on_#{head}", fixtures[head], status, @v4}
      end

    cases =
      v4_on_mismatch ++
        [
          # C3, unchanged: same projection refused, different permitted.
          {"v3_on_v3_mismatch", fixtures["v3_mismatch"], "reconciled", @v3},
          {"v2_on_v1_mismatch", fixtures["v1_mismatch"], "reconciled", @v2},
          # A v4 successor of a non-mismatch head is permitted.
          {"v4_on_v3_inferred", fixtures["v3_inferred"], "reconciled", @v4}
        ]

    Map.new(cases, fn {name, head_id, status, projection} ->
      {name, attempt(head_id, status, projection)}
    end)
  end

  defp attempt(head_id, status, projection) do
    sql = """
    INSERT INTO wire_witness_links
      (id, tenant_id, model_invocation_id, proxy_record_ref, proxy_request_sha256,
       proxy_response_sha256, link_status, method, evidence, supersedes_id,
       recorded_at, trace_id, span_id, inserted_at)
    SELECT $2, tenant_id, model_invocation_id, proxy_record_ref, proxy_request_sha256,
           proxy_response_sha256, $3, method,
           evidence || jsonb_build_object('projection_version', $4::text,
                                          'supersede_reason', 'migration_probe'),
           $1, recorded_at, trace_id, span_id, inserted_at
      FROM wire_witness_links WHERE id = $1
    """

    params = [
      Ecto.UUID.dump!(head_id),
      Ecto.UUID.dump!(Ash.UUIDv7.generate()),
      status,
      projection
    ]

    Repo.transaction(fn ->
      case SQL.query(Repo, sql, params) do
        {:ok, %{num_rows: 1}} -> Repo.rollback(:permitted)
        {:ok, other} -> Repo.rollback({:unexpected, other.num_rows})
        {:error, %Postgrex.Error{postgres: %{code: code}}} -> Repo.rollback({:refused, code})
      end
    end)
    |> case do
      {:error, :permitted} -> "permitted"
      {:error, {:refused, code}} -> "refused:#{code}"
      other -> "unexpected:#{inspect(other)}"
    end
  end
end
