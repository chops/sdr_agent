---
name: handoff
description: Capture session state for continuation. Use when context is running low or before ending a session.
allowed-tools: Bash(git:*), Bash(mkdir:*), Read, Glob, Write, Edit, AskUserQuestion
---

# Session Handoff

Captures session state and generates a comprehensive continuation document for resuming work in a new session with zero prior context.

## When to Use

- Context is running low (approaching token limit)
- Ending a session but work remains
- Want to checkpoint progress before a risky operation

## Critical Requirement

The continuation prompt must give the next agent **everything it needs to start working immediately**:
- Project type and tech stack
- Workflow system and phases
- Rules that govern behavior
- Current task context
- **SPECIFIC NEXT ACTION** (most important!)

The next agent starts with ZERO context. Assume it knows nothing about this project.

## MANDATORY: "What's Next" Section

**The "Your Next Action" section is the MOST IMPORTANT part of the handoff.**

The next agent must know EXACTLY what to do first. Not a summary. Not a vague direction. A SPECIFIC, ACTIONABLE instruction.

### GOOD Examples:
```
**Immediate next step:** Write failing test for User.register action that verifies email uniqueness validation

**Start by:**
1. Read the plan: notes/features/user-registration.org
2. Create test file: test/my_app/accounts/user_test.exs
3. Write test that calls Accounts.register(%{email: "existing@test.com"}) and expects error
```

```
**Immediate next step:** Implement the email validation in lib/my_app/accounts/user.ex:45

**Start by:**
1. Read the failing test at test/my_app/accounts/user_test.exs:23
2. Add validate_format constraint for email attribute
3. Run mix test test/my_app/accounts/user_test.exs:23 to verify it passes
```

### BAD Examples (NEVER do this):
- "Continue with the plan" ❌
- "Pick up where we left off" ❌
- "Implement remaining features" ❌
- "See the plan for next steps" ❌
- Just listing what was completed without next action ❌

## Workflow

### 1. Gather Context

```bash
git status
git log --oneline -10
git diff --stat
```

Also gather:
- Project type (check mix.exs for deps: Ash, Phoenix, etc.)
- Development environment declarations and their current status
- Active plan file location
- Key files modified in current work
- **TDD enforcement status:**
  - Do failing test files exist? (check `test/` — or `apps/*/test/` in an umbrella)
  - Were tests verified with `tdd-verify`?
  - **If NO failing tests exist → Phase 4b is BLOCKED. Next agent MUST write tests first.**
