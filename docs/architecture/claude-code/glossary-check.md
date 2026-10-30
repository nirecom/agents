# Glossary Check

Three checks keep the project's wording on the glossary (#2529). Entry criteria and file placement
are owned by [rules/docs/glossary.md](../../../rules/docs/glossary.md); how writers and reviewers use the
combined glossary is owned by [combined-glossary.md](../../../skills/_shared/combined-glossary.md).

| Check | Question | Owner |
|---|---|---|
| glossary provenance check | did every glossary add / delete / redefine come from the approved intent glossary? | `bin/check-glossary-provenance`, `bin/lib/glossary-provenance.js` |
| deterministic drift | does a stage's artifact spell a glossary term with a variant the [matching rules](#matching-rules) count as drift? | `bin/check-glossary-drift`, `bin/lib/glossary-drift.js` |
| tagged concern | did a reviewer raise a glossary-drift concern that is still open? | `bin/lib/concern-ledger/drift-tag.sh` |

The user lifts any of the three, term by term, with one sentinel: `WORKFLOW_GLOSSARY_ACCEPTED`.

## Stages

Each glossary stage maps to the workflow step whose completion it gates (`STAGE_STEP`,
`hooks/workflow-state/glossary-check/scope.js`):

| Stage | Step | Rule | Ledger format |
|---|---|---|---|
| `intent` | `clarify_intent` | R-A | — |
| `outline` | `outline` | R-A | `outline-plan` |
| `detail` | `detail` | R-A | `detail-plan` |
| `tests` | `review_tests` | R-S | `test-review` |
| `code` | `review_security` | R-S | `review-security-shared` |
| `docs` | `review_docs` | R-S | — |

**R-A (plan artifact).** The stage reads `<PLANS_DIR>/<sid>-<stage>.md` once and cuts it with
`artifactRangeOfBuffer(buf, step)`, which drops the same `digestExcludes` ranges as the plan approval
hash. The scan and the fingerprint read that one range. Intent's `## Issues` section is outside it:
Path C backfill writes that section mechanically from GitHub issue titles, so including it would make
every backfill stale the record, and the `CONFIRM_INTENT` approval sha already excludes it.

**R-S (committed files).** The stage reads the staged paths (`git diff --cached --name-only -z
--no-renames`) that `classifyStageFile` assigns to it: `tests` takes a `tests/` or `test/` prefix,
`docs` takes the `DOCS_ONLY_ALLOWLIST` of `hooks/workflow-gate/staged-evidence.js`, and `code` takes
everything else. Content comes from the index blobs (`stagedOids`, read through `git cat-file --batch`),
never from the working tree. A staged deletion enters as the pair (path, `"deleted"`). The digest is the
sha256 of `JSON.stringify(pairs)`; `empty` is true when no path matched.

