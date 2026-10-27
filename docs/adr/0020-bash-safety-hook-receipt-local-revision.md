---
status: proposed
date: 2026-10-27
supersedes: null
---

# ADR-0020 Scratch-folder deletes in the Bash safety hook: local revision of the receipt for `.claude/hooks/bash-safety.sh`

## Status

**Proposed. Not yet accepted.**

- **Authority.** The owner approved the change itself as **D-234** (2026-10-27). D-234 approves exactly
  one thing: a scoped, owner-approved local baseline revision of the one receipt-owned unit
  `.claude/hooks/bash-safety.sh`, under the 5b precedent (ADR-0017; shape as in ADR-0019).
- **Acceptance path.** Codex's independent exact-text PASS, then a separate decision row recording
  acceptance and citing D-234. Acceptance is never recorded in this file's own commit.
- **Scope.** This ADR approves no other change to a safety control.

## Context

`.claude/hooks/bash-safety.sh` is the project's Claude Code `PreToolUse` hook for the Bash tool
(`.claude/settings.json`). It blocks a few commands (exit 2) and, for risky ones, prints
`{"permissionDecision": "ask", ...}`. One of its ask rules matches any `rm` with `-r`, `-R` or `-f`
flags. An ask holds the agent's turn until the owner answers, so unattended agents stall on routine
cleanups of their own scratch folders.

**The owner's words (D-234, owner chat 2026-10-27):**

- "why do you keep asking for approval for certain commands? what are you going to do if i'm away
  from the keyboard and time runs out? i would much prefer you just run those commands after asking
  codex to review the command instead of relying on my to always be in front of my computer"
  (20:32:26Z);
- "but doesn't that risk leaving a bunch of useless junk in the repo? that doesn't sound like a good
  compromise." (20:35:06Z);
- to Claude's proposal (the hook allows deletes only inside the scratch folders by exact path;
  everything else, including other deletes, database drops, sudo and force-push, still asks; the
  owner's OK plus a short ADR, because the hook is a receipt-owned workflow unit; Codex reviews both):
  "yes" (20:35:55Z, UUID e13c965c-1124-4e4e-833a-d28d7472fbb7).

**The receipt.** `.workflow/receipt.json` was written once by the project factory: scaffold commit
`eccbe8fa9b35156206b0387fcc5449c10ad034f4`, receipt sha256
`26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475`, `created_at`
2026-10-06T21:26:41.360710Z, factory 0.1.0, upstream revision
`22277a8e41667b489686c6baf34d10187cbae2db`. One of its 44 owned units is the hook:

```json
{"artifact_id":"hook-bash-safety","destination":".claude/hooks/bash-safety.sh","lifecycle":"managed_file",
 "operation":"copy","operation_version":1,
 "sha256":"846ab6d21c8ed733c624a420430001e9bb1256cdce6b9619fed229579b0775ac","unit":".claude/hooks/bash-safety.sh"}
```

`bin/verify` runs `bin/verify-workflow`, which runs `.workflow/verify_workflow.exs`. This unit has
none of the validator's dispatch keys, so its evidence is the whole-file sha256; any edit fails with
`drifted from installed receipt: owned unit differs: .claude/hooks/bash-safety.sh`. The factory has
no update or re-receipt command.

## Decision

### 1. The hook: one narrow allow

A new section, **after** the existing BLOCKERS and **before** the existing ASK rules, exits 0 (allow,
no output) only when **all** of the following hold. Otherwise it does nothing and every later rule
runs exactly as before.

1. The whole command is a single `rm` invocation: its first word is exactly `rm`.
2. Its flags are a subset of `-r`, `-R` and `-f`, combined or separate (`-rf`, `-r -f`, `-fR -r`).
   Flags come first; nothing else starting with `-` is accepted (`--`, `-v`, `-i`,
   `--no-preserve-root` are refused).
