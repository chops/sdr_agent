# Component Relationships

Generated: 2026-10-06

Project shape: single

This diagram shows the major components and their relationships.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#fff3e0', 'primaryBorderColor': '#e65100'}}}%%
graph TB
    subgraph Application["Application"]
        App[Application Supervisor]
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

    App --> Endpoint
    Endpoint --> Router
    Endpoint --> PubSub
    Router --> Controllers
    Router --> LiveViews
    LiveViews --> UIComponents
    Controllers --> Domains
    LiveViews --> Domains
    Domains --> Resources
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

- [ ] GenServer processes
- [ ] Supervision tree details
- [ ] Background workers (Oban, etc.)
- [ ] External service clients
