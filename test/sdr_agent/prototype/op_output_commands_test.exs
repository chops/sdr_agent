defmodule SdrAgent.Prototype.OpOutputCommandsTest do
  @moduledoc """
  `mix sdr.prototype.op review` and `approve` (interfaces r6 IF-5, Q1; S4
  completion, Codex ownership split m_1793755781248705084_8611d47e): the
  operator adapters beyond `output_test.exs`, plus the pure CLI dispatch
  and result mapping.

    * `review --draft ID` writes the private bundle (pending revision and
      run views) through `Output.write_bundle/3` and prints its UUID and
      item count once, as `bundle_written`; an unknown draft refuses
      `:not_found` and writes no bundle.
    * `approve --revision ID --revision-sha256 HEX --recipient-email ADDR`
      passes all three reviewed inputs unchanged to the existing
      `Outreach.approve/3`; a digest that is not the revision's is
      `:stale_review`; an unknown revision is `:not_found`. Neither writes an
      approval.
    * `session_mode/1`: `assign` and `approve` enter Session with the
      insert-only Oban (the grant inserts its delivery job in the same
      transaction); `review` and `seed` enter without it; `reject`, `revoke`
      and `status` stay unimplemented.
    * `op_outcome/2` maps one result to one closed `op_result` line, the id
      being the command's subject input.

  Synthetic fixtures only; no model, API or hosted call.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  @op Mix.Tasks.Sdr.Prototype.Op

  defp bundle_dir! do
    dir = Path.join(exclusive_root!("d237-op-bundles"), "bundles")
    put_env!(SdrAgent.Prototype.Output, bundle_dir: dir)
    dir
  end

  defp approve_parsed(revision_id, sha, email),
    do: %{
      command: :approve,
      agent: :claude_code,
      revision: revision_id,
      revision_sha256: sha,
      recipient_email: email
    }

  defp captured(fun) do
    stderr =
      capture_io(:stderr, fn ->
        log =
          capture_log(fn ->
            out = capture_io(fn -> send(self(), {:result, fun.()}) end)
            send(self(), {:stdout, out})
          end)

        send(self(), {:log, log})
      end)

    assert_received {:result, result}
    assert_received {:stdout, out}
    assert_received {:log, log}
    {result, out <> stderr <> log}
  end

  describe "execute review" do
    test "prints the bundle UUID and item count once, and nothing else of the bundle" do
      ctx = prototype_drafted!()
      dir = bundle_dir!()
      parsed = %{command: :review, agent: :claude_code, draft: ctx.draft.id}

      {result, channels} = captured(fn -> call(@op, :execute, [parsed, ctx.operator]) end)

      assert match?({:ok, %{bundle_id: _, items: 2}}, result), "review failed: #{inspect(result)}"
      {:ok, %{bundle_id: bundle_id}} = result

      assert length(String.split(channels, bundle_id)) == 2,
             "the bundle UUID is not printed exactly once"

      assert File.ls!(dir) == [bundle_id <> ".json"]
    end

    test "an unknown draft is not_found and writes no bundle" do
      ctx = prototype_drafted!()
      dir = bundle_dir!()
      parsed = %{command: :review, agent: :claude_code, draft: Ecto.UUID.generate()}

      {result, _channels} = captured(fn -> call(@op, :execute, [parsed, ctx.operator]) end)

      assert result == {:error, :not_found}
      refute File.exists?(dir) and File.ls!(dir) != []
    end
  end

  describe "execute approve" do
    test "a digest other than the revision's is stale_review, and no approval exists" do
      ctx = prototype_drafted!()
      other = String.duplicate("0", 64)
      refute other == hex(ctx.revision.content_sha256)

      result =
        call(@op, :execute, [
          approve_parsed(ctx.revision.id, other, to_string(ctx.contact.email)),
          ctx.operator
        ])

      assert result == {:error, :stale_review}
      assert approvals!(ctx, ctx.draft) == []
    end

    test "an unknown revision is not_found, and no approval exists" do
      ctx = prototype_drafted!()

      result =
        call(@op, :execute, [
          approve_parsed(
            Ecto.UUID.generate(),
            hex(ctx.revision.content_sha256),
            to_string(ctx.contact.email)
          ),
          ctx.operator
        ])

      assert result == {:error, :not_found}
      assert approvals!(ctx, ctx.draft) == []
    end
  end

  describe "session_mode/1" do
    test "assign and approve enqueue; review and seed do not; the rest stay unimplemented" do
      assert @op.session_mode(:assign) == :enqueue
      assert @op.session_mode(:approve) == :enqueue
      assert @op.session_mode(:review) == :plain
      assert @op.session_mode(:seed) == :plain

      for command <- [:reject, :revoke, :status] do
        assert @op.session_mode(command) == :not_implemented, "#{command} became reachable"
      end
    end
  end

  describe "op_outcome/2" do
    @draft "11111111-1111-4111-8111-111111111111"
    @revision "22222222-2222-4222-8222-222222222222"

    test "a review success is one ok line with the draft id" do
      parsed = %{command: :review, agent: :claude_code, draft: @draft}

      assert @op.op_outcome(parsed, {:ok, %{bundle_id: Ecto.UUID.generate(), items: 2}}) ==
               {:say, :op_result, [command: :review, id: @draft, result: :ok, reason: :none]}
    end

    test "an approve refusal is one refused line with the revision id and its code" do
      parsed = approve_parsed(@revision, String.duplicate("a", 64), "a@example.test")

      for code <- [:stale_review, :not_found, :forbidden, :binding_mismatch] do
        assert @op.op_outcome(parsed, {:error, code}) ==
                 {:say, :op_result,
                  [command: :approve, id: @revision, result: :refused, reason: code]}
      end
    end

    test "a code outside the op reasons, or a malformed result, is an outer abort" do
      parsed = %{command: :review, agent: :claude_code, draft: @draft}
      assert {:abort, _} = @op.op_outcome(parsed, {:error, :something_else})
      assert {:abort, _} = @op.op_outcome(parsed, :ok)
    end
  end
end