3. There is at least one target.
4. Every target is a literal absolute path that starts with exactly
   `/private/tmp/claude-501/-Users-charles-src-SDR-agent/` followed by at least one more path
   component. The root itself, the root plus `/` (or `//`), a sibling such as
   `…/-Users-charles-src-SDR-agent-evil/x`, `/private/tmp/claude-501/` and the `/tmp/…` alias are
   refused.
5. The command contains none of `;` `&` `|` `` ` `` `$` `(` `)` `<` `>` `*` `?` `[` `]` `{` `}` `~`, a
   newline, a quote character, or a `..` path segment.

It also enforces four **narrowings** that only ever turn an allow into today's ask:

- **(N1) Character allowlist.** The command may contain only ASCII letters, digits, space, `.`, `_`,
  `-` and `/`. This implies rule 5 and also refuses a backslash (`\.\.` would become `..`), a tab, `#`,
  `!`, `=`, `%`, `@`, any other control character and any non-ASCII character.
- **(N2) Length as sent.** The command's length as the hook sees it must equal the JSON string's
  length (`jq '.tool_input.command | length'`), so a NUL byte the shell drops, or a trailing newline
  that command substitution strips, cannot hide.
- **(N3) No `.` segment.** A `.` segment is refused as well as `..`, so `…/-Users-charles-src-SDR-agent/.`
  cannot name the root.
- **(N4) No symlink on the path.** No prefix of a target, from its first component down to the target
  itself, may be a symbolic link when the hook runs. A literal path under the root that resolves
  elsewhere through a link (for example `…/scratchpad/wt/lib`, where `wt` links to a worktree) is
  refused, with or without a trailing slash.

The section defines `SCRATCH_ROOT` once, on a line of its own, and two functions
(`scratch_target`, `scratch_delete_only`). It uses only bash 3.2 features (`/bin/bash` on macOS) and
`jq`, which the hook already needs. No other rule, message or exit code changes. The revised hook is
6199 bytes, sha256 `d1b9bf6a3d447d99db5e50dc060b10474358646f35d56f200294c374b4e4659e`.

**Unchanged on purpose.**
- Blockers still exit 2: `rm -rf /`, `rm -rf ~`, `curl … | sh`, `wget … | bash`.
- Asks still ask, with their existing reasons: every other `rm -r/-R/-f`, `git push --force`,
  `git reset --hard`, `git clean -fd`, `mix ecto.drop`/`ecto.reset`, `DROP TABLE/DATABASE`, `TRUNCATE`,
  `DELETE` without `WHERE`, and `sudo` (including `sudo rm …` of a scratch path).
- The existing rm pattern's own gaps are neither widened nor narrowed: it never asked for `rm -rfv …`,
  `rm --recursive …` or a bare `rm -rf` with no trailing space, and it still does not.
- Codex's separate hook unit, `.codex/hooks/bash-safety.sh`, is not touched.

### 2. Why it is safe

- **Scratch only.** The only newly allowed effect is deleting entries strictly below the agents' own
  scratch folder, which holds per-session temporary files outside the repository, the worktrees and
  `~/.local/state`. The hook checks the location only. It cannot tell whether a target is still in
  use, is retained evidence, or belongs to another session: being outside Git does not make data
  expendable.
- **Literal paths only.** With N1 no expansion of any kind can run (variables, globs, braces, tilde,
  command substitution, quotes, escapes), so the paths the hook checks are the paths `rm` receives. N4
  rejects a path whose prefix is a symlink when the hook runs. That is a check before the command
  executes, in a different process, not an atomic guarantee: a same-user process could still change a
  path between the check and the delete. The intended use assumes the scratch folder's ancestors stay
  stable and that only the trusted agents act there; it does not claim confinement against concurrent
  hostile path substitution.
- **Every other control is unchanged.** Blockers run first, untouched. A command that fails any
  condition falls through to the same rules as before, so it asks or blocks exactly as it did.
