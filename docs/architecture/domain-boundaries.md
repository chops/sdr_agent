# Domain Boundaries

Generated: 2026-10-06 (Sales and Research added by hand in S5, Outreach in S8, Reply, ReplyAssessment and WebhookEvent in S9, 2026-10-07)

Project shape: single

This diagram shows Ash domains and their resources, representing bounded contexts in the system.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#e1f5fe', 'primaryBorderColor': '#01579b'}}}%%
graph TB
    subgraph Outreach["Outreach Domain (highest layer)"]
        Draft[Draft]
        DraftRevision[DraftRevision]
        RevisionCitation[RevisionCitation]
        Approval[Approval]
        Suppression[Suppression]
        DeliveryOperation[DeliveryOperation]
        DeliveryReceipt[DeliveryReceipt]
        SendQuotaDay[SendQuotaDay]
        Reply[Reply]
        ReplyAssessment[ReplyAssessment]
    end
    subgraph Research["Research Domain"]
        ResearchArtifact[ResearchArtifact]
        EvidenceClaim[EvidenceClaim]
        Qualification[Qualification]
        QualificationEvidence[QualificationEvidence]
    end
    subgraph Sales["Sales Domain"]
        IcpDefinition[IcpDefinition]
        Account[Account]
        Contact[Contact]
        Lead[Lead]
        Campaign[Campaign]
        Sequence[Sequence]
        SequenceStep[SequenceStep]
        CampaignEnrollment[CampaignEnrollment]
    end
    subgraph Agents["Agents Domain"]
        AgentDefinition[AgentDefinition]
        AgentRun[AgentRun]
        ModelInvocation[ModelInvocation]
        ToolInvocation[ToolInvocation]
        Decision[Decision]
        WireWitnessLink[WireWitnessLink<br/>append-only, per-exchange lineage]
    end
    subgraph Operations["Operations Domain"]
        Operation[Operation]
        Failure[Failure]
        WebhookEvent[WebhookEvent]
    end
    subgraph Accounts["Accounts Domain"]
        User[User]
        Token[Token]
    end
    subgraph Audit["Audit Domain (lowest layer)"]
        Tenant[Tenant]
        AuditEvent[AuditEvent]
        AuditChainHead[AuditChainHead]
        ProvenanceSnapshot[ProvenanceSnapshot]
        Payload[Payload]
        AuditAccess[AuditAccess]
        RetentionMarker[RetentionMarker]
        AuditSigningKey[AuditSigningKey]
        AuditAnchor[AuditAnchor]
        AnchorSinkReceipt[AnchorSinkReceipt]
        AuditExport[AuditExport]
        Kernel{{Audit kernel<br/>append / verify / guard}}
    end

    AgentDefinition --> AgentRun
    AgentRun --> ModelInvocation
    AgentRun --> ToolInvocation
    AgentRun --> Decision
    ModelInvocation --> Decision
    ModelInvocation -. request/response sha256 FK .-> Payload
    ModelInvocation --> WireWitnessLink
    WireWitnessLink -. supersedes same exchange .-> WireWitnessLink
    WireWitnessLink -. REC scoped read_reconciliation_content .-> Payload
    ToolInvocation -. input/output sha256 FK .-> Payload
    Decision -. inputs sha256 FK .-> Payload
    Agents -. tenant_id FK .-> Tenant
    Agents == "AppendEvent change (same transaction)" ==> Kernel
    Kernel --> AuditChainHead
    Kernel --> AuditEvent
    Kernel --> AuditAccess
    AuditEvent --> ProvenanceSnapshot
    AuditEvent --> Tenant
    AuditChainHead --> Tenant
    AuditAnchor --> AuditSigningKey
    AuditAnchor --> AnchorSinkReceipt
    AuditExport -. anchor ids .-> AuditAnchor

    Account --> Contact
    Contact --> Lead
    Account --> Lead
    IcpDefinition --> Campaign
    Sequence --> SequenceStep
    Sequence --> Campaign
    Campaign --> CampaignEnrollment
    Lead --> CampaignEnrollment
    Lead -. last_decision_id FK .-> Decision
    Lead -. owner_user_id FK .-> User
    ResearchArtifact --> EvidenceClaim
    Qualification --> QualificationEvidence
    EvidenceClaim --> QualificationEvidence
    ResearchArtifact -. lead_id FK .-> Lead
    EvidenceClaim -. lead_id FK .-> Lead
    Qualification -. lead_id / icp FK .-> Lead
    Qualification -. qualify / disqualify in the same transaction .-> Lead
    ResearchArtifact -. run / tool invocation FK .-> ToolInvocation
    EvidenceClaim -. extraction decision FK .-> Decision
    Qualification -. decision / run FK .-> Decision
    ResearchArtifact -. content sha256 FK .-> Payload
    User -. tenant_id FK .-> Tenant
    Sales -. tenant_id FK .-> Tenant
    Research -. tenant_id FK .-> Tenant
    Operation --> Failure
    Operation -. last_failure_id FK .-> Failure
    AgentRun -. operation_id FK .-> Operation
    AgentRun -. attention_failure_id FK (same transaction) .-> Failure
    Lead -. blocked opens Failure (same transaction) .-> Failure
    Failure -. resolved_by_id FK .-> User
    Failure -. detail sha256 FK .-> Payload
    Operations -. tenant_id FK .-> Tenant
    Operations == "AppendEvent (operations.*)" ==> Kernel
    Accounts == "AppendEvent (user.*, auth.*)" ==> Kernel
    Sales == "AppendEvent (sales.*)" ==> Kernel
    Research == "AppendEvent (research.*)" ==> Kernel
    Draft --> DraftRevision
    DraftRevision --> RevisionCitation
    Draft -. current_revision_id FK (deferred) .-> DraftRevision
    Draft --> Approval
    Approval -. binds revision id + sha256 .-> DraftRevision
    Approval -. recipient / campaign FK .-> Contact
    Approval -. approver FK .-> User
    Draft -. lead / enrollment / step / campaign / recipient FK .-> CampaignEnrollment
    Draft -. origin_agent_run_id FK .-> AgentRun
    DraftRevision -. draft_proposal decision FK .-> Decision
    RevisionCitation -. evidence_claim_id FK .-> EvidenceClaim
    Suppression -. stops leads / enrollments (same transaction) .-> Lead
    Suppression -. invalidates approvals, cancels drafts .-> Approval
    Suppression -. created_by / decision FK .-> User
    Outreach -. tenant_id FK .-> Tenant
    Outreach == "AppendEvent (outreach.*)" ==> Kernel
    Approval -- "grant inserts outbox row (same transaction)" --> DeliveryOperation
    DeliveryOperation --> DeliveryReceipt
    DeliveryOperation -. send_quota_date (first claim) .-> SendQuotaDay
    DeliveryOperation -. rendered sha256 FK .-> Payload
    DeliveryReceipt -. rendered sha256 FK .-> Payload
    DeliveryOperation -. last_decision_id FK (send_gate) .-> Decision
    DeliveryOperation -. attention_failure_id FK (same transaction) .-> Failure
    DeliveryOperation -. advance_step on acceptance .-> CampaignEnrollment
    Suppression -. delivery_operation_id FK; cancels unclaimed deliveries .-> DeliveryOperation
    Reply -. webhook_event_id FK (one reply per event) .-> WebhookEvent
    Reply -. matched: delivery, contact, lead, enrollment FKs .-> DeliveryOperation
    Reply -. matched: enrollment + lead replied, unsent work cancelled (same transaction) .-> CampaignEnrollment
    Suppression -. reply_id / webhook_event_id FKs (S9 sources) .-> Reply
    DeliveryReceipt -. webhook_event_id FK (delivered / bounced) .-> WebhookEvent
    WebhookEvent -. raw body sha256 FK .-> Payload
    WebhookEvent -. failure_id FK (rejected / failed) .-> Failure
    ReplyAssessment -- "reply_id FK (supersedes lineage)" --> Reply
    ReplyAssessment -. agent_run / decision / model_invocation FKs (llm reply_classification) .-> Decision


    %% Project shape: single
    %% Layering (ADR-0009): Audit <- Accounts <- Operations <- Agents <- Sales <- Research <- Outreach
    %% Embedded resources (incl. IcpCriteria, SourceLocation, QualificationCriteria) are omitted.
```

## Notes

- Each box represents a domain (bounded context)
- Resources inside show entities managed by that domain
- Cross-domain references should use IDs, not direct associations

## Manual Additions Needed

- [ ] Cross-domain relationships (arrows between domains)
- [ ] External service boundaries
- [ ] Shared kernel modules (if any)
