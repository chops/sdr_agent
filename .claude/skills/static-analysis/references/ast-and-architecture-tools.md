# AST and Architecture Tools

This is detailed package guidance loaded by the `static-analysis` skill when a
project is evaluating optional AST or architecture tooling. It is not runtime
doctrine and none of these packages is selected merely because it appears here.

These tools extend the skill's core static-analysis checks with AST-aware generated-code checks and module/call boundary analysis. `ex_slop` adds generated-code smell checks inside Credo; Reach analyzes module and call graphs to enforce architectural boundaries; ProgramFacts can generate known-answer module facts for analyzer trials. These tools do not replace Ash policies, validations, actions, or authorization rules. They also do not replace Credo: Credo remains the style and consistency gate, while these tools cover generated-code patterns and graph-level architecture checks that Credo does not model.

## Verdicts

| Tool | Verdict | Template Default | Rationale |
|------|---------|------------------|-----------|
| `ex_slop` | ADOPT | Yes | Credo plugin for high-signal generated-code smells and anti-patterns beyond ordinary Credo checks. |
| `reach` | TRIAL | Advisory only | Enforces module/call boundaries, but hard gating requires a project baseline and `REACH_ENFORCE=1`. |
| `program_facts` | TRIAL | No | Useful with Reach for validating analyzer and architecture-rule behavior; advisory only. |
| `ex_ast` | ADOPT | Yes | Default dev-only dependency for safe mechanical AST refactors; 0.12.0 release on 2026-05-15 signals active maintenance. |
| `ex_dna` | DEFER | No | Duplicate detection may be useful per project, but do not ship guessed Ash macro exclusions. |
| `instructor` | TRIAL-ON-PROJECT | No | Wraps Req for schema-validated LLM JSON outputs. Correct Hex package: `instructor`; opt in when structured LLM output validation is needed. |
| `credence` | TRIAL | Advisory only | `Credence.analyze/2` is report-only; never run `Credence.fix/2` in CI or TDD projects. |
| `vibe` | REJECT | No | Separate agent runtime collides with the ai-pair harness and current Claude/Codex workflow. |

## ExSlop

`ex_slop` is a Credo plugin for generated-code smells and anti-patterns: blanket rescues, swallowed exceptions, narrator docs/comments, identity passthroughs, bad Enum patterns, query-in-loop shapes, and related issues that ordinary Credo may not cover.

Add the dev/test dependency:

```elixir
{:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
```

The dependency alone is inert. Register the plugin in `.credo.exs`:

```elixir
%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}]
    }
  ]
}
```

Validation procedure for a new project:

```bash
mix deps.get
mix credo --strict
```

Run it once, triage the findings, fix real problems, and explicitly suppress or disable noisy checks with rationale. Promote it to CI only after that first triage pass.

## Reach

Reach analyzes module and call graphs. Use it to enforce architecture boundaries such as `web -> core` only, never `core -> web`. Reach is not an authorization system and does not replace Ash policies, Ash actions, validations, or Phoenix 1.8+ Scopes.

Reach requires Elixir 1.18+ and OTP 27+. Add it only after the project satisfies that floor:

```elixir
{:reach, "~> 2.7.1", only: [:dev, :test], runtime: false}
```

Correct call-rule shape must include the root module and submodules. Do not use `"MyApp.*"` alone because that misses a root `MyApp` caller.

```elixir
calls: [
  forbidden: [
    {["MyAppWeb", "MyAppWeb.*"], ["MyApp.Repo.*", "MyApp.Persistence.*"]},
    {["MyApp", "MyApp.*"], ["MyAppWeb", "MyAppWeb.*"]}
  ]
]
```

Reach anchors module patterns and escapes dots before expanding `*`, so `MyApp.*` does not match `MyAppWeb`. Prefix collision between `MyApp` and `MyAppWeb` is not the concern. Pattern overlap is still possible when adding more layers; Reach's `forbid_multiple_matches` coverage check flags modules that match more than one layer.

Baseline workflow:

```bash
mix reach.check --arch --write-baseline .reach-baseline.json
git add .reach.exs .reach-baseline.json
```

Advisory run:

```bash
mix reach.check --arch || true
mix reach.check --smells || true
```

Opt-in hard gate:

```bash
if [ "${REACH_ENFORCE:-0}" = "1" ]; then
  test -f .reach-baseline.json
  mix reach.check --arch
else
  mix reach.check --arch || true
fi
```