- **Tested both ways.** `test/workflow/bash_safety_hook_test.exs` (86 cases) covers each allowed
  shape, each refusal above and the unchanged rules. A derived copy of the hook, differing only in the
  `SCRATCH_ROOT` line, exercises N4 without touching the real scratch folder. Eight one-line mutants
  of the new section (no symlink check, no allowlist, no length check, no dot-segment check, no
  component check, wider flags, prefix without `/`, no target required) are each killed.

### 2a. What it does not authorise

- This omits one hook prompt for one command shape. It is not authority to delete arbitrary files
  under the scratch root.
- Each actual cleanup must be authorised by the task at hand, name concrete targets, and be known to
  be disposable. Evidence that a report, review or decision cites is preserved, or archived durably
  first.
- No agent deletes another session's output, an active run's files, lease or job directories, or a
  whole session tree merely because it is under the root. When ownership is uncertain, coordinate with
  its owner first.

### 3. The receipt: binding conditions (ADR-0019 shape)

**C1. Original-generation provenance is retained.** Every top-level receipt field is unchanged. The
original unit digest `846ab6d2…75ac` is kept in `local_revision.original_generation.sha256`, with the
generation's identity (receipt sha256, scaffold commit, `created_at`, factory version, upstream
revision, `operation`, `operation_version`).

**C2. One unit's digest changes, plus explicit local-revision metadata, in exactly this shape.** The
only differences from the original receipt are inside the owned unit whose
`unit == ".claude/hooks/bash-safety.sh"`: (i) `sha256` changes from `846ab6d2…` to the revised hook's
digest; (ii) one key, `local_revision`, is added. No unit is added, removed or reordered;
`artifact_id`, `destination`, `lifecycle` (`managed_file`), `operation` (`copy`) and
`operation_version` (1) are unchanged. `local_revision` uses ADR-0019's schema
`sdr-agent/receipt-local-revision/2`, keys sorted as the factory sorts:

```json
"local_revision": {
  "adr": "docs/adr/0020-bash-safety-hook-receipt-local-revision.md",
  "decision": "D-234",
  "enforced_by_validator": false,
  "original_generation": {
    "created_at": "2026-10-06T21:26:41.360710Z",
    "factory_version": "0.1.0",
    "operation": "copy",
    "operation_version": 1,
    "receipt_sha256": "26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475",
    "scaffold_commit": "eccbe8fa9b35156206b0387fcc5449c10ad034f4",
    "sha256": "846ab6d21c8ed733c624a420430001e9bb1256cdce6b9619fed229579b0775ac",
    "upstream_revision": "22277a8e41667b489686c6baf34d10187cbae2db"
  },
  "provenance": "owner-approved local baseline (D-234); the factory did not generate these bytes and the original validation does not cover them",
  "reason": "D-234: the Bash safety hook lets a single rm of literal paths inside the agents' scratch folder run without asking",
  "revised_sha256": "d1b9bf6a3d447d99db5e50dc060b10474358646f35d56f200294c374b4e4659e",
  "revision": 1,
  "schema": "sdr-agent/receipt-local-revision/2"
}
```

`revised_sha256` equals the unit's `sha256`, and both equal sha256 of the revised hook. No
`local_revision` key is a validator dispatch key, so the unit is still checked as a whole-file digest.

**C3. The validator, the recipe and every other receipt field are unchanged.** Not edited:
`bin/verify-workflow` (`854262ac…f428`), `.workflow/verify_workflow.exs` (`e88a15f8…f158`),
`bin/verify` (`1e5237a5…3d18`), the recipe (`identity.recipe_sha256`) and `schema_version` 1. No unit
deletion, no `external_generator` relabelling, no lifecycle-based skip, no blanket rebaseline.

**C4. The drift canary.** `test/workflow/bash_safety_hook_receipt_revision_test.exs`, ADR-0019's A1-A4
for this unit. It runs in `mix test` (so in `bin/verify` and CI), never skips, and needs only git,
the copied tree and the validator.
- **A1:** the units carrying `local_revision` are exactly {`hook-bash-safety`}, `managed_file`,
  `copy`, 1.
