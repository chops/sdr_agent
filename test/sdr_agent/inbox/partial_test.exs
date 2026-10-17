defmodule SdrAgent.Inbox.PartialTest do
  @moduledoc """
  C1-02 truthful refresh failures. The selector is a closed, compile-time
  test seam, not a configurable producer/module or production error bypass.
  Real database deadline/cancellation proofs are separate from this seam.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, operator!: 2]

  for mode <- [:returned, :raised, :timeout] do
    test "#{mode} draft-list failure retains fresh Failure rows but no draft number", ctx do
      %{draft: draft} = drafted!(ctx)
      failure = failure!(ctx)
      session = session!(ctx.admin)

      assert {:ok, page} = refresh(session, test_fault: {:draft_list, unquote(mode)})
      assert page.completeness == :partial
      assert Enum.map(page.items, & &1.subject_ref.id) == [failure.id]
      refute Enum.any?(page.items, &(&1.subject_ref.id == draft.id))
      assert %{status: :unavailable, value: nil} = page.totals.pending_email_drafts
      assert total!(page, :live_failures) == 1
      assert page.errors != []
      refute inspect(page) =~ "RuntimeError"
      refute inspect(page) =~ "SELECT"
    end

    test "#{mode} Failure-list failure retains drafts, never claiming empty success", ctx do
      %{draft: draft} = drafted!(ctx)
      failure!(ctx)
      session = session!(ctx.admin)

      assert {:ok, page} = refresh(session, test_fault: {:failure_list, unquote(mode)})
      assert page.completeness == :partial
      assert Enum.map(page.items, & &1.subject_ref.id) == [draft.id]
      assert %{status: :unavailable, value: nil} = page.totals.live_failures
      assert total!(page, :pending_email_drafts) == 1
    end

    for metric <- [:pending_email_drafts, :live_failures, :local_captures_this_week] do
      test "#{mode} #{metric} count failure clears its number but keeps fresh authorized rows",
           ctx do
        failure = failure!(ctx)
        session = session!(ctx.admin)

        assert {:ok, page} = refresh(session, test_fault: {unquote(metric), unquote(mode)})
        assert page.completeness == :partial
        assert Enum.map(page.items, & &1.subject_ref.id) == [failure.id]
        assert %{status: :unavailable, value: nil} = Map.fetch!(page.totals, unquote(metric))

        assert Enum.all?(Map.delete(page.totals, unquote(metric)), fn {_key, value} ->
                 value.status == :ready
               end)

        assert page.errors != []
      end
    end

    test "#{mode} auditor append failure withholds the whole page and all numbers", ctx do
      failure!(ctx)
      session = session!(operator!(ctx, :auditor))

      assert {:error, :audit_unavailable} =
               refresh(session, test_fault: {:audit_append, unquote(mode)})

      assert events_of_type(ctx.tenant, "audit.access.record_view") == []
    end
  end

  test "unknown fault selectors are refused, never dynamically dispatched", ctx do
    session = session!(ctx.admin)

    for selector <- [
          {:any_module, :returned},
          {:failure_list, :run_arbitrary},
          "Elixir.System",
          fn -> :ok end
        ] do
      assert {:error, :invalid_input} = refresh(session, test_fault: selector)
    end
  end
end
