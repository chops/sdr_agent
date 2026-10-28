defmodule SdrAgent.Prototype.ResearchImportBodyTest do
  @moduledoc """
  S3's bodies of S1's `:import` shells (Codex ownership ruling d4196c02),
  reached directly through `SdrAgent.Research.record_dossier_entry/2` and
  `record_dossier_source/2` as the resolved operator, the way
  `SdrAgent.Prototype.DossierImport` calls them inside a row transaction:

  - `DossierEntry :import` accepts the row's lead, account, contact, the
    dossier and spot-check digests, the row id, the three contact labels
    and the claims and notes Payload digests; the importing delegation is
    the acting operator, never caller-supplied; it appends one
    `research.dossier_entry.imported` event attributed to the delegation;
    a second entry for the same `(dossier_sha256, row_id)` is refused
    (replay is the coordinator's decision, before any write);
  - `DossierSource :import` accepts the source fields and its verified
    excerpt Payload digest, appends one `research.dossier_source.imported`
    event, and is refused for an entry of another lead.

  The lead, account and contact are arranged with ordinary fixtures before
  entering prototype runtime; the Payloads are stored through S1's scoped
  `:store_prototype_input`. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Audit.Checks.PrototypeInputScope
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Research
  alias SdrAgent.SalesFixtures

  setup do
    fx = bound!(enter_runtime: false)
    lead = SalesFixtures.lead!(fx.tenant)
    other_lead = SalesFixtures.lead!(fx.tenant)
    enter!(fx)

    %{
      fx: fx,
      actor: fx.actor,
      tenant: fx.tenant,
      lead: lead,
      other_lead: other_lead,
      claims: store!(fx, :dossier_claims, ~s({"claims":[]})),
      notes: store!(fx, :dossier_notes, ~s({"why_fit":"Synthetic."})),
      excerpt: store!(fx, :dossier_excerpts, "Acme 1 has a team of 24 people.")
    }
  end

  # One Payload through S1's scoped operator store.
  defp store!(fx, purpose, content) do
    sha = :crypto.hash(:sha256, content)

    scope =
      PrototypeInputScope.context(%{
        tenant_id: fx.tenant.id,
        delegation_id: fx.actor.id,
        purpose: purpose,
        sha256s: [sha]
      })

    result =
      Payload
      |> Ash.Changeset.for_create(
        :store_prototype_input,
        %{content: content, content_type: "text/plain"},
        actor: fx.actor,
        context: scope
      )
      |> Ash.create()

    assert match?({:ok, _}, result), "prerequisite: the scoped store returned #{inspect(result)}"
    sha
  end

  defp entry_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        lead_id: ctx.lead.id,
        account_id: ctx.lead.account_id,
        contact_id: ctx.lead.contact_id,
        dossier_sha256: String.duplicate("a", 64),
        row_id: "row-1",
        spotcheck_sha256: String.duplicate("b", 64),
        email_kind: :personal_work,
        contact_classification: :unverified,
        contact_confidence: :high,
        claims_sha256: ctx.claims,
        notes_sha256: ctx.notes
      },
      overrides
    )
  end

  defp source_attrs(ctx, entry, overrides \\ %{}) do
    Map.merge(
      %{
        entry_id: entry.id,
        lead_id: ctx.lead.id,
        source_id: "s2",
        original_url: "https://www.acme1.test/about",
        final_url: "https://www.acme1.test/about",
        source_type: :company_site,
        retrieved_on: ~D[2026-10-26],
        checked_at: ~U[2026-10-27 16:00:00.000000Z],
        content_sha256: ctx.excerpt
      },
      overrides
    )
  end

  defp entry!(ctx, overrides \\ %{}) do
    result = Research.record_dossier_entry(entry_attrs(ctx, overrides), actor: ctx.actor)
    assert match?({:ok, _}, result), "record_dossier_entry/2 returned #{inspect(result)}"
    {:ok, entry} = result
    entry
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  describe "DossierEntry :import" do
    test "writes the row as the operator's delegation, with one attributed event", ctx do
      entry = entry!(ctx)

      assert {entry.tenant_id, entry.delegation_id, entry.lead_id, entry.row_id} ==
               {ctx.tenant.id, ctx.actor.id, ctx.lead.id, "row-1"}

      assert {entry.claims_sha256, entry.notes_sha256} == {ctx.claims, ctx.notes}

      assert [event] = events_of_type(ctx.tenant, "research.dossier_entry.imported")
      assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
    end

    # Codex 2cf8613e: tested against the real positive, not a blanket stub
    # refusal: the forged metadata is refused, and the same attributes
    # without it write the row as the operator's delegation in its tenant.
    test "a caller-supplied delegation or tenant is not an input; the real positive is unforged",
         ctx do
      for extra <- [%{delegation_id: Ecto.UUID.generate()}, %{tenant_id: Ecto.UUID.generate()}] do
        result = Research.record_dossier_entry(entry_attrs(ctx, extra), actor: ctx.actor)
        assert match?({:error, _}, result), "record_dossier_entry/2 returned #{inspect(result)}"
      end

      assert count("dossier_entries") == 0

      entry = entry!(ctx)
      assert {entry.delegation_id, entry.tenant_id} == {ctx.actor.id, ctx.tenant.id}
      assert count("dossier_entries") == 1
    end

    test "a second entry for the same dossier row is refused, writing nothing", ctx do
      entry!(ctx)
      result = Research.record_dossier_entry(entry_attrs(ctx), actor: ctx.actor)
      assert match?({:error, _}, result), "a second entry returned #{inspect(result)}"
      assert count("dossier_entries") == 1
    end
  end

  describe "DossierSource :import" do
    test "writes the verified-excerpt source with one event", ctx do
      entry = entry!(ctx)
      result = Research.record_dossier_source(source_attrs(ctx, entry), actor: ctx.actor)
      assert match?({:ok, _}, result), "record_dossier_source/2 returned #{inspect(result)}"
      {:ok, source} = result

      assert {source.tenant_id, source.entry_id, source.lead_id, source.source_id} ==
               {ctx.tenant.id, entry.id, ctx.lead.id, "s2"}

      assert source.content_sha256 == ctx.excerpt
      assert [event] = events_of_type(ctx.tenant, "research.dossier_source.imported")
      assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
    end

    test "a source for an entry of another lead is refused, writing nothing", ctx do
      entry = entry!(ctx)
      attrs = source_attrs(ctx, entry, %{lead_id: ctx.other_lead.id})
      result = Research.record_dossier_source(attrs, actor: ctx.actor)
      assert match?({:error, _}, result), "record_dossier_source/2 returned #{inspect(result)}"
      assert count("dossier_sources") == 0
    end
  end
end