- **A2:** `local_revision` equals the C2 literal as a JSON value; `revised_sha256 == unit sha256 ==
  sha256(hook)`; the `adr` path exists. Each of the 16 leaves changed, and a missing and an extra key
  at each level, is rejected.
- **A3:** from git object `eccbe8fa…:.workflow/receipt.json` (sha256 `26beb14b…` checked before
  decoding), the current receipt with this unit's `sha256` set from its own
  `original_generation.sha256` and `local_revision` deleted equals the original. This is the check
  that every other owned unit is untouched.
- **A4:** on fresh copies of the tracked tree, (i) the copy's receipt and hook hash to the pins (the
  whole revised receipt, 25672 bytes, sha256
  `bd5b9a1b1d970b0d3cd5d6ab62b907b806fa601c070778613a185943553f2f05`, and `d1b9bf6a…`); (ii) the
  copy's own `bin/verify-workflow`: unchanged, exit 0; a byte appended to the hook, or the original
  factory hook, exit 1 with exactly the drift message; only `local_revision` removed, exit 0, and A1,
  A2 and A3 each reject that receipt.

**C5. Atomic landing.** The hook change, the receipt revision and the canary land in **one commit**;
this ADR may precede it in the same pull request. No receipt-only or hook-only commit reaches main.
For every commit `c` in the merged range, `sha256(c:.claude/hooks/bash-safety.sh)` equals the hook
unit's `sha256` in `c:.workflow/receipt.json`. Exact-head CI and the exact-candidate full gate pass
before the ordinary D-157 rebase merge. No history rewrite is authorized.

