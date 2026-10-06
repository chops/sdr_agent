---
name: static-analysis
description: Run full static analysis suite - compile, format, credo, dialyzer, sobelow. Use before commits, PRs, or to check code quality.
allowed-tools: Bash(*), Read
---

# Static Analysis

Run the comprehensive static analysis suite for Elixir/Ash projects.

## Tools Executed

1. **Compile** - `mix compile --warnings-as-errors`
2. **Format** - `mix format --check-formatted`
3. **Credo** - `mix credo --strict` (if installed)
4. **Dialyzer** - `mix dialyzer` (if configured)
5. **Sobelow** - `mix sobelow --config` (if installed)
6. **Deps Audit** - `mix deps.audit` (if installed)

## Execution

For optional ExSlop, Reach, ProgramFacts, ExAST, ExDNA, Instructor, Credence,
and Vibe decisions, read
[`references/ast-and-architecture-tools.md`](references/ast-and-architecture-tools.md)
before proposing package or configuration changes.

```bash
bash "${CLAUDE_PROJECT_DIR:-.}/bin/static_analysis.sh"
```

## After Running

1. Check overall PASS/FAIL status
2. Review individual tool results
3. Artifacts in `tmp/ai/static_analysis/`:
   - `summary.md` - Overall results
   - `compile.txt` - Compile output
   - `credo.txt` - Code quality issues
   - `dialyzer.txt` - Type errors
   - `sobelow.txt` - Security issues

## Output Format

Return a 5-10 bullet summary including:
- Overall PASS/FAIL status
- Status of each tool (PASS/FAIL/SKIP)
- Issue counts by category
- Most critical issues (if any) with file:line references
- Path to detailed artifacts

Do NOT paste full tool output. Categorize issues and reference artifact paths.

## Priority Order for Fixes

1. Compile errors (blocking)
2. Security issues (sobelow)
3. Type errors (dialyzer)
4. Code quality (credo)
5. Format issues (auto-fixable)
