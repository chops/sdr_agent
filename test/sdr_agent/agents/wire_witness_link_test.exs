defmodule SdrAgent.Agents.WireWitnessLinkTest do
  @moduledoc """
  S12b step 5: the S2 WireWitnessLink resource under the approved S12 entity
  ruling (R1 per-exchange lineage subject `(tenant, invocation,
  proxy_record_ref)`; C3 same-version mismatch; C4 no-fork lineage; C5
  bounded allowlisted evidence; P2 no account identifiers). REC creates;
  same-tenant metadata readers read; APPEND-ONLY; every link appends
  `agents.witness.linked` in its own transaction.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Test.SecretShapes

  setup do
    assert function_exported?(Agents, :link_wire_witness, 2),
           "S12b: Agents.link_wire_witness/2 is not implemented"

    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: system_actor(:reconciler, tenant),
      invocation: terminal_invocation!(run, agent, :claude_cli, "wwl-1")
    }
  end

  describe "create and read" do
    test "REC links a terminal ClaudeCLI invocation; the event carries hash, run and invocation",
         ctx do
      before = length(events(ctx.tenant))
      assert {:ok, link} = Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)

      assert link.model_invocation_id == ctx.invocation.id
      assert link.tenant_id == ctx.tenant.id
      assert link.link_status == :inferred
      assert link.method == :propagated_id
      assert link.supersedes_id == nil
      assert link.proxy_request_sha256 == digest("raw request")
      assert link.evidence["projection_version"] == "claude-message-json/1+prompt-builder/1"
      assert link.trace_id =~ ~r/^[0-9a-f]{32}$/

      assert [event] = events_of_type(ctx.tenant, "agents.witness.linked")
      assert length(events(ctx.tenant)) == before + 1
      assert event.model_invocation_id == ctx.invocation.id
      assert event.agent_run_id == ctx.run.id
      assert event.actor_type == :reconciler
      assert event.subject_id == link.id
      assert event.payload["record_sha256"] == RecordHash.hex(link)

      assert {:ok, report} = SdrAgent.Audit.verify_chain(actor: human(:admin, ctx.tenant))
      assert report.valid?, inspect(report.issues)
    end

    test "only REC may link; an auditor's attempt is refused and audited once", ctx do
      for actor <- [
            ctx.agent,
            system_actor(:kernel, ctx.tenant),
            system_actor(:auditor_cli, ctx.tenant),
            system_actor(:delivery_worker, ctx.tenant),
            human(:admin, ctx.tenant),
            human(:reviewer, ctx.tenant),
            nil
          ] do
        assert match?(
                 {:error, %Ash.Error.Forbidden{}},
                 Agents.link_wire_witness(attrs(ctx.invocation), actor: actor)
               ),
               inspect(actor)
      end

      assert events_of_type(ctx.tenant, "authz.denied") == []
      auditor = human(:auditor, ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.link_wire_witness(attrs(ctx.invocation), actor: auditor)

      assert [denied] = events_of_type(ctx.tenant, "authz.denied")
      assert denied.actor_role == :auditor
      assert events_of_type(ctx.tenant, "agents.witness.linked") == []
      assert {:ok, []} = Agents.list_wire_witness_links(ctx.invocation.id, actor: ctx.rec)
    end

    test "same-tenant metadata readers read links; anonymous callers do not", ctx do
      assert {:ok, link} = Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)

      for actor <- [
            ctx.rec,
            ctx.agent,
            system_actor(:auditor_cli, ctx.tenant),
            human(:admin, ctx.tenant),
            human(:reviewer, ctx.tenant),
            human(:auditor, ctx.tenant)
          ] do
        assert {:ok, [read]} = Agents.list_wire_witness_links(ctx.invocation.id, actor: actor)
        assert read.id == link.id
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.list_wire_witness_links(ctx.invocation.id, actor: nil)
    end

    test "only terminal ClaudeCLI invocations can be linked", ctx do
      fake = terminal_invocation!(ctx.run, ctx.agent, :fake, "wwl-fake")
      open = sent_invocation!(ctx.run, ctx.agent, "wwl-open")

      for invocation <- [fake, open] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Agents.link_wire_witness(attrs(invocation), actor: ctx.rec)
      end

      assert events_of_type(ctx.tenant, "agents.witness.linked") == []
    end

    test "proxy record refs are opaque lowercase UUIDs; raw digests are 32 bytes", ctx do
      for overrides <- [
            %{proxy_record_ref: "../../witnesses/x"},
            %{proxy_record_ref: "/Users/someone/.llm-proxy/witnesses/x.json"},
            %{proxy_record_ref: String.upcase(record_ref())},
            %{proxy_record_ref: ""},
            %{proxy_request_sha256: binary_part(digest("short"), 0, 31)},
            %{proxy_response_sha256: digest("long") <> <<0>>}
          ] do
        assert match?(
                 {:error, %Ash.Error.Invalid{}},
                 Agents.link_wire_witness(attrs(ctx.invocation, overrides), actor: ctx.rec)
               ),
               inspect(overrides)
      end
    end
  end

  describe "evidence (C5, P2)" do
    test "accepts the typed allowlist only", ctx do
      digest_hex = hex(digest("x"))

      bad = [
        {"unknown key", %{"note" => "free text"}},
        {"nested map", %{"route" => %{"path" => "/anthropic/v1/messages"}}},
        {"raw request header", %{"authorization" => SecretShapes.bearer()}},
        {"header map", %{"headers" => %{"x-api-key" => SecretShapes.provider_key()}}},
        {"raw body", %{"content" => ~s({"messages":[{"role":"user"}]})}},
        {"account id key", %{"user_id" => "user_" <> String.duplicate("ab", 32)}},
        {"metadata key", %{"metadata.user_id" => "user_" <> String.duplicate("cd", 32)}},
        {"account id code", %{"reason_codes" => ["user_" <> String.duplicate("ef", 32)]}},
        {"absolute path", %{"proxy_version" => "/Users/someone/.llm-proxy/blobs"}},
        {"relative path", %{"projection_version" => "../../witness/sha256"}},
        {"unknown route", %{"route" => "/anthropic/v1/messages?beta=true"}},
        {"short digest", %{"app_request_sha256" => String.slice(digest_hex, 0, 63)}},
        {"uppercase digest", %{"app_request_sha256" => String.upcase(digest_hex)}},
        {"too many codes", %{"reason_codes" => Enum.map(1..17, &"code_#{&1}")}},
        {"non-boolean flag", %{"stream_complete" => "true"}},
        {"bad schema", %{"witness_schema" => "1"}},
        {"oversized", %{"reason_codes" => List.duplicate(String.duplicate("a", 39), 16)}}
      ]

      secret_shaped =
        for sample <- SecretShapes.samples() do
          {"secret-shaped #{String.slice(sample, 0, 6)}", %{"proxy_version" => sample}}
        end

      for {label, evidence} <- bad ++ secret_shaped do
        assert match?(
                 {:error, %Ash.Error.Invalid{}},
                 Agents.link_wire_witness(
                   attrs(ctx.invocation, %{evidence: Map.merge(evidence(), evidence)}),
                   actor: ctx.rec
                 )
               ),
               label
      end

      assert events_of_type(ctx.tenant, "agents.witness.linked") == []

      assert {:ok, link} =
               Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)

      rendered = inspect(events_of_type(ctx.tenant, "agents.witness.linked"), limit: :infinity)
      refute rendered =~ "user_id"
      refute rendered =~ "authorization"
      assert Map.keys(link.evidence) |> Enum.all?(&is_binary/1)
    end
  end

  describe "lineage (R1, C3, C4)" do
    test "each exchange is its own subject; a correction supersedes the current head", ctx do
      assert {:ok, root} = Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)
      other_ref = record_ref()

      assert {:ok, other} =
               Agents.link_wire_witness(attrs(ctx.invocation, %{proxy_record_ref: other_ref}),
                 actor: ctx.rec
               )

      assert {:ok, successor} =
               Agents.link_wire_witness(successor_attrs(root, %{link_status: :reconciled}),
                 actor: ctx.rec
               )

      assert {:ok, current} = Agents.current_wire_witness_links(ctx.invocation.id, actor: ctx.rec)
      assert Enum.sort(Enum.map(current, & &1.id)) == Enum.sort([successor.id, other.id])
      assert {:ok, all} = Agents.list_wire_witness_links(ctx.invocation.id, actor: ctx.rec)
      assert length(all) == 3
      assert length(events_of_type(ctx.tenant, "agents.witness.linked")) == 3
    end

    test "a second root for the same exchange is refused", ctx do
      assert {:ok, _root} = Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)
    end

    test "superseding anything but the current head of the same exchange is refused", ctx do
      assert {:ok, root} = Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)
      assert {:ok, head} = Agents.link_wire_witness(successor_attrs(root), actor: ctx.rec)

      # fork: a second successor of the (no longer current) root
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.link_wire_witness(successor_attrs(root), actor: ctx.rec)

      # cross-subject: another exchange of the same invocation supersedes this head
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.link_wire_witness(
                 successor_attrs(head, %{proxy_record_ref: record_ref()}),
                 actor: ctx.rec
               )

      # cross-invocation supersede
      other = terminal_invocation!(ctx.run, ctx.agent, :claude_cli, "wwl-2")

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.link_wire_witness(
                 successor_attrs(head, %{model_invocation_id: other.id}),
                 actor: ctx.rec
               )

      # a successor must state why it supersedes
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.link_wire_witness(
                 successor_attrs(head, %{evidence: evidence()}),
                 actor: ctx.rec
               )
    end

    test "a mismatch is superseded only under a different projection version", ctx do
      assert {:ok, mismatch} =
               Agents.link_wire_witness(attrs(ctx.invocation, %{link_status: :mismatch}),
                 actor: ctx.rec
               )

      for status <- [:reconciled, :inferred, :mismatch] do
        assert match?(
                 {:error, %Ash.Error.Invalid{}},
                 Agents.link_wire_witness(successor_attrs(mismatch, %{link_status: status}),
                   actor: ctx.rec
                 )
               ),
               "same-version #{status}"
      end

      assert {:ok, corrected} =
               Agents.link_wire_witness(
                 successor_attrs(mismatch, %{
                   link_status: :reconciled,
                   evidence:
                     Map.merge(evidence(), %{
                       "projection_version" => "claude-message-json/2+prompt-builder/1",
                       "supersede_reason" => "projection_version_changed"
                     })
                 }),
                 actor: ctx.rec
               )

      assert corrected.supersedes_id == mismatch.id
      assert {:ok, all} = Agents.list_wire_witness_links(ctx.invocation.id, actor: ctx.rec)
      assert Enum.any?(all, &(&1.id == mismatch.id and &1.link_status == :mismatch))
    end
  end

  describe "database enforcement" do
    setup ctx do
      assert {:ok, root} = Agents.link_wire_witness(attrs(ctx.invocation), actor: ctx.rec)
      %{root: root}
    end

    test "the table is append-only (UPDATE, DELETE, TRUNCATE)", _ctx do
      for sql <- [
            "UPDATE wire_witness_links SET link_status = 'reconciled'",
            "DELETE FROM wire_witness_links",
            "TRUNCATE wire_witness_links CASCADE"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{message: message}}} = raw_error(sql)
        assert message =~ "append-only", sql
      end
    end

    test "raw inserts cannot fork, cross subjects or rewrite a same-version mismatch", ctx do
      assert {:ok, head} = Agents.link_wire_witness(successor_attrs(ctx.root), actor: ctx.rec)

      # fork of the root (already superseded by head)
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               raw_insert(head, supersedes_id: ctx.root.id)

      # successor of head under another exchange ref (cross-subject)
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               raw_insert(head, supersedes_id: head.id, proxy_record_ref: record_ref())

      assert {:ok, mismatch} =
               Agents.link_wire_witness(successor_attrs(head, %{link_status: :mismatch}),
                 actor: ctx.rec
               )

      # same projection version: mismatch -> reconciled
      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw_insert(mismatch, supersedes_id: mismatch.id, link_status: "reconciled")

      assert message =~ "projection version"
    end
  end

  ## Fixtures

  defp attrs(invocation, overrides \\ %{}) do
    Map.merge(
      %{
        model_invocation_id: invocation.id,
        proxy_record_ref: Process.get(:wwl_ref) || put_ref(),
        proxy_request_sha256: digest("raw request"),
        proxy_response_sha256: digest("raw response"),
        link_status: :inferred,
        method: :propagated_id,
        evidence: evidence()
      },
      overrides
    )
  end

  defp put_ref do
    ref = record_ref()
    Process.put(:wwl_ref, ref)
    ref
  end

  defp successor_attrs(predecessor, overrides \\ %{}) do
    Map.merge(
      %{
        model_invocation_id: predecessor.model_invocation_id,
        proxy_record_ref: predecessor.proxy_record_ref,
        proxy_request_sha256: predecessor.proxy_request_sha256,
        proxy_response_sha256: predecessor.proxy_response_sha256,
        link_status: :inferred,
        method: :propagated_id,
        supersedes_id: predecessor.id,
        evidence: Map.put(evidence(), "supersede_reason", "inventory_rescanned")
      },
      overrides
    )
  end

  defp evidence do
    %{
      "witness_schema" => 1,
      "proxy_version" => "0.2.0",
      "cli_version" => "2.1.291",
      "route" => "/anthropic/v1/messages",
      "http_method" => "POST",
      "http_status" => 200,
      "outcome" => "complete",
      "started_at" => "2026-10-07T12:00:00.000001Z",
      "completed_at" => "2026-10-07T12:00:02.5Z",
      "request_bytes_seen" => 2048,
      "response_bytes_seen" => 4096,
      "request_capture_complete" => true,
      "response_capture_complete" => true,
      "stream_complete" => true,
      "traceparent_match" => true,
      "classification" => "primary",
      "projection_version" => "claude-message-json/1+prompt-builder/1",
      "app_request_sha256" => hex(digest("app request")),
      "projected_request_sha256" => hex(digest("projected request")),
      "inventory_sha256" => hex(digest("inventory")),
      "reason_codes" => ["propagated_id_match"]
    }
  end

  defp record_ref, do: Ash.UUIDv7.generate()

  defp terminal_invocation!(run, agent, provider, key) do
    invocation = sent_invocation!(run, agent, key, provider)

    {:ok, done} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: agent)

    done
  end

  defp sent_invocation!(run, agent, key, provider \\ :claude_cli) do
    attrs = AgentsFixtures.model_attrs(key) |> Map.put(:provider, provider)
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, sent} = Agents.mark_model_invocation_sent(invocation, actor: agent)
    sent
  end

  # Copies `row` into a new raw row (triggers on), overriding columns.
  defp raw_insert(row, overrides) do
    overrides = Map.new(overrides)

    raw_error(
      """
      INSERT INTO wire_witness_links
        (id, tenant_id, model_invocation_id, proxy_record_ref, proxy_request_sha256,
         proxy_response_sha256, link_status, method, evidence, supersedes_id,
         recorded_at, trace_id, span_id, inserted_at)
      SELECT $2, tenant_id, model_invocation_id, $3, proxy_request_sha256,
             proxy_response_sha256, $4, method,
             evidence || '{"supersede_reason":"raw_insert"}'::jsonb, $5,
             recorded_at, trace_id, span_id, inserted_at
        FROM wire_witness_links WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(row.id),
        Ecto.UUID.dump!(Ash.UUIDv7.generate()),
        Map.get(overrides, :proxy_record_ref, row.proxy_record_ref),
        Map.get(overrides, :link_status, to_string(row.link_status)),
        Ecto.UUID.dump!(Map.fetch!(overrides, :supersedes_id))
      ]
    )
  end
end
