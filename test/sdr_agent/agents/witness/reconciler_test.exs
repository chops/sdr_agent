defmodule SdrAgent.Agents.Witness.ReconcilerTest do
  @moduledoc """
  S12c steps 6–7, hermetic functional fixture pipeline (NOT a transport or
  independence proof — the fake CLI writes protocol-shaped files itself; the
  real shim/proxy are covered by S12a and the mandatory S12d real proof): ModelProvider facade → ClaudeCLI
  (child env) → fake CLI playing shim + S12a proxy → stand-in witness store
  → reconciler (bounded reader, audited scoped payload read, projection) →
  WireWitnessLinks, attention Failures and `Agents.witness_status/2`.

  C1 invocation aggregate, C2 missing/incomplete/ambiguous attention without
  fabricated links, C3 mismatch attention, P2 no account id in SDR records,
  P7 count_tokens classification, idempotent replays, and R3. Dev and prod
  ship exactly one exact entry (S12d enablement). The test environment's
  allowlist is empty, so a perfect proof stays `inferred` there; `reconciled`
  appears only under an explicit, isolated test allowlist or the shipped
  entry.
  """
  use SdrAgent.AuditCase, async: false

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Operations
  alias SdrAgent.Telemetry.InMemoryExporter
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy
  alias SdrAgent.Test.WitnessRoot

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @fake Path.expand("../../../support/fake_claude_cli.exs", __DIR__)
  @test_only_allowlist [:propagated_id]

  setup do
    # Spans are global to the test VM: start from this test's own, so the
    # "no account id in telemetry" render below stays bounded as the suite
    # grows (S13d: the acceptance suites add many spans; an unbounded
    # inspect of every span timed out in CI).
    InMemoryExporter.reset()
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    root = WitnessRoot.mkdir!("e2e")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      root: root,
      rec: system_actor(:reconciler, tenant)
    }
  end

  # S12d enablement (proof 3, Codex evidence PASS c9a2bba3): dev/prod ship
  # exactly one exact entry; the test env stays empty (hermetic default).
  @shipped_entry %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }

  test "the runtime allowlist ships exactly the one exact v3 entry (R3)" do
    for env <- [:dev, :prod] do
      shipped =
        Config.Reader.read!("config/config.exs", env: env, target: :host)
        |> Keyword.fetch!(:sdr_agent)
        |> Keyword.fetch!(Witness)

      assert Keyword.fetch!(shipped, :reconciled_methods) == [@shipped_entry], inspect(env)
    end

    config = Application.get_env(:sdr_agent, Witness, [])
    assert Keyword.get(config, :reconciled_methods, []) == []
  end

  test "under the shipped entry only the exact v3 tuple reconciles; all else stays inferred",
       ctx do
    for {variant, expected, projection} <- [
          {"cli_shape_v3", :reconciled, "claude-message-json/3+prompt-builder/1"},
          {"cli_shape", :inferred, "claude-message-json/2+prompt-builder/1"},
          {"ok", :inferred, "claude-message-json/1+prompt-builder/1"}
        ] do
      invocation = call_model!(ctx, variant)
      result = reconcile(ctx, invocation, [@shipped_entry])
      assert match?({:ok, %{status: ^expected}}, result), "#{variant}: #{inspect(result)}"
      {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert link.evidence["projection_version"] == projection, variant

      if expected == :inferred,
        do: assert("method_not_enabled" in link.evidence["reason_codes"], variant)
    end

    # The same v3 proof under the entry with any other field stays inferred.
    for {label, entry} <- [
          {"other CLI version", %{@shipped_entry | cli_version: "2.1.292"}},
          {"other provider", %{@shipped_entry | provider: :fake}},
          {"v2 projection",
           %{@shipped_entry | projection_version: "claude-message-json/2+prompt-builder/1"}}
        ] do
      invocation = call_model!(ctx, "cli_shape_v3")
      result = reconcile(ctx, invocation, [entry])
      assert match?({:ok, %{status: :inferred}}, result), "#{label}: #{inspect(result)}"
    end
  end

  test "a perfect proof stays inferred at runtime; links carry digests, not content", ctx do
    invocation = call_model!(ctx, "ok")
    assert {:ok, summary} = reconcile(ctx, invocation)
    assert summary.status == :inferred

    assert {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
    assert link.link_status == :inferred
    assert link.method == :propagated_id
    assert link.evidence["classification"] == "primary"
    assert "method_not_enabled" in link.evidence["reason_codes"]
    assert link.evidence["app_request_sha256"] == hex(invocation.request_sha256)

    assert link.evidence["projected_request_sha256"] ==
             link.evidence["observed_request_projection_sha256"]

    assert link.proxy_request_sha256 != nil
    assert link.evidence["projection_version"] =~ "claude-message-json/1"

    assert {:ok, :inferred} = status(invocation, ctx.rec)
    assert attention(ctx) == []

    # P2: the raw request's account id never enters SDR records or telemetry.
    rendered =
      inspect([link, events(ctx.tenant), InMemoryExporter.spans()], limit: :infinity)

    refute rendered =~ Proxy.account_id()
    refute rendered =~ "Synthetic CLI system text"
  end

  test "under an isolated test allowlist the same proof is reconciled", ctx do
    invocation = call_model!(ctx, "ok")
    assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)

    assert {:ok, [%{link_status: :reconciled}]} =
             Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

    assert {:ok, :reconciled} = status(invocation, ctx.rec)
  end

  test "replays publish no duplicate link or Failure and never re-send the model", ctx do
    invocation = call_model!(ctx, "mismatch")
    assert {:ok, _} = reconcile(ctx, invocation)
    links = length(elem(Agents.list_wire_witness_links(invocation.id, actor: ctx.rec), 1))
    linked = length(events_of_type(ctx.tenant, "agents.witness.linked"))
    failures = length(attention(ctx))
    sent = length(events_of_type(ctx.tenant, "model.invocation.sent"))

    assert {:ok, _} = reconcile(ctx, invocation)
    assert {:ok, _} = reconcile(ctx, invocation)

    assert length(elem(Agents.list_wire_witness_links(invocation.id, actor: ctx.rec), 1)) == links
    assert length(events_of_type(ctx.tenant, "agents.witness.linked")) == linked
    assert length(attention(ctx)) == failures
    assert length(events_of_type(ctx.tenant, "model.invocation.sent")) == sent
  end

  test "a mismatch links, opens critical attention and is the invocation status (C3)", ctx do
    for variant <- ["mismatch", "prompt_changed", "tool_use"] do
      invocation = call_model!(ctx, variant)
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, @test_only_allowlist)

      assert {:ok, [%{link_status: :mismatch}]} =
               Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

      assert {:ok, :mismatch} = status(invocation, ctx.rec)
      assert [failure] = attention(ctx, invocation)
      assert {failure.class, failure.severity} == {:reconciliation_required, :critical}
    end
  end

  test "no witness record: no fabricated link, one warning, unwitnessed (C2)", ctx do
    invocation = call_model!(ctx, "none")

    for _ <- 1..2, do: assert({:ok, %{status: :unwitnessed}} = reconcile(ctx, invocation))

    assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    assert {:ok, :unwitnessed} = status(invocation, ctx.rec)
    assert [failure] = attention(ctx, invocation)
    assert {failure.class, failure.severity} == {:reconciliation_required, :warning}
    assert failure.message =~ "witness_missing"
  end

  test "ambiguous, open or unclassified extra traffic downgrades and warns (C1, P7)", ctx do
    for {variant, reason} <- [
          {"double", "multiple_primary_exchanges"},
          {"open", "exchange_open"},
          {"unknown_route", "unclassified_exchange"},
          {"count_tokens_content", "unclassified_exchange"},
          {"no_stop", "response_stream_incomplete"}
        ] do
      invocation = call_model!(ctx, variant)
      assert {:ok, summary} = reconcile(ctx, invocation, @test_only_allowlist)
      assert summary.status == :inferred, variant
      assert {:ok, :inferred} = status(invocation, ctx.rec)
      assert [failure] = attention(ctx, invocation), variant
      assert failure.severity == :warning
      assert failure.message =~ reason, "#{variant}: #{failure.message}"
    end
  end

  test "a content-free count_tokens extra is ancillary and keeps a reconciled primary", ctx do
    invocation = call_model!(ctx, "count_tokens")
    assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)
    assert {:ok, links} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

    assert Enum.sort(Enum.map(links, & &1.evidence["classification"])) ==
             ["ancillary", "primary"]

    assert {:ok, :reconciled} = status(invocation, ctx.rec)
    assert attention(ctx, invocation) == []
  end

  test "an unconfigured store does nothing and opens no attention", ctx do
    invocation = call_model!(ctx, "ok")

    assert {:ok, %{status: :skipped}} =
             Witness.reconcile(invocation.id, actor: ctx.rec, store_root: nil)

    assert attention(ctx) == []
  end

  test "only REC reconciles; the chain stays valid", ctx do
    invocation = call_model!(ctx, "ok")

    for actor <- [ctx.agent, human(:admin, ctx.tenant), human(:auditor, ctx.tenant)] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Witness.reconcile(invocation.id, actor: actor, store_root: ctx.root)
    end

    assert {:ok, _} = reconcile(ctx, invocation)
    assert {:ok, report} = SdrAgent.Audit.verify_chain(actor: human(:admin, ctx.tenant))
    assert report.valid?, inspect(report.issues)
  end

  describe "conservative outcomes (no unsupported proof becomes reconciled)" do
    test "ancillary-only, incomplete, gzip, unknown proxy or schema stay below reconciled",
         ctx do
      for {variant, reason, linked?} <- [
            {"count_tokens_only", "no_primary_exchange", true},
            {"incomplete", "capture_incomplete", true},
            {"gzip", "content_encoding_unsupported", true},
            {"proxy_version", "proxy_version_unsupported", true},
            {"schema2", "record_invalid", false}
          ] do
        invocation = call_model!(ctx, variant)
        assert {:ok, summary} = reconcile(ctx, invocation, @test_only_allowlist)
        assert summary.status in [:inferred, :unwitnessed], variant
        {:ok, links} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        refute Enum.any?(links, &(&1.link_status == :reconciled)), variant
        assert links != [] == linked?, variant
        assert {:ok, status} = status(invocation, ctx.rec)
        assert status in [:inferred, :unwitnessed], variant
        assert [failure] = attention(ctx, invocation), variant
        assert failure.severity == :warning
        assert failure.message =~ reason, "#{variant}: #{failure.message}"
      end
    end

    test "corrupt, missing or oversized raw blobs downgrade and warn", ctx do
      for {label, damage} <- [
            {"corrupt", fn path -> File.write!(path, "tampered") end},
            {"missing", &File.rm!/1},
            {"oversized", fn path -> File.write!(path, String.duplicate("x", max_blob() + 1)) end}
          ] do
        invocation = call_model!(ctx, "ok")
        [link_path] = response_blob_paths(ctx.root, invocation)
        damage.(link_path)

        result = reconcile(ctx, invocation, @test_only_allowlist)
        assert match?({:ok, %{status: :inferred}}, result), "#{label}: #{inspect(result)}"

        assert [failure] = attention(ctx, invocation), label
        assert failure.message =~ "blob_", "#{label}: #{failure.message}"
      end
    end
  end

  describe "false-assurance transitions (C1–C3)" do
    test "a later unclassified extra downgrades a reconciled invocation", ctx do
      invocation = call_model!(ctx, "ok")
      assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)

      Proxy.exchange!(ctx.root, invocation.id,
        route: "/anthropic/unknown",
        request: "{}",
        response: "{}"
      )

      assert {:ok, %{status: :inferred}} = reconcile(ctx, invocation, @test_only_allowlist)
      assert {:ok, :inferred} = status(invocation, ctx.rec)
      assert [%{severity: :warning}] = attention(ctx, invocation)
    end

    test "a later unreadable inventory supersedes a reconciled link, keeping history", ctx do
      invocation = call_model!(ctx, "ok")
      assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)
      dir = Path.join([ctx.root, "witnesses", invocation.id])
      File.write!(Path.join(dir, Proxy.uuid7() <> ".json"), "not json")

      assert {:ok, %{status: :inferred}} = reconcile(ctx, invocation, @test_only_allowlist)
      assert {:ok, :inferred} = status(invocation, ctx.rec)
      assert {:ok, all} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
      assert Enum.map(all, & &1.link_status) == [:reconciled, :inferred]
      assert [current] = elem(Agents.current_wire_witness_links(invocation.id, actor: ctx.rec), 1)
      assert "record_invalid" in current.evidence["reason_codes"]
    end

    test "a same-version mismatch stays a mismatch even if a later observation matches", ctx do
      invocation = call_model!(ctx, "mismatch")
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, @test_only_allowlist)

      # Rewrite the record so its response now carries the application output.
      [record_path] = terminal_record_paths(ctx.root, invocation)
      record = record_path |> File.read!() |> JSON.decode!()
      good = Proxy.blob!(ctx.root, Proxy.sse_response(~s({"answer":"qualified","score":42})))
      File.write!(record_path, JSON.encode!(%{record | "response_sha256" => good}))

      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, @test_only_allowlist)
      assert {:ok, :mismatch} = status(invocation, ctx.rec)
      assert {:ok, [_]} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    end

    test "no weaker or unsupported observation erases a mismatch (C3)", ctx do
      damages = [
        {"missing blob",
         fn record, _path -> File.rm!(blob_path(ctx.root, record["response_sha256"])) end},
        {"incomplete capture",
         fn record, path ->
           File.write!(path, JSON.encode!(%{record | "response_capture_complete" => false}))
         end},
        {"unknown proxy version",
         fn record, path ->
           File.write!(path, JSON.encode!(%{record | "proxy_version" => "9.9.9"}))
         end},
        {"now ambiguous",
         fn _record, _path ->
           :ok
         end},
        {"corrupt blob",
         fn record, _path -> File.write!(blob_path(ctx.root, record["response_sha256"]), "x") end}
      ]

      for {label, damage} <- damages do
        invocation = call_model!(ctx, "mismatch")
        assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, @test_only_allowlist)
        [path] = terminal_record_paths(ctx.root, invocation)
        record = path |> File.read!() |> JSON.decode!()
        damage.(record, path)

        if label == "now ambiguous",
          do: Proxy.exchange!(ctx.root, invocation.id, request: "{}", response: "{}")

        result = reconcile(ctx, invocation, @test_only_allowlist)
        assert match?({:ok, %{status: :mismatch}}, result), "#{label}: #{inspect(result)}"
        assert {:ok, :mismatch} = status(invocation, ctx.rec)
        {:ok, links} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        assert Enum.any?(links, &(&1.link_status == :mismatch)), label
      end
    end

    test "all records gone after reconciled downgrades to inferred, history kept", ctx do
      invocation = call_model!(ctx, "ok")
      assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation, @test_only_allowlist)
      File.rm_rf!(Path.join([ctx.root, "witnesses", invocation.id]))

      assert {:ok, %{status: :inferred}} = reconcile(ctx, invocation, @test_only_allowlist)
      assert {:ok, :inferred} = status(invocation, ctx.rec)
      assert {:ok, [_, _]} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    end

    test "an older observation cannot overwrite a newer store state", ctx do
      invocation = call_model!(ctx, "none")

      hook = fn ->
        Proxy.exchange!(ctx.root, invocation.id, request: "{}", response: "{}")
      end

      assert {:error, :stale_observation} =
               Witness.reconcile(invocation.id,
                 actor: ctx.rec,
                 store_root: ctx.root,
                 after_observe: hook
               )

      assert attention(ctx, invocation) == []
      assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    end

    test "missing then mismatching: the warning is resolved, one critical stays live", ctx do
      invocation = call_model!(ctx, "none")
      assert {:ok, %{status: :unwitnessed}} = reconcile(ctx, invocation)
      assert [%{severity: :warning}] = attention(ctx, invocation)

      Proxy.exchange!(ctx.root, invocation.id,
        request: Proxy.messages_request("not the rendered prompt"),
        response: Proxy.sse_response(~s({"answer":"qualified","score":42}))
      )

      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation)
      assert [%{severity: :critical}] = attention(ctx, invocation)
    end
  end

  test "runtime allowlist entries must match provider, attested CLI and projection exactly",
       ctx do
    previous = Application.get_env(:sdr_agent, Witness, [])
    on_exit(fn -> Application.put_env(:sdr_agent, Witness, previous) end)

    exact = %{
      provider: :claude_cli,
      cli_version: ClaudeCLI.provenance().provider_version,
      projection_version: Witness.Projection.version(),
      method: :propagated_id
    }

    for {label, entries, expected} <- [
          {"exact", [exact], :reconciled},
          {"other CLI", [%{exact | cli_version: "0.0.1"}], :inferred},
          {"other projection", [%{exact | projection_version: "claude-message-json/9"}],
           :inferred},
          {"bare atom in config", [:propagated_id], :inferred}
        ] do
      Application.put_env(
        :sdr_agent,
        Witness,
        Keyword.put(previous, :reconciled_methods, entries)
      )

      invocation = call_model!(ctx, "ok")
      assert {:ok, %{status: ^expected}} = reconcile(ctx, invocation), label
    end
  end

  describe "projection v2 (S12d)" do
    @v2 "claude-message-json/2+prompt-builder/1"

    test "the real CLI request shape reconciles only under an exact v2 entry", ctx do
      v2 = %{
        provider: :claude_cli,
        cli_version: ClaudeCLI.provenance().provider_version,
        projection_version: @v2,
        method: :propagated_id
      }

      v1 = %{v2 | projection_version: Witness.Projection.version()}

      for {label, entries, expected} <- [
            {"v1 entry", [v1], :inferred},
            {"v2 entry", [v2], :reconciled}
          ] do
        invocation = call_model!(ctx, "cli_shape")
        assert {:ok, %{status: ^expected}} = reconcile(ctx, invocation, entries), label
        {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        assert link.evidence["projection_version"] == @v2, label
        assert "cli_injected_context" in link.evidence["reason_codes"], label
        assert link.evidence["reminder_count"] == 1, label
        assert link.evidence["trailing_system_count"] == 1, label
        assert link.evidence["request_extras_sha256"] =~ ~r/\A[0-9a-f]{64}\z/, label
        refute inspect(link.evidence) =~ Proxy.account_id()
      end
    end

    test "a zero-context v2 proof keeps the complete eight-key group", ctx do
      invocation = call_model!(ctx, "cli_shape_zero")
      assert {:ok, _} = reconcile(ctx, invocation, @test_only_allowlist)
      {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

      for key <- ~w(reminder_count reminder_sha256s reminder_bytes trailing_system_count
                    trailing_system_sha256s trailing_system_bytes request_extras_sha256
                    request_fields) do
        assert Map.has_key?(link.evidence, key), key
      end

      assert {link.evidence["reminder_count"], link.evidence["trailing_system_count"]} == {0, 0}
    end

    test "an invalid derived evidence group downgrades and never clears a mismatch", ctx do
      tamper = fn group -> Map.put(group, "reminder_count", 9) end
      invocation = call_model!(ctx, "cli_shape")

      result =
        Witness.reconcile(invocation.id,
          actor: ctx.rec,
          store_root: ctx.root,
          methods: @test_only_allowlist,
          evidence_tamper: tamper
        )

      assert match?({:ok, %{status: :inferred}}, result), inspect(result)
      {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert link.link_status == :inferred
      assert "evidence_contract_invalid" in link.evidence["reason_codes"]
      refute Map.has_key?(link.evidence, "reminder_count")
      assert [failure] = attention(ctx, invocation)
      assert failure.message =~ "evidence_contract_invalid"

      # An earlier (v1) mismatch is not cleared by an invalid v2 observation.
      mismatched = call_model!(ctx, "mismatch")
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, mismatched, @test_only_allowlist)
      [path] = terminal_record_paths(ctx.root, mismatched)
      record = path |> File.read!() |> JSON.decode!()

      stdin =
        blob_path(ctx.root, record["request_sha256"])
        |> File.read!()
        |> JSON.decode!()
        |> get_in(["messages", Access.at(0), "content", Access.at(0), "text"])

      request = Proxy.blob!(ctx.root, Proxy.cli_request(stdin))
      response = Proxy.blob!(ctx.root, Proxy.sse_response(~s({"answer":"qualified","score":42})))

      rewritten =
        Map.merge(record, %{
          "request_sha256" => request,
          "response_sha256" => response,
          "request_capture_sha256" => request,
          "response_capture_sha256" => response
        })

      File.write!(path, JSON.encode!(rewritten))

      result =
        Witness.reconcile(mismatched.id,
          actor: ctx.rec,
          store_root: ctx.root,
          methods: @test_only_allowlist,
          evidence_tamper: tamper
        )

      assert match?({:ok, %{status: :mismatch}}, result), inspect(result)
      assert {:ok, :mismatch} = status(mismatched, ctx.rec)
    end

    test "a different sole stdin in the CLI shape is a mismatch with critical attention", ctx do
      invocation = call_model!(ctx, "cli_shape_mismatch")
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, @test_only_allowlist)
      assert [%{severity: :critical}] = attention(ctx, invocation)
    end
  end

  test "outside tests the method allowlist cannot be overridden per call", ctx do
    invocation = call_model!(ctx, "ok")
    previous = Application.get_env(:sdr_agent, Witness, [])

    Application.put_env(
      :sdr_agent,
      Witness,
      Keyword.put(previous, :allow_method_override, false)
    )

    try do
      assert {:error, :method_override_forbidden} =
               reconcile(ctx, invocation, @test_only_allowlist)

      # The test-only evidence seam is refused the same way.
      assert {:error, :method_override_forbidden} =
               Witness.reconcile(invocation.id,
                 actor: ctx.rec,
                 store_root: ctx.root,
                 evidence_tamper: & &1
               )
    after
      Application.put_env(:sdr_agent, Witness, previous)
    end

    assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
  end

  test "links, link events and attention commit together or not at all", ctx do
    invocation = call_model!(ctx, "mismatch")

    SQL.query!(Repo, """
    CREATE FUNCTION s12c_refuse_failure() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'failure store unavailable'; END; $$
    """)

    SQL.query!(
      Repo,
      "CREATE TRIGGER s12c_refuse_failure BEFORE INSERT ON failures " <>
        "FOR EACH ROW EXECUTE FUNCTION s12c_refuse_failure()"
    )

    assert {:error, _failure_store_error} = reconcile(ctx, invocation)
    assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    assert events_of_type(ctx.tenant, "agents.witness.linked") == []
  end

  describe "deterministic schema generation (JsonSchema.render/1)" do
    test "the stored app request schema is the rendered schema and equals the sent stdin",
         ctx do
      module = SdrAgent.AI.JsonSchema
      Code.ensure_loaded(module)
      assert function_exported?(module, :render, 1), "JsonSchema.render/1 is not implemented"

      invocation = call_model!(ctx, "cli_shape")
      {:ok, %{request: request}} = Agents.read_reconciliation_payloads(invocation, actor: ctx.rec)
      stored = request |> JSON.decode!() |> Map.fetch!("schema")

      assert Canonical.encode!(stored) == Canonical.encode!(module.render(@schema))

      # Sent stdin equals the re-rendering of the stored schema.
      assert {:ok, _} = reconcile(ctx, invocation, [:propagated_id])
      {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)

      assert link.evidence["projected_request_sha256"] ==
               link.evidence["observed_request_projection_sha256"]
    end
  end

  describe "projection v3 (S12d, hermetic)" do
    @v3 "claude-message-json/3+prompt-builder/1"
    @v2_label "claude-message-json/2+prompt-builder/1"

    test "the proof-shaped request reconciles only under an exact v3 entry", ctx do
      v3 = entry(@v3)

      for {label, entries, expected} <- [
            {"v1 entry", [entry(Witness.Projection.version())], :inferred},
            {"v2 entry", [entry(@v2_label)], :inferred},
            {"v3 entry, other CLI version", [%{v3 | cli_version: "0.0.0"}], :inferred},
            {"v3 entry", [v3], :reconciled}
          ] do
        invocation = call_model!(ctx, "cli_shape_v3")
        result = reconcile(ctx, invocation, entries)
        assert match?({:ok, %{status: ^expected}}, result), "#{label}: #{inspect(result)}"
        {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        assert link.evidence["projection_version"] == @v3, label
        assert link.evidence["projections_inapplicable"] == ["v2"], label
        assert link.evidence["trailing_output_config"] == ["present"], label
        assert link.evidence["reminder_count"] == 1, label
        assert "cli_injected_context" in link.evidence["reason_codes"], label
        refute inspect(link.evidence) =~ Proxy.account_id()
      end
    end

    test "the test env allowlist is empty: a perfect v3 proof stays inferred", ctx do
      invocation = call_model!(ctx, "cli_shape_v3")
      result = reconcile(ctx, invocation)
      assert match?({:ok, %{status: :inferred}}, result), inspect(result)
      {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert link.evidence["projection_version"] == @v3
      assert "method_not_enabled" in link.evidence["reason_codes"]
    end

    test "a v2-admitted request stays labelled v2, even with an unsupported response", ctx do
      for {variant, expected} <- [{"cli_shape", :reconciled}, {"cli_shape_thinking", :inferred}] do
        invocation = call_model!(ctx, variant)
        result = reconcile(ctx, invocation, [entry(@v2_label), entry(@v3)])
        assert match?({:ok, %{status: ^expected}}, result), "#{variant}: #{inspect(result)}"
        {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        assert link.evidence["projection_version"] == @v2_label, variant
        assert link.evidence["projections_inapplicable"] == [], variant

        for key <- WitnessEvidence.context_group(),
            do: assert(Map.has_key?(link.evidence, key), "#{variant}: #{key}")

        refute Map.has_key?(link.evidence, "trailing_output_config"), variant
      end
    end

    test "a request outside v2 and v3 falls back to v1, labelled [v2, v3]", ctx do
      invocation = call_model!(ctx, "ok")
      assert {:ok, %{status: :inferred}} = reconcile(ctx, invocation, [entry(@v3)])
      {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert link.evidence["projection_version"] == Witness.Projection.version()
      assert link.evidence["projections_inapplicable"] == ["v2", "v3"]
      refute Map.has_key?(link.evidence, "reminder_count")
    end

    test "an inexact derived v3 group is evidence_contract_invalid", ctx do
      for {label, tamper} <- [
            {"v3 key missing", &Map.delete(&1, "trailing_output_config")},
            {"diagnostic injected", &Map.put(&1, "projections_inapplicable", [])},
            {"legacy key injected", &Map.put(&1, "outcome", "complete")},
            {"cardinality broken", &Map.put(&1, "trailing_output_config", [])}
          ] do
        invocation = call_model!(ctx, "cli_shape_v3")

        result =
          Witness.reconcile(invocation.id,
            actor: ctx.rec,
            store_root: ctx.root,
            methods: [entry(@v3)],
            evidence_tamper: tamper
          )

        assert match?({:ok, %{status: :inferred}}, result), "#{label}: #{inspect(result)}"
        {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
        assert "evidence_contract_invalid" in link.evidence["reason_codes"], label
        refute link.evidence["projection_version"] == @v3, label
      end
    end

    test "a v3 mismatch survives later invalid or unsupported observations", ctx do
      invocation = call_model!(ctx, "cli_shape_v3_mismatch")
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation, [entry(@v3)])
      [path] = terminal_record_paths(ctx.root, invocation)
      record = path |> File.read!() |> JSON.decode!()

      stdin =
        blob_path(ctx.root, record["request_sha256"])
        |> File.read!()
        |> JSON.decode!()
        |> get_in(["messages", Access.at(0), "content", Access.at(0), "text"])
        |> String.replace_suffix(" (edited)", "")

      v3_opts = [
        cache_ttl: "1h",
        trailing_message_extra: %{"output_config" => %{"effort" => "x"}}
      ]

      for {label, request, opts} <- [
            {"invalid v3 group", Proxy.cli_request(stdin, v3_opts),
             [evidence_tamper: &Map.delete(&1, "trailing_output_config")]},
            {"outside v2 and v3",
             Proxy.cli_request(stdin, Keyword.put(v3_opts, :cache_ttl, "5m")), []}
          ] do
        request = Proxy.blob!(ctx.root, request)

        response =
          Proxy.blob!(ctx.root, Proxy.sse_response(~s({"answer":"qualified","score":42})))

        rewritten =
          Map.merge(record, %{
            "request_sha256" => request,
            "response_sha256" => response,
            "request_capture_sha256" => request,
            "response_capture_sha256" => response
          })

        File.write!(path, JSON.encode!(rewritten))

        result =
          Witness.reconcile(
            invocation.id,
            [actor: ctx.rec, store_root: ctx.root, methods: [entry(@v3)]] ++ opts
          )

        assert match?({:ok, %{status: :mismatch}}, result), "#{label}: #{inspect(result)}"
        assert {:ok, :mismatch} = status(invocation, ctx.rec)
      end
    end

    defp entry(projection) do
      %{
        provider: :claude_cli,
        cli_version: ClaudeCLI.provenance().provider_version,
        projection_version: projection,
        method: :propagated_id
      }
    end
  end

  describe "enablement runtime mode (shipped entry, overrides off)" do
    setup do
      previous = Application.get_env(:sdr_agent, Witness)

      Application.put_env(:sdr_agent, Witness,
        store_root: nil,
        reconciled_methods: [@shipped_entry],
        allow_method_override: false
      )

      on_exit(fn -> Application.put_env(:sdr_agent, Witness, previous) end)
    end

    test "only the exact v3 tuple reconciles; per-call overrides are refused", ctx do
      for {variant, expected} <- [
            {"cli_shape_v3", :reconciled},
            {"cli_shape", :inferred},
            {"ok", :inferred}
          ] do
        invocation = call_model!(ctx, variant)
        result = reconcile(ctx, invocation)
        assert match?({:ok, %{status: ^expected}}, result), "#{variant}: #{inspect(result)}"
      end

      invocation = call_model!(ctx, "cli_shape_v3")

      for methods <- [[:propagated_id], [@shipped_entry]] do
        assert {:error, :method_override_forbidden} = reconcile(ctx, invocation, methods)
      end
    end

    test "a reconciled proof is downgraded when its configured root becomes untrusted or missing",
         ctx do
      invocation = call_model!(ctx, "cli_shape_v3")
      assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation)

      link = ctx.root <> "-link"
      File.ln_s!(ctx.root, link)
      on_exit(fn -> File.rm(link) end)

      File.chmod!(ctx.root, 0o777)
      result = reconcile(ctx, invocation)
      File.chmod!(ctx.root, 0o700)
      assert match?({:ok, %{status: :inferred}}, result), "untrusted: #{inspect(result)}"
      {:ok, [head]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert "store_root_untrusted" in head.evidence["reason_codes"]
      assert [warning] = attention(ctx, invocation)
      assert warning.message =~ "store_root_untrusted"

      # A trusted root re-evaluates normally.
      assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation)

      # A symlinked override is untrusted too.
      result = Witness.reconcile(invocation.id, actor: ctx.rec, store_root: link)
      assert match?({:ok, %{status: :inferred}}, result), "symlink: #{inspect(result)}"

      assert {:ok, %{status: :reconciled}} = reconcile(ctx, invocation)
      moved = ctx.root <> "-moved"
      File.rename!(ctx.root, moved)
      result = reconcile(ctx, invocation)
      File.rename!(moved, ctx.root)
      assert match?({:ok, %{status: :inferred}}, result), "missing: #{inspect(result)}"
      {:ok, [head]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert "store_root_missing" in head.evidence["reason_codes"]
    end

    test "a mismatch stays a mismatch when its root becomes untrusted or missing", ctx do
      invocation = call_model!(ctx, "cli_shape_v3_mismatch")
      assert {:ok, %{status: :mismatch}} = reconcile(ctx, invocation)

      File.chmod!(ctx.root, 0o777)
      result = reconcile(ctx, invocation)
      File.chmod!(ctx.root, 0o700)
      assert match?({:ok, %{status: :mismatch}}, result), inspect(result)

      moved = ctx.root <> "-moved"
      File.rename!(ctx.root, moved)
      result = reconcile(ctx, invocation)
      File.rename!(moved, ctx.root)
      assert match?({:ok, %{status: :mismatch}}, result), inspect(result)
      assert {:ok, :mismatch} = status(invocation, ctx.rec)
    end

    test "the configured root (no per-call override) is revalidated and downgrades", ctx do
      Application.put_env(
        :sdr_agent,
        Witness,
        Keyword.put(Application.get_env(:sdr_agent, Witness), :store_root, ctx.root)
      )

      invocation = call_model!(ctx, "cli_shape_v3")
      assert {:ok, %{status: :reconciled}} = Witness.reconcile(invocation.id, actor: ctx.rec)

      File.chmod!(ctx.root, 0o777)
      result = Witness.reconcile(invocation.id, actor: ctx.rec)
      File.chmod!(ctx.root, 0o700)
      assert match?({:ok, %{status: :inferred}}, result), inspect(result)
      {:ok, [head]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      assert "store_root_untrusted" in head.evidence["reason_codes"]
    end

    test "genuinely unset stays skipped", ctx do
      invocation = call_model!(ctx, "cli_shape_v3")
      assert {:ok, %{status: :skipped}} = Witness.reconcile(invocation.id, actor: ctx.rec)
    end
  end

  ## Helpers

  defp max_blob, do: Witness.Store.max_blob_bytes()

  defp blob_path(root, digest),
    do: Path.join([root, "witness", "sha256", binary_part(digest, 0, 2), digest <> ".json"])

  defp terminal_record_paths(root, invocation) do
    Path.join([root, "witnesses", invocation.id, "*.json"])
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".started.json"))
  end

  defp response_blob_paths(root, invocation) do
    for path <- terminal_record_paths(root, invocation) do
      digest = path |> File.read!() |> JSON.decode!() |> Map.fetch!("response_sha256")
      Path.join([root, "witness", "sha256", binary_part(digest, 0, 2), digest <> ".json"])
    end
  end

  defp call_model!(ctx, variant) do
    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        command_args: [@fake, "witness", ctx.root, variant]
      )

    id = "witness-#{variant}-#{System.unique_integer([:positive])}"
    attrs = AgentsFixtures.model_attrs(id)

    audit =
      Map.take(attrs, [
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    {:ok, result} =
      ModelProvider.complete(
        %{
          id: id,
          run: ctx.run,
          actor: ctx.agent,
          operation: "model.complete",
          prompt: "Qualify the fixture lead #{variant} (#{id})",
          schema: @schema,
          audit: audit
        },
        provider: ClaudeCLI,
        provider_options: [server: server]
      )

    GenServer.stop(server)
    result.invocation
  end

  defp reconcile(ctx, invocation, methods \\ nil) do
    opts = [actor: ctx.rec, store_root: ctx.root]
    opts = if methods, do: Keyword.put(opts, :methods, methods), else: opts
    Witness.reconcile(invocation.id, opts)
  end

  defp status(invocation, actor), do: Agents.witness_status(invocation.id, actor: actor)

  defp attention(ctx, invocation \\ nil) do
    {:ok, failures} = Operations.list_attention(actor: human(:admin, ctx.tenant))

    Enum.filter(failures, fn failure ->
      failure.class == :reconciliation_required and
        (is_nil(invocation) or failure.subject_id == invocation.id)
    end)
  end
end
