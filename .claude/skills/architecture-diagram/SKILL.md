---
name: architecture-diagram
description: Generate or update Mermaid architectural diagrams. Use after architectural changes or when exploring a new codebase.
allowed-tools: Bash(*), Read, Glob, Grep, Write
---

# Architecture Diagram Generator

Generates three types of Mermaid diagrams representing system architecture:
1. **Domain Boundaries** - Ash domains and their resources
2. **Data Flow** - How data moves between components
3. **Component Relationships** - Module dependencies and layers

## Execution

```bash
bash "${CLAUDE_PROJECT_DIR:-.}/bin/architecture_diagram.sh"
```

If no Ash domain or resource is detected, the command exits successfully
without creating `docs/architecture/` or any diagram files.

## After Running

1. Review the generated diagrams in `docs/architecture/`:
   - `domain-boundaries.mmd` - Ash domains visualization
   - `data-flow.mmd` - Data flow between components
   - `components.mmd` - Module and layer relationships
   - Each `.mmd` has a corresponding `.md` wrapper for GitHub rendering

2. If script output is insufficient, manually enhance diagrams using the analysis data

## Output Format

Return a 5-10 bullet summary including:
- Diagram files created/updated
- Key domains and resources identified
- Notable architectural patterns
- Any relationships that couldn't be auto-detected (for manual addition)
- Path to diagrams: `docs/architecture/`

## Manual Enhancement

The script provides a foundation. Common manual additions:
- External service integrations (APIs, databases)
- Runtime relationships (PubSub, supervision)
- Cross-cutting concerns (authentication, logging)

Edit the `.mmd` files directly; they're the source of truth.

## When to Invoke

**Automatically (Phase 5):**
- Claude evaluates if architecture changed during implementation
- If yes, this skill is invoked automatically

**Manually:**
- "Generate architecture diagram"
- "Update the architecture diagrams"
- "Show me the system architecture"
