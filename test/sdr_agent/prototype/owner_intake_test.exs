defmodule SdrAgent.Prototype.OwnerIntakeTest do
  @moduledoc "Owner intake through the real domain coordinator; synthetic data only."
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.HostedOwnerFixtures, as: H

  @intake SdrAgent.Prototype.OwnerIntake

  setup do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    reviewer = human(:reviewer, ctx.fx.tenant)
    H.enter!(ctx)
    Map.merge(ctx, %{user: enrolled.user, owner: enrolled.owner, reviewer: reviewer})
  end

  defp params(email \\ "jordan@intake.test") do
    %{
      "company_name" => "Intake Company",
      "domain" => "intake.test",
      "website_url" => "https://intake.test",
      "first_name" => "Jordan",
      "last_name" => "Testperson",
      "title" => "Founder",
      "email" => email,
      "sources" => [
        %{
          "url" => "https://intake.test",
          "source_type" => "company_site",
          "retrieved_on" => "2026-11-01",
          "excerpt" => "  Jordan Testperson, Founder. jordan@intake.test\n"
        }
      ]
    }
  end

  defp preview(params, user), do: call(@intake, :preview, [params, user])
  defp commit(params, preview, user), do: call(@intake, :commit, [params, preview, user])

  defp save!(params, user) do
    assert {:ok, preview} = preview(params, user)
    assert {:ok, :created, ids} = commit(params, preview, user)
    ids
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM " <> table)
    n
  end

  defp counts, do: Map.new(~w(accounts contacts leads payloads audit_events), &{&1, count(&1)})

  test "preview is read-only and exposes normalized form values", ctx do
    before = counts()
    input = %{params() | "domain" => "INTAKE.TEST", "email" => "JORDAN@INTAKE.TEST"}
    assert {:ok, p} = preview(input, ctx.user)
    assert p.mode == :create
    assert p.account_id == nil
    assert p.input["domain"] == "intake.test"
    assert p.input["email"] == "jordan@intake.test"
    assert byte_size(p.submission_sha256) == 32
    assert counts() == before
  end

  test "save creates new manual lead and immutable honest owner provenance", ctx do
    ids = save!(params(), ctx.user)
    assert {:ok, lead} = SdrAgent.Sales.fetch(SdrAgent.Sales.Lead, ids.lead_id, actor: ctx.user)
    assert lead.status == :new
    assert lead.source == :manual

    %{rows: [[owner_id, binding_id, relocation_id, classification]]} =
      Repo.query!(
        "SELECT owner_user_id, binding_id, relocation_id, classification FROM owner_prospect_intakes WHERE id=$1",
        [Ecto.UUID.dump!(ids.entry_id)]
      )

    assert Ecto.UUID.cast!(owner_id) == ctx.user.id
    assert Ecto.UUID.cast!(binding_id) == ctx.fx.binding.id
    assert Ecto.UUID.cast!(relocation_id) == ctx.relocation.id
    assert classification == "unverified"
    assert count("owner_prospect_sources") == 1
    assert count("dossier_entries") == 0
    assert count("agent_runs") == 0
  end

  test "raw source bytes including spaces and newline survive exact hashing", ctx do
    ids = save!(params(), ctx.user)
    raw = hd(params()["sources"])["excerpt"]

    %{rows: [[hash, bytes]]} =
      Repo.query!(
        "SELECT s.content_sha256,p.content FROM owner_prospect_sources s JOIN payloads p ON p.tenant_id=s.tenant_id AND p.sha256=s.content_sha256 WHERE s.intake_id=$1",
        [Ecto.UUID.dump!(ids.entry_id)]
      )

    assert bytes == raw
    assert hash == :crypto.hash(:sha256, raw)
  end

  test "identical replay uses original ids and writes absolutely nothing", ctx do
    ids = save!(params(), ctx.user)
    before = counts()
    assert {:ok, p} = preview(params(), ctx.user)
    assert p.mode == :replay
    assert {:ok, :replay, ^ids} = commit(params(), p, ctx.user)
    assert counts() == before
    assert count("owner_prospect_intakes") == 1
  end

  test "distinct contacts reuse one company without modifying its row", ctx do
    first = save!(params(), ctx.user)

    %{rows: [before]} =
      Repo.query!("SELECT row_to_json(a) FROM accounts a WHERE id=$1", [
        Ecto.UUID.dump!(first.account_id)
      ])

    input = %{params("alex@intake.test") | "first_name" => "Alex"}
    assert {:ok, p} = preview(input, ctx.user)
    assert p.mode == :reuse
    assert p.account_id == first.account_id
    assert {:ok, :created, second} = commit(input, p, ctx.user)
    assert second.account_id == first.account_id
    refute second.contact_id == first.contact_id
    assert count("accounts") == 1
    assert count("contacts") == 2

    %{rows: [after_row]} =
      Repo.query!("SELECT row_to_json(a) FROM accounts a WHERE id=$1", [
        Ecto.UUID.dump!(first.account_id)
      ])

    assert before == after_row
  end

  test "changed source for an existing email conflicts without partial writes", ctx do
    _ids = save!(params(), ctx.user)
    input = put_in(params(), ["sources", Access.at(0), "excerpt"], "Different source")
    before = counts()
    assert {:error, :intake_conflict} = preview(input, ctx.user)
    assert counts() == before
  end

  test "new company appearing after preview requires re-preview and zero writes", ctx do
    input = params("alex@intake.test")
    assert {:ok, p} = preview(input, ctx.user)
    save!(params(), ctx.user)
    before = counts()
    assert {:error, :preview_stale} = commit(input, p, ctx.user)
    assert counts() == before
  end

  test "changing submitted bytes after preview is stale and writes nothing", ctx do
    assert {:ok, p} = preview(params(), ctx.user)
    before = counts()
    input = %{params() | "first_name" => "Changed"}
    assert {:error, :preview_stale} = commit(input, p, ctx.user)
    assert counts() == before
  end

  test "ordinary reviewer auditor delegated and anonymous actors cannot preview", ctx do
    for actor <- [ctx.reviewer, ctx.fx.auditor, ctx.fx.actor, nil] do
      assert {:error, :forbidden} = preview(params(), actor)
    end
  end

  test "forged tenant and owner identifiers cannot preview", ctx do
    for actor <- [
          %{ctx.user | id: Ecto.UUID.generate()},
          %{ctx.user | tenant_id: Ecto.UUID.generate()}
        ] do
      assert {:error, :forbidden} = preview(params(), actor)
    end
  end

  test "owner revoked after preview cannot commit", ctx do
    assert {:ok, p} = preview(params(), ctx.user)
    assert {:ok, _} = H.disable(ctx, ctx.owner.id, actor: ctx.user)
    before = Map.drop(counts(), ["audit_events"])
    assert {:error, :forbidden} = commit(params(), p, ctx.user)
    assert Map.drop(counts(), ["audit_events"]) == before
  end

  test "arbitrary caller tenant ownership or verified fields are refused", ctx do
    for key <- ~w(tenant_id owner_user_id delegation_id classification trust_level) do
      assert {:error, :invalid_input} = preview(Map.put(params(), key, "forged"), ctx.user)
    end
  end

  test "ASCII-only public hosts refuse IDN IP and special-use hosts", ctx do
    for domain <- ["münich.test", "127.0.0.1", "localhost", "example.local", "x.invalid"] do
      assert {:error, :invalid_input} = preview(%{params() | "domain" => domain}, ctx.user)
    end
  end

  test "work address must match company and must not be a role mailbox", ctx do
    for email <- [
          "jordan@elsewhere.test",
          "hello@intake.test",
          "sales@intake.test",
          "jordan@gmail.com"
        ] do
      assert {:error, :invalid_input} = preview(%{params() | "email" => email}, ctx.user)
    end
  end

  test "source count URL shape future date and exact byte limits are validated", ctx do
    source = hd(params()["sources"])

    cases = [
      [],
      List.duplicate(source, 4),
      [%{source | "url" => "http://intake.test/team"}],
      [%{source | "url" => "https://127.0.0.1/team"}],
      [%{source | "retrieved_on" => "2999-01-01"}],
      [%{source | "excerpt" => String.duplicate("é", 1001)}],
      [%{source | "source_type" => "trusted_owner"}]
    ]

    for sources <- cases do
      assert {:error, :invalid_input} = preview(%{params() | "sources" => sources}, ctx.user)
    end
  end

  test "privacy event payloads contain no submitted names email URLs or excerpts", ctx do
    save!(params(), ctx.user)

    %{rows: rows} =
      Repo.query!(
        "SELECT payload::text FROM audit_events WHERE event_type LIKE 'sales.%' OR event_type LIKE 'research.owner_%'"
      )

    for [payload] <- rows,
        value <- [
          "Jordan",
          "Testperson",
          "jordan@intake.test",
          "https://intake.test",
          "Intake Company"
        ] do
      refute payload =~ value
    end
  end

  test "one retained company source must match the effective website URL", ctx do
    input = put_in(params(), ["sources", Access.at(0), "url"], "https://intake.test/other")
    assert {:error, :website_source_missing} = preview(input, ctx.user)
  end

  test "an empty or arbitrary preview cannot authorize a save", ctx do
    before = counts()
    assert {:error, :preview_stale} = commit(params(), %{}, ctx.user)
    assert counts() == before
  end

  test "direct owner resource create without coordinator context is forbidden", ctx do
    loaded!(SdrAgent.Research.OwnerProspectIntake)
    ids = save!(params(), ctx.user)

    assert {:ok, entry} =
             Ash.get(SdrAgent.Research.OwnerProspectIntake, ids.entry_id, H.kernel(ctx))

    attrs =
      Map.take(entry, [
        :account_id,
        :contact_id,
        :lead_id,
        :binding_id,
        :relocation_id,
        :submission_sha256
      ])

    assert {:error, %Ash.Error.Forbidden{}} =
             SdrAgent.Research.OwnerProspectIntake
             |> Ash.Changeset.for_create(:record, attrs, actor: ctx.user)
             |> Ash.create()
  end

  test "archived company is refused without reactivation or duplicate company", ctx do
    assert :ok = PrototypeFixtures.leave_runtime()
    admin = human(:admin, ctx.fx.tenant)

    assert {:ok, account} =
             SdrAgent.Sales.create_account(
               %{name: "Archived", domain: "intake.test", source: :manual},
               actor: admin
             )

    assert {:ok, _} = SdrAgent.Sales.update(account, :archive, %{}, actor: admin)
    H.enter!(ctx)
    before = counts()
    assert {:error, :account_inactive} = preview(params(), ctx.user)
    assert counts() == before
  end

  test "existing domain suppression prevents owner intake", ctx do
    assert :ok = PrototypeFixtures.leave_runtime()
    admin = human(:admin, ctx.fx.tenant)

    assert {:ok, suppression} =
             SdrAgent.Outreach.suppress(%{scope: :domain, value: "intake.test"},
               actor: admin
             )

    H.enter!(ctx)
    assert SdrAgent.Outreach.SuppressionMatch.covers?(suppression, params()["email"])
    before = counts()
    assert {:error, :suppressed} = preview(params(), ctx.user)
    assert counts() == before
  end

  test "four contacts at one company are permitted without a lifetime quota", ctx do
    for index <- 1..4 do
      input = %{params("person#{index}@intake.test") | "first_name" => "Person#{index}"}
      save!(input, ctx.user)
    end

    assert count("accounts") == 1
    assert count("contacts") == 4
    assert count("leads") == 4
  end

  test "existing email suppression also prevents owner intake", ctx do
    assert :ok = PrototypeFixtures.leave_runtime()
    admin = human(:admin, ctx.fx.tenant)

    assert {:ok, _} =
             SdrAgent.Outreach.suppress(%{scope: :email, value: params()["email"]}, actor: admin)

    H.enter!(ctx)
    before = counts()
    assert {:error, :suppressed} = preview(params(), ctx.user)
    assert counts() == before
  end

  test "a failed authoritative suppression read is not mistaken for no match", ctx do
    before = counts()
    Repo.query!("ALTER TABLE suppressions RENAME TO intake_test_hidden_suppressions")

    try do
      assert {:error, :intake_failed} = preview(params(), ctx.user)
    after
      Repo.query!("ALTER TABLE intake_test_hidden_suppressions RENAME TO suppressions")
    end

    assert counts() == before
  end

  test "a later legacy dossier import still refuses an owner-created company domain", ctx do
    input =
      params()
      |> Map.put("domain", "acme1.test")
      |> Map.put("website_url", "https://acme1.test")
      |> Map.put("email", "newperson@acme1.test")
      |> put_in(["sources", Access.at(0), "url"], "https://acme1.test")

    save!(input, ctx.user)
    [row] = SdrAgent.DossierFixtures.route_rows!([SdrAgent.DossierFixtures.company(1)], ["row-1"])
    before = counts()

    assert {:error, :dossier_conflict} =
             call(SdrAgent.Prototype.DossierImport, :import_row, [row, ctx.fx.actor])

    assert counts() == before
  end

  test "the database refuses dossier provenance on an owner-intake lead", ctx do
    ids = save!(params(), ctx.user)
    content_hash = :crypto.hash(:sha256, hd(params()["sources"])["excerpt"])

    attrs = %{
      lead_id: ids.lead_id,
      account_id: ids.account_id,
      contact_id: ids.contact_id,
      dossier_sha256: String.duplicate("0", 64),
      row_id: "other-origin",
      spotcheck_sha256: String.duplicate("1", 64),
      email_kind: :personal_work,
      contact_classification: :unverified,
      contact_confidence: :low,
      claims_sha256: content_hash,
      notes_sha256: content_hash
    }

    assert {:error, _} = SdrAgent.Research.record_dossier_entry(attrs, actor: ctx.fx.actor)
    assert count("dossier_entries") == 0
    assert count("owner_prospect_intakes") == 1
  end
end
