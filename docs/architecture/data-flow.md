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

    subgraph AuditKernel["Audit kernel (system of record)"]
        Append[Append: lock chain head,<br/>sequence+1, sha256 chain]
        Verify[verify_chain / read_content<br/>recorded as AuditAccess]
    end

    subgraph Data["Data Layer"]
        Postgres[(PostgreSQL<br/>append-only triggers)]
        Cache[(Cache)]
    end

    subgraph AI["Structured Model Boundary"]
        Provider[ModelProvider facade]
        Budget[S3 persisted 20/run<br/>volatile 200/day guard]
        Validation[Zoi output validation]
        Adapter[Serialized tool-free ClaudeCLI adapter<br/>empty private cwd]
        Fake[Deterministic Fake<br/>dev/test default]
    end

    subgraph Observability["OpenTelemetry"]
        Instrumentation[Phoenix / Bandit / Ecto<br/>Oban / Req / Ash]
        GenAI[gen_ai spans<br/>IDs and hashes by default]
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
    Append -. trace_id / span_id .-> Instrumentation
    Resources -.-> Cache
    Actions --> Provider
    Provider --> Budget
    Provider --> Validation
    Provider --> Fake
    Provider --> Adapter
    Adapter -- stream JSON --> Claude
    Router -. spans .-> Instrumentation
    Resources -. spans .-> Instrumentation
    Provider -. spans .-> GenAI
    Instrumentation -. OTLP dev only .-> Tempo
    GenAI -. OTLP dev only .-> Tempo

    %% Project shape: single
    %% Detected data layers:
    %% - AshPostgres (PostgreSQL)
```

## Flow Description

1. **External** - Browsers, mobile apps, API clients
2. **Web Layer** - Phoenix router, controllers, LiveViews, channels
3. **Domain Layer** - Ash domains orchestrate business logic
4. **Model Boundary** - A pre-call budget reservation precedes deterministic
   Fake or serialized ClaudeCLI invocation; every output is Zoi-validated.
5. **Data Layer** - Persistence (PostgreSQL, ETS, etc.)

## Manual Additions Needed

- [x] Claude CLI local stream integration
- [ ] Message queues (if any)
- [ ] Background job processors
- [ ] PubSub flows for real-time updates
