# Domain Boundaries

Generated: 2026-10-06

Project shape: single

This diagram shows Ash domains and their resources, representing bounded contexts in the system.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#e1f5fe', 'primaryBorderColor': '#01579b'}}}%%
graph TB
    subgraph Accounts do["Accounts do Domain"]
    end

    %% Project shape: single
```

## Notes

- Each box represents a domain (bounded context)
- Resources inside show entities managed by that domain
- Cross-domain references should use IDs, not direct associations

## Manual Additions Needed

- [ ] Cross-domain relationships (arrows between domains)
- [ ] External service boundaries
- [ ] Shared kernel modules (if any)
