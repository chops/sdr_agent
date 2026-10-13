defmodule SdrAgent.Agents.ModelResultReleaseRaceTest do
  @moduledoc """
  R0-07 concurrent decide under real concurrency (`sandbox: false`, as the
  S3 concurrency suite): AGT processes race to decide the release of one
  invocation, each in its own connection and transaction. Identical
  decisions all return the one committed row with a single event; a
  conflicting decision racing an identical one never writes a second row.
  Committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  @racers 8

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    previous = AgentsFixtures.put_allowlist!()

    on_exit(fn ->
      Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous)
      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)
    invocation = AgentsFixtures.claude_completed!(run, agent, "release-race")
    link = AgentsFixtures.reconciled_link!(invocation, rec)
    %{tenant: tenant, agent: agent, invocation: invocation, link: link}
  end

  test "concurrent identical decides: one row, one event, every caller gets it", ctx do
    attrs = %{
      model_invocation_id: ctx.invocation.id,
      disposition: :released,
      reason: :reconciled,
      wire_witness_link_id: ctx.link.id
    }

    results = race(fn _ -> Agents.decide_result_release(attrs, actor: ctx.agent) end)

    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

    assert results |> Enum.map(fn {:ok, release} -> release.id end) |> Enum.uniq() |> length() ==
             1

    assert_one_release(ctx, "model.result.released")
  end

  test "concurrent conflicting decides: exactly one disposition commits", ctx do
    results =
      race(fn n ->
        attrs =
          if rem(n, 2) == 0,
            do: %{
              model_invocation_id: ctx.invocation.id,
              disposition: :released,
              reason: :reconciled,
              wire_witness_link_id: ctx.link.id
            },
            else: %{
              model_invocation_id: ctx.invocation.id,
              disposition: :withheld,
              reason: :witness_timeout
            }

        Agents.decide_result_release(attrs, actor: ctx.agent)
      end)

    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))
    assert oks != [] and errors != [], inspect(results)
    assert oks |> Enum.map(fn {:ok, r} -> r.disposition end) |> Enum.uniq() |> length() == 1
    assert Enum.all?(errors, &match?({:error, %Ash.Error.Invalid{}}, &1)), inspect(errors)

    aud = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
    {:ok, [release]} = Agents.list_result_releases(actor: aud)
    assert length(oks) == length(Enum.filter(results, &same?(&1, release)))
    {:ok, report} = Audit.verify_chain(actor: aud)
    assert report.valid?, inspect(report.issues)
  end

  defp same?({:ok, release}, stored), do: release.id == stored.id
  defp same?(_result, _stored), do: false

  defp race(fun) do
    1..@racers
    |> Enum.map(fn n -> Task.async(fn -> racer(fun, n) end) end)
    |> Task.await_many(60_000)
  end

  defp racer(fun, n), do: with_connection(fn -> fun.(n) end)

  defp assert_one_release(ctx, event_type) do
    aud = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
    {:ok, releases} = Agents.list_result_releases(actor: aud)
    assert length(releases) == 1
    {:ok, events} = Audit.list_events(actor: aud)
    assert Enum.count(events, &(&1.event_type == event_type)) == 1
    {:ok, report} = Audit.verify_chain(actor: aud)
    assert report.valid?, inspect(report.issues)
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(SdrAgent.Repo)
    end
  end

  defp cleanup! do
    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])

      %{rows: rows} =
        SQL.query!(
          SdrAgent.Repo,
          "SELECT t FROM unnest($1::text[]) t WHERE to_regclass(t) IS NOT NULL",
          [@tables]
        )

      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(List.flatten(rows), ", ")} CASCADE", [])
    end)
  end
end
