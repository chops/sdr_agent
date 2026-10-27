---
status: accepted
date: 2026-10-27
supersedes: null
---

# ADR-0019 Local revision of the factory receipt for `.workflow/project-facts.md`

## Acceptance note

Accepted (2026-10-27) as **D-229**, owner acceptance delegated by D-219 (with
D-221 and ADR-0014 Amendment 3, D-222); D-229 quotes no new owner answer.

- **The accepted text** is published below between the `ADR-0019` BEGIN and
  END markers exactly as reviewed, so its own front matter and Status still
  read *proposed*. The bytes between the two marker lines, including the
  newlines inside them, are 17797 bytes with SHA256
  `03b60bf48d9a9464d331823e5a73c665dc95283f91fb8da83700d8e97bf7780b`: Codex's
  exact-text PASS as submitted (efc3fe10; review
  `codex-c2star-s1-prb-p5-facts-r2-review-20261027.org`, SHA256
  `e01021f55591422a9e4973225757a7da582e9229c25de6867e1368be149dd728`). Source:
  draft `claude-c2star-facts-receipt-addendum-draft-r2.md`, SHA256
  `236283e1fe39de25ca4c52e669a87cc5c571df5bb67a1149c9abafb86bf1574f`, checked
  against `c2star-s1-environment` at `cf86b7aa77b3cd0766e37f7bcf88c4b44bd3abb5`.
- **It lands in S1's atomic facts commit (C5)** on `c2star-s1-prb-r2`, with:
  `.workflow/project-facts.md` revised (778 bytes, SHA256
  `80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c`);
  `.workflow/receipt.json` changed by the one substring replacement of the
  facts unit (SHA256
  `ca002d060d92e554de707d5f9b06e422a9de055b9963115e4dc5bc482f433ebf`, the
  one-unit derivation from the original receipt
  `26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475`); and the
  canary `test/workflow/project_facts_receipt_revision_test.exs` (A1-A4). The
  validator, the recipe and every other unit are unchanged. The number 0019
  was re-checked free on `main` at `d9bf2272bab6476795081f010813dfb2780cdac7`
  and on `c2star-s1-prb-r2` immediately before that commit.
- **It does not** edit or approve any change to #210 (ADR-0017). The joint
  canary amendment (C6) needs its own exact-text PASS and acceptance, and
  current authority if the delegation window (2026-11-01T06:00Z) has passed.
  The final candidate head and its re-sign are a separate review record.

<!-- BEGIN PROPOSED TEXT: ADR-0019 -->

---
status: proposed
date: 2026-10-27
supersedes: null
---

# ADR-0019 Local revision of the factory receipt for `.workflow/project-facts.md`

## Status

**Proposed. Not yet accepted.**

- **Acceptance path.** Codex's independent exact-text PASS, then a decision row recording owner
  acceptance delegated by D-219 (with D-221 item 5 and D-222, ADR-0014 Amendment 3). No owner wait
  is required.
- **Scope.** It approves exactly one thing: a project-local revision of the factory receipt's
  `.workflow/project-facts.md` unit, under the conditions below.
- **Until accepted:** no receipt edit and no facts edit are made.

**Acceptance note (filled on acceptance).** It names the exact reviewed text (its sha256 and the
head it was reviewed at) and the acceptance decision row. The final candidate head and its re-sign are
a separate review record, because adding the note itself changes the commit sha.

**Sources:**
- ADR-0004, agent-environment amendment item 1 (accepted as D-224);
- Codex review F4 and the OQ 1 answer of the S1 r1 plan review.

## Context

`.workflow/receipt.json` was written once by the project factory:
- scaffold commit `eccbe8fa9b35156206b0387fcc5449c10ad034f4`;
- receipt sha256 `26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475`;
- `created_at` 2026-10-06T21:26:41.360710Z;
- factory 0.1.0;
- upstream revision `22277a8e41667b489686c6baf34d10187cbae2db`.

One of its 44 owned units is the project facts file:

