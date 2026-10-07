# Domain Boundaries

Generated: 2026-10-06

Project shape: single

This diagram shows Ash domains and their resources, representing bounded contexts in the system.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#e1f5fe', 'primaryBorderColor': '#01579b'}}}%%
graph TB
    subgraph Agents["Agents Domain"]
        AgentDefinition[AgentDefinition]
        AgentRun[AgentRun]
        ModelInvocation[ModelInvocation]
        ToolInvocation[ToolInvocation]
        Decision[Decision]
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
        Kernel{{Audit kernel<br/>append / verify / guard}}
    end

    AgentDefinition --> AgentRun
    AgentRun --> ModelInvocation
    AgentRun --> ToolInvocation
    AgentRun --> Decision
    ModelInvocation --> Decision
    ModelInvocation -. request/response sha256 FK .-> Payload
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

    %% Project shape: single
    %% Layering (ADR-0009): Audit <- Accounts <- Operations <- Agents <- Sales <- Research <- Outreach
    %% Embedded resources (Authorization, Budget, Usage, ExternalRequestRef, InputRef) are omitted.
```

## Notes

- Each box represents a domain (bounded context)
- Resources inside show entities managed by that domain
- Cross-domain references should use IDs, not direct associations

## Manual Additions Needed

- [ ] Cross-domain relationships (arrows between domains)
- [ ] External service boundaries
- [ ] Shared kernel modules (if any)
