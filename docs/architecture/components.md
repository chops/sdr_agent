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
        ClaudeCLIAdapter[ClaudeCLI adapter<br/>serialized, tool-free GenServer]
        Telemetry[Telemetry setup, GenAI and agent spans]
        Oban[Oban: cron, queues default + research]
        Cadence[Anchor cadence worker]
        UpgradeDispatch[OTS upgrade dispatcher<br/>10-minute bounded batch]
        UpgradeJobs[Per-anchor receipt jobs<br/>unique, 3 attempts]
        Anchoring[Audit.Anchoring]
    end

    subgraph AgentPlane["Agent plane"]
        AgentWorker[SDR AgentWorker]
        SDRAgent[SDRAgent Jido agent<br/>routes -> Actions / Flows]
        Integrations[Fixture CRM / search / web adapters]
    end

    subgraph Phoenix["Phoenix"]
        Endpoint[Endpoint]
        Router[Router]
        PubSub[PubSub]
    end

    subgraph Web["Web Components"]
        Controllers["Controllers (2)"]
        LiveViews["LiveViews (2)"]
        Channels["Channels (1)"]
        UIComponents["UI Components (2)"]
    end

    subgraph Ash["Ash Framework"]
        Domains["Domains (6)"]
        Resources["Resources (49)"]
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
    ClaudeCLIAdapter --> Claude
    Oban --> AgentWorker
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
    Telemetry -. instruments .-> Endpoint
    Telemetry -. instruments .-> Domains
    Telemetry -. instruments .-> Resources
```

## Component Counts

| Component | Count |
|-----------|-------|
| Controllers | 2 |
| LiveViews | 2 |
| Channels | 1 |
| UI Components | 2 |
| Ash Domains | 6 |
| Ash Resources | 49 |

## Manual Additions Needed

- [x] S6a budget process and serialized ClaudeCLI GenServer
- [x] S6a supervision tree detail
- [x] Audit anchor cadence and bounded, unique OTS upgrade jobs
- [x] Claude CLI local process boundary