```json
{"artifact_id":"template-project-facts","destination":".workflow/project-facts.md","lifecycle":"seed_once",
 "operation":"render","operation_version":1,
 "sha256":"cc0ab2de09dd3f41e320bb4a92e927b1a022bd88a3fa00638f747039598b2d17","unit":".workflow/project-facts.md"}
```

**How the validator treats it.** `bin/verify` runs `bin/verify-workflow`, which runs
`.workflow/verify_workflow.exs`.
- It checks every owned unit (`validate_units/2`). It does not consult `lifecycle` except for
  `"external_generator"`.
- This unit has none of the dispatch keys (`symlink_target`, `marker_id`, `structured_entries`,
  `elixir_project_config`, `owned_lines`, `owned_tree_entries`). So its evidence is the whole-file
  sha256.
- On a mismatch the validator exits 1 with
  `drifted from installed receipt: owned unit differs: .workflow/project-facts.md`.

**Why a revision is needed.**
- The file says it is project-owned after creation (its line 3: "Lifecycle: `seed_once`;
  project-owned after creation."), but the receipt pins its bytes.
- ADR-0004's agent-environment amendment item 1 (D-224) requires port 4130 to be recorded there.
- The factory has no update or re-receipt command.

## Decision

Record a **project-local revision** of exactly one owned unit, `template-project-facts`
(`.workflow/project-facts.md`), accepted under D-219's delegation. The receipt keeps saying what the
factory generated, and it adds an explicit statement of the later local baseline. The factory did not
generate the revised bytes, and the original validation does not cover them.

### Binding conditions (each testable)

**C1. Original-generation provenance is retained.**
- Every top-level receipt field is semantically unchanged: `created_at`, `factory`, `generators`,
  `identity`, `preexisting_unowned`, `schema_version`, `selection`, `toolchain`, `upstream_revision`
  and `validation`.
- The original unit digest `cc0ab2de…2d17` is preserved in `local_revision.original_generation.sha256`,
  together with the generation's identity (receipt sha256, scaffold commit, `created_at`, factory
  version, upstream revision, `operation`, `operation_version`).

**C2. One unit's digest changes, plus explicit local-revision metadata, in exactly this shape.**
- The only differences from the original receipt are inside the owned unit whose
  `unit == ".workflow/project-facts.md"`:
  - (i) `sha256` changes from `cc0ab2de…` to the revised file's digest;
  - (ii) one key, `local_revision`, is added.
- No unit is added, removed or reordered.
- `artifact_id`, `destination`, `lifecycle` (`seed_once`), `operation` (`render`) and
  `operation_version` (1) are unchanged.
- `local_revision` has exactly this shape, schema `sdr-agent/receipt-local-revision/2`. That is
  ADR-0017's `/1` key set without `pr`. The change is identified by `adr`, `revision` and
  `revised_sha256`, never by an external number. The distinct schema id lets a canary tell the two
  shapes apart. Keys are sorted as the factory sorts:

```json
"local_revision": {
  "adr": "docs/adr/0019-project-facts-receipt-local-revision.md",
  "decision": "D-224",
  "enforced_by_validator": false,
  "original_generation": {
    "created_at": "2026-10-06T21:26:41.360710Z",
    "factory_version": "0.1.0",
    "operation": "render",
    "operation_version": 1,
    "receipt_sha256": "26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475",
    "scaffold_commit": "eccbe8fa9b35156206b0387fcc5449c10ad034f4",
    "sha256": "cc0ab2de09dd3f41e320bb4a92e927b1a022bd88a3fa00638f747039598b2d17",
    "upstream_revision": "22277a8e41667b489686c6baf34d10187cbae2db"
  },
  "provenance": "delegated-acceptance local baseline (D-219); the factory did not generate these bytes and the original validation does not cover them",
  "reason": "ADR-0004 agent-environment amendment item 1 (D-224): record the agentenv-1 Phoenix port 4130 and its database",
  "revised_sha256": "80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c",
  "revision": 1,
  "schema": "sdr-agent/receipt-local-revision/2"
}
```