**Merge-incoming exclusion.** While a merge is in progress (a `MERGE_HEAD` file exists), R-S drops
every merge-incoming file before reading blobs: a staged path whose index state (blob ID, or absence)
equals the state of the same path in `MERGE_HEAD`. Such a file came in with the merge untouched by the
branch, so scanning it would report drift the branch never introduced. `hooks/lib/merge-incoming.js`
decides this by reading the `git rev-parse --git-path MERGE_HEAD` file once (a ref named `MERGE_HEAD`
is never consulted) and asking git once for the index-versus-`MERGE_HEAD` diff. An octopus merge, a
malformed `MERGE_HEAD`, or a git failure is undecidable, and the stage keeps every path (fail-safe).
Outside a merge the pairs and the digest are unchanged; inside one the digest covers the remaining
pairs. `artifact.mergeIncoming` reports the outcome for diagnostics and is not part of the digest. The
module inherits `GIT_DIR` / `GIT_INDEX_FILE` from the environment. It reads the merge state through
`hooks/lib/merge-state.js` (`readMergeState`), which the tests gates' merge-parent baseline also uses
([case-marker-gate.md](case-marker-gate.md#merge-commits)).

Worktree resolution order: `opts.repoDir`, then `resolveSessionWorktreePath(sid)`, then the git root of
the cwd. None resolving is the error `worktree-unresolved`.

## Fingerprint (invariant I-FP)

The fingerprint covers exactly the inputs the check reads, and `loadStageInputs` in `scope.js` is the
only reader of them. It is the sha256 of `JSON.stringify` of the four input digests:

| Input | Digest |
|---|---|
| `artifact` | R-A range or R-S pairs, as above |
| `glossary` | sha256 of `JSON.stringify([[label, sha]…], legacy)` over `listMainGlossaryFiles` of the main worktree (the first `worktree ` line of `git worktree list --porcelain`); a read failure is `glossary-unavailable` |
| `intent_rows` | sha256 of the sorted JSON of `[term (case-exact, as the drift scan reads it), category, operation, normalizeDefinition(definition)]`; the intent stage builds rows from its own range, every other stage reads intent.md once, and a missing file means no rows |
| `rules` | sha256 over the path-sorted per-file sha256 of `RULE_MODULES`: `bin/lib/glossary-drift.js`, `hooks/lib/glossary-term.js`, `hooks/lib/comment-block-scan.js`, `hooks/lib/markdown-fence.js`, `bin/lib/glossary-provenance.js`, and the modules of `bin/lib/glossary-drift/` (`extract.js`, `terms.js`, `context.js`, `match.js`, `scan.js`) |

A changed matcher therefore stales every record, exactly as a changed artifact or glossary does.

## Deterministic drift check

`bin/check-glossary-drift --session <sid> --stage <stage> [--record]` scans the stage inputs for
spelling variants only — intent Accepted Tradeoff "the deterministic drift check covers spelling variants only".
Which variants count is set by the [matching rules](#matching-rules).
A term an intent row deletes is no longer canonical, so its variants are not checked, even while the main worktree glossary file still lists it; a delete paired with an add of the same term (a category move) keeps it. A delete row matches its own spelling only (case-insensitive, not singularized), so deleting `workflows` keeps a distinct `workflow`.
Meaning drift stays with the reviewers. It reads the current intent.md, not the approved version.

Exit codes: `0` no open finding, `1` open findings, `2` usage error, unreadable inputs, or fingerprint
unavailable. Each open finding prints

`  DRIFT: <stage> "<variant>" -> "<term>" at <file>:<line>`

followed by a narrow accept example (`term=<term> stage=<stage>`).

### Matching rules

Words are matched in one of two contexts (#2763). In `identifier context` (code spans, chunks with
`_ = $ { }`, capital words, fixed-format lines) a naming-convention difference is not drift, but a
changed word form or a whitespace split is. In `prose context` a regular plural and the capitals of a
sentence start, a heading line or a table header row are tolerated; case mid-sentence, a hyphen for a
space, and an identifier split into words stay drift. The full rules, with examples, are in
[matching-rules.md](glossary-check/matching-rules.md).

### `glossary_check` record

`--record` writes a step annotation on the stage's step (provenance `observed`, origin
`check-glossary-drift`):

```json
{ "v": 1, "stage": "docs", "fingerprint": "<sha256>",
  "inputs": { "artifact": "…", "glossary": "…", "intent_rows": "…", "rules": "…" },
  "findings": [ { "source": "deterministic", "class": "spelling", "term": "…", "norm": "…", "variant": "…", "where": "…" } ],
  "grants": [ { "norm": "…", "fingerprint": "<sha256>", "reason": "…" } ],
  "ledger_grants": [ { "norm": "…", "discrim": "…", "reason": "…" } ] }
```

On re-record only `grants` with the new fingerprint carry over; `ledger_grants` always carry over. A
record holding only `ledger_grants` (written by the sentinel before any `--record`) has no fingerprint
and counts as missing.

### Evaluation

`evaluateGlossaryCheck` (`record.js`) judges in this order:

1. Commit mode, an R-S stage, and `artifact.empty` — ok (this commit stages nothing for the stage, including when every staged path of the stage is a merge-incoming file).
2. No record, or no `fingerprint` in it — `glossary-check-missing`.
3. The current fingerprint cannot be computed — `glossary-fingerprint-unavailable`.
4. The fingerprints differ — `glossary-check-stale`, with `detail.changed` naming the changed inputs.
5. A finding without a grant of the same fingerprint and norm — `glossary-findings-unresolved`.

### Completion boundary

`events.js` calls `glossaryBoundaryForBatch` right after `completionBoundaryEventsForBatch`. When one of
the six steps moves from not-complete to `complete` without a valid record it throws
`GlossaryCheckIncompleteError`, so every writer — hooks, `next-step`, `reconcile-state` — is gated alike.
An inherited batch (`origin: "session-inherit"`) and a `RESET_FROM` batch (one carrying a `reset` event)
are not judged. On the read side, `canResolveFromEvidence` (`effective-state.js`) also
requires `evaluateGlossaryCheck(...).ok` before it resolves an approval-gated step from pending to
complete. The boundary requires a record even when the R-S file set is empty.
A plan stage already recorded complete whose record no longer verifies reads as `pending`:
`gatedCompleteRefusal` (`effective-state.js`) is the one predicate the reconciled view, `current-step.js`
and the `--advance` "already complete" answer share, so a re-issued `--advance` is refused, not `already`.
A post-delivery session is exempt (#2796): once `final_report` is recorded complete or `merge_to_main` is
recorded settled (complete or skipped), `gatedCompleteRefusal` returns null, so the delivered plan stages
stay complete when main's glossary changes and the stop guard stops demanding a re-plan.
`isPostDeliverySession` (`effective-state/post-delivery.js`) judges the raw record, not the table-skip
projection, so a WF-META session whose `merge_to_main` is only table-skipped stays pre-delivery.

### Commit gate

`hooks/workflow-gate/commit-gate-steps.js` runs `checkGlossaryRecord`
(`hooks/workflow-gate/glossary-record-checker.js`) for `review_tests`, `review_security` and
`review_docs` at every step status, `pending` included, before any other checker, bypass or status
shortcut. A step whose stage has none of its targets staged passes; otherwise a missing record blocks
with `glossary-check-missing`. The record is re-verified against that commit's staged files, so its lifetime is one commit: a commit
staging nothing for a stage passes that stage, and any other commit needs a fresh `--record` (the
record keeps the latest value only). A block reads

`<step>: <code>(detail) — run: check-glossary-drift --stage <stage> --record (session <sid>), then fix each DRIFT finding or record an ACCEPTED grant.`

## Glossary provenance check

`bin/check-glossary-provenance --staged [--session <sid>] --repo <root>` compares the HEAD term sets
(both sides read old paths alike, see [Migration](#migration-temporary)) with the index term sets and derives the
add / delete / redefine operations per category. A redefinition is any change of the definition text —
intent Accepted Tradeoff "a redefinition covers every change of the definition text"; delete is not compared on definition.
A heading's case is part of the term: a case-only heading rename is a delete of the old heading plus
an add of the new one, approved by a `delete` row and an `add` row (the `use-redefine` BLOCK pairs only
terms spelled identically). Zero operations exit 0 before any session is resolved. Only an unborn
HEAD is an absent side: a blob that HEAD or the index lists but cannot be read exits 2, and
`bin/review-doc-glossary` also BLOCKs it in its format scan (fail-closed).

The glossary provenance check compares category-file term sets only, so the format scan also reads a staged (non-deleted) `docs/glossary.md` index blob and BLOCKs any `### ` heading outside fenced code there (`check-index`; an unreadable blob or an unclosed fence BLOCKs too).

`resolveProvenanceSession` resolves the session explicit (`--session`) → env (`CLAUDE_CODE_SESSION_ID`)
→ none:

| Source | Result |
|---|---|
| none | `BLOCK: no-session` on stdout, nothing recorded, no ACCEPTED hint, exit 1 |
| env | case B: every operation blocked as `session-unverified`, recorded on the env session, hint to re-run with `--session` |
| explicit | `loadIntentGlossary` judges, in order: A `intent-missing`; P `intent-unapproved` (no confirm-sentinel approval, no sha, or another session's id); P `intent-modified` (sha differs); C `intent-unreadable`; else `matchOperations` reasons `not-in-intent`, `category-mismatch`, `session-term`, `definition-mismatch` |

An operation passes when a grant of the same fingerprint covers its `{norm, operation, category}`. A
failed record write still exits 1 and prints the recovery. Each remaining block prints

`  BLOCK: <term> <op> <cat>: <reason> — record it in the intent glossary, or on the user's decision: echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=… op=… cat=… — <reason>>>"`

Callers: `bin/glossary-promote` before its write, and the commit gate through
`commit-gate-steps` → `review-docs-checker` → `bin/review-doc-gates` → `bin/review-doc-glossary` →
`bin/check-glossary-provenance`, which forwards the session id only when it is valid.

### `glossary_provenance` record

Written on `review_docs` (origin `check-glossary-provenance`):

```json
{ "v": 1, "fingerprint": "<sha256>",
  "inputs": { "ops": "…", "intent_rows": "<approval sha or null>", "rules": "…" },
  "session_source": "explicit",
  "blocked": [ { "term": "…", "norm": "…", "operation": "add", "category": "user", "reason": "…" } ],
  "grants": [ { "norm": "…", "operation": "add", "category": "user", "fingerprint": "<sha256>", "reason": "…" } ] }
```

`provenanceFingerprint` binds `ops` (`opsFingerprint`), the approval sha (null for cases B / A / P / C)
and `rulesVersion`. `session_source` is `explicit` or `env`.

### Named exceptions

Intent Accepted Tradeoff "two named exceptions to S1 (ACCEPTED lifts the block)" — ACCEPTED cannot lift:

- `no-session`: there is no session to record a grant on.
- The `bin/glossary-promote` pre-write block: layer 0 pins the approved intent (A / P / C), layer 1 is
  `checkIntentRows`, layer 2 is `computeOperations` + `matchOperations`. Promotion writes only what the
  approved intent glossary says.

## `WORKFLOW_GLOSSARY_ACCEPTED`

One sentinel lifts all three checks — intent Accepted Tradeoff "there is only one kind of ACCEPTED sentinel":

`echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term> [op=<add|delete|redefine>] [cat=<user|internal>] [stage=<stage>] — <reason>>>"`

`GLOSSARY_ACCEPTED_RE_DQ` (`hooks/lib/sentinel-patterns.js`) parses it; a `LOOKSLIKE` match that fails
the strict form gets a malformed message. `hooks/workflow-mark/glossary-accept-handler.js` rejects a
value outside the domain, a repeated discriminator, `op=` / `cat=` mixed with `stage=`, and a reason of
fewer than 3 non-space characters; a missing session id is fatal. The `ask` permission rule in
`settings.json` makes every grant a user decision.

Grant targets, all for the normalized term:

- **(a) Finding.** An open deterministic finding of the current stage (`resolveCurrentStep` →
  `stageOfStep`); skipped when `op=` or `cat=` is given. The handler recomputes the fingerprint before
  the lock and grants only when it equals the record's; otherwise it answers that the record is older
  than its inputs and to re-run `--record`.
- **(b) Glossary provenance check block.** Entries of `glossary_provenance.blocked` with the same norm, narrowed by
  `op=` / `cat=`; skipped when `stage=` is given. The grant is bound to the record's fingerprint;
  freshness is checked on the next gate run.
- **(c) Tagged concern.** On a stage with a ledger, the handler runs `bin/concern-ledger list-drift`
  and adds `{norm, discrim, reason}` to `ledger_grants` for each open or reopened tagged concern of the
  term. A failed listing adds nothing (fail-closed).

When nothing matches, the handler answers "nothing pending" and the state is unchanged. A grant never
completes a step.

## Tagged concerns

Reviewers start every glossary-drift concern with `[glossary-drift term=<term>]` right after `[SEV]`,
never at line start. A tag, not a severity, marks drift — intent Accepted Tradeoff "drift is marked by a tag,
not by HIGH"; a reviewer forgetting the tag is accepted — "a forgotten tag is tolerated".

`bin/lib/concern-ledger/drift-tag.sh` owns the tag:

- Recognition: the prefix `[glossary-drift ` anywhere in the text; the term is read with
  `\[glossary-drift term=([^]|]+)\]`.
- `cl_guard_reject` returns 4 for a tagged concern, unconditionally: a tagged concern is never rejected.
- `cl_accept` closes a tagged concern only (rc 2 when untagged), and only when
  `bin/check-glossary-ledger-grant` of the checkout that holds `drift-tag.sh` confirms a ledger grant with the same norm and
  DISCRIM (field 7). Every other failure is rc 4. It writes the label `accepted(glossary-drift)`.
- `cl_list_drift` prints `DISCRIM<TAB>term` per open or reopened tagged concern; no ledger is an empty
  success, an unreadable ledger rc 1.

`bin/check-glossary-ledger-grant --session <sid> --format <format> --norm <norm> --discrim <D>` exits 0
granted, 1 not granted (or a format that belongs to no stage), 2 usage or state error.

Per stage — intent Accepted Tradeoff "in outline, detail, intent and docs nothing blocks mechanically; the user decides":

- **outline / detail.** The planner directive forbids `reject:` for a tagged concern and offers
  `accepted(glossary-drift): <reason>` after the user's ACCEPTED. The mid-round AskUserQuestion is the
  named exception to the no-pause rule of `make-outline-plan` and `make-detail-plan`.
- **tests / code.** Triage (RT-4a / RCS-3) counts a tagged concern as unresolved whatever reject
  returns. After ESCALATE deletes the ledger, reject returns 1, and the existing terminal paths apply:
  RT-5c warnings with `WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED`, or the code escalation path.
- **intent / docs.** No ledger concern is accepted by sentinel; the findings reach the user on the
  approval list.

The approval list (term, finding, Claude's handling) covers intent, outline, detail and docs; it enters
through `confirm-plan.md` and `update-docs` UD-4a / UD-5. The full procedure:
[glossary-drift-check.md](../../../skills/_shared/glossary-drift-check.md).

## WORKFLOW_OFF hole

The git `pre-commit` hook calls no review-doc or glossary check. A commit under `WORKFLOW_OFF` therefore
skips both the glossary provenance check and the entry-form check. Afterwards, an entry-form error still surfaces in a later session's advisory `review-doc-gates --all` scan, but an unapproved add, delete or redefine is not detected: the glossary provenance check compares staged content with HEAD, and the change is already in HEAD.

## Migration (temporary)

Each code block that bridges the move window opens with the marker line below; this section is
bounded by the same markers.

`--- BEGIN temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration added 2026-10-17 ---`

Until the PR that moved the files merges, the main worktree holds only `docs/glossary-user.md` and
`docs/glossary-internal.md`.

- `bin/lib/glossary-format/files.js` (`LEGACY_NAME_RE`): the read paths (codex prompt data, drift)
  fall back to the old names per category, only for a category with no `docs/glossary/` file; a
  `docs/` read failure other than absence throws. The write paths (`glossary-promote`,
  `review-doc-glossary`) never fall back. `legacyLayoutBlocks` names a staged add / modify /
  rename-into of an old-layout path.
- `bin/lib/glossary-provenance.js` (`legacyCategoryOf`): both sides read an old-layout path under
  the same per-category rule, so the move commit and an untouched old file diff as zero operations.
  `legacyIndexBlocks`: a staged add / modify of an old-layout path is refused.
- `bin/lib/glossary-format/cli.js` (`legacy-paths`), `bin/review-doc-glossary` and
  `bin/check-glossary-provenance`: the staged gates BLOCK such a path (provenance is not judged);
  a deletion, i.e. the move away, passes, and in `review-doc-glossary` it still triggers the glossary
  provenance check, which reports the terms it removes.

Delete all of these blocks together, with `tests/bin/feat-2529-glossary-legacy-read.sh`, once origin/main
has neither old file and no worktree in `git worktree list` still has them; `files.js` lists them.

`--- END temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration ---`
