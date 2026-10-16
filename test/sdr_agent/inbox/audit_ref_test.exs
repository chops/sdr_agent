defmodule SdrAgent.Inbox.AuditRefTest do
  @moduledoc "C1-02 pure bounded auditor reference encoder, before any append."
  use ExUnit.Case, async: true

  test "a reference exceeding the hard byte ceiling is refused without truncation" do
    reference = %{
      version: "c1-inbox-view/1",
      shown: [%{producer: :outreach_drafts, id: String.duplicate("a", 12_001)}],
      metrics: []
    }

    assert Code.ensure_loaded?(SdrAgent.Inbox.AuditRef) and
             function_exported?(SdrAgent.Inbox.AuditRef, :encode, 1),
           "C1-02 bounded auditor ref encoder is not implemented"

    assert {:error, :audit_unavailable} = apply(SdrAgent.Inbox.AuditRef, :encode, [reference])
  end
end
