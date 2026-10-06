---
name: debug-bundle
description: Collect error context bundle - logs, stacktraces, source files for debugging. Use when diagnosing errors, investigating bugs, or collecting debug info.
allowed-tools: Bash(*), Read, Grep, Glob
---

# Debug Bundle

Collect comprehensive error context for debugging issues.

## Arguments

- `$1` - Optional: file:line reference to focus on (e.g., `lib/my_app/resource.ex:42`)
- `$2` - Optional: search term to find related files

## Execution

```bash
bash "${CLAUDE_PROJECT_DIR:-.}/bin/debug_bundle.sh" $ARGUMENTS
```

## What Gets Collected

1. **Logs** - Recent dev/test logs, extracted error lines
2. **Stacktraces** - Errors from recent test runs
3. **Source** - Files around error reference with context
4. **Search** - Files matching search term
5. **State** - Current compile output, dependency tree
6. **Environment** - Elixir version, git state

## After Running

Review artifacts in `tmp/ai/debug/bundle_TIMESTAMP/`:
- `summary.md` - Bundle overview
- `logs/` - Application logs
- `stacktraces/` - Error details
- `source/` - Relevant source files
- `state/` - Compile/deps state
- `environment.txt` - Runtime info

## Output Format

Return a 5-10 bullet summary including:
- What was collected
- Key errors found (with file:line references)
- Relevant source files identified
- Hypothesis about error cause (if determinable)
- Path to bundle for detailed investigation

## Debugging Protocol

1. Run `/debug-bundle` with error reference
2. Read key artifacts based on error type
3. Form hypothesis
4. Propose minimal fix
5. Verify with targeted test
