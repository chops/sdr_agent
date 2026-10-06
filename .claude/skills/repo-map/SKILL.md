---
name: repo-map
description: Analyze codebase structure - Ash resources, domains, actions, Phoenix components. Use when exploring a new codebase or understanding project structure.
allowed-tools: Bash(*), Read, Glob, Grep
---

# Repository Map

Run the repo-map analysis script to generate a structured overview of the codebase.

## Execution

```bash
bash "${CLAUDE_PROJECT_DIR:-.}/bin/repo_map.sh"
```

## After Running

1. Review the summary output
2. Key artifacts are in `tmp/ai/repo_map/`:
   - `summary.md` - Overview with counts
   - `resources.txt` - Ash resource definitions
   - `domains.txt` - Ash domain definitions
   - `actions.txt` - Action patterns
   - `phoenix.txt` - Controllers/LiveViews
   - `tests.txt` - Test structure

## Output Format

Return a 5-10 bullet summary including:
- Total counts (resources, domains, controllers, tests)
- Key Ash resources identified
- Domain structure
- Notable patterns observed
- Path to detailed artifacts

Do NOT paste full file contents. Reference artifact paths for details.