**C6. Coordination with ADR-0017 (#210, `devenv.nix`) and ADR-0019 (S1, project facts).** Both are
accepted but neither is on main at this ADR's base (`9589ede1`). Each canary pins a one-unit revision
set (its A1), normalizes only its own unit (its A3) and pins the whole receipt file (its A4 (i)), so
whichever lands after another changes the receipt and fails the other's canary. Before a later
landing, a bounded exact-text amendment of every affected ADR's C4 is reviewed and accepted, with
ADR-0019 C6's delta generalized to the landed set: each A1 set becomes exactly the landed units; each
A3 normalizes exactly those units, each from its own `original_generation`; each A4 (i) pins the
reviewed final combined receipt and keeps its own unit-file hash; A2 literals and A4 (ii) are
unchanged. The later landing applies exactly one substring replacement, for its own unit, to the
receipt as found. Never: a weakened baseline check, a rule accepting "any unit carrying
`local_revision`", or an edit of another ADR's PR from this one.

### 4. Exact `receipt.json` change

The receipt is one line of compact, key-sorted JSON with a trailing newline. The change is exactly one
substring replacement of text that occurs once, applied byte-preserving, never by re-serializing.

Old:

```
{"artifact_id":"hook-bash-safety","destination":".claude/hooks/bash-safety.sh","lifecycle":"managed_file","operation":"copy","operation_version":1,"sha256":"846ab6d21c8ed733c624a420430001e9bb1256cdce6b9619fed229579b0775ac","unit":".claude/hooks/bash-safety.sh"}
```

New:

```
{"artifact_id":"hook-bash-safety","destination":".claude/hooks/bash-safety.sh","lifecycle":"managed_file","local_revision":{"adr":"docs/adr/0020-bash-safety-hook-receipt-local-revision.md","decision":"D-234","enforced_by_validator":false,"original_generation":{"created_at":"2026-10-06T21:26:41.360710Z","factory_version":"0.1.0","operation":"copy","operation_version":1,"receipt_sha256":"26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475","scaffold_commit":"eccbe8fa9b35156206b0387fcc5449c10ad034f4","sha256":"846ab6d21c8ed733c624a420430001e9bb1256cdce6b9619fed229579b0775ac","upstream_revision":"22277a8e41667b489686c6baf34d10187cbae2db"},"provenance":"owner-approved local baseline (D-234); the factory did not generate these bytes and the original validation does not cover them","reason":"D-234: the Bash safety hook lets a single rm of literal paths inside the agents' scratch folder run without asking","revised_sha256":"d1b9bf6a3d447d99db5e50dc060b10474358646f35d56f200294c374b4e4659e","revision":1,"schema":"sdr-agent/receipt-local-revision/2"},"operation":"copy","operation_version":1,"sha256":"d1b9bf6a3d447d99db5e50dc060b10474358646f35d56f200294c374b4e4659e","unit":".claude/hooks/bash-safety.sh"}
```

### 5. Resulting `bin/verify-workflow` behaviour

| State | Exit | Output |
|---|---|---|
| Revised receipt + revised hook | 0 | `workflow receipt: ok` |
| Revised receipt + original hook (`846ab6d2…`) | 1 | `drifted from installed receipt: owned unit differs: .claude/hooks/bash-safety.sh` (why C5 is atomic) |
| Revised receipt + any later hook edit | 1 | the same message, until another reviewed revision |
| `local_revision` removed or altered, `sha256` still matching | 0 | not validator-enforced; the canary's A1-A3 reject it |
| Any other unit, the validator or the recipe changed | 1 | the validator's existing messages; a coordinated edit of another unit and its digest is rejected by A3 |

## Procedure for any later revision of this unit

1. An owner decision (a hook is a safety control; delegated acceptance does not cover it).
2. An ADR amendment or a new ADR with the exact new grammar and Codex's exact-text PASS.
3. RED tests for the new behaviour, then the hook edit.
4. One byte-preserving substring replacement of this unit's entry: `sha256` and `revised_sha256` set to
   the new hook digest, `revision` incremented, `original_generation` unchanged, `decision`, `reason`
   and `adr` updated.
5. The canary's pinned literal and A4 (i) hashes updated in the same commit as the hook and receipt
   (C5); `bin/verify-workflow` and the full gate pass at the exact head.

## Revisit when

- the scratch root moves (a different user id, project path or Claude Code scratchpad location, or
  sessions started in a worktree whose scratch root differs), which turns the allow into today's ask;
- an allow is observed that should have asked, or a scratch cleanup still asks that this grammar
  meant to allow;
- Claude Code changes its hook input or decision contract;
- the factory gains a re-receipt or update command (this local revision is then replaced);
- the owner wants a broader route, such as Codex review in place of the owner's confirmation for other
  destructive commands (a separate decision).

## Consequences

- The receipt's hook unit means "the owner-approved local baseline", with the factory's bytes kept as
  provenance; the canary makes that checkable.
- A hook edit now needs this ADR's procedure, and the second of #210, S1 and this change to land pays
  C6's joint amendment.
- The rule is machine- and path-specific by design (uid 501, this project path). Other scratch roots
  keep asking.

## Alternatives rejected

1. **Never delete; write fresh directories instead** (today's practice): rejected by the owner, because
   scratch accumulates (20:35:06Z).
2. **Let Codex approve any destructive command:** broader; not chosen in D-234.
3. **A prefix test without the narrowings:** a backslash, a tab, a dropped NUL, a `.` segment or a
   symlink would each let a "literal scratch path" reach outside the folder.
4. **Edit the validator, drop or relabel the unit, or allow any unit with `local_revision`:** removes
   drift detection or edits factory-owned files (C3).

## Non-goals

- No change to any other rule of the hook, to `.codex/hooks/bash-safety.sh`, to `.claude/settings.json`,
  to the validator, the recipe or any other receipt unit.
- No change to the factory or its templates.
- This ADR does not accept itself.

## Verification

1. `test/workflow/bash_safety_hook_test.exs`: RED on the unchanged hook (13 assertion failures of 86),
   GREEN on the revised hook (86/86); eight mutants each killed.
2. The canary A1-A4 RED on the unrevised receipt, GREEN on the revised one.
3. `bin/verify-workflow` prints `workflow receipt: ok`; C5's per-commit digest check holds over the
   pull request's commits.
4. The exact-candidate full gate passes on the standing lane runner, and exact-head CI passes.
