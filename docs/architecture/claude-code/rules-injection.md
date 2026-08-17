# Rules Injection Scope

How `rules/*.md` reaches a session's context, how a rule opts out of that, and what
enforces the opt-out.

## Background

Claude Code injects instruction files at session start. `~/.claude/rules` is a symlink
to the agents repository's **main worktree** `rules/` directory, so what a session
actually loads is the merged state — a change made in a linked worktree is not
reflected until it lands on the default branch.

A rule file with no `paths:` frontmatter key is injected **unconditionally**, into every
session, regardless of what the session is doing. A rule file with a `paths:` list is
injected only when the session touches a file matching one of those globs.

Unconditional injection is not free: every such rule consumes context in sessions that
will never act on it, and a rule that only one skill ever needs is pure noise everywhere
else. The scope of a rule is therefore a design decision, not an accident of whether
someone remembered to write frontmatter.

## The three injection scopes

| Scope | Notation | When it loads |
|---|---|---|
| Unconditional | no `paths:` key | every session |
| Conditional | `paths:` with real globs | when a matching file is touched |
| On demand | `paths:` with the reserved token, plus the marker comment | never automatically; the owning skill Reads it explicitly |

## The on-demand notation

Two things together, both required:

1. `paths:` containing **exactly one** entry, the reserved token
   `.on-demand-only/never-match`.
2. The marker comment in the body:
   `<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->`

The token is a glob that can never match, because the path it names must never exist in
the repository. That is what suppresses auto-injection — there is no "off" switch in the
loader, only the absence of a match.

The marker exists because the token alone is unreadable. A contributor who opens the
file sees a nonsense glob and no explanation; a contributor who deletes it has silently
turned the rule back on in every session. The marker states the intent in the document
itself, and its presence-or-absence is what the static checker can grade.

Why both, rather than either one: the token without the marker is undocumented magic,
and the marker without the token is a rule that claims to be de-injected while still
loading everywhere. Both failure directions are silent, which is exactly why they are
checked.

A rule that is on demand must have an owning SKILL.md with an explicit Read step. A rule
nothing reads is not "on demand", it is dead.

## SSOT

`hooks/lib/rules-injection-policy.js` declares six constants and nothing else:

| Constant | Meaning |
|---|---|
| `ON_DEMAND_TOKEN` | the reserved never-match glob |
| `ON_DEMAND_MARKER_RE` | the marker-comment pattern (no `/g` flag — a stateful `.test()` would flip verdicts between calls) |
| `ON_DEMAND_READERS` | one `rule\|reader,reader` row per on-demand rule, naming the SKILL.md files obliged to carry a Read step for it |
| `EXPECTED_UNCONDITIONAL` | every rule that is deliberately unconditional |
| `MINIMIZED_UNCONDITIONAL` | one `rule\|pointer` row per escape-hatch rule — a subset of `EXPECTED_UNCONDITIONAL`, disjoint from `ON_DEMAND_READERS` |
| `MINIMIZED_MAX_BYTES` | the byte ceiling every minimized rule must stay under, written as a string literal because the parser reads strings only |

`ON_DEMAND_FILES` is **not** declared. It is a value the reader derives from the key
column of `ON_DEMAND_READERS`, so the set of on-demand rules and their obliged readers
are never two lists that can disagree. Deriving is the reader's privilege alone —
`hooks/lib/rules-policy-reader.js` is agents-owned code; the declaration file states each
rule name once and computes nothing.

The file is **data, not a program**. It is contributor-editable and is read on every
pre-commit run and on every `InstructionsLoaded` firing, so both consumers parse its
source text for constant declarations rather than `require()`-ing it — a `require()`
would execute whatever a pull request put in the module body, before review, with the
reviewer's privileges, merely because a session started on that branch.
Keep every declaration a plain one-line literal so that reader keeps working.

The reader is one shared implementation, `hooks/lib/rules-policy-reader.js`, used by
both `bin/check-on-demand-rules.sh` and `hooks/instructions-loaded-audit.js`. That module
is agents-owned code, so `require()`-ing it is correct; only the declaration file is
untrusted. The `RULES_INJECTION_POLICY` path override is a test seam and is read as data
on the same path — it is never executed either.

## Adopted scope

The real-loader gate `tests/TL3-rules-injection-off-switch.sh` returned **G-PASS**: the
reserved token genuinely suppresses auto-injection in a live session, with no `S-LEAK`
and no missing receipt. That result is what authorized moving rules off the unconditional
set rather than merely documenting the notation.

Eight rules are on demand. The table below is the declaration's own content
(`ON_DEMAND_READERS`), not a second copy of it — the obliged readers live there:

| Rule | Read by |
|---|---|
| `rules/branch.md` | `/make-detail-plan`, `/worktree-start` |
| `rules/coding.md` | `/write-code` |
| `rules/docs.md` | `/update-docs` |
| `rules/github-issues.md` | `/issue-create`, `/issue-close-stage`, `/issue-close-finalize`, `/issue-reconcile`, `/issue-close-migrated`, `/clarify-intent`, `/commit-push`, `/worktree-end`, `/workflow-init`, `/sweep-issues`, `/issue-setup` |
| `rules/mid-workflow-findings.md` | `/issue-create`, `/worktree-end` |
| `rules/ops.md` | `/worktree-end` |
| `rules/test.md` | `/write-tests`, `/review-tests`, `/run-tests` |
| `rules/worktree.md` | `/make-detail-plan`, `/worktree-start` |

