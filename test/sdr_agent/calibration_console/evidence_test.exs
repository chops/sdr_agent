defmodule SdrAgent.CalibrationConsole.EvidenceTest do
  @moduledoc """
  R0-07 slice E, rows R10-4 and R11-3 (harness round 13, entity PASS at
  094caa86): the calibration evidence file.

    * One file per invocation, `r0-calibration-<profile>-<invocation id>.json`,
      in an owner-only directory (0700, not a symlink), mode 0600, bytes in
      the closed schema `r0-calibration-evidence/1` under
      `sdr-canonical-json/1`.
    * Create-only: the first file published **is** the frozen observation.
      A later or concurrent publish never replaces it and never recomputes
      it; it validates the existing file and returns its exact bytes and
      hash.
    * Validation (no recomputation): a regular file, not a symlink, mode
      0600; the closed schema; the target's invocation, run, tenant and
      profile; the code-owned prompt and schema commitments; and every link
      it names exists, belongs to the invocation and has the evidence hash
      it recorded. A later successor link does not invalidate it. Anything
      else is `:calibration_evidence_conflict`.
    * The document carries no release or latch data, and no prompt,
      response, output or error text.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.Prompt

  @moduletag :tmp_dir

  @v3 "claude-message-json/3+prompt-builder/1"
  # A unique marker in the model's output: it must never reach the file or
  # a log line.
  @canary "canary-5d1f0c2e"
  @output %{"answer" => "blue #{@canary}", "confidence" => 0.9}

  setup %{tmp_dir: tmp} = tags do
    # A missing module fails as an assertion, never as a crash.
    assert Code.ensure_loaded?(Prompt), "SdrAgent.CalibrationConsole.Prompt is not defined"

    tenant = bootstrap!()

    AgentsFixtures.grant!(tenant, %{
      total_attempts: 6,
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 2},
        %{key: :proof, applies_to: [:proof], attempts: 4}
      ]
    })

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, usage_origin: :proof)
    rec = system_actor(:reconciler, tenant)
    invocation = proof!(run, agent, Map.get(tags, :call, :completed), Map.get(tags, :refs))

    link =
      AgentsFixtures.reconciled_link!(invocation, rec, evidence: v3_evidence())

    dir = Path.join(tmp, "evidence")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    # The call was reserved under the same literal v3 candidate the document
    # and link name (its original reservation event records it).
    assert [reserved] =
             tenant
             |> events_of_type("model.invocation.reserved")
             |> Enum.filter(&(&1.subject_id == invocation.id))

    assert reserved.payload["arguments"]["calibration_tuple"] ==
             Agents.Admission.Gate.tuple_record(candidate())

    # After every fixture has been built: a missing Evidence fails as an
    # assertion here, never as a crash.
    assert Code.ensure_loaded?(Evidence), "SdrAgent.CalibrationConsole.Evidence is not defined"

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: rec,
      invocation: invocation,
      link: link,
      dir: dir,
      document: document(invocation, run, [link], Map.get(tags, :call, :completed))
    }
  end

  describe "publish" do
    test "creates the deterministic file, 0600, with the canonical bytes", ctx do
      assert {:ok, %{path: path, sha256: sha, bytes: bytes}} = publish(ctx, ctx.document)

      assert Path.basename(path) ==
               "r0-calibration-claude_cli_opus-#{ctx.invocation.id}.json"

      assert Path.dirname(path) == ctx.dir
      assert File.read!(path) == bytes
      assert bytes == Canonical.encode!(ctx.document)
      assert sha == hex(:crypto.hash(:sha256, bytes))
      assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Path.wildcard(Path.join(ctx.dir, "*")) == [path]
    end

    test "a second publish with a different document returns the first file unchanged", ctx do
      {:ok, first} = publish(ctx, ctx.document)
      later = %{ctx.document | observed_at: DateTime.add(ctx.document.observed_at, 60)}

      assert {:ok, again} = publish(ctx, later)
      assert {again.path, again.sha256, again.bytes} == {first.path, first.sha256, first.bytes}
      assert File.read!(first.path) == first.bytes
      assert Path.wildcard(Path.join(ctx.dir, "*")) == [first.path]
    end

    test "concurrent publishers converge on one file", ctx do
      docs =
        for n <- 1..4,
            do: %{ctx.document | observed_at: DateTime.add(ctx.document.observed_at, n)}

      results =
        docs
        |> Enum.map(fn doc -> Task.async(fn -> publish(ctx, doc) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert [{:ok, %{sha256: sha}} | _] = results
      assert Enum.all?(results, &match?({:ok, %{sha256: ^sha}}, &1))
      assert [_one] = Path.wildcard(Path.join(ctx.dir, "*.json"))
      assert Path.wildcard(Path.join(ctx.dir, ".*")) |> Enum.reject(&dot?/1) == []
    end

    test "an unsafe directory is refused and nothing is written", ctx do
      File.chmod!(ctx.dir, 0o755)
      assert {:error, :evidence_dir_unsafe} = publish(ctx, ctx.document)
      assert Path.wildcard(Path.join(ctx.dir, "*")) == []

      link = ctx.dir <> "-link"
      File.chmod!(ctx.dir, 0o700)
      File.ln_s!(ctx.dir, link)
      assert {:error, :evidence_dir_unsafe} = Evidence.publish(link, ctx.document, opts(ctx))
    end

    test "a document outside the closed schema is refused before any file", ctx do
      for bad <- [
            Map.put(ctx.document, :response_text, "x"),
            Map.put(ctx.document, :release_id, Ash.UUIDv7.generate()),
            Map.delete(ctx.document, :outcome),
            %{ctx.document | schema: "r0-calibration-evidence/2"},
            %{ctx.document | outcome: "released"}
          ] do
        assert {:error, :evidence_schema} = publish(ctx, bad)
      end

      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
    end

    test "an existing file that fails validation is a conflict and is left alone", ctx do
      path = Path.join(ctx.dir, Evidence.file_name(:claude_cli_opus, ctx.invocation.id))
      File.write!(path, "not json")
      File.chmod!(path, 0o600)

      assert {:error, :calibration_evidence_conflict} = publish(ctx, ctx.document)
      assert File.read!(path) == "not json"
    end
  end

  describe "validate" do
    setup ctx do
      {:ok, published} = publish(ctx, ctx.document)
      %{published: published}
    end

    test "the published file is valid and its exact bytes and hash are returned", ctx do
      assert {:ok, %{sha256: sha, bytes: bytes}} = validate(ctx, ctx.published.path)
      assert {sha, bytes} == {ctx.published.sha256, ctx.published.bytes}
    end

    test "a later successor link does not invalidate the historical reference", ctx do
      {:ok, _successor} =
        ctx.invocation
        |> AgentsFixtures.link_attrs(
          proxy_record_ref: ctx.link.proxy_record_ref,
          supersedes_id: ctx.link.id,
          evidence: %{"supersede_reason" => "reconciliation_rerun"}
        )
        |> Agents.link_wire_witness(actor: ctx.rec)

      assert {:ok, %{sha256: sha}} = validate(ctx, ctx.published.path)
      assert sha == ctx.published.sha256
    end

    test "a symlink, a wrong mode or a missing file is a conflict", ctx do
      path = ctx.published.path
      link = path <> ".lnk"
      File.ln_s!(path, link)
      assert {:error, :calibration_evidence_conflict} = validate(ctx, link)

      File.chmod!(path, 0o644)
      assert {:error, :calibration_evidence_conflict} = validate(ctx, path)

      assert {:error, :calibration_evidence_conflict} = validate(ctx, path <> ".missing")
    end

    test "a file naming another target is a conflict", ctx do
      for {key, value} <- [
            invocation_id: Ash.UUIDv7.generate(),
            run_id: Ash.UUIDv7.generate(),
            tenant_id: Ash.UUIDv7.generate(),
            profile_id: "claude_cli_sonnet"
          ] do
        assert {:error, :calibration_evidence_conflict} =
                 rewrite_and_validate(ctx, &Map.put(&1, key, value)),
               inspect(key)
      end
    end

    test "a file with other prompt or schema commitments is a conflict", ctx do
      other = %{id: "calibration.prompt", version: "1", sha256: hex(:crypto.hash(:sha256, "x"))}

      assert {:error, :calibration_evidence_conflict} =
               rewrite_and_validate(ctx, &Map.put(&1, :prompt, other))

      assert {:error, :calibration_evidence_conflict} =
               rewrite_and_validate(ctx, &Map.put(&1, :output_schema, other))
    end

    test "a link that is unknown, foreign or with another evidence hash is a conflict", ctx do
      # Another invocation's link: a business call, since an unlatched proof
      # invocation is a B4' predecessor that blocks a second proof reservation.
      %{run: other_run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      other = AgentsFixtures.claude_completed!(other_run, agent, "other")
      foreign = AgentsFixtures.reconciled_link!(other, ctx.rec)

      for links <- [
            [%{id: Ash.UUIDv7.generate(), evidence_sha256: link_sha(ctx.link)}],
            [%{id: foreign.id, evidence_sha256: link_sha(foreign)}],
            [%{id: ctx.link.id, evidence_sha256: hex(:crypto.hash(:sha256, "other"))}]
          ] do
        assert {:error, :calibration_evidence_conflict} =
                 rewrite_and_validate(ctx, &Map.put(&1, :links, links))
      end
    end
  end

  test "the document carries no output, prompt or error text", ctx do
    {:ok, %{bytes: bytes}} = publish(ctx, ctx.document)
    refute bytes =~ @canary
    refute bytes =~ "blue"
    refute bytes =~ Prompt.render()

    for key <- ~w(release_id disposition evidence_sha256 parsed_output response prompt_text) do
      refute Map.has_key?(Jason.decode!(bytes), key), key
    end
  end

  describe "code review (Codex, 661e19d)" do
    test "validate refuses a file under a directory that lost privacy", ctx do
      {:ok, published} = publish(ctx, ctx.document)
      File.chmod!(ctx.dir, 0o755)
      assert {:error, :calibration_evidence_conflict} = validate(ctx, published.path)
    end

    test "validate refuses a file reached through a symlinked ancestor", ctx do
      {:ok, published} = publish(ctx, ctx.document)
      real = Path.dirname(ctx.dir)
      alias_dir = real <> "-valias"
      File.rm(alias_dir)
      on_exit(fn -> File.rm(alias_dir) end)
      File.ln_s!(real, alias_dir)

      via_alias = Path.join([alias_dir, "evidence", Path.basename(published.path)])
      assert {:error, :calibration_evidence_conflict} = validate(ctx, via_alias)
    end

    test "the candidate is the invocation's admitted tuple, never other text", ctx do
      for {key, value} <- [
            model_id: "untrusted-model-canary",
            profile_id: "claude_cli_sonnet",
            model_id: "claude-sonnet-5-5",
            projection_version: "claude-message-json/1+prompt-builder/1",
            cli_version: "2.1.291",
            method: "time_window"
          ] do
        bad = put_in(ctx.document, [:candidate, key], value)
        assert {:error, _} = publish(ctx, bad), inspect(key)
      end

      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
      {:ok, published} = publish(ctx, ctx.document)
      ctx = Map.put(ctx, :published, published)

      assert {:error, :calibration_evidence_conflict} =
               rewrite_and_validate(ctx, &put_in(&1, [:candidate, :model_id], "untrusted"))
    end

    test "observed attestation is the candidate's init pair or null, never other text", ctx do
      for bad <- [
            %{ctx.document | attested_model_id: "untrusted-init-canary"},
            %{ctx.document | attested_cli_version: "2.1.291"},
            %{ctx.document | attested_model_id: nil},
            %{ctx.document | attested_cli_version: nil}
          ] do
        assert {:error, _} = publish(ctx, bad)
      end

      nulls = %{ctx.document | attested_model_id: nil, attested_cli_version: nil}
      assert {:ok, _} = publish(ctx, %{nulls | outcome: "init_drift"})
    end

    test "the evaluated tuple is a named link's, or null without links", ctx do
      for bad <- [
            %{ctx.document | evaluated_projection_version: "untrusted-projection"},
            %{ctx.document | evaluated_method: "untrusted-method"},
            %{ctx.document | evaluated_projection_version: nil},
            %{ctx.document | links: []}
          ] do
        assert {:error, _} = publish(ctx, bad)
      end

      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
    end

    test "under a latch, a changed or replaced file conflicts; the original replays", ctx do
      {:ok, published} = publish(ctx, ctx.document)

      {:ok, %{release: latch}} =
        Agents.finish_calibration(ctx.invocation, %{sha256: published.sha256}, actor: ctx.agent)

      assert latch.evidence_sha256 == published.sha256
      assert {:ok, %{sha256: sha}} = validate(ctx, published.path)
      assert sha == published.sha256

      changed = Map.put(ctx.document, :observed_at, DateTime.add(ctx.document.observed_at, 60))
      File.write!(published.path, Canonical.encode!(changed))
      assert {:error, :calibration_evidence_conflict} = validate(ctx, published.path)

      File.rm!(published.path)
      assert {:error, :calibration_evidence_conflict} = validate(ctx, published.path)
      assert {:error, :calibration_evidence_conflict} = publish(ctx, changed)
    end

    test "a write refusal is a returned error, not an exception, and publishes nothing", ctx do
      me = self()
      handler = "evidence-write-fault-#{System.unique_integer([:positive])}"

      # After the row checks, before the temporary file: the directory
      # becomes unwritable.
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == me and is_binary(meta.query) and meta.query =~ "wire_witness_links",
            do: File.chmod!(ctx.dir, 0o500)
        end,
        nil
      )

      try do
        assert {:error, :calibration_evidence_conflict} = publish(ctx, ctx.document)
      after
        :telemetry.detach(handler)
        File.chmod!(ctx.dir, 0o700)
      end

      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
      assert Path.wildcard(Path.join(ctx.dir, ".*")) |> Enum.reject(&dot?/1) == []
    end
  end

  describe "code review (Codex, 32af7f8)" do
    test "under a latch a missing file is never recreated, even from identical bytes", ctx do
      {:ok, published} = publish(ctx, ctx.document)

      {:ok, _} =
        Agents.finish_calibration(ctx.invocation, %{sha256: published.sha256}, actor: ctx.agent)

      File.rm!(published.path)

      assert {:error, :calibration_evidence_conflict} = publish(ctx, ctx.document)
      refute File.exists?(published.path)
      assert Path.wildcard(Path.join(ctx.dir, ".*")) |> Enum.reject(&dot?/1) == []
    end

    test "timestamps are canonical UTC timestamps, never other text", ctx do
      for bad <- [
            "raw-output-canary-not-a-timestamp",
            "2026-10-13",
            "2026-10-13T06:00:00Z",
            "2026-10-13T06:00:00.000000+01:00",
            "2026-13-40T06:00:00.000000Z"
          ] do
        assert {:error, :evidence_schema} = publish(ctx, %{ctx.document | observed_at: bad}),
               bad
      end

      assert Path.wildcard(Path.join(ctx.dir, "*")) == []

      assert {:ok, _} =
               publish(ctx, %{ctx.document | observed_at: "2026-10-13T06:00:00.000000Z"})
    end

    test "an existing file with a non-timestamp observed_at is a conflict", ctx do
      {:ok, published} = publish(ctx, ctx.document)
      ctx = Map.put(ctx, :published, published)

      assert {:error, :calibration_evidence_conflict} =
               rewrite_and_validate(ctx, &Map.put(&1, :observed_at, "raw-text"))
    end
  end

  # A proof invocation reserved with the calibration input's own references
  # (or, `refs: :generic`, an ordinary prompt's), completed with a synthetic
  # parsed answer or failed after it was sent.
  describe "input and output commitments" do
    @tag refs: :generic
    test "a document whose prompt commitments the reservation does not carry", ctx do
      assert {:error, :calibration_evidence_conflict} = publish(ctx, ctx.document)
      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
    end

    test "a wrong output commitment is a conflict", ctx do
      {:ok, published} = publish(ctx, ctx.document)
      ctx = Map.put(ctx, :published, published)
      other = hex(Canonical.sha256(%{"answer" => "green", "confidence" => 0.9}))

      assert {:error, :calibration_evidence_conflict} =
               rewrite_and_validate(ctx, &Map.put(&1, :output_sha256, other))
    end
  end

  describe "a failed call" do
    @describetag call: :failed

    test "no output, no observed init, no evaluation: published and valid", ctx do
      assert {:ok, %{path: path, sha256: sha}} = publish(ctx, ctx.document)
      assert {:ok, %{sha256: ^sha}} = validate(ctx, path)

      decoded = path |> File.read!() |> Jason.decode!()

      for key <- ~w(output_sha256 attested_cli_version attested_model_id
                    evaluated_projection_version evaluated_method) do
        assert Map.fetch!(decoded, key) == nil, key
      end
    end

    test "an output commitment for a call without output is a conflict", ctx do
      bad = %{ctx.document | output_sha256: hex(Canonical.sha256(@output))}
      assert {:error, :calibration_evidence_conflict} = publish(ctx, bad)
      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
    end
  end

  describe "paths" do
    test "a directory under a symlinked ancestor is unsafe", ctx do
      real = Path.dirname(ctx.dir)
      alias_dir = real <> "-alias"
      # Beside the per-test tmp dir, so removed explicitly.
      File.rm(alias_dir)
      on_exit(fn -> File.rm(alias_dir) end)
      File.ln_s!(real, alias_dir)

      assert {:error, :evidence_dir_unsafe} =
               Evidence.publish(Path.join(alias_dir, "evidence"), ctx.document, opts(ctx))

      assert Path.wildcard(Path.join(ctx.dir, "*")) == []
    end

    test "identifiers that would leave the directory are refused", ctx do
      for bad <- [
            %{ctx.document | invocation_id: "../../escape"},
            %{ctx.document | profile_id: "claude_cli_opus/../escape"}
          ] do
        assert {:error, :evidence_schema} = publish(ctx, bad)
      end

      root = ctx.dir |> Path.dirname() |> Path.dirname()
      assert Path.wildcard(Path.join(root, "**/*escape*")) == []
    end
  end

  test "no output text reaches a log line, on success or refusal", ctx do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, published} = publish(ctx, ctx.document)
        File.chmod!(published.path, 0o644)
        {:error, _} = validate(ctx, published.path)
        {:error, _} = publish(ctx, Map.put(ctx.document, :extra, @canary))
      end)

    refute log =~ @canary
  end

  defp proof!(run, agent, call, refs) do
    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(
          run,
          attrs("ev-#{System.unique_integer([:positive])}", refs),
          actor: agent,
          calibration: CalibrationAdmission.context(:claude_cli_opus, candidate())
        )
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    settle(sent, agent, call)
  end

  defp attrs(key, :generic), do: AgentsFixtures.claude_attrs(key)

  defp attrs(key, _calibration) do
    prompt = Prompt.prompt_ref()
    schema = Prompt.schema_ref()

    key
    |> AgentsFixtures.claude_attrs()
    |> Map.merge(%{
      prompt_template_id: prompt.id,
      prompt_template_version: prompt.version,
      prompt_template_sha256: prompt.sha256,
      output_schema_id: schema.id,
      output_schema_version: schema.version,
      output_schema_sha256: schema.sha256
    })
  end

  defp settle(sent, agent, :completed) do
    completion = %{
      AgentsFixtures.completion()
      | response: Jason.encode!(@output),
        parsed_output: @output
    }

    {:ok, done} = Agents.complete_model_invocation(sent, completion, actor: agent)
    done
  end

  defp settle(sent, agent, :failed) do
    {:ok, failed} =
      Agents.fail_model_invocation(sent, %{error: %{"kind" => "provider_error"}}, actor: agent)

    failed
  end

  # A closed-schema document for `invocation` (the console builds it from
  # committed rows, row R11-4; here it is literal). The candidate is the
  # literal v3 tuple; a completed call commits to its parsed output, a
  # failed one has no output, no observed init and no evaluation.
  defp document(invocation, run, links, call) do
    entry = candidate()
    stamp = &(&1 && Base.encode16(&1, case: :lower))
    ref = &%{id: &1.id, version: &1.version, sha256: stamp.(&1.sha256)}
    completed? = call == :completed

    %{
      schema: "r0-calibration-evidence/1",
      canonicalization: Canonical.version(),
      invocation_id: invocation.id,
      run_id: run.id,
      tenant_id: invocation.tenant_id,
      profile_id: "claude_cli_opus",
      candidate: Map.new(entry, fn {k, v} -> {k, to_string(v)} end),
      evaluated_projection_version: if(completed?, do: @v3),
      evaluated_method: if(completed?, do: "propagated_id"),
      outcome: if(completed?, do: "match", else: "missing"),
      links: if(completed?, do: Enum.map(links, &link_ref/1), else: []),
      inventory_sha256: nil,
      prompt: ref.(Prompt.prompt_ref()),
      output_schema: ref.(Prompt.schema_ref()),
      attested_cli_version: if(completed?, do: invocation.provider_version),
      attested_model_id: if(completed?, do: invocation.model_id),
      invocation_status: to_string(invocation.status),
      validation_status: to_string(invocation.validation_status),
      output_sha256: if(completed?, do: hex(Canonical.sha256(@output))),
      reserved_at: invocation.reserved_at,
      sent_at: invocation.sent_at,
      completed_at: invocation.completed_at,
      observed_at: ~U[2026-10-13 06:00:00.000000Z]
    }
  end

  # The literal v3 candidate: the calibration marker the call is reserved
  # under, the document's candidate and the link's evaluated projection.
  defp candidate, do: AdmissionFixtures.entry(:claude_cli_opus, @v3)

  defp link_ref(link), do: %{id: link.id, evidence_sha256: link_sha(link)}

  # A v3 claim carries its complete context group (WitnessEvidence).
  defp v3_evidence do
    %{
      "projection_version" => @v3,
      "reminder_count" => 0,
      "reminder_sha256s" => [],
      "reminder_bytes" => [],
      "trailing_system_count" => 0,
      "trailing_system_sha256s" => [],
      "trailing_system_bytes" => [],
      "request_extras_sha256" => String.duplicate("c3", 32),
      "request_fields" => [],
      "trailing_output_config" => []
    }
  end

  defp rewrite_and_validate(ctx, fun) do
    path = ctx.published.path
    tampered = ctx.published.bytes |> Jason.decode!(keys: :atoms) |> fun.()
    File.chmod!(path, 0o600)
    File.write!(path, Canonical.encode!(tampered))
    File.chmod!(path, 0o600)
    validate(ctx, path)
  end

  defp publish(ctx, document), do: Evidence.publish(ctx.dir, document, opts(ctx))

  defp validate(ctx, path) do
    target = %{
      invocation_id: ctx.invocation.id,
      run_id: ctx.run.id,
      tenant_id: ctx.tenant.id,
      profile_id: :claude_cli_opus
    }

    Evidence.validate(path, target, opts(ctx))
  end

  defp opts(ctx), do: [actor: system_actor(:agent_runtime, ctx.tenant)]

  defp link_sha(link), do: hex(Canonical.sha256(link.evidence))

  defp dot?(path), do: Path.basename(path) in [".", ".."]
end
