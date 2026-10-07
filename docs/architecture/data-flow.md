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

    subgraph AI["Structured Model Boundary"]
        Provider[ModelProvider facade]
        Budget[S3 persisted 20/run<br/>volatile 200/day guard]
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
    Provider --> Budget
    Provider --> Validation
    Provider --> Adapter
    Adapter --> Claude
    Resources -.-> Cache

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
