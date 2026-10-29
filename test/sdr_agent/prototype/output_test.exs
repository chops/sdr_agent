defmodule SdrAgent.Prototype.OutputTest do
  @moduledoc """
  D-237 IF-5 output serialization (interfaces r6 IF-5, must-fix R2, Q1;
  plan r7 section 6 rows F4 output and R2 output channels and digests).

  - Typed digests on real records made by the existing flows (ordinary
    runtime, demo data): the canonical revision content digest equals
    `DraftRevision.content_sha256` equals `Approval.revision_content_sha256`;
    `sha256(rendered bytes)` equals `DeliveryReceipt.rendered_sha256`; a
    tampered field is `:digest_mismatch`; the two digests are never
    interchangeable; both byte streams are unchanged and the label never
    enters them.
  - Views and the private bundle in prototype runtime: the pending-revision
    view with the recipient contact id and exact email (Q1) and no approval
    wording; the approval and receipt views; the block on every view; the
    0600 exclusive bundle under a 0700 directory; an existing bundle path
    refused; `op review` printing only the bundle UUID and item count, with
    no content in stdout, stderr or log events.
  - Q1 through `op approve`: the three reviewed inputs are each required
    and never refilled; a changed recipient email or a new revision after
    review refuses the approval as stale.
  - The Mix task allow-list (Codex S4 RED ruling 6: closed, exact names):
    `sdr.prototype.{setup,provision,import,op,serve}` and `sdr.audit.export`.
    Every `run/1` clause of every other task of `lib/mix/tasks` begins,
    outside any rescue, with the terminal fixed-code refusal; only that extracted guard
    is ever evaluated here, so no task body runs. A partial or malformed
    switch is a refusal, never ordinary permission.

  Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Outreach
  alias SdrAgent.Prototype.Output
  alias SdrAgent.Sales

  @op Mix.Tasks.Sdr.Prototype.Op
  @label "UNVERIFIED (PROTOTYPE)"
  @block_keys ["dataset_class", "entry_sha256", "instance_id", "label", "policy_id"]
  @pending_fields ~w(revision_id draft_id revision_number subject body_text revision_content_sha256
                     canonicalization_version recipient_contact_id recipient_email state)
  @approval_fields ~w(id verdict approval_mode delegation_id draft_revision_id revision_content_sha256)
  @receipt_fields ~w(id status operation_id rendered_sha256 rendered_bytes)
  @run_fields ~w(id status stop_reason release_decision)
  @nil_uuid "00000000-0000-0000-0000-000000000000"

  # ------------------------------------------------------------------ ordinary fixtures

  defp ordinary_drafted! do
    ctx = demo!(nil)
    Map.merge(ctx, drafted!(ctx))
  end

  defp rendered_bytes!(ctx, receipt) do
    {:ok, bytes} = SdrAgent.Audit.read_content(receipt.rendered_sha256, actor: ctx.admin)
    bytes
  end

  defp captured!(ctx) do
    approval = approve!(ctx, ctx.draft, operator!(ctx, :reviewer))
    delivery = delivery_of!(ctx, approval)
    deliver!()
    receipt = Enum.find(receipts!(ctx, delivery), &(&1.kind == :captured))
    assert receipt, "the ordinary delivery recorded no captured receipt"
    %{approval: approval, delivery: delivery, receipt: receipt}
  end

  # ------------------------------------------------------------------ typed digests (ordinary records)

  test "check_revision: canonical {subject, body_text} = DraftRevision.content_sha256; a tamper is a mismatch" do
    %{revision: revision} = ordinary_drafted!()

    assert revision.content_sha256 ==
             Canonical.sha256(%{subject: revision.subject, body_text: revision.body_text})

    assert Output.check_revision(revision) == :ok

    for tampered <- [
          %{revision | subject: revision.subject <> " "},
          %{revision | body_text: revision.body_text <> "\n"},
          %{revision | content_sha256: :crypto.hash(:sha256, "other")},
          %{revision | canonicalization_version: "sdr-canonical-json/0"}
        ] do
      assert Output.check_revision(tampered) == {:error, :digest_mismatch}
    end
  end

  test "check_approval: Approval.revision_content_sha256 = the bound DraftRevision.content_sha256" do
    ctx = ordinary_drafted!()
    approval = approve!(ctx, ctx.draft, operator!(ctx, :reviewer))
    assert approval.revision_content_sha256 == ctx.revision.content_sha256
    assert Output.check_approval(approval, ctx.revision) == :ok

    tampered = %{approval | revision_content_sha256: :crypto.hash(:sha256, "other")}
    assert Output.check_approval(tampered, ctx.revision) == {:error, :digest_mismatch}

    other_revision = %{ctx.revision | id: Ecto.UUID.generate()}
    assert Output.check_approval(approval, other_revision) == {:error, :digest_mismatch}

    tampered_revision = %{ctx.revision | subject: ctx.revision.subject <> "!"}
    assert Output.check_approval(approval, tampered_revision) == {:error, :digest_mismatch}
  end

  test "check_receipt: sha256(rendered bytes) = DeliveryReceipt.rendered_sha256; bytes unchanged, no label" do
    ctx = ordinary_drafted!()
    %{receipt: receipt, delivery: delivery} = captured!(ctx)
    bytes = rendered_bytes!(ctx, receipt)

    assert :crypto.hash(:sha256, bytes) == receipt.rendered_sha256
    assert receipt.rendered_sha256 == outreach!(ctx, delivery).rendered_sha256
    assert Output.check_receipt(receipt, bytes) == :ok
    refute bytes =~ @label

    flipped = binary_part(bytes, 0, byte_size(bytes) - 1) <> "X"
    assert Output.check_receipt(receipt, flipped) == {:error, :digest_mismatch}
  end

  test "the two digests are typed: neither ever stands in for the other" do
    ctx = ordinary_drafted!()
    %{receipt: receipt} = captured!(ctx)
    bytes = rendered_bytes!(ctx, receipt)
    revision = ctx.revision

    refute receipt.rendered_sha256 == revision.content_sha256

    assert Output.check_revision(%{revision | content_sha256: receipt.rendered_sha256}) ==
             {:error, :digest_mismatch}

    canonical = Canonical.encode!(%{subject: revision.subject, body_text: revision.body_text})

    assert Output.check_receipt(%{receipt | rendered_sha256: revision.content_sha256}, bytes) ==
             {:error, :digest_mismatch}

    assert Output.check_receipt(%{receipt | rendered_sha256: revision.content_sha256}, canonical) ==
             {:error, :digest_mismatch}
  end

  test "outside prototype runtime no view and no bundle is produced" do
    ctx = ordinary_drafted!()
    reviewer = operator!(ctx, :reviewer)

    for kind <- Output.kinds() do
      assert Output.view(kind, ctx.draft.id, reviewer) == {:error, :not_prototype_runtime}
    end

    assert Output.write_bundle(
             [{:pending_revision, ctx.draft.id}],
             reviewer,
             Ecto.UUID.generate()
           ) ==
             {:error, :not_prototype_runtime}
  end

  # ------------------------------------------------------------------ op argument contract (Q1)

  defp op_parse(argv), do: call(@op, :parse, [argv])

  test "Q1: op approve requires the reviewed revision, its digest and the recipient email" do
    revision = Ecto.UUID.generate()
    sha = String.duplicate("ab", 32)
    email = "reviewed@example.test"
    base = ["approve", "--agent", "claude_code"]
    full = base ++ ["--revision", revision, "--revision-sha256", sha, "--recipient-email", email]

    assert {:ok, parsed} = op_parse(full)
    assert parsed.command == :approve

    assert {parsed.revision, parsed.revision_sha256, parsed.recipient_email} ==
             {revision, sha, email}

    for drop <- ["--revision", "--revision-sha256", "--recipient-email"] do
      index = Enum.find_index(full, &(&1 == drop))
      argv = List.delete_at(List.delete_at(full, index), index)
      assert op_parse(argv) == {:error, :invalid_arguments}, "accepted without #{drop}"
    end

    assert op_parse(
             base ++
               ["--revision", "not-a-uuid", "--revision-sha256", sha, "--recipient-email", email]
           ) ==
             {:error, :invalid_arguments}

    assert op_parse(
             base ++
               ["--revision", revision, "--revision-sha256", "abc", "--recipient-email", email]
           ) ==
             {:error, :invalid_arguments}

    assert op_parse(
             base ++ ["--revision", revision, "--revision-sha256", sha, "--recipient-email", ""]
           ) ==
             {:error, :invalid_arguments}
  end

  test "op commands: closed set, --agent required, ids validated, unknown switches refused" do
    id = Ecto.UUID.generate()

    assert {:ok, %{command: :review, draft: ^id}} =
             op_parse(["review", "--agent", "codex_cli", "--draft", id])

    assert {:ok, %{command: :assign}} =
             op_parse(["assign", "--agent", "claude_code", "--lead", id, "--campaign", id])

    assert {:ok, %{command: :revoke, approval: ^id}} =
             op_parse(["revoke", "--agent", "claude_code", "--approval", id])

    assert op_parse(["review", "--draft", id]) == {:error, :invalid_arguments}
    assert op_parse(["review", "--agent", "other", "--draft", id]) == {:error, :invalid_arguments}
    assert op_parse(["review", "--agent", "claude_code"]) == {:error, :invalid_arguments}
    assert op_parse(["delete", "--agent", "claude_code"]) == {:error, :invalid_arguments}

    assert op_parse(["review", "--agent", "claude_code", "--draft", id, "--extra", "x"]) ==
             {:error, :invalid_arguments}

    assert op_parse([]) == {:error, :invalid_arguments}
  end

  # ------------------------------------------------------------------ the Mix task allow-list

  # Codex S4 RED ruling 6: a CLOSED allow-list of exact task names; no
  # prefix grants anything to a future task.
  @allow_listed ~w(sdr.prototype.setup sdr.prototype.provision sdr.prototype.import
                   sdr.prototype.op sdr.prototype.serve sdr.audit.export)
  @switch_vars ["SDR_PROTOTYPE", "SDR_PROTOTYPE_INSTANCE"]

  defp tasks do
    for path <- Path.wildcard("lib/mix/tasks/*.ex") do
      ast = path |> File.read!() |> Code.string_to_quoted!()
      {_ast, module} = Macro.prewalk(ast, nil, &defmodule_name/2)
      assert module, "#{path} defines no module"
      %{path: path, module: module, name: Mix.Task.task_name(module), ast: ast}
    end
  end

  defp defmodule_name({:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil),
    do: {node, Module.concat(parts)}

  defp defmodule_name(node, acc), do: {node, acc}

  defp strip(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _meta -> [] end))

  # The one terminal refusal: a fixed Mix.raise whenever the helper does not
  # return :ok. A bare, ignored task_refusal/1 call does not refuse anything.
  defp expected_guard(name) do
    strip(
      quote do
        if SdrAgent.Prototype.Output.task_refusal(unquote(name)) != :ok,
          do: Mix.raise("prototype runtime: task refused")
      end
    )
  end

  # Every `def run/1` clause, as its keyword blocks (`[do: body]`, or with
  # `rescue:` and the like, which a terminal guard must not sit inside).
  defp run_clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:run, _, [_arg]}, blocks]} = node, acc when is_list(blocks) ->
          {node, [blocks | acc]}

        {:def, _, [{:when, _, [{:run, _, [_arg]} | _]}, blocks]} = node, acc
        when is_list(blocks) ->
          {node, [blocks | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp first_expr({:__block__, _, [first | _]}), do: first
  defp first_expr(expr), do: expr

  # The clause is a plain do-block (the guard is not inside a rescue) whose
  # first statement is exactly the terminal guard.
  defp guarded?([do: body], name), do: strip(first_expr(body)) == expected_guard(name)
  defp guarded?(_blocks, _name), do: false

  # Runs `fun` with exactly `vars` of the switch set (the others unset), then
  # restores the previous values.
  defp with_env(vars, fun) do
    previous = Map.new(@switch_vars, &{&1, System.get_env(&1)})
    Enum.each(@switch_vars, &System.delete_env/1)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp full_switch,
    do: [{"SDR_PROTOTYPE", "d237-prototype/1"}, {"SDR_PROTOTYPE_INSTANCE", Ecto.UUID.generate()}]

  test "every run/1 clause of every non-allow-listed task begins with the terminal refusal" do
    all = tasks()
    assert Enum.any?(all, &(&1.name == "sdr.demo.seed"))
    assert Enum.any?(all, &(&1.name == "sdr.audit.export"))

    for task <- all, task.name not in @allow_listed do
      clauses = run_clauses(task.ast)
      assert clauses != [], "#{task.path}: no run/1"

      for blocks <- clauses do
        assert guarded?(blocks, task.name),
               "#{task.path}: a run/1 clause does not begin with the terminal prototype " <>
                 "refusal outside any rescue"
      end
    end
  end

  test "the extracted guard alone, with the switch set, raises the fixed refusal; no task body runs" do
    for task <- tasks(), task.name not in @allow_listed do
      clauses = run_clauses(task.ast)
      assert clauses != [], "#{task.path}: no run/1"

      for blocks <- clauses do
        # Only the exact expected guard is ever evaluated, never any other
        # first statement, so a missing guard cannot reach real task work.
        assert guarded?(blocks, task.name), "#{task.path}: no terminal guard to evaluate"
        guard = first_expr(blocks[:do])

        with_env(full_switch(), fn ->
          assert_raise Mix.Error, ~r/\Aprototype runtime: task refused\z/, fn ->
            Code.eval_quoted(guard)
          end
        end)

        with_env([], fn -> assert {nil, _binding} = Code.eval_quoted(guard) end)
      end
    end
  end

  test "task_refusal: a closed allow-list of exact names; every other task is refused with the switch" do
    with_env(full_switch(), fn ->
      for name <- @allow_listed do
        assert Output.task_refusal(name) == :ok, "#{name} is allow-listed but refused"
      end

      for name <- ~w(sdr.demo.seed sdr.audit.verify sdr.prototype.other sdr.prototype ecto.migrate
                     phx.server) ++ [""] do
        assert Output.task_refusal(name) == {:error, :prototype_task_refused},
               "#{inspect(name)} was not refused with the switch set"
      end
    end)
  end

  test "task_refusal: a partial or malformed switch is a refusal, never ordinary permission" do
    for vars <- [
          [{"SDR_PROTOTYPE", "d237-prototype/1"}],
          [{"SDR_PROTOTYPE_INSTANCE", Ecto.UUID.generate()}],
          [{"SDR_PROTOTYPE", "garbage"}],
          [{"SDR_PROTOTYPE", ""}],
          [{"SDR_PROTOTYPE_INSTANCE", "not-a-uuid"}]
        ] do
      with_env(vars, fn ->
        assert Output.task_refusal("sdr.demo.seed") == {:error, :prototype_task_refused},
               "a partial switch (#{inspect(Enum.map(vars, &elem(&1, 0)))}) was ordinary permission"
      end)
    end
  end

  test "the runtime doc names the closed allow-list exactly, with no prefix permission" do
    assert Output.allowed_tasks() == @allow_listed
    doc = File.read!("docs/product/d237/prototype-runtime.md")

    for name <- @allow_listed do
      assert doc =~ "`#{name}`", "the runtime doc does not name `#{name}` on the allow-list"
    end

    refute doc =~ "sdr.prototype.*", "the runtime doc grants a prefix-based task permission"
  end

  test "without the switch, in ordinary runtime, no task is refused" do
    with_env([], fn ->
      for task <- tasks() do
        assert Output.task_refusal(task.name) == :ok, "#{task.name} refused in ordinary runtime"
      end
    end)
  end

  # ------------------------------------------------------------------ prototype runtime: views

  defp bundle_dir!(context) do
    # Output creates the bundle directory inside a root this test owns.
    dir = Path.join(exclusive_root!("d237-bundles"), "bundles")
    put_env!(SdrAgent.Prototype.Output, bundle_dir: dir)
    Map.put(context, :bundle_dir, dir)
  end

  defp block!(view) do
    assert view["schema"] == "d237-output/2"
    block = view["prototype"]
    assert is_map(block) and Enum.sort(Map.keys(block)) == @block_keys
    assert block["label"] == @label
    assert block["policy_id"] == "d237-prototype/1"
    assert block["dataset_class"] == "real_prototype"
    block
  end

  test "the pending-revision view: current revision, recipient id and exact email, digest, no approval wording" do
    ctx = prototype_drafted!()
    assert {:ok, view} = Output.view(:pending_revision, ctx.draft.id, ctx.operator)
    block!(view)
    assert view["kind"] == "pending_revision"
    fields = view["fields"]
    assert Enum.sort(Map.keys(fields)) == Enum.sort(@pending_fields)
    assert fields["revision_id"] == ctx.revision.id
    assert fields["draft_id"] == ctx.draft.id
    assert fields["subject"] == ctx.revision.subject
    assert fields["body_text"] == ctx.revision.body_text
    assert fields["revision_content_sha256"] == hex(ctx.revision.content_sha256)
    assert fields["recipient_contact_id"] == ctx.contact.id
    assert fields["recipient_email"] == to_string(ctx.contact.email)
    assert fields["state"] == "pending_review"

    wording = view |> Jason.encode!() |> String.downcase()
    refute wording =~ "approv"
  end

  test "a tampered stored revision field is :digest_mismatch, and nothing is serialized" do
    ctx = prototype_drafted!()

    tamper!("UPDATE draft_revisions SET subject = subject || ' (edited)' WHERE id = $1", [
      Ecto.UUID.dump!(ctx.revision.id)
    ])

    assert Output.view(:pending_revision, ctx.draft.id, ctx.operator) ==
             {:error, :digest_mismatch}
  end

  test "a live binding mismatch refuses every view" do
    ctx = prototype_drafted!()
    assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok

    for kind <- Output.kinds() do
      assert Output.view(kind, ctx.draft.id, ctx.operator) == {:error, :binding_mismatch}
    end
  end

  test "a non-operator actor gets no view in prototype runtime" do
    ctx = prototype_drafted!()

    for actor <- [
          ctx.admin,
          ctx.agent,
          %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}
        ] do
      assert Output.view(:pending_revision, ctx.draft.id, actor) == {:error, :forbidden}
    end
  end

  test "the approval view: delegated mode, delegation id, the revision's digest; no message bytes" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    assert {:ok, view} = Output.view(:approval, approval.id, ctx.operator)
    block!(view)
    fields = view["fields"]
    assert Enum.sort(Map.keys(fields)) == Enum.sort(@approval_fields)
    assert fields["approval_mode"] == "delegated_machine"
    assert fields["delegation_id"] == ctx.operator.id
    assert fields["draft_revision_id"] == ctx.revision.id
    assert fields["revision_content_sha256"] == hex(ctx.revision.content_sha256)
    assert fields["verdict"] == "approved"
  end

  test "the receipt view: the captured rendered bytes and their digest, unchanged, block outside them" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    deliver!()
    receipt = Enum.find(receipts!(ctx, delivery_of!(ctx, approval)), &(&1.kind == :captured))
    assert receipt, "no captured receipt"
    stored = rendered_bytes!(ctx, receipt)

    assert {:ok, view} = Output.view(:receipt, receipt.id, ctx.operator)
    block!(view)
    fields = view["fields"]
    assert Enum.sort(Map.keys(fields)) == Enum.sort(@receipt_fields)
    assert fields["rendered_bytes"] == stored
    assert fields["rendered_sha256"] == hex(receipt.rendered_sha256)
    assert hex(:crypto.hash(:sha256, fields["rendered_bytes"])) == fields["rendered_sha256"]
    assert fields["status"] == "captured"
    refute fields["rendered_bytes"] =~ @label
  end

  test "the run view: id, status, stop reason, release decisions" do
    ctx = prototype_drafted!()
    assert {:ok, view} = Output.view(:run, ctx.run.id, ctx.operator)
    block!(view)
    assert Enum.sort(Map.keys(view["fields"])) == Enum.sort(@run_fields)
    assert view["fields"]["id"] == ctx.run.id
  end

  # ------------------------------------------------------------------ the private bundle

  test "write_bundle: exclusive 0600 file in a 0700 directory, each view labelled; an existing path refused",
       context do
    ctx = prototype_drafted!() |> Map.merge(bundle_dir!(context))
    bundle_id = Ecto.UUID.generate()
    items = [{:pending_revision, ctx.draft.id}, {:run, ctx.run.id}]

    assert {:ok, %{bundle_id: ^bundle_id, items: 2}} =
             Output.write_bundle(items, ctx.operator, bundle_id)

    path = Path.join(ctx.bundle_dir, bundle_id <> ".json")
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, %File.Stat{mode: dir_mode}} = File.lstat(ctx.bundle_dir)
    assert Bitwise.band(dir_mode, 0o777) == 0o700

    bundle = path |> File.read!() |> Jason.decode!()
    assert bundle["prototype"]["label"] == @label
    assert length(bundle["items"]) == 2
    Enum.each(bundle["items"], &block!/1)

    before = File.read!(path)

    assert match?({:error, _}, Output.write_bundle(items, ctx.operator, bundle_id)),
           "an existing bundle path was not refused"

    assert File.read!(path) == before
  end

  test "op review writes the bundle and prints only its UUID and item count; no content anywhere",
       context do
    ctx = prototype_drafted!() |> Map.merge(bundle_dir!(context))
    markers = [ctx.revision.subject, ctx.revision.body_text, to_string(ctx.contact.email)]
    parsed = %{command: :review, agent: :claude_code, draft: ctx.draft.id}

    stderr =
      capture_io(:stderr, fn ->
        log =
          capture_log(fn ->
            out =
              capture_io(fn ->
                send(self(), {:result, call(@op, :execute, [parsed, ctx.operator])})
              end)

            send(self(), {:stdout, out})
          end)

        send(self(), {:log, log})
      end)

    assert_received {:stdout, out}
    assert_received {:log, log}
    stdout = out <> stderr
    assert_received {:result, result}

    assert match?({:ok, %{bundle_id: _, items: 2}}, result),
           "op review failed: #{inspect(result)}"

    {:ok, %{bundle_id: bundle_id}} = result
    assert stdout =~ bundle_id
    assert File.exists?(Path.join(ctx.bundle_dir, bundle_id <> ".json"))

    for marker <- markers, channel <- [stdout, log] do
      refute String.contains?(channel, marker), "content reached the content-free channel"
    end
  end

  # ------------------------------------------------------------------ Q1 stale review through op approve

  defp approve_parsed(revision, email),
    do: %{
      command: :approve,
      agent: :claude_code,
      revision: revision.id,
      revision_sha256: hex(revision.content_sha256),
      recipient_email: email
    }

  # The review step of the Q1 tests: the pending-revision view must succeed
  # (an assertion, never a bare match) before its recipient is reused.
  defp reviewed_email!(ctx) do
    result = Output.view(:pending_revision, ctx.draft.id, ctx.operator)

    assert match?(
             {:ok, %{"fields" => %{"recipient_email" => email}}} when is_binary(email),
             result
           ),
           "the review step (pending-revision view) failed: #{inspect(result)}"

    {:ok, %{"fields" => %{"recipient_email" => email}}} = result
    email
  end

  test "Q1: review, then the contact's email changes, then approve with the reviewed address → stale",
       context do
    ctx = prototype_drafted!() |> Map.merge(bundle_dir!(context))
    reviewed = reviewed_email!(ctx)

    {:ok, _} =
      Sales.update(ctx.contact, :change_email, %{email: "changed-after-review@example.test"},
        actor: ctx.admin
      )

    result = call(@op, :execute, [approve_parsed(ctx.revision, reviewed), ctx.operator])

    assert result == {:error, :stale_review},
           "approved against a changed recipient: #{inspect(result)}"

    assert approvals!(ctx, ctx.draft) == []
  end

  test "Q1: review, then a new revision, then approve with the reviewed revision → stale",
       context do
    ctx = prototype_drafted!() |> Map.merge(bundle_dir!(context))
    reviewed = reviewed_email!(ctx)
    PrototypeFixtures.leave_runtime()

    {:ok, _edited} =
      Outreach.edit_draft(
        ctx.draft,
        %{subject: "Edited after review", body_text: ctx.revision.body_text},
        actor: ctx.admin
      )

    enter_window!(ctx.fixture)
    result = call(@op, :execute, [approve_parsed(ctx.revision, reviewed), ctx.operator])
    assert result == {:error, :stale_review}, "approved a superseded revision: #{inspect(result)}"
    assert approvals!(ctx, ctx.draft) == []
  end

  test "Q1: op approve with the reviewed inputs grants exactly that revision to that address",
       context do
    ctx = prototype_drafted!() |> Map.merge(bundle_dir!(context))
    reviewed = reviewed_email!(ctx)

    assert {:ok, %{id: approval_id}} =
             call(@op, :execute, [approve_parsed(ctx.revision, reviewed), ctx.operator])

    [approval] = approvals!(ctx, ctx.draft)
    assert approval.id == approval_id
    assert to_string(approval.recipient_email) == reviewed
    assert approval.draft_revision_id == ctx.revision.id
    refute approval_id == @nil_uuid
  end
end
