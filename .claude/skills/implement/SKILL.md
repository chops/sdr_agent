---
name: implement
description: Execute approved implementation plan with TDD tracking. Use after plan approval in Phase 4.
allowed-tools: Bash(*), Read, Grep, Glob, Edit, Write, LSP, Task
---

# Implementation Execution (TDD Protocol)

Execute an approved implementation plan using Test-Driven Development. This skill enforces the Phase 4a/4b split.

## Prerequisites

- Plan document exists in `notes/features/` or `notes/fixes/` as Org, or as legacy in-flight Markdown
- Human has explicitly approved the plan
- No unapproved changes to scope
- If plan's ADR section says "Required: YES", ADR exists in `docs/adr/` with status "Accepted"

## TDD Workflow

### Phase 4a: Write Failing Tests

1. **Create test files**
   ```bash
   # Identify test location based on module being tested
   # e.g., lib/my_app/accounts/user.ex → test/my_app/accounts/user_test.exs
   #   (umbrella: apps/my_app/lib/... → apps/my_app/test/...)
   ```

2. **Write tests for each "Required Tests" item**
   - Follow Ash testing rules: test through domain API
   - Include success, failure, and authorization scenarios
   - Do NOT write any implementation code yet

3. **Verify tests fail correctly**
   ```bash
   bash "${CLAUDE_PROJECT_DIR:-.}/bin/tdd_verify.sh" test/path/to/test.exs
   ```

4. **Present TDD Gate checkpoint**
   ```
   === Phase 4a Complete ===
   Tests written: N
   Tests verified failing: N
   Failure types: [assertion failures]

   Awaiting confirmation to proceed to Phase 4b (Implementation)
   ```

**HARD STOP:** Do not proceed to Phase 4b without explicit confirmation.

### Phase 4b: Implement

1. **Check generators first**
   ```bash
   mix help | grep -E "(ash|phoenix).gen"
   mix ash.gen.resource --yes  # if applicable
   ```

2. **Implement to make tests pass**
   - Follow Ash patterns exclusively
   - Never bypass Ash APIs with lower-level persistence mutations
   - Smallest change that makes the next test pass
   - After each change:
     ```bash
     mix compile --warnings-as-errors
     mix test test/path/to/test.exs:LINE  # run specific failing test
     ```

3. **Track progress**
   - Note any deviations from plan

4. **Complete when all Phase 4a tests pass**

## Constraints

- **Phase 4a is test-only** — no implementation files, no production code changes
- **Phase 4b follows tests** — implementation guided by failing tests
- **Ash patterns only** — no direct struct or lower-level persistence mutation
- **Scope discipline** — implement only what was approved
- **Compile frequently** — catch errors early

## Output Format

### After Phase 4a:
```
Phase 4a Complete: Failing Tests Written

Tests created:
- test/my_app/accounts/user_test.exs:15 - "creates user with valid attributes" [FAILING]
- test/my_app/accounts/user_test.exs:25 - "rejects invalid email" [FAILING]
- test/my_app/accounts/user_test.exs:35 - "allows admin to create" [FAILING]
- test/my_app/accounts/user_test.exs:45 - "denies guest creation" [FAILING]

TDD Verification: VERIFIED (4 tests fail with assertion errors)

Awaiting confirmation to proceed to Phase 4b.
```

### After Phase 4b steps:
```
Completed: [step description]
Files modified: [list]
Tests now passing: [list with file:line]
Tests still failing: [list]
Next: [next step]
```

## Escalation

Stop and ask if:
- Tests cannot be written before implementation (see Edge Cases below)
- Implementation reveals plan gaps
- Unexpected policy/authorization complexity
- Test failures indicate design issues (wrong failure type)
- Scope creep detected

## Edge Cases: When Tests-First Is Difficult

Some scenarios require exploration before tests can be written:

| Scenario | Approach |
|----------|----------|
| **API exploration** | Write spike code in scratch file, delete before 4a, then write tests |
| **Generator output unknown** | Run generator, examine output, write tests for expected behavior |
| **External service integration** | Write contract tests based on documentation first |
| **Complex Ash query building** | Use `iex` to explore, document findings, then write tests |

**Protocol for edge cases:**
1. Document why tests-first is blocked in plan notes
2. Perform minimal exploration to understand interface
3. Write tests based on exploration findings
4. Delete exploration code
5. Proceed with normal TDD flow

## Phase 5: Verify + Finalize

**This phase is mandatory.** Do not present completion until all steps are done.

### Step 1: Test Suite
```bash
mix compile --warnings-as-errors
mix test  # full suite, not just new tests
```

### Step 2: Moduledoc Review
Review new/modified public modules for missing or placeholder `@moduledoc`. Write meaningful docs with full implementation context.

### Step 3: Update Plan Document
Add implementation notes to the Org or legacy in-flight Markdown plan document under `notes/features/` or `notes/fixes/`.

### Step 4: Architecture Evaluation

**HARD STOP.** Evaluate whether this implementation changed the system architecture. Check each trigger:

- [ ] New child app added to the umbrella?
- [ ] New Ash domain created?
- [ ] New Ash resource added to a domain?
- [ ] Resource moved between domains or child apps?
- [ ] New Phoenix channel or LiveView added?
- [ ] New external integration (API client, message queue, etc.)?
- [ ] Data flow between domains changed?
- [ ] Supervision tree structure modified?

**If ANY box is checked:** Run the `architecture-diagram` skill to regenerate diagrams.

**If NONE are checked:** Explicitly state "Architecture unchanged — no diagram update needed."

**You must report your evaluation.** Example:
```
Architecture Evaluation:
- New Ash resource added? NO
- New LiveView added? YES (RunDetailLive)
→ Running architecture-diagram skill.
```

### Step 5: Present Completion Summary
```
=== Phase 5 Complete ===
Tests: N passing, 0 failures
Moduledocs: reviewed
Plan: updated with implementation notes
Architecture: [unchanged / diagrams updated]

Awaiting final confirmation.
```

**CHECKPOINT:** Await final confirmation before marking complete.
