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
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.Prompt

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    tenant = bootstrap!()

    AgentsFixtures.grant!(tenant, %{
      total_attempts: 4,
      allocations: [%{key: :proof, applies_to: [:proof], attempts: 4}]
    })

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, usage_origin: :proof)
    rec = system_actor(:reconciler, tenant)
    invocation = completed_proof!(run, agent)
    link = AgentsFixtures.reconciled_link!(invocation, rec)
    dir = Path.join(tmp, "evidence")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: rec,
      invocation: invocation,
      link: link,
      dir: dir,
      document: document(invocation, run, [link])
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
      %{run: other_run, agent: agent} =
        AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

      foreign = AgentsFixtures.reconciled_link!(completed_proof!(other_run, agent), ctx.rec)

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
    refute bytes =~ "qualified"
    refute bytes =~ "criteria"
    refute bytes =~ Prompt.render()

    for key <- ~w(release_id disposition evidence_sha256 parsed_output response prompt_text) do
      refute Map.has_key?(Jason.decode!(bytes), key), key
    end
  end

  defp completed_proof!(run, agent) do
    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(
          run,
          AgentsFixtures.claude_attrs("ev-#{System.unique_integer([:positive])}"),
          actor: agent,
          calibration: AdmissionFixtures.calibration()
        )
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)

    {:ok, done} =
      Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: agent)

    done
  end

  # A closed-schema document for `invocation` (the console builds it from
  # committed rows, row R11-4; here it is literal).
  defp document(invocation, run, links) do
    entry = AdmissionFixtures.entry()
    stamp = &(&1 && Base.encode16(&1, case: :lower))
    ref = &%{id: &1.id, version: &1.version, sha256: stamp.(&1.sha256)}

    %{
      schema: "r0-calibration-evidence/1",
      canonicalization: Canonical.version(),
      invocation_id: invocation.id,
      run_id: run.id,
      tenant_id: invocation.tenant_id,
      profile_id: "claude_cli_opus",
      candidate: Map.new(entry, fn {k, v} -> {k, to_string(v)} end),
      evaluated_projection_version: entry.projection_version,
      evaluated_method: "propagated_id",
      outcome: "match",
      links: Enum.map(links, &%{id: &1.id, evidence_sha256: link_sha(&1)}),
      inventory_sha256: nil,
      prompt: ref.(Prompt.prompt_ref()),
      output_schema: ref.(Prompt.schema_ref()),
      attested_cli_version: invocation.provider_version,
      attested_model_id: invocation.model_id,
      invocation_status: to_string(invocation.status),
      validation_status: to_string(invocation.validation_status),
      output_sha256: stamp.(invocation.response_sha256),
      reserved_at: invocation.reserved_at,
      sent_at: invocation.sent_at,
      completed_at: invocation.completed_at,
      observed_at: ~U[2026-10-13 06:00:00.000000Z]
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
