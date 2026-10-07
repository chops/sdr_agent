defmodule SdrAgent.ReconstructionTest do
  @moduledoc """
  S13 Postgres-only reconstruction (ADR-0002 "Reconstruction acceptance
  test"): given a captured email, rebuild every step — lead, research
  artifacts and evidence, qualification, decisions, model invocations with
  their full request/response payloads, tool calls, draft revisions,
  approval, delivery and the exact captured message, the signed reply and
  its assessment — from database rows alone, then verify that story
  against the audit ledger.

  The story is read with plain SQL (`Ecto.Adapters.SQL.query!/3`), as an
  auditor with `psql` would: no Jido process, Oban job or telemetry
  backend is consulted (tests export spans in memory only). The only
  application code used is the verifier's own canonical hashing:

    * every content hash the story names resolves to a stored Payload whose
      bytes hash to it;
    * every story row is a subject of the ledger, and the ledger's latest
      after-image hash (`record_sha256`) of that subject equals the hash of
      the row as stored now — the database has not drifted from the chain;
    * the binding facts agree (approval ↔ revision ↔ delivery ↔ receipt ↔
      reply), the ledger orders the steps causally, and the chain verifies.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures, only: [process!: 0]

  alias Ecto.Adapters.SQL
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Demo.Replies

  # {table, resource} of every row kind the story includes (all audited).
  @audited %{
    "leads" => SdrAgent.Sales.Lead,
    "agent_runs" => SdrAgent.Agents.AgentRun,
    "decisions" => SdrAgent.Agents.Decision,
    "model_invocations" => SdrAgent.Agents.ModelInvocation,
    "tool_invocations" => SdrAgent.Agents.ToolInvocation,
    "research_artifacts" => SdrAgent.Research.ResearchArtifact,
    "evidence_claims" => SdrAgent.Research.EvidenceClaim,
    "qualifications" => SdrAgent.Research.Qualification,
    "drafts" => SdrAgent.Outreach.Draft,
    "draft_revisions" => SdrAgent.Outreach.DraftRevision,
    "approvals" => SdrAgent.Outreach.Approval,
    "delivery_operations" => SdrAgent.Outreach.DeliveryOperation,
    "delivery_receipts" => SdrAgent.Outreach.DeliveryReceipt,
    "replies" => SdrAgent.Outreach.Reply,
    "reply_assessments" => SdrAgent.Outreach.ReplyAssessment
  }

  setup ctx do
    # The golden path through an interested reply, for lead 01.
    approved = approved!(ctx)
    assert %{success: 1} = deliver!()
    delivery = outreach!(ctx, approved.delivery)
    assert delivery.state == :accepted

    assert {:ok, 202} = Replies.post(:interested, delivery, plug: SdrAgentWeb.Endpoint)
    assert %{success: 1} = process!()
    assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)

    %{delivery_id: delivery.id}
  end

  test "a captured email's whole story is rebuilt from Postgres and matches the ledger", ctx do
    story = reconstruct(ctx.delivery_id)

    # The story is complete.
    assert [%{"state" => "accepted"} = delivery] = story["delivery_operations"]
    assert [%{"verdict" => "approved"} = approval] = story["approvals"]
    assert [captured] = Enum.filter(story["delivery_receipts"], &(&1["kind"] == "captured"))

    assert [revision] =
             Enum.filter(story["draft_revisions"], &(&1["id"] == approval["draft_revision_id"]))

    assert [%{"match_status" => "matched"} = reply] = story["replies"]
    assert [%{"classification" => "interested"}] = story["reply_assessments"]
    assert story["research_artifacts"] != [] and story["evidence_claims"] != []
    assert [%{"qualified" => true}] = story["qualifications"]
    assert Enum.any?(story["decisions"], &(&1["kind"] == "draft_proposal"))
    assert Enum.any?(story["decisions"], &(&1["kind"] == "send_gate" and &1["outcome"] == "pass"))
    assert length(story["model_invocations"]) >= 3
    assert story["tool_invocations"] != []

    # Binding facts agree: what was approved is what was rendered and sent.
    assert approval["revision_content_sha256"] == revision["content_sha256"]
    assert delivery["revision_content_sha256"] == revision["content_sha256"]
    assert delivery["draft_revision_id"] == revision["id"]
    assert delivery["recipient_email"] == approval["recipient_email"]
    assert captured["rendered_sha256"] == delivery["rendered_sha256"]
    assert reply["delivery_operation_id"] == delivery["id"]

    # Content: every hash resolves to stored bytes that hash to it, and the
    # captured message is the approved revision to the approved recipient.
    message = payload!(delivery["rendered_sha256"])
    assert message =~ "To: #{approval["recipient_email"]}"
    assert message =~ revision["subject"]

    for invocation <- story["model_invocations"],
        sha <- [invocation["request_sha256"], invocation["response_sha256"]],
        sha != nil do
      assert byte_size(payload!(sha)) > 0
    end

    for artifact <- story["research_artifacts"], do: payload!(artifact["content_sha256"])

    # The ledger: every story row is a subject, and its latest after-image
    # hash equals the row as stored now.
    for {table, rows} <- story, resource = @audited[table], row <- rows do
      assert ledger_hash(row["id"]) == current_hash(resource, row["id"], ctx.tenant.id),
             "#{table} #{row["id"]} drifted from the ledger"
    end

    # The ledger orders the story causally, and the chain verifies.
    assert causal?(ctx.tenant.id, [
             {"sdr.lead.assigned", story["agent_runs"] |> hd() |> Map.fetch!("lead_id")},
             {"outreach.revision.created", revision["id"]},
             {"outreach.approval.granted", approval["id"]},
             {"outreach.delivery.accepted", delivery["id"]},
             {"outreach.reply.received", reply["id"]},
             {"outreach.reply.assessed", hd(story["reply_assessments"])["id"]}
           ])

    {:ok, head} = Kernel.lock_head(ctx.tenant.id)
    assert %{valid?: true, issues: []} = SdrAgent.Audit.Verifier.verify(ctx.tenant.id, head)
  end

  test "a story row edited behind the application no longer matches the ledger", ctx do
    tamper!(
      "UPDATE delivery_operations SET recipient_email = 'someone.else@example.test' WHERE id = $1",
      [uuid(ctx.delivery_id)]
    )

    [delivery] = reconstruct(ctx.delivery_id)["delivery_operations"]
    assert delivery["recipient_email"] == "someone.else@example.test"

    refute ledger_hash(delivery["id"]) ==
             current_hash(SdrAgent.Outreach.DeliveryOperation, delivery["id"], ctx.tenant.id)
  end

  ## Plain-SQL reconstruction (no application reads)

  defp reconstruct(delivery_id) do
    [delivery] = rows("SELECT * FROM delivery_operations WHERE id = $1", [uuid(delivery_id)])
    lead_id = scalar("SELECT lead_id FROM drafts WHERE id = $1", [uuid(delivery["draft_id"])])
    lead = uuid(lead_id)
    runs = rows("SELECT * FROM agent_runs WHERE lead_id = $1 ORDER BY inserted_at", [lead])
    run_ids = Enum.map(runs, &uuid(&1["id"]))
    drafts = rows("SELECT * FROM drafts WHERE lead_id = $1", [lead])
    draft_ids = Enum.map(drafts, &uuid(&1["id"]))
    replies = rows("SELECT * FROM replies WHERE delivery_operation_id = $1", [uuid(delivery_id)])
    reply_ids = Enum.map(replies, &uuid(&1["id"]))
    assessments = rows("SELECT * FROM reply_assessments WHERE reply_id = ANY($1)", [reply_ids])
    all_runs = run_ids ++ Enum.map(assessments, &uuid(&1["agent_run_id"]))

    %{
      "leads" => rows("SELECT * FROM leads WHERE id = $1", [lead]),
      "agent_runs" => runs,
      "decisions" =>
        rows("SELECT * FROM decisions WHERE agent_run_id = ANY($1) OR subject_id = $2", [
          all_runs,
          uuid(delivery_id)
        ]),
      "model_invocations" =>
        rows("SELECT * FROM model_invocations WHERE agent_run_id = ANY($1)", [all_runs]),
      "tool_invocations" =>
        rows("SELECT * FROM tool_invocations WHERE agent_run_id = ANY($1)", [run_ids]),
      "research_artifacts" => rows("SELECT * FROM research_artifacts WHERE lead_id = $1", [lead]),
      "evidence_claims" => rows("SELECT * FROM evidence_claims WHERE lead_id = $1", [lead]),
      "qualifications" => rows("SELECT * FROM qualifications WHERE lead_id = $1", [lead]),
      "drafts" => drafts,
      "draft_revisions" =>
        rows("SELECT * FROM draft_revisions WHERE draft_id = ANY($1)", [draft_ids]),
      "approvals" => rows("SELECT * FROM approvals WHERE draft_id = ANY($1)", [draft_ids]),
      "delivery_operations" => [delivery],
      "delivery_receipts" =>
        rows("SELECT * FROM delivery_receipts WHERE delivery_operation_id = $1", [
          uuid(delivery_id)
        ]),
      "replies" => replies,
      "reply_assessments" => assessments
    }
  end

  defp rows(sql, params) do
    %{columns: columns, rows: rows} = SQL.query!(Repo, sql, params)
    Enum.map(rows, fn row -> columns |> Enum.zip(Enum.map(row, &plain/1)) |> Map.new() end)
  end

  defp scalar(sql, params) do
    %{rows: [[value]]} = SQL.query!(Repo, sql, params)
    plain(value)
  end

  # UUIDs and hashes as text, so rows compare like psql output.
  defp plain(<<_::128>> = bin) do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> bin
    end
  end

  defp plain(<<_::256>> = sha), do: Base.encode16(sha, case: :lower)
  defp plain(value), do: value

  defp uuid(text), do: Ecto.UUID.dump!(text)

  defp payload!(hex) do
    sha = Base.decode16!(hex, case: :lower)

    %{rows: [[content]]} =
      SQL.query!(Repo, "SELECT content FROM payloads WHERE sha256 = $1", [sha])

    assert :crypto.hash(:sha256, content) == sha, "payload #{hex} does not hash to its address"
    content
  end

  defp ledger_hash(subject_id) do
    SQL.query!(
      Repo,
      "SELECT payload->>'record_sha256' FROM audit_events WHERE subject_id = $1 " <>
        "AND payload ? 'record_sha256' ORDER BY sequence DESC LIMIT 1",
      [subject_id]
    )
    |> case do
      %{rows: [[hash]]} -> hash
      %{rows: []} -> nil
    end
  end

  defp current_hash(resource, id, tenant_id),
    do: resource |> Ash.get!(id, Kernel.opts(tenant_id)) |> RecordHash.hex()

  defp causal?(tenant_id, steps) do
    sequences =
      for {type, subject} <- steps do
        %{rows: [[sequence]]} =
          SQL.query!(
            Repo,
            "SELECT min(sequence) FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
              "AND (subject_id = $3 OR payload->'data'->>'lead_id' = $3)",
            [uuid(tenant_id), type, subject]
          )

        assert sequence, "no #{type} event for #{subject}"
        sequence
      end

    sequences == Enum.sort(sequences)
  end
end
