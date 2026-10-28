defmodule SdrAgent.Research do
  @moduledoc """
  Research bounded context (S2): the evidence an agent gathers about a lead
  and the qualification it rests on.

  Resources: `ResearchArtifact`, `EvidenceClaim`, `Qualification`,
  `QualificationEvidence` (all append-only). Research sits above Sales (FKs
  to leads and ICPs; it moves a lead to qualified/disqualified inside the
  qualification create) and Agents (FKs to runs, tool invocations,
  decisions, model invocations), and below Outreach. Full source content is
  stored in the Audit Payload store.

  Public API (every function takes `actor:`; writes run through
  `SdrAgent.Audit.Guard`, so refused auditor mutations are audited):

    * `record_artifact/2` (AGT) — idempotent on lead, URL and content hash;
    * `record_claim/2` (AGT) — grounding-checked against the artifact
      content;
    * `record_qualification/2` (AGT) and `override_qualification/2` (ADM,
      REV) — supersedes lineage, cited evidence;
    * reads (tenant-scoped) — `current_qualification/2`, `fetch/3`,
      `list_records/2`;
    * D-237 (OPR, prototype runtime) — `record_dossier_entry/2` and
      `record_dossier_source/2`, called only by the prototype dossier import.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Research.DossierEntry
  alias SdrAgent.Research.DossierSource
  alias SdrAgent.Research.EvidenceClaim
  alias SdrAgent.Research.Qualification
  alias SdrAgent.Research.ResearchArtifact

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  resources do
    resource SdrAgent.Research.ResearchArtifact
    resource SdrAgent.Research.EvidenceClaim
    resource SdrAgent.Research.Qualification
    resource SdrAgent.Research.QualificationEvidence
    # D-237 (interfaces r6 IF-6): imported prototype dossier rows and sources.
    resource SdrAgent.Research.DossierEntry
    resource SdrAgent.Research.DossierSource
  end

  @doc "AGT: records a retrieved source; `content` is stored in full as a Payload."
  def record_artifact(attrs, opts) do
    GuardedCall.create(ResearchArtifact, :record, attrs, subject(opts, attrs, :lead_id))
  end

  @doc "AGT: records a grounded claim; `content` must be the artifact's stored content."
  def record_claim(attrs, opts) do
    GuardedCall.create(EvidenceClaim, :record, attrs, subject(opts, attrs, :research_artifact_id))
  end

  @doc "AGT: records an agent qualification (`evidence_claim_ids`) and moves the lead."
  def record_qualification(attrs, opts) do
    GuardedCall.create(Qualification, :record, attrs, subject(opts, attrs, :lead_id))
  end

  @doc "ADM, REV: overrides the current qualification of a lead (`supersedes_id`, `reason`)."
  def override_qualification(attrs, opts) do
    GuardedCall.create(Qualification, :override, attrs, subject(opts, attrs, :lead_id))
  end

  @doc "The current qualification of a lead, or `{:ok, nil}`."
  def current_qualification(lead_id, opts) do
    Qualification
    |> Ash.Query.for_read(:current, %{lead_id: lead_id}, actor: Keyword.get(opts, :actor))
    |> Ash.read_one()
  end

  @doc "Reads one Research record of `resource` by id in the actor's tenant."
  def fetch(resource, id, opts), do: GuardedCall.get(resource, id, opts)

  @doc "Lists `resource` records in the actor's tenant (`filter:`, `sort:` options)."
  def list_records(resource, opts), do: GuardedCall.list(resource, opts)

  @doc """
  OPR (D-237, interfaces r6 IF-6; supplement 1 R9): records one imported
  dossier entry through `DossierEntry :import`, as called by
  `SdrAgent.Prototype.DossierImport` (S3) inside its per-row transaction.
  Only the resolved prototype operator passes
  (`SdrAgent.Prototype.Checks.OperatorAction`, `:import_dossier`, the live
  resolver on every call); every other actor is refused with `Forbidden`
  before any changeset is built. Both paths are guarded: a refusal of a
  recognized actor of an initialized tenant chain appends exactly one
  `authz.denied` (`SdrAgent.Audit.Guard.refuse/2`), and the operator's
  `:import` runs as a guarded action, so a later policy denial is audited
  too; missing or non-actor input is refused with no append. The action,
  its body and its policies are S3's; until it exists the operator's call
  fails, never falling back to a raw write.
  """
  @spec record_dossier_entry(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def record_dossier_entry(attrs, opts), do: record_dossier(DossierEntry, attrs, opts)

  @doc """
  OPR (D-237): records one imported dossier source through
  `DossierSource :import`, under the same operator gate as
  `record_dossier_entry/2`.
  """
  @spec record_dossier_source(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def record_dossier_source(attrs, opts), do: record_dossier(DossierSource, attrs, opts)

  if @prototype_compiled do
    # Aliased inside the compiled branch only: the production branch never
    # names the operator check (no unused alias under --warnings-as-errors).
    alias SdrAgent.Prototype.Checks.OperatorAction

    # Two disjoint paths, one guard each (Codex ca4624a1 B): a caller whose
    # operator precheck passes runs the guarded `:import` (a later real
    # policy denial is audited too); every other caller is refused before
    # any changeset.
    defp record_dossier(resource, attrs, opts) do
      if OperatorAction.match?(Keyword.get(opts, :actor), nil, action: :import_dossier) do
        GuardedCall.create(resource, :import, attrs, Keyword.put(opts, :guarded?, true))
      else
        refuse_import(resource, opts)
      end
    end
  else
    # No prototype authority in this build (production): no actor is the
    # prototype operator, so every import is refused before any changeset.
    defp record_dossier(resource, _attrs, opts), do: refuse_import(resource, opts)
  end

  # The precheck's closed refusal, audited once through the guard for a
  # recognized actor of an initialized tenant chain (`Guard.refuse/2`); no
  # input attribute reaches the audit record.
  defp refuse_import(resource, opts) do
    meta = %{resource: resource, action: :import, guarded?: true, subject_id: nil}
    Guard.refuse(meta, Keyword.get(opts, :actor))
  end

  defp subject(opts, attrs, key), do: Keyword.put(opts, :subject_id, Map.get(Map.new(attrs), key))
end