A declared reader is the skill that MUST carry a Read step; agents and skills that also
Read a rule opportunistically are not obliged and are not declared.

`EXPECTED_UNCONDITIONAL` therefore holds **7** entries, down from 14.

## Making a rule on demand

The notation is only half the change. Injection-off removes the rule body from every
subagent context too, so before flipping a rule:

1. Grep the reader side (`agents/`, `skills/`) for directives that forbid re-reading
   rules — "already in your system prompt", "do not re-read" — and correct every one so
   it exempts on-demand rules by name.
2. Add an explicit Read step at each callsite that depends on the rule body.
3. Add a `rule|readers` row to `ON_DEMAND_READERS` and remove the rule from
   `EXPECTED_UNCONDITIONAL`.
4. Add a pointer line naming the rule in `CLAUDE.md`. A de-injected rule that nothing
   points at is unreachable to a session that has not already decided to run the owning
   skill; this is what `MISSING_ONDEMAND_POINTER` fires on.
5. Run `bin/check-on-demand-rules.sh --all`.

Step 1 comes first. A reference added under a standing "do not re-read rules" directive
is a reference the reader is instructed to ignore.

## When a rule must NOT be made on demand: the escape-hatch class

On demand means "the owning skill Reads it". That is exactly the assumption an escape
hatch cannot make. A rule that says how to get **unstuck** must not require the machinery
the session is stuck in — if reaching it depends on the workflow, the guard, or the skill
that has already failed, the rule is unreachable at the only moment it is needed. Such a
rule stays unconditional no matter how large it is.

Size is still a real cost, so the treatment is different rather than absent: the rule is
**minimized in place**. It keeps only what a stuck session must recognise — the trigger
conditions, and the pointer at where the procedure now lives — and the procedure itself
moves to that pointer. Injection scope is unchanged; only the payload shrinks.

The class is recorded as data, not as prose: each such rule is a `rule|pointer` row in
`MINIMIZED_UNCONDITIONAL`, held under `MINIMIZED_MAX_BYTES` and graded by the four
`MINIMIZED_*` tokens above. That is the point of the row. #1651 applied the on-demand
notation and left every remaining unconditional rule as an undifferentiated residue, with
no record of which ones were deliberate exceptions and why — so the next pass had nothing
to read and the same judgement had to be made again from scratch. A declared row is the
recurrence prevention: the exception is now checkable, and a later pass that tries to
de-inject an escape hatch fails on `MINIMIZED_NOT_UNCONDITIONAL` instead of succeeding
quietly.

## Enforcement: two halves, opposite failure modes

The two mechanisms are deliberately asymmetric, because they answer different questions
at different moments.

### Static, fail-closed — `bin/check-on-demand-rules.sh`

Answers "is the notation internally consistent?" before a commit lands. Wired into
`hooks/pre-commit` behind an agents-repo guard. Checks:

| Token | Violation |
|---|---|
| `INVALID_ON_DEMAND_PATHS` | a registered on-demand rule whose `paths:` is not exactly the token |
| `MISSING_ON_DEMAND_MARKER` | the token without the marker comment |
| `ORPHAN_ON_DEMAND_MARKER` | the marker comment without the token |
| `RESERVED_PATH_EXISTS` | the never-match path exists in the worktree — every on-demand rule would start matching |
| `NONCANONICAL_ON_DEMAND_TOKEN` | a near-miss spelling of the token, which matches nothing while looking correct |
| `UNLISTED_UNCONDITIONAL_RULE` | a rule with no `paths:` that is absent from `EXPECTED_UNCONDITIONAL` |
| `UNREGISTERED_ON_DEMAND_RULE` | an annotated rule absent from `ON_DEMAND_READERS` |
| `OUT_OF_ROOT_STAGED_PATH` | a staged path that does not resolve inside the checked root |
| `MALFORMED_READER_ROW` | a reader row with no `\|` separator, or a separator followed by nothing — either way nobody is obliged to Read the rule |
| `READER_TARGET_MISSING` | a declared reader that is not a file inside the checked root |
| `DUPLICATE_POLICY_ENTRY` | a rule declared in both `ON_DEMAND_READERS` and `EXPECTED_UNCONDITIONAL` |
| `MISSING_ONDEMAND_POINTER` | a de-injected rule that `CLAUDE.md` never names, so nothing points the model at it |
| `MINIMIZED_NOT_UNCONDITIONAL` | a minimized rule absent from `EXPECTED_UNCONDITIONAL` or wired as an on-demand reader row — a de-injected escape hatch is one a stuck session cannot see |
| `MINIMIZED_POINTER_MISSING` | a minimized row that declares no pointer, whose rule file cannot be read, or whose body does not name the pointer |
| `MINIMIZED_POINTER_TARGET_MISSING` | a declared pointer that is not a file inside the checked root |
| `MINIMIZED_RULE_TOO_LARGE` | a minimized rule over `MINIMIZED_MAX_BYTES` — measured in bytes, since a UTF-16 length would let a multibyte rule reach roughly triple the budget |

