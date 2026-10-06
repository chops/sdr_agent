#!/bin/bash
# architecture_diagram.sh - Generates Mermaid architectural diagrams
# Outputs: docs/architecture/

set -uo pipefail
shopt -s nullglob

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/docs/architecture"
TIMESTAMP=$(date +%Y-%m-%d)

echo "Analyzing codebase for architecture diagrams..."

PROJECT_SHAPE="unknown"
LIB_DIRS=()
for app_dir in "$PROJECT_DIR"/apps/*; do
    [ -d "$app_dir/lib" ] && LIB_DIRS+=("$app_dir/lib")
done
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    PROJECT_SHAPE="umbrella"
elif [ -d "$PROJECT_DIR/lib" ]; then
    PROJECT_SHAPE="single"
    LIB_DIRS=("$PROJECT_DIR/lib")
fi

grep_libs() {
    if [ ${#LIB_DIRS[@]} -eq 0 ]; then
        return 1
    fi
    grep "$@" "${LIB_DIRS[@]}"
}

find_libs() {
    if [ ${#LIB_DIRS[@]} -eq 0 ]; then
        return 1
    fi
    find "${LIB_DIRS[@]}" "$@"
}

if ! grep_libs -rqE "use Ash\.(Domain|Resource)" 2>/dev/null; then
    echo "No Ash domains or resources detected; no diagrams generated."
    exit 0
fi

mkdir -p "$OUTPUT_DIR"

# Temporary working directory
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# =============================================================================
# 1. DOMAIN BOUNDARIES DIAGRAM
# =============================================================================

echo "Generating domain boundaries diagram..."

DOMAINS_FILE="$WORK_DIR/domains.txt"
RESOURCES_FILE="$WORK_DIR/resources.txt"

if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    grep_libs -rl "use Ash.Domain" 2>/dev/null | while read -r file; do
        DOMAIN_MODULE=$(grep -E "defmodule\s+" "$file" | head -1 | sed 's/.*defmodule\s\+\([A-Za-z0-9_.]*\).*/\1/')
        DOMAIN_SHORT=$(echo "$DOMAIN_MODULE" | awk -F'.' '{print $NF}')
        echo "$DOMAIN_SHORT|$DOMAIN_MODULE|$file"
    done > "$DOMAINS_FILE" 2>/dev/null || touch "$DOMAINS_FILE"

    grep_libs -rl "use Ash.Resource" 2>/dev/null | while read -r file; do
        RESOURCE_MODULE=$(grep -E "defmodule\s+" "$file" | head -1 | sed 's/.*defmodule\s\+\([A-Za-z0-9_.]*\).*/\1/')
        RESOURCE_SHORT=$(echo "$RESOURCE_MODULE" | awk -F'.' '{print $NF}')
        DOMAIN_HINT=$(echo "$RESOURCE_MODULE" | awk -F'.' '{if(NF>1) print $(NF-1); else print "Unknown"}')
        echo "$RESOURCE_SHORT|$RESOURCE_MODULE|$DOMAIN_HINT"
    done > "$RESOURCES_FILE" 2>/dev/null || touch "$RESOURCES_FILE"
else
    touch "$DOMAINS_FILE" "$RESOURCES_FILE"
fi

cat > "$OUTPUT_DIR/domain-boundaries.mmd" << 'MERMAID_HEADER'
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#e1f5fe', 'primaryBorderColor': '#01579b'}}}%%
graph TB
MERMAID_HEADER

if [ -s "$DOMAINS_FILE" ]; then
    while IFS='|' read -r domain_short _domain_full _file; do
        echo "    subgraph ${domain_short}[\"${domain_short} Domain\"]"
        grep -E "\|${domain_short}$" "$RESOURCES_FILE" 2>/dev/null | while IFS='|' read -r res_short _res_full _res_domain; do
            echo "        ${res_short}[${res_short}]"
        done
        echo "    end"
    done < "$DOMAINS_FILE" >> "$OUTPUT_DIR/domain-boundaries.mmd"
