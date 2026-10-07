# Data Flow

Generated: 2026-10-06

Project shape: single

This diagram shows how data flows through the system, from external clients through Phoenix to domain modules.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#e8f5e9', 'primaryBorderColor': '#1b5e20'}}}%%
flowchart LR
    subgraph External["External"]
        Browser[Browser/Client]
        API[External APIs]
        Claude[Claude CLI<br/>personal local login]
        Tempo[Tempo OTLP HTTP<br/>dev only 127.0.0.1:4318]
        AnchorGit[Private protected Git<br/>owner trust domain]
        OTS[OpenTimestamps calendars<br/>hashes only]
        OTSCLI[ots 0.7.2 executable<br/>signing key excluded from env]
        Bitcoin[Operator-configured Bitcoin node]
    end

    subgraph Web["Phoenix Web Layer"]
        Router[Router]
        Controllers[Controllers]
        LiveViews[LiveViews]
        Channels[Channels]
    end

    subgraph Domain["Domain Layer"]
        Domains[Ash Domains]
        Resources[Resources]
        Actions[Actions]
        Policies[Policies]
    end

    subgraph Data["Data Layer"]
        Postgres[(PostgreSQL<br/>append-only triggers)]
        Cache[(Cache)]
    end

    subgraph AuditKernel["Audit kernel (system of record)"]
        Append[Append: lock chain head,<br/>sequence+1, sha256 chain]
        Verify[verify/read/export<br/>recorded as AuditAccess]
        Anchor[Ed25519 anchor + export]
        Upgrade[Public proof upgrade<br/>serialized receipt confirmation]
        UpgradeJobs[Oban 10-minute dispatch<br/>bounded unique receipt jobs]
    end

    subgraph AgentPlane["Agent plane (Jido v3)"]
        Assign[SDR.assign_lead<br/>lead + run + Operation + signal + job, one txn]
        Worker[Oban AgentWorker<br/>queue research, max_attempts 1]
        Runner[Runner: Jido.Agent.cmd per signal<br/>emitted signals -> ledger -> next turn]
        Flows[ResearchLeadFlow / PrepareOutreachFlow<br/>Actions = ToolInvocations + Decisions]
        Fixtures[Fixture CRM / search / web<br/>offline, reserved hosts]
        HandOff[HandOffProposal: enrollment + lead in_outreach<br/>+ sdr.draft.completed + Outreach Draft/Revision, one txn]
        SupCheck[SuppressionCheck.Store<br/>reads Outreach suppressions]
    end

    subgraph Delivery["Outbox delivery (S8b, local capture only)"]
        Grant[Approval grant<br/>+ DeliveryOperation + delivery job, one txn]
        Gate[DeliveryWorker: send_gate Decision<br/>quiet hours, 25/day quota, suppression, binding]
        Capture[CaptureAdapter<br/>captured receipt, idempotent on key]
        Outcome[accepted / retryable / permanent / unknown<br/>receipts, draft sent, advance_step]
        Reconcile[ReconcileWorker + StaleDeliverySweeper<br/>delivery_reconciliation, never blind resend]
        Followup[FollowupWorker at next_step_due_at<br/>followup_next_step + sdr.followup.due]
    end

    subgraph AI["Structured Model Boundary"]
        Provider[ModelProvider facade]
        Budget[persisted 20/run + 200/UTC day<br/>inside the reservation transaction]
        Validation[Zoi output validation]
        Adapter[Serialized tool-free ClaudeCLI adapter]
    end

    Browser --> Router
    API --> Router
    Router --> Controllers
    Router --> LiveViews
    Router --> Channels
    Controllers --> Domains
    LiveViews --> Domains
    Channels --> Domains
    Domains --> Resources
    Resources --> Actions
    Actions --> Policies
    Resources --> Postgres
    Actions -- same transaction --> Append
    Append --> Postgres
    Verify --> Postgres
    Anchor --> Postgres
    Anchor -. Git enabled .-> AnchorGit
    Anchor -. OTS enabled: dev/prod .-> OTS
    UpgradeJobs --> Upgrade
    Upgrade --> Postgres
    Upgrade -. OTS enabled .-> OTSCLI
    OTSCLI -. upgrade .-> OTS
    OTSCLI -. verify .-> Bitcoin
    Actions --> Provider
    Controllers -.-> Assign
    Assign --> Domains
    Assign -- Oban.insert same txn --> Postgres
    Postgres -- job --> Worker
    Worker --> Runner
    Runner --> Flows
    Flows --> Fixtures
    Flows --> Domains
    Flows --> Provider
    Flows --> HandOff
    HandOff --> Domains
    Flows --> SupCheck
    SupCheck --> Domains
    Runner -- signal events --> Append
    Provider --> Budget
    Provider --> Validation
    Provider --> Adapter
    Adapter --> Claude
    Resources -.-> Cache
    LiveViews -.-> Grant
    Grant --> Postgres
    Postgres -- delivery job --> Gate
    Gate --> Capture
    Capture --> Outcome
    Outcome -- unknown --> Reconcile
    Reconcile --> Capture
    Outcome -- followup job --> Followup
    Gate -- same transaction --> Append
    Outcome -- same transaction --> Append
    Followup -- signal event --> Append

    %% Project shape: single
    %% Detected data layers:
    %% - AshPostgres (PostgreSQL)
```

## Flow Description

1. **External** - Browsers, mobile apps, API clients
2. **Web Layer** - Phoenix router, controllers, LiveViews, channels
3. **Domain Layer** - Ash domains orchestrate business logic
4. **Data Layer** - Persistence (PostgreSQL, ETS, etc.)

## Manual Additions Needed

- [ ] Specific external API integrations
- [ ] Message queues (if any)
- [ ] Background job processors
- [ ] PubSub flows for real-time updates