The `MISSING_ONDEMAND_POINTER` check is skipped when the checked root has no `CLAUDE.md`:
a reader must exist in every tree, because that is internal consistency of the
declaration, whereas `CLAUDE.md` is a property of this repo and not of an arbitrary tree.

**Pointer representation.** The declaration side is always a repo-relative path — one
spelling, so the checker can confirm the target exists. The rule body is graded more
loosely, because a pointer matching `^skills/([^/]+)/SKILL\.md$` has a second legitimate
form: `/<name>` is how a prompt file tells a session to run a skill. Such a pointer is
satisfied by **either** the slash form or the path. Any other pointer — a doc, or a code
SSOT — has no invocation form, so only the literal path satisfies it.

Both `--all` and `--staged` run the same **tree-wide** invariants. Grading only the
staged files would miss the two cases that matter most: a policy-only edit that breaks a
rule it never touched, and a violation committed last week that is still a broken gate
today. Exit codes: `0` clean, `1` violations, `2` usage or unreadable policy. The hook
blocks on `1` and `2`; anything else warns on stderr and continues.

The marker is searched in the document **body only**. An HTML comment buried inside the
YAML frontmatter is not part of the rendered document and must not count as annotation.

### Dynamic, fail-open — `hooks/instructions-loaded-audit.js`

Answers "what did this session actually load?" while it is running. The host fires
`InstructionsLoaded` once per file, asynchronously, in a separate process, so the hook
classifies one file and publishes one receipt.

Verdicts: `ok`, `S-MISSING` (no `paths:` and not an expected unconditional rule),
`S-MALFORMED` (a `paths:` key that is not the block-list form), `S-LEAK` (the reserved
token is on disk and the loader injected the file anyway), `unreadable`.

`S-LEAK` is **not** AND-conditioned on `load_reason`. If the reserved path is ever
created for real, the loader reports a perfectly legitimate glob match, and an
AND-conditioned predicate would stop detecting the leak at exactly the moment the leak
became real.

This hook always exits 0 with empty stdout. An observation tool that can break a live
session is worse than no observation at all — the blocking is the static checker's job.

## Receipts and quiescence

Receipts live at
`<workflowDir>/<sanitized session_id>.instructions-loaded/<sha1(file_path)>.json`, one
entry per loaded file, published atomically (temp name + rename) so a reader never sees
a partial entry. A repeated load collides on its own key by design. `cleanupZombies`
sweeps the directory after 7 days.

Only `file_path` and `load_reason` are persisted; every other payload value is dropped
and only its key name survives as a diagnostic. Both are redacted for credential shapes,
sentinel-shaped substrings, and control bytes.

Two session identifiers are involved and must not be conflated: the receipt directory is
keyed on the Claude `session_id` from the payload, while the supervisor emit is keyed on
the workflow session id. An unresolved workflow session id skips the supervisor emit
only — the receipt is still written.

`waitForQuiescence()` is how a reader knows the picture is complete:

- **Q1 — completeness barrier**: every expected path has a settled entry. An empty
  expectation set is `INCOMPLETE`, never a vacuous OK.
- **Q2 — stability window**: the pair (entry set, newest `fired_at`) has not changed for
  the window. Watching the set alone would read a re-fired event that republishes an
  existing key as a motionless directory and settle while the session is still loading.
- **Q3 — terminal re-check**: the state is confirmed once more at the end.

## Tests

| Area | Entry point |
|---|---|
| Static checker + policy SSOT | `tests/bin-check-on-demand-rules.sh` |
| Pre-commit wiring | `tests/cc-pre-commit-on-demand-rules.sh` |
| Audit hook verdicts | `tests/cc-instructions-loaded-audit.sh` |
| Quiescence protocol | `tests/cc-instructions-loaded-quiescence.sh` |
| Receipt cleanup | `tests/cc-instructions-loaded-cleanup.sh` |
| Hook registration | `tests/cc-instructions-loaded-registration.sh` |
| Supervisor emit | `tests/cc-supervisor-emit-rules-injection.sh` |
| Skill ownership of on-demand rules | `tests/cc-on-demand-skill-ownership.sh` |
| Reader-row violation tokens (TL2) | `tests/bin-check-on-demand-rules/cases-readers.sh` |
| `MINIMIZED_*` violation tokens (TL2) | `tests/bin-check-on-demand-rules/cases-minimized.sh` |
| Escape-hatch class: disjointness, triggers, relocation round-trip (TL2) | `tests/feature-2037-minimized-escape-hatches.sh` (+ `feature-2037-minimized-escape-hatches/marker-sequence.sh`) |
| Relocated procedures executed as documents (TL2) | `tests/feature-2037-admin-close-skill.sh` (+ `feature-2037-admin-close-skill/guard-sequence.sh`, `supervisor-report-cli.sh`) |
| Real-loader off-switch (TL3) | `tests/TL3-rules-injection-off-switch.sh` |
