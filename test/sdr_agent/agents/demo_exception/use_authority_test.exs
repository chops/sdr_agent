defmodule SdrAgent.Agents.DemoException.UseAuthorityTest do
  @moduledoc """
  C2* S3 RED-3, present use authority (plan r2 §4.2 S3-a contract, §8 row
  `use_authority_test.exs`; ADR-0005 C2* amendment item 2 "Use authority";
  Codex binding correction 1: these DB-backed tests belong to the
  post-migration pair; S4 Ruling 2 (76afb32e): a real `live_binding?/2`
  performs a database identity read, so the double here is the
  read-performing synthetic adapter of `SdrAgent.DemoExceptionFixtures` and
  every read is reported).

  `DemoException.use_authority(release, invocation, now)` returns `:ok` or
  the first `{:error, code}` in this order: `:not_demo_exception`,
  `:invocation_mismatch`, `:exception_off`, `:entry_changed`,
  `:environment_unattested`, `:binding_drift`, `:expired`,
  `:grant_revoked`, `:mismatch`, `:critical_cause`. Its only reads are
  plain: the binding read (through `Source.live_binding?/2`), the funding
  grant by id, the invocation's links and its `reconciliation_required`
  Failures, all in the release's tenant. It takes no lock clause, writes
  nothing, and gives the same answer inside `Audit.transaction/1` after
  `Kernel.lock_head/1`. With no active registration only `attestation/0` is
  consulted and nothing is read.

  Classification (RED-3 at 2578a6f5): every test is structural. Each first
  asserts that `use_authority/3` is exported (a function-presence guard; it
  is GREEN-3's), and the demo-row tests also need a demo-exception release,
  which only GREEN-3's finalizer can decide.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations

  @module DemoException
  @writes ~r/\A\s*(INSERT|UPDATE|DELETE)\b/i

  setup do
    assert_exported!()
    %{env: Fx.demo_env!()}
  end

  describe "a release that is not a demo exception" do
    test "a withheld release is :not_demo_exception", %{env: env} do
      parts = Fx.constructed!(env)
      Application.delete_env(:sdr_agent, SdrAgent.Agents.DemoException)

      result = ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})
      assert {:withheld, release, _run} = result

      assert use_authority(release, parts.invocation, env.now) ==
               {:error, :not_demo_exception}
    end
  end

  describe "a demo-exception release" do
    setup %{env: env} do
      %{demo: Fx.demo_invocation!(env)}
    end

    test ":ok with exactly the four plain reads, no lock, no write", %{env: env, demo: demo} do
      Fx.reset_calls!(env)
      {result, sql} = GateFixtures.capture(fn -> use_authority(demo, env.now) end)
      assert result == :ok
      assert_plain!(sql)

      # S4 Ruling 2: binding, funding grant, links, Failures (provisional
      # bound; any further read is reported, never dropped or cached).
      assert Enum.map(sql, &read_kind/1) |> Enum.sort() ==
               Enum.sort([:binding, :grant, :links, :failures]),
             inspect(sql)

      assert Enum.any?(Fx.calls(env), &match?({:live_binding?, _pid}, &1))
    end

    test "the same answer inside Audit.transaction after Kernel.lock_head", %{
      env: env,
      demo: demo
    } do
      {:ok, {result, sql}} =
        Audit.transaction(fn ->
          {:ok, _head} = Kernel.lock_head(env.tenant.id)
          GateFixtures.capture(fn -> use_authority(demo, env.now) end)
        end)

      assert result == :ok
      assert_plain!(sql)
    end

    test "another invocation is :invocation_mismatch", %{env: env, demo: demo} do
      other = Fx.constructed!(env).invocation

      assert use_authority(demo.release, other, env.now) == {:error, :invocation_mismatch}
    end

    test "the selector off is :exception_off", %{env: env, demo: demo} do
      Application.delete_env(:sdr_agent, SdrAgent.Agents.DemoException)
      assert use_authority(demo, env.now) == {:error, :exception_off}
    end

    test "a changed entry digest is :entry_changed", %{env: env, demo: demo} do
      Fx.put_source!(:authorization_id, "test-only-authorization-2")
      refute DemoException.entry_sha256() == env.entry_sha256
      assert use_authority(demo, env.now) == {:error, :entry_changed}
    end

    test "no active registration is :environment_unattested; only attestation/0, no read",
         %{env: env, demo: demo} do
      Fx.put_source!(:attestation, :none)
      Fx.reset_calls!(env)
      {result, sql} = GateFixtures.capture(fn -> use_authority(demo, env.now) end)
      assert result == {:error, :environment_unattested}
      assert sql == []
      assert Fx.calls(env) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [:attestation]
    end

    test "a provisioning-level attestation is :environment_unattested", %{env: env, demo: demo} do
      Fx.put_source!(:attestation, {:ok, %{env.attestation | level: :provisioning}})
      Fx.put_source!(:live_binding?, true)
      assert use_authority(demo, env.now) == {:error, :environment_unattested}
    end

    for {label, drift} <- [
          {"a changed environment binding digest", :binding_sha256},
          {"another tenant", :tenant},
          {"another authorization id", :authorization_id},
          {"another authorization entry digest", :entry_sha256},
          {"the live database binding (lease nonce or oid)", :live_binding}
        ] do
      @tag drift: drift
      test "#{label} is :binding_drift", %{env: env, demo: demo} = ctx do
        drift!(env, ctx.drift)
        assert use_authority(demo, env.now) == {:error, :binding_drift}
      end
    end

    test "at exception_expires_at it is :expired; one microsecond before, :ok", %{demo: demo} do
      expires = demo.release.exception_expires_at
      assert use_authority(demo, DateTime.add(expires, -1, :microsecond)) == :ok
      assert use_authority(demo, expires) == {:error, :expired}
    end

    test "a revoked funding grant is :grant_revoked", %{env: env, demo: demo} do
      {:ok, _} =
        Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: human(:admin, env.tenant))

      assert use_authority(demo, env.now) == {:error, :grant_revoked}
    end

    test "a later mismatch link of the invocation is :mismatch", %{env: env, demo: demo} do
      rec = system_actor(:reconciler, env.tenant)
      AgentsFixtures.reconciled_link!(demo.invocation, rec, %{link_status: :mismatch})
      assert use_authority(demo, env.now) == {:error, :mismatch}
    end

    test "a critical cause, live or resolved, is :critical_cause", %{env: env, demo: demo} do
      critical = GateFixtures.cause!(demo.invocation, severity: :critical)
      assert use_authority(demo, env.now) == {:error, :critical_cause}

      {:ok, _} =
        Operations.resolve_failure(critical, %{resolution_note: "seen"},
          actor: human(:admin, env.tenant)
        )

      assert use_authority(demo, env.now) == {:error, :critical_cause}
    end

    test "the first error in the listed order wins", %{env: env, demo: demo} do
      GateFixtures.cause!(demo.invocation, severity: :critical)

      {:ok, _} =
        Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: human(:admin, env.tenant))

      after_end = DateTime.add(demo.release.exception_expires_at, 1, :second)
      assert use_authority(demo, after_end) == {:error, :expired}
      assert use_authority(demo, env.now) == {:error, :grant_revoked}

      Fx.put_source!(:attestation, :none)
      assert use_authority(demo, after_end) == {:error, :environment_unattested}

      Application.delete_env(:sdr_agent, SdrAgent.Agents.DemoException)
      assert use_authority(demo, after_end) == {:error, :exception_off}
    end
  end

  ## Harness

  defp assert_exported! do
    Code.ensure_loaded!(@module)

    assert function_exported?(@module, :use_authority, 3),
           "SdrAgent.Agents.DemoException.use_authority/3 is not exported"
  end

  defp use_authority(demo, now), do: use_authority(demo.release, demo.invocation, now)

  defp use_authority(release, invocation, now),
    do: call(@module, :use_authority, [release, invocation, now])

  defp call(module, function, args), do: apply(module, function, args)

  defp assert_plain!(sql) do
    assert Enum.filter(sql, &GateFixtures.lock?/1) == [], inspect(sql)
    assert Enum.filter(sql, &(&1 =~ @writes)) == [], inspect(sql)
  end

  defp read_kind(statement) do
    cond do
      statement =~ Fx.binding_marker() -> :binding
      statement =~ ~s("model_call_grants") -> :grant
      statement =~ ~s("wire_witness_links") -> :links
      statement =~ ~s("failures") -> :failures
      true -> {:other, statement}
    end
  end

  defp drift!(_env, :live_binding), do: Fx.put_source!(:live_binding?, false)

  defp drift!(env, drift) do
    att = env.attestation

    changed =
      case drift do
        :binding_sha256 -> %{att | environment_binding_sha256: Fx.hex("another environment")}
        :tenant -> %{att | tenant_id: Ecto.UUID.generate()}
        :authorization_id -> %{att | authorization: %{att.authorization | id: "other-auth"}}
        :entry_sha256 -> %{att | authorization: %{att.authorization | entry_sha256: Fx.hex("e")}}
      end

    # Only the attestation drifts: the live binding read itself still holds.
    Fx.put_source!(:attestation, {:ok, changed})
    Fx.put_source!(:live_binding?, true)
  end
end
