# Component Relationships

Generated: 2026-10-06

Project shape: single

This diagram shows the major components and their relationships.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#fff3e0', 'primaryBorderColor': '#e65100'}}}%%
graph TB
    subgraph Application["Application"]
        App[Application Supervisor]
        Budget[In-memory BudgetStore<br/>supervised Agent]
        ModelProvider[ModelProvider facade<br/>budget + Zoi validation]
        CodexAdapter[CodexAppServer adapter<br/>serialized, tool-free GenServer]
        Telemetry[Telemetry setup and GenAI helper]
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
        Domains["Domains (3)"]
        Resources["Resources (12 + 2 auth)"]
    end

    subgraph External["Local External Process"]
        Codex[Codex app-server<br/>JSONL over stdio]
    end

    App --> Endpoint
    App --> Budget
    App --> Telemetry
    ModelProvider --> Budget
    ModelProvider --> CodexAdapter
    ModelProvider -. spans .-> Telemetry
    CodexAdapter --> Codex
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
| Ash Domains | 1 |
| Ash Resources | 2 |

## Manual Additions Needed

- [x] S6a budget process and serialized app-server GenServer
- [x] S6a supervision tree detail
- [ ] Background workers (Oban, etc.)
- [x] Codex app-server local process boundary