`mix reach.check --smells` is advisory. Do not gate on smell findings unless a project explicitly promotes a specific smell policy after baseline triage.

Caveat: persistence call-edge detection is unverified on a real Ash umbrella as of 2026-05-23. Keep that rule advisory until confirmed on the target project.

## ProgramFacts

ProgramFacts generates valid Elixir programs with known module, call, data-flow, effect, and architecture facts. It pairs with Reach when testing architecture-rule templates or analyzer behavior.

Trial dependency for workflow/analyzer tests only:

```elixir
{:program_facts, "~> 0.2.1", only: [:dev, :test], runtime: false}
```

Do not add ProgramFacts to normal app templates. Use it in workflow-tool tests or analyzer-focused projects when the expected module graph must be known before the tool runs.

## ExAST

ExAST is the default dev-only dependency for safe mechanical AST refactors that would be brittle with regex, such as removing `dbg/1`, replacing a known call shape, or searching for a Phoenix/Ash DSL pattern structurally.

Default dev/test dependency:

```elixir
{:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false}
```

Always preview rewrites, keep patches narrow, run `mix format`, and run the Phase 4a tests before broad verification.

## ExDNA

Defer ExDNA as a template default. If a project has a real duplication problem, start with ExDNA's built-in defaults and inspect the first report.

Do not ship a guessed `.ex_dna.exs` with Ash macro exclusions. Ash DSL macro noise must be proven by a real project run before exclusions are added.

## Instructor

Trial Instructor on projects that need structured LLM JSON output validation. The correct Hex package is `instructor`; the repo/package branding may appear as `instructor_ex`.

Instructor wraps Req-backed LLM calls with schemas, validation, and retry handling for invalid structured outputs. Use it behind a project-local adapter such as `MyApp.LLM.StructuredOutput` rather than calling it directly from LiveViews, Ash changes, or Oban workers.

Trial dependency:

```elixir
{:instructor, "~> 0.1.0"}
```

Do not add Instructor to default templates. Opt in only when the project has real structured-output needs, such as competitor extraction, company profile enrichment, or generated analysis summaries.

## Credence

Trial Credence as advisory reporting only. `Credence.analyze/2` detects issues without modifying code; `Credence.fix/2` applies rewrites and must not run in CI or TDD projects.

Use `Credence.analyze/2` for reporting only. Never run `Credence.fix/2` in CI or TDD projects. Keep findings advisory until baseline triage is complete.

## Vibe

Reject Vibe for this workflow. It is a separate BEAM-native coding agent runtime with its own TUI, web console, sessions, plugins, skills, subagents, and provider auth. That overlaps with the ai-pair harness and the current Claude/Codex workflow instead of strengthening the Ash/Phoenix umbrella rules.

## Phase Integration

| Phase | Tool Use |
|-------|----------|
| Phase 1 Research | Use Reach advisory commands such as `mix reach.map`, `mix reach.inspect`, and `mix reach.trace` when the question is about dependencies, impact, call paths, or data flow. Use ExAST for structural search when regex would be brittle. |
| Phase 2 Plan | If the plan changes app boundaries, call paths, dependency direction, or data-flow boundaries, name the relevant `.reach.exs` policy and whether the baseline must be updated. |
| Phase 4b Implement | Do not apply generated auto-fixes blindly. AST rewrites still require `mix format`, `mix compile --warnings-as-errors`, and the Phase 4a tests. |
| Phase 5 Verify | Run `mix credo --strict` with ExSlop after initial triage. Run Reach architecture checks advisory unless `.reach-baseline.json` exists and `REACH_ENFORCE=1` is set. Run Reach smells advisory only. |

Reach baseline creation is a one-time per-project step before first CI gating. Existing projects must baseline before hard fail is allowed.

## Anti-Patterns

- Installing `ex_slop` without registering `{ExSlop, []}` in `.credo.exs`.
- Adding `reach` as a hard CI gate before `.reach-baseline.json` exists.
- Treating Reach as a substitute for Ash policies, validations, actions, or authorization.
- Gating on `mix reach.check --smells` by default.
- Shipping a guessed `.ex_dna.exs` with Ash macro exclusions.
- Running Credence whole-repo auto-fix in a TDD project.
- Using `"MyApp.*"` alone in Reach call rules without also including the root `"MyApp"` pattern.
- Adding `ex_dna`, `program_facts`, `credence`, or `vibe` as template default deps.