else
    echo "    NoDomainsFound[\"No Ash Domains Found\"]" >> "$OUTPUT_DIR/domain-boundaries.mmd"
fi

{
    echo ""
    echo "    %% Project shape: $PROJECT_SHAPE"
} >> "$OUTPUT_DIR/domain-boundaries.mmd"

cat > "$OUTPUT_DIR/domain-boundaries.md" << EOF
# Domain Boundaries

Generated: $TIMESTAMP

Project shape: $PROJECT_SHAPE

This diagram shows Ash domains and their resources, representing bounded contexts in the system.

\`\`\`mermaid
$(cat "$OUTPUT_DIR/domain-boundaries.mmd")
\`\`\`

## Notes

- Each box represents a domain (bounded context)
- Resources inside show entities managed by that domain
- Cross-domain references should use IDs, not direct associations

## Manual Additions Needed

- [ ] Cross-domain relationships (arrows between domains)
- [ ] External service boundaries
- [ ] Shared kernel modules (if any)
EOF

# =============================================================================
# 2. DATA FLOW DIAGRAM
# =============================================================================

echo "Generating data flow diagram..."

cat > "$OUTPUT_DIR/data-flow.mmd" << 'MERMAID_HEADER'
%%{init: {'theme': 'base', 'themeVariables': { 'primaryColor': '#e8f5e9', 'primaryBorderColor': '#1b5e20'}}}%%
flowchart LR
    subgraph External["External"]
        Browser[Browser/Client]
        API[External APIs]
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
        Postgres[(PostgreSQL)]
        Cache[(Cache)]
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
    Resources -.-> Cache
MERMAID_HEADER

HAS_POSTGRES=""
HAS_SQLITE=""
HAS_ETS=""
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    HAS_POSTGRES=$(grep_libs -r "AshPostgres" 2>/dev/null | head -1 || true)
    HAS_SQLITE=$(grep_libs -r "AshSqlite" 2>/dev/null | head -1 || true)
    HAS_ETS=$(grep_libs -r "Ash.DataLayer.Ets" 2>/dev/null | head -1 || true)
fi

{
    echo ""
    echo "    %% Project shape: $PROJECT_SHAPE"
    echo "    %% Detected data layers:"
    [ -n "$HAS_POSTGRES" ] && echo "    %% - AshPostgres (PostgreSQL)"
    [ -n "$HAS_SQLITE" ] && echo "    %% - AshSqlite (SQLite)"
    [ -n "$HAS_ETS" ] && echo "    %% - Ash.DataLayer.Ets (ETS)"
} >> "$OUTPUT_DIR/data-flow.mmd"

cat > "$OUTPUT_DIR/data-flow.md" << EOF
# Data Flow

Generated: $TIMESTAMP

Project shape: $PROJECT_SHAPE

This diagram shows how data flows through the system, from external clients through Phoenix to domain modules.

\`\`\`mermaid
$(cat "$OUTPUT_DIR/data-flow.mmd")
\`\`\`

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
EOF

# =============================================================================
# 3. COMPONENT RELATIONSHIPS DIAGRAM
# =============================================================================

echo "Generating component relationships diagram..."

cat > "$OUTPUT_DIR/components.mmd" << 'MERMAID_HEADER'
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
MERMAID_HEADER

if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    CONTROLLERS=$(find_libs -name "*_controller.ex" 2>/dev/null | wc -l | tr -d ' ')
    LIVEVIEWS=$(grep_libs -rl "use.*LiveView" 2>/dev/null | wc -l | tr -d ' ')
    CHANNELS=$(grep_libs -rl "use.*Channel" 2>/dev/null | wc -l | tr -d ' ')
    COMPONENTS=$(find_libs -path "*/components/*.ex" 2>/dev/null | wc -l | tr -d ' ')
    DOMAINS_COUNT=$(grep_libs -rl "use Ash.Domain" 2>/dev/null | wc -l | tr -d ' ')
    RESOURCES_COUNT=$(grep_libs -rl "use Ash.Resource" 2>/dev/null | wc -l | tr -d ' ')
else
    CONTROLLERS=0
    LIVEVIEWS=0
    CHANNELS=0
    COMPONENTS=0
    DOMAINS_COUNT=0
    RESOURCES_COUNT=0
fi

if [ "$CONTROLLERS" -gt 0 ] || [ "$LIVEVIEWS" -gt 0 ]; then
    echo "" >> "$OUTPUT_DIR/components.mmd"
    echo "    subgraph Web[\"Web Components\"]" >> "$OUTPUT_DIR/components.mmd"
    [ "$CONTROLLERS" -gt 0 ] && echo "        Controllers[\"Controllers ($CONTROLLERS)\"]" >> "$OUTPUT_DIR/components.mmd"
    [ "$LIVEVIEWS" -gt 0 ] && echo "        LiveViews[\"LiveViews ($LIVEVIEWS)\"]" >> "$OUTPUT_DIR/components.mmd"
    [ "$CHANNELS" -gt 0 ] && echo "        Channels[\"Channels ($CHANNELS)\"]" >> "$OUTPUT_DIR/components.mmd"
    [ "$COMPONENTS" -gt 0 ] && echo "        UIComponents[\"UI Components ($COMPONENTS)\"]" >> "$OUTPUT_DIR/components.mmd"
    echo "    end" >> "$OUTPUT_DIR/components.mmd"
fi

if [ "$DOMAINS_COUNT" -gt 0 ] || [ "$RESOURCES_COUNT" -gt 0 ]; then
    echo "" >> "$OUTPUT_DIR/components.mmd"
    echo "    subgraph Ash[\"Ash Framework\"]" >> "$OUTPUT_DIR/components.mmd"
    [ "$DOMAINS_COUNT" -gt 0 ] && echo "        Domains[\"Domains ($DOMAINS_COUNT)\"]" >> "$OUTPUT_DIR/components.mmd"
    [ "$RESOURCES_COUNT" -gt 0 ] && echo "        Resources[\"Resources ($RESOURCES_COUNT)\"]" >> "$OUTPUT_DIR/components.mmd"
    echo "    end" >> "$OUTPUT_DIR/components.mmd"
fi

cat >> "$OUTPUT_DIR/components.mmd" << 'RELATIONSHIPS'

    App --> Endpoint
    Endpoint --> Router
    Endpoint --> PubSub
    Router --> Controllers
    Router --> LiveViews
    LiveViews --> UIComponents
    Controllers --> Domains
    LiveViews --> Domains
    Domains --> Resources
RELATIONSHIPS

cat > "$OUTPUT_DIR/components.md" << EOF
# Component Relationships

Generated: $TIMESTAMP

Project shape: $PROJECT_SHAPE

This diagram shows the major components and their relationships.

\`\`\`mermaid
$(cat "$OUTPUT_DIR/components.mmd")
\`\`\`

## Component Counts

| Component | Count |
|-----------|-------|
| Controllers | $CONTROLLERS |
| LiveViews | $LIVEVIEWS |
| Channels | $CHANNELS |
| UI Components | $COMPONENTS |
| Ash Domains | $DOMAINS_COUNT |
| Ash Resources | $RESOURCES_COUNT |

## Manual Additions Needed

- [ ] GenServer processes
- [ ] Supervision tree details
- [ ] Background workers (Oban, etc.)
- [ ] External service clients
EOF

echo ""
echo "=== ARCHITECTURE DIAGRAMS COMPLETE ==="
echo ""
echo "Generated diagrams in $OUTPUT_DIR:"
echo "  - domain-boundaries.mmd (.md)"
echo "  - data-flow.mmd (.md)"
echo "  - components.mmd (.md)"
echo ""
echo "Detected:"
echo "  - Project Shape: $PROJECT_SHAPE"
echo "  - Ash Domains: $DOMAINS_COUNT"
echo "  - Ash Resources: $RESOURCES_COUNT"
echo "  - Controllers: $CONTROLLERS"
echo "  - LiveViews: $LIVEVIEWS"
echo "  - Channels: $CHANNELS"
echo ""
echo "Review the .md files for rendered diagrams and manual enhancement notes."
