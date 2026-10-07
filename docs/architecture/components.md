# Component Relationships

Generated: 2026-10-06

Project shape: single

This diagram shows the major components and their relationships.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#fff3e0', 'primaryBorderColor': '#e65100'}}}%%
graph TB
    subgraph Application["Application"]
        App[Application Supervisor]
        Budget[Persisted budgets<br/>20/run + 200/UTC day in Postgres]
        ModelProvider[ModelProvider facade<br/>budget + Zoi validation]
        ClaudeCLIAdapter[ClaudeCLI adapter<br/>serialized, tool-free GenServer<br/>per-call SDR witness env, bypass routes scrubbed]
        Telemetry[Telemetry setup, GenAI and agent spans]
        Oban[Oban: cron, queues default, research,<br/>delivery 5, reconciliation 5, followup 10,<br/>integration 5, agent 10]
        Cadence[Anchor cadence worker]
        UpgradeDispatch[OTS upgrade dispatcher<br/>10-minute bounded batch]
        UpgradeJobs[Per-anchor receipt jobs<br/>unique, 3 attempts]
        Anchoring[Audit.Anchoring]
        Relay[LiveEvents.Relay<br/>LISTEN sdr_audit_events -> PubSub]
    end

    subgraph AgentPlane["Agent plane"]
        AgentWorker[SDR AgentWorker]
        FollowupWorker[SDR FollowupWorker<br/>followup_next_step + sdr.followup.due]
        SDRAgent[SDRAgent Jido agent<br/>routes -> Actions / Flows]
        Integrations[Fixture CRM / search / web adapters]
    end

    subgraph Phoenix["Phoenix"]
        Endpoint[Endpoint]
        Router[Router]
        PubSub[PubSub]
    end

    subgraph Web["Web Components"]
        Controllers["Controllers (1)"]
        LiveViews["LiveViews (2 auth + 11 console)"]
        Channels["Channels (1)"]
        UIComponents["UI Components (3)"]
    end

    subgraph Ash["Ash Framework"]
        Domains["Domains (7)"]
        Resources["Resources (57)"]
    end

    subgraph External["Local External Process"]
        Claude[Claude CLI<br/>stream JSON via llm-proxy-shim]
        OTSCLI[OpenTimestamps CLI 0.7.2]
        OTSCalendars[Public OTS calendars]
        Bitcoin[Operator-configured Bitcoin node]
    end

    App --> Oban
    Oban --> Cadence
    Oban --> UpgradeDispatch
    UpgradeDispatch --> UpgradeJobs
    Cadence --> Anchoring
    UpgradeJobs --> Anchoring
    Anchoring --> Domains
    Anchoring -. OTS enabled: digest submission .-> OTSCalendars
    Anchoring -. OTS enabled: public proof .-> OTSCLI
    OTSCLI -. upgrade .-> OTSCalendars
    OTSCLI -. verify .-> Bitcoin
    App --> Endpoint
    App --> Telemetry
    ModelProvider --> Budget
    ModelProvider --> ClaudeCLIAdapter
    ModelProvider -. spans .-> Telemetry
    ClaudeCLIAdapter -- "SDR_MODEL_INVOCATION_ID + SDR_TRACEPARENT (child env only)" --> Claude
    Claude -. "S12a proxy deployed: loopback correlation, stripped upstream" .-> WitnessStore[(Local proxy witness store<br/>owner-only, outside SDR)]
    Oban -. "cron */5 ScanWorker; queue reconciliation: 1 (shared with delivery)" .-> WitnessReconciler[Agents.Witness reconciler<br/>REC, inert while store_root nil]
    WitnessReconciler -. "bounded read-only reader" .-> WitnessStore
    WitnessReconciler --> Domains
    Oban --> AgentWorker
    Oban --> FollowupWorker
    FollowupWorker --> Domains
    Oban --> DeliveryJobs[Outreach DeliveryWorker / ReconcileWorker /<br/>StaleDeliverySweeper -> Delivery gate]
    DeliveryJobs --> Domains
    DeliveryJobs --> Capture[CaptureAdapter<br/>local capture only, no network]
    Oban --> WebhookWorker[Outreach WebhookWorker<br/>process verified WebhookEvents]
    WebhookWorker --> Domains
    Oban --> ReplyWorker[SDR ReplyWorker<br/>classify a matched reply]
    ReplyWorker --> SDRAgent
    AgentWorker --> SDRAgent
    SDRAgent --> ModelProvider
    SDRAgent --> Integrations
    SDRAgent --> Domains
    Endpoint --> Router
    Endpoint --> PubSub
    Router --> Controllers
    Router --> LiveViews
    LiveViews --> UIComponents
    Controllers --> Domains
    LiveViews --> Domains
    Domains --> Resources
    App --> Relay
    Domains -. audit append: pg_notify, delivered at commit .-> Relay
    Relay -- tenant topic --> PubSub
    PubSub -. live refresh: re-read via Domains .-> LiveViews
    Telemetry -. instruments .-> Endpoint
    Telemetry -. instruments .-> Domains
    Telemetry -. instruments .-> Resources
```

## Component Counts

| Component | Count |
|-----------|-------|
| Controllers | 1 (auth) |
| LiveViews | 13 (2 AshAuthentication + 11 S10 console) |
| Channels | 1 |
| UI Components | 3 (core, layouts, console UI) |
| Ash Domains | 7 |
| Ash Resources | 57 |

## Manual Additions Needed

- [x] S6a budget process and serialized ClaudeCLI GenServer
- [x] S6a supervision tree detail
- [x] Audit anchor cadence and bounded, unique OTS upgrade jobs
- [x] Claude CLI local process boundary
- [x] S13 LiveEvents.Relay (commit-time audit notifications -> PubSub -> live console views, ADR-0012)