- **ADR status:**
  - Does the active plan require an ADR? (check the plan's ADR section)
  - If required, does the ADR file exist in `docs/adr/`? What is its status?
  - **If ADR required but missing → next agent must create it before implementation.**

### 1b. Gather Environment Constraints

Read the project doctrine and local environment declarations if they exist:

```bash
cat AGENTS.md 2>/dev/null || echo "No AGENTS.md"
cat .envrc 2>/dev/null || true
```

Extract key constraints for the continuation prompt:
- Platform (OS)
- Tools that are NOT available (critical - prevents bad suggestions)
- Preferred tools and approaches
- Any project-specific environment notes

### 2. Find and Update Plan Document

Locate the active plan by globbing `*.org` and legacy `*.md` under both
`notes/features/` and `notes/fixes/`. New feature and fix plans use Org;
plans that predate the migration may finish in Markdown and must not be
converted merely because they are touched.

- **Mark completed tasks** as done (based on git commits, modified files)
- **Add unplanned work** that was done but not in original plan
- Save the updated plan

### 3. Handle Uncommitted Changes (Before Handoff)

If uncommitted changes exist:
- Prompt: "Commit these changes before handoff?"
- If yes → ask for commit message (suggest "WIP: [feature]" if incomplete, proper message if finished)
- If no → proceed without committing

**Important:** Commit handling is YOUR responsibility. Do NOT include commit instructions in the handoff document.

### 4. Generate Handoff Document

Create the ignored runtime directory first with `mkdir -p notes/sessions`.
Then create `notes/sessions/handoff-YYYYMMDD-HHMMSS.md` with complete context:

```markdown
---
created: YYYY-MM-DD HH:MM:SS
plan_file: [path to plan]
---

# Session Handoff

## Session Summary
[One paragraph describing work in progress]

## Work Completed
- [x] Task 1 - files: `path/file.ex:123`
- [x] Task 2 - files: `path/other.ex:45`

## Work Remaining
- [ ] Task 3 - next steps: ...
- [ ] Task 4 - blocked by: ...

## Key Decisions Made
- Decision 1: [rationale]

## ADR Status
- **Required by plan:** YES / NO
- **ADR file:** `docs/adr/NNNN-title.md` or N/A
- **Status:** Proposed / Accepted / N/A

## Git State at Handoff
[Record only - "All committed" or list of uncommitted files]

## Current Blockers
- [Any unresolved questions]

---

## Continuation Prompt

Copy below this line to start new session:

---

# Context

You are continuing work on this project.

## Project Structure
- **Project kind and stack:** [derive from the project files and workflow receipt]
- **Application boundaries:** [list the relevant modules, domains, or document sets]
- **Development environment:** [derive from `.envrc`, flake files, and project facts]
- **Workflow rules:** `.claude/rules/` contains behavior rules you MUST follow
- **Skills:** `.claude/skills/` contains specialized workflows (plan, implement, review, etc.)

## Development Environment

Read `.workflow/project-facts.md`, `.workflow/recipe.json`,
`.workflow/receipt.json`, `.envrc`, and any checked-in flake files. Record the
exact setup and start commands they prescribe. Do not hand-copy workflow files
or invent environment settings; generation is an atomic factory operation.

## Environment Constraints (DO NOT VIOLATE)

**Read `AGENTS.md` and project-local environment configuration for full details.**

**Platform:** [macOS / Linux]

**Tools NOT available (never suggest these):**
- [List tools from environment rules, e.g., Docker, docker-compose]

**Preferred approaches:**
- [List preferences from environment rules]

**IMPORTANT:** If you're unsure whether a tool is available, check project-local environment declarations before suggesting it.

## Workflow System

This project uses a phased workflow:

1. **Phase 1 (Research):** Read-only exploration
2. **Phase 2 (Plan):** Create an Org plan in `notes/features/` or `notes/fixes/`; legacy in-flight Markdown plans remain readable
3. **Phase 3 (Approve):** HARD STOP - wait for human approval
4. **Phase 4a (Tests):** Write failing tests first (TDD)
5. **Phase 4a Gate:** Verify tests fail with `tdd-verify` skill
6. **Phase 4b (Implement):** Make tests pass
7. **Phase 5 (Verify):** Run full test suite, update docs

**Key doctrine to read first:**
- `AGENTS.md` - canonical project workflow and selected stack constraints
- `.claude/rules/` - Claude-only rules that load alongside `AGENTS.md`, when present

## Available Skills

Invoke these by context (the model activates them based on what you ask):
- `plan` - Design before implement
- `implement` - Execute approved plan with TDD
- `tdd-verify` - Verify tests fail correctly
- `review` - Code review with categorized output
- `test-runner` - Run tests with structured output
- `static-analysis` - Run compile, credo, dialyzer, sobelow
- `pr-ready` - Pre-merge checklist

## Ash Constraints (Non-Negotiable)

- **Never** mutate Ash structs directly (`%Resource{resource | field: value}`)
- **Always** use `Ash.Changeset.for_create/update` or Domain actions
- **Test through domain API** (`Domain.create!`, `Ash.read!`)
- **Policies** require both allow AND deny test scenarios

## TDD ENFORCEMENT (NON-NEGOTIABLE)

**YOU MUST WRITE FAILING TESTS BEFORE ANY IMPLEMENTATION CODE.**

### What "failing tests" means:
1. **Happy path test** - Tests the success case (MUST exist and FAIL)
2. **Sad path test(s)** - Tests failure cases (MUST exist and FAIL)
3. **Verified with `tdd-verify`** - Must show status: VERIFIED

### Enforcement:
- **Phase 4a** = Write tests that FAIL. NO implementation code allowed.
- **TDD Gate** = Run `tdd-verify`. Must return VERIFIED.
- **Phase 4b** = ONLY after gate passes, implement to make tests pass.

### If you don't have failing tests:
**STOP. You cannot write implementation code.**
1. Write a failing happy path test first
2. Write failing sad path test(s)
3. Run `tdd-verify` to verify they fail with assertion errors
4. THEN you may implement

**Violation = writing ANY non-test code before tests are verified failing.**

See the TDD section in `AGENTS.md` for project-specific examples and gates.

---

# Current Task

**Plan file:** [path to plan file]

**What we're building:** [one sentence description]

**Completed this session:**
- [x] [completed item 1]
- [x] [completed item 2]

**Remaining work:**
- [ ] [remaining item 1]
- [ ] [remaining item 2]

## TDD ENFORCEMENT GATE

**Before writing ANY implementation code, ALL must be true:**

- [ ] Failing happy path test exists
- [ ] Failing sad path test(s) exist
- [ ] Tests verified with `tdd-verify` (status: VERIFIED)

**Current status:**
- **Failing tests written:** [YES / NO]
- **Happy path tests:** [list test names or "none yet"]
- **Sad path tests:** [list test names or "none yet"]
- **tdd-verify result:** [VERIFIED / NOT RUN / BLOCKED]

**Test files:** [paths to test files or "none yet"]

**ENFORCEMENT:** If any checkbox above is unchecked, you are in **Phase 4a**.
You CANNOT write implementation code. You MUST write failing tests first.

**Key files you'll need:**
- `[path/to/file.ex]` - [what it does]
- `[path/to/other.ex]` - [what it does]

---

# YOUR NEXT ACTION (MANDATORY - BE SPECIFIC!)

**Current phase:** [Phase 4a / Phase 4b / Phase 5]

**TDD Gate Status:** [NOT PASSED - write tests first / PASSED - implementation allowed]

**If Phase 4a (tests only, NO implementation):**
- Write failing happy path test for: [specific behavior]
- Write failing sad path test for: [specific failure case]
- Then run: `tdd-verify test/path/to/test.exs`

**If Phase 4b (implementation, tests must already exist):**
- Tests to make pass: [list test file:line]
- Implement in: [specific file:line]

**Immediate next step:** [SPECIFIC action - "Write failing test for X" or "Implement X to make test pass"]

**Start by:**
1. [Exact first command or file to read]
2. [Exact second action]
3. [Expected outcome]

---
```

### 5. Output Directly to User

**CRITICAL:** You MUST print the full continuation prompt directly in your response. The user should be able to copy it without opening any files.

## Output Format

```
Session handoff complete.

Plan updated: 3 tasks marked complete, 1 task added
Handoff saved: notes/sessions/handoff-20240115-143022.md

---

## Continuation Prompt

Copy everything below to start a new session:

---

# Context

You are continuing work on an **Ash/Phoenix/Elixir** project.

[... full continuation prompt as shown above ...]

---
```

## Do NOT

- Reference the handoff file instead of printing the prompt
- Include commit instructions in the continuation prompt
- Assume the next agent knows anything about this project
- Skip the project structure / workflow explanation
- **Skip the environment constraints section** - next agent MUST know what tools are unavailable
- **Assume Docker/containers are available** - check environment rules first
- **Give vague next steps** like "continue with the plan" or "see remaining work"
- **End with just a summary** - summaries are NOT actionable
- **Skip the "Your Next Action" section** - this is MANDATORY

## Do

- Explain the tech stack (Ash/Phoenix/Elixir)
- List the key rules files to read
- Explain the workflow phases
- List available skills
- Give specific file paths
- **Include environment constraints from `AGENTS.md` and project-local configuration**
- **Explicitly list tools that are NOT available** (prevents bad suggestions)
- **Give a SPECIFIC next action with exact file paths and line numbers**
- **Tell the next agent exactly what command to run or file to edit first**
- **Include the current workflow phase (4a, 4b, 5, etc.)**

## Invocation Triggers

- "Prepare for handoff"
- "Save session state"
- "Context is running low"
- "Checkpoint this session"
- `/handoff`