- **Value rules.** `revised_sha256` equals the unit's `sha256`, and both equal sha256 of the revised
  `.workflow/project-facts.md` bytes. No `local_revision` key is a validator dispatch key, so the unit is
  still checked as a whole-file digest.
- **Which decision.** `decision` names the accepted requirement (D-224). D-224 did not itself accept
  this receipt edit. The ADR's acceptance row is recorded in the Status note, never in the receipt, so
  nothing refers to itself.

**C3. The validator, the recipe and every other receipt field are unchanged.**
- None of these is edited, and their recorded digests stay: `bin/verify-workflow` (`854262ac…f428`),
  `.workflow/verify_workflow.exs` (`e88a15f8…f158`), `bin/verify` (`1e5237a5…3d18`), and the recipe
  (`identity.recipe_sha256` `250b7b63…2572`).
- `schema_version` stays 1.
- Not done: no unit deletion, no `external_generator` relabelling, no lifecycle-based skip in the
  validator, no blanket rebaseline, no automatic drift acceptance.

**C4. A reviewed, scoped drift canary.** This is the ExUnit test
`test/workflow/project_facts_receipt_revision_test.exs`. It runs in `mix test`, so it is part of
`bin/verify` and CI. It never skips: any missing input fails. It needs only git, the copied tree and
the validator script, with no network, service or database. It checks:

- **A1, the revised unit set.** The set of owned units carrying `local_revision` is exactly
  {`template-project-facts`} (C6 governs the only permitted change of this set). That unit's
  `lifecycle`, `operation` and `operation_version` are `seed_once`, `render` and 1.
- **A2, the metadata is pinned in full.**
  - `local_revision` equals, as a JSON value, the complete C2 literal, including every string.
  - `revised_sha256 == unit.sha256 == sha256(.workflow/project-facts.md bytes)`, and the `adr` path exists.
  - **Pure sensitivity cases.** The A2 check must reject each of these: any single changed string
    value (at least `provenance`, `reason`, `decision`, `adr` and `schema`); any changed non-string value
    (`revision`, `enforced_by_validator`, each `original_generation` value); and one missing and one
    extra key at each level.
- **A3, nothing else changed.**
  - Load the original receipt from git object `eccbe8fa…:.workflow/receipt.json`, and verify its sha256
    `26beb14b…` before decoding it. CI checks out with `fetch-depth: 0`. A missing object fails, and
    there is no fetch or network fallback.
  - Normalize the current receipt: set the revised unit's `sha256` to the
    `local_revision.original_generation.sha256` read from that same receipt, and delete
    `local_revision`. The result must equal the original as a JSON value.
  - A missing `local_revision`, `original_generation` or `original_generation.sha256` fails A3 as
    missing provenance. A3 never substitutes a test literal for the receipt's own provenance.
- **A4, the validator still enforces the revised baseline.** A4 has two distinct parts.
  - **(i) Baseline-verification precondition.** Each case runs on its own fresh copy of the tracked
    tree (`git ls-files -z`) under the test's `tmp_dir`, with symlinks and modes preserved, and never
    writes through a link or into the worktree. Before each case, the copy's
    `.workflow/receipt.json` and `.workflow/project-facts.md` must hash to the pinned reviewed values:
    the whole revised receipt file, and `80fc3e55…953c`. Otherwise the case fails before the validator
    runs. The pinned receipt-file hash is the reviewed final receipt-byte expectation; only C6 may
    replace it.
  - **(ii) Behavioural cases.** Each runs the copy's own `bin/verify-workflow`, with a timeout, with
    exit status, stdout and stderr captured, and the copy removed afterwards.
    - (a) unchanged: exit 0, stdout `workflow receipt: ok`;
    - (b) one byte appended to the facts file: exit 1, stderr exactly
      `drifted from installed receipt: owned unit differs: .workflow/project-facts.md`;
    - (c) the facts file replaced by the original factory bytes (from git object
      `eccbe8fa…:.workflow/project-facts.md`, sha256 `cc0ab2de…` verified first): the same exit 1 and
      message;
    - (d) only `local_revision` removed from the receipt: exit 0. This is the documentary-metadata
      fact, recorded on purpose. A1, A2 and A3 must each, by its own independent assertion, reject
      that receipt.
