defmodule SdrAgentWeb.AuditedViewTest do
  @moduledoc """
  The console's audited read path: an auditor's view is recorded as an
  AuditAccess before it is served and fails closed when the record cannot
  be written; other roles are not recorded for record views; payload
  content is read only through `SdrAgent.Audit.read_content/2`.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.Scope

  test "an auditor's view is recorded with the records shown", ctx do
    auditor = user!(ctx, :auditor)
    scope = Scope.for_user(auditor)

    assert :ok = AuditedView.record(scope, "SdrAgent.Sales.Lead", ["a", "b"], "test view")

    assert [%{access_kind: :record_view, target_ref: "a,b", purpose: "test view"}] =
             accesses_of(ctx, auditor)
  end

  test "an access that cannot be recorded is an error (the caller serves nothing)", ctx do
    scope = Scope.for_user(user!(ctx, :auditor))
    assert {:error, _reason} = AuditedView.record(scope, "SdrAgent.Sales.Lead", nil, "test view")
  end

  test "admins and reviewers are not recorded for record views", ctx do
    for role <- [:admin, :reviewer] do
      user = user!(ctx, role)
      assert :ok = AuditedView.record(Scope.for_user(user), "SdrAgent.Sales.Lead", "x", "view")
      assert accesses_of(ctx, user) == []
    end
  end

  test "payload content is read through the audited read, as hex or binary", ctx do
    %{delivery: op} = approved!(ctx)
    assert %{success: 1} = deliver!()
    op = outreach!(ctx, op)
    reviewer = user!(ctx, :reviewer)

    assert {:ok, content} =
             AuditedView.read_content(Scope.for_user(reviewer), hex(op.rendered_sha256), "test")

    assert :crypto.hash(:sha256, content) == op.rendered_sha256
    assert [%{access_kind: :payload_view}] = accesses_of(ctx, reviewer)
  end

  test "error messages never echo raw exception internals" do
    internal = %RuntimeError{message: "ERROR 42P01 relation secret_table does not exist"}
    message = AuditedView.error_message(Ash.Error.to_error_class(internal))
    refute message =~ "secret_table"

    refute AuditedView.error_message({:crash, %{pid: self(), internal: "secret_table"}}) =~
             "secret_table"

    assert AuditedView.error_message(%Ash.Error.Forbidden{}) =~ "Not permitted"
  end
end