- **How it fails:** an ExUnit assertion naming the check and the differing field, or the exact
  validator status and stderr.
- **Scope:** no other unit's metadata is asserted beyond A3's equality.

**C5. Atomic landing.**
- The revised facts file, the receipt revision, the canary and this ADR (with its acceptance note) land
  in **one commit** of the S1 pull request that carries PR-B.
- No receipt-only or facts-only commit reaches main.
- Before merge, for every commit `c` in the merged range,
  `sha256(c:.workflow/project-facts.md)` must equal the facts unit's `sha256` in `c:.workflow/receipt.json`.
- The canary's meaningful RED and its mutation evidence are retained as artifacts, never as
  inconsistent intermediate commits.
- Exact-head CI and the exact-candidate full gate pass, followed by the ordinary D-157 rebase merge.
- No history rewrite is authorized.

**C6. Coordination with ADR-0017 (#210, `devenv.nix`), without importing it.**
- **This ADR does not touch** `devenv.nix`, its unit or its canary, and it does not amend ADR-0017.
- **The conflict.** Each canary pins a one-unit revision set (its A1), normalizes only its own unit
  (its A3), and pins the whole receipt file's bytes in its A4 baseline precondition. So whichever of
  the two lands second changes the receipt file and makes the other's canary fail.
- **The joint amendment contract.** Before the second landing, a bounded exact-text amendment of both
  ADR-0017 C4 and this C4 is reviewed. It covers both canaries, both ADRs and the final combined
  receipt bytes. It needs its own independent PASS and its own D-219-delegated acceptance. Its delta
  is exactly this:
  - each canary's A1 set becomes exactly {`template-devenv`, `template-project-facts`};
  - each A3 normalizes exactly those two units, each from its own receipt-held `original_generation`;
  - each canary's A4 baseline precondition (i) pins the reviewed final combined receipt file's sha256,
    replacing its one-unit receipt hash, and keeps its own unit-file hash;
  - each canary's A4 behavioural cases (ii) are unchanged, for its own unit;
  - each canary's A2 literal for its own unit is unchanged, with every `original_generation` value and
    accepted unit metadata value preserved.
- **How the second landing edits the receipt.** It applies exactly one substring replacement, for its
  own unit, to the receipt as the first landing left it, and the final bytes are the reviewed ones. It
  never re-applies the first landing's replacement and never rebaselines another unit. C5's per-commit
  check covers both units.
- **Never:**
  - weakening or removing a receipt-baseline check to keep either canary green;
  - a rule accepting "any unit carrying `local_revision`";
  - a claim that a one-unit canary accepts two units;
  - permission to edit #210 now.

## Exact proposed change to `.workflow/project-facts.md`

Insert three lines after line 10 (`- Local services and explicit ports: PostgreSQL `5520`, Phoenix `4120``).
Every other byte is unchanged, and the trailing newline stays.

```
- Agent environment `agentenv-1` (ADR-0004 agent-environment amendment,
  D-224): Phoenix `4130` on loopback only; database `sdr_agent_agentenv` on
  PostgreSQL `5520`
```

Resulting file: 778 bytes, sha256 `80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c`
(the original is 610 bytes, `cc0ab2de…`).

## Exact proposed `receipt.json` change

The receipt is one line of compact, key-sorted JSON with a trailing newline. The change is exactly one
substring replacement; the old text occurs exactly once. It is applied as a byte-preserving patch,
never by re-serializing the file.

Old:

```
{"artifact_id":"template-project-facts","destination":".workflow/project-facts.md","lifecycle":"seed_once","operation":"render","operation_version":1,"sha256":"cc0ab2de09dd3f41e320bb4a92e927b1a022bd88a3fa00638f747039598b2d17","unit":".workflow/project-facts.md"}
```

New:

```
{"artifact_id":"template-project-facts","destination":".workflow/project-facts.md","lifecycle":"seed_once","local_revision":{"adr":"docs/adr/0019-project-facts-receipt-local-revision.md","decision":"D-224","enforced_by_validator":false,"original_generation":{"created_at":"2026-10-06T21:26:41.360710Z","factory_version":"0.1.0","operation":"render","operation_version":1,"receipt_sha256":"26beb14b426b8f2154096fa7d943fc9dc667f596e1769846ec6f7d739e829475","scaffold_commit":"eccbe8fa9b35156206b0387fcc5449c10ad034f4","sha256":"cc0ab2de09dd3f41e320bb4a92e927b1a022bd88a3fa00638f747039598b2d17","upstream_revision":"22277a8e41667b489686c6baf34d10187cbae2db"},"provenance":"delegated-acceptance local baseline (D-219); the factory did not generate these bytes and the original validation does not cover them","reason":"ADR-0004 agent-environment amendment item 1 (D-224): record the agentenv-1 Phoenix port 4130 and its database","revised_sha256":"80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c","revision":1,"schema":"sdr-agent/receipt-local-revision/2"},"operation":"render","operation_version":1,"sha256":"80fc3e55362ea74cb2545bd0c8668efdb63da336e32aaeba0e594f7a68ec953c","unit":".workflow/project-facts.md"}
```

If the facts bytes change before acceptance, both digests and C2's literal are re-reviewed.

## Resulting `bin/verify-workflow` behaviour

| State | Exit | Output |
|---|---|---|
| Revised receipt + revised facts | 0 | `workflow receipt: ok` |
| Revised receipt + original facts (`cc0ab2de…`) | 1 | `drifted from installed receipt: owned unit differs: .workflow/project-facts.md` (why C5 is atomic) |
| Revised receipt + any later facts edit | 1 | the same message, until another reviewed revision |
| Original receipt + revised facts | 1 | the same message |
| `local_revision` removed or altered, `sha256` still matching | 0 | not validator-enforced (`enforced_by_validator: false`); the canary's A1-A3 reject it |
| Any other unit, the validator, the recipe or `validation` changed | 1 | the validator's existing messages. A coordinated edit of another unit together with its digest is rejected by A3, not by the validator |

## Consequences

- **What the unit means now.** It is the accepted local baseline, with the factory's bytes kept as
  provenance. The canary makes that distinction checkable.
- **Future facts edits.** Each one needs another reviewed revision: an accepted decision, an ADR
  amendment or a new ADR, `revision` incremented, `original_generation` unchanged, and the canary's
  pinned literals updated in the same change. This ADR authorizes revision 1 only.
- **Cost.** Repeated per-unit revisions are a cost, and the second of #210 and S1 pays the C6 joint
  delta. A factory-side re-receipt remains the better long-term fix, as separate scoped work.

## Alternatives rejected

1. **Record port 4130 only in code, the launcher and a runtime comment.** This does not satisfy D-224's
   item 1 (Codex F4).
2. **Drop or relabel the unit, or make the validator skip `seed_once`.** This removes drift detection
   and edits factory-owned validator files (C3).
3. **Extend D-186/D-188 or ADR-0017 to cover this unit.** Those authorize `devenv.nix` only.

## Non-goals

- No other unit changes: `devenv.nix`, `flake.nix`, `bin/verify`, the validator files, the recipe,
  every managed block, structured-entry set and skill tree.
- No change to the factory or its templates.
- No agent-environment launch, database access, port bind, real call or spend.
- This ADR does not accept itself.

## Verification (on acceptance, in the S1 pull request)

1. Canary checks A1-A4 pass on the exact candidate. The meaningful RED (A1 fails on the unrevised
   tree) and the sensitivity cases are retained as artifacts.
2. C5's per-commit digest check holds over the merged range.
3. The exact-candidate full gate passes, including `bin/verify-workflow`, and exact-head CI passes.

<!-- END PROPOSED TEXT: ADR-0019 -->
