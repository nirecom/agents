# Workflow state directories: artifacts vs control files

Two directories hold per-session workflow files. Which one a file belongs in is
a policy, not a convention: the placement guard, the RC-4 lint and the one-time
migration all enforce it from the same registry,
`hooks/lib/plans-artifact-registry.js` (SSOT for every kind name below).

| Directory | Holds | Who may write |
|---|---|---|
| `WORKFLOW_PLANS_DIR` (default `~/.workflow-plans/`) | **Artifacts** — prose a human reads (`<sid>-detail.md`, surveys, raw review rounds) | The model (Write), workers, wrappers |
| `<WORKFLOW_STATE_DIR>/<sid>.control/` (default root `~/.workflow-state/`) | **Control files** — JSON and numbers a machine reads to drive a gate (round counters, terminal markers, ledgers, payloads, outcomes) | Only the owning CLI or hook, never the model while `WORKFLOW=on` |

When `PLAN_SYNC_REMOTE_URL` is set and `bin/plan-sync-init` has run, the artifacts
directory is also a git working tree: it gains a `.git/` and an allowlist `.gitignore`
that tracks only `*-intent.md`, `*-outline.md` and `*-detail.md`. Every other artifact
stays untracked and local; control files live outside it. See
[plan-sync.md](plan-sync.md).

## Why the split

A control file decides what a gate does next: a round number caps the review
loop, a terminal file ends it, an exit6 marker accepts residual HIGH findings.
When those files sat beside the prose in PLANS_DIR, the model could write them
with the same Write call it uses for plans — and so could skip a gate by
touching a file (#2434, #1814). Moving them under `WORKFLOW_STATE_DIR` lets the
guard refuse every model write there without touching the artifact workflow.

## Classification rule

- A prose file a human reads is an artifact. A JSON or number file a machine
  reads, or a file whose mere existence changes a gate, is control.
- Extension is not a signal: `concern-carrier.md`, `handoff.md` and
  `workflow-init-aborted-*.md` are control files.
- Names are parsed kind-first (`parsePlansEntry`): the basename is split at
  every `-`, the prefix must match the one session-id grammar
  (`SESSION_ID_VALID_RE` in `hooks/workflow-state/state-io/core.js`), and the
  remainder must fully match one registered kind. More than one reading is
  `ambiguous` — treated as control, never migrated, a lint error.
- One tie-break is fixed: when the shortest-sid reading is a single control
  kind and every longer-sid reading is an artifact, the control reading wins.
  `<uuid>-codex-context.md` is the control file `codex-context.md`, not the
  artifact `context.md` of a session named `<uuid>-codex`. Two control readings
  stay ambiguous.
- A name that matches no kind is `unregistered` when some `-`-prefix is a live
  session (its `-context.md`, `-intent.md` or `<wf>/<prefix>.json` exists) and
  `no-sid` otherwise.

## Inventory

`<fmt>` is one of the registry's `FORMAT_TOKENS`: `outline-plan`,
`detail-plan`, `test-review`, `security-code`, `security-plan`,
`review-security-shared`.

### Artifacts (stay in PLANS_DIR)

| Kind (after `<sid>-`) | Writer | Main readers |
|---|---|---|
| `intent.md`, `outline.md`, `detail.md`, `context.md` | Model | Skills and hooks (confirm-checkpoint, completion-approval, diff-fingerprint, branch-diff) |
| `survey-<name>.md` | Model | Plan skills |
| `issue-prefill.md`, `test-review.md` | Model | Issue skills, review-tests |
| `[<stage>-]concerns-log.md`, `[<stage>-]codex-round-<N>-raw.md`, `<stage>-debug.log` | Orchestrator, wrapper | Planner, human |
| `{complexity,outline,detail,write-tests,write-code}-judge-raw.txt` | Model | `normalize-judge-signals` (the normalized signals drive the gate) |
| `<fmt>-finalize-diagnostic.txt` | `concern-ledger finalize` (on failure) | Human |
| `worker-<name>[-<seq>].draft.json` | Model (WD-2) | `bin/worker-dispatch-payload` only; deleted on publish |
| `notes-backup/` | `capture-env.sh` | worktree-end |
| `issue-create-dispatch.txt`, `issue-create-survey.json`, `sweep-issues-{survivors,decisions}.tsv`, `refactor-prompts-scan.json` | Model, subagents, scratchpad scripts | Owning skill |
| `note-<topic>.{md,txt,json,tsv}` | Model scratch notes | Human |

### Control files (in `<sid>.control/`, stored without the `<sid>-` prefix)

| Kind | Canonical writer | Readers |
|---|---|---|
| `<fmt>-round-number.txt`, `-last-round.txt`, `-terminal.txt`, `-unresolved-concerns.json` | `run-codex-review-loop` via the wrappers | Wrappers, evidence-resolver, `state-io/review-tests.js` |
| `<fmt>-concern-ledger[-cycle<N>\|-cap-snapshot].txt`, `-concern-carrier.md`, `-round-<N>-delta-<producer>.txt` | `bin/concern-ledger`, `bin/lib/concern-ledger/` | concern-ledger, evidence-resolver |
| `{security-code,review-plan-security,review-tests}-exit6-accepted.txt` | `bin/accept-exit6-residual` | The three security/test wrappers |
| `{outline,detail}-risk-signal.txt` | `bin/record-risk-signal` | make-{outline,detail}-plan wrappers |
| `worker-<name>[-<seq>].json`, `.dispatched` | `bin/worker-dispatch-payload`; the dispatcher writes `.dispatched` | worker-dispatch |
| `codex-context.md`, `codex-context.<fmt>.built`, `plan.jsonl`, `changed-files.txt` | `build-codex-context`, `run-codex-review-loop`, `review-plan-codex` | Wrappers, show-diff |
| `{complexity,outline,detail,write-tests,write-code}-signals.txt` | `normalize-judge-signals` | `derive-complexity-level`, handoff-record |
| `finalize-state-<N>.json`, `finalize-binding-<N>.json`, `issue-close-outcome.json`, `session-close-gate.json`, `final-report-env.json` | Workers, `issue-close-write-outcome.js`, `capture-env.sh` | Close-family skills, stop-final-report-guard, session-close-build-env |
| `supervisor-state.json` | `hooks/lib/supervisor-state-writer/` | Supervisor agents, `bin/supervisor-*`, sweep-supervisor-state |
| `wi-checkpoint.json`, `handoff.md`, `wt-cleanup-active`, `workflow-init-aborted-*.md` | checkpoint.js, handoff-artifact.js, worktree-cleanup-marker.js, path-a-label-and-board.sh | The same modules, workflow-init |
| `handoff-{risk,pressure,flush-mark}.json` | handoff-sidecar.js (one writer each: `recordRiskSignal`, the nudge hook, `handoff-append`) | handoff-pressure.js, handoff-risk-signal.js |
| `companion-precheck.json`, `intent-scan-block.txt`, `guard-attempt.tmp` | precheck-companions.sh, clarify-commit-scope.sh, clarify-guard-loop.sh | clarify-intent |
| `calibration-asked.txt` | `skills/run-tests/scripts/mark-calibration-asked.sh` (before the dialog), `answer-calibration.sh` | `probe-calibration.sh` |

Named exceptions:

- The sid-less `cache/` lives at `<WORKFLOW_STATE_DIR>/cache/`.
- Sid-less worker logs live at `<WORKFLOW_STATE_DIR>/worker-logs/` (see "Worker logs").
- Never moved: `*.lock`, `*.tmp`, `*.migrating.*.tmp`, `.sg-*`, `.prev-*`.
  `guard-attempt.tmp` is a short-lived marker that expires in place
  (`MIGRATABLE_KINDS` excludes it).

## Resolving the state root

`hooks/workflow-state/state-io/state-root.js` owns the root (SSOT); shell and
prompts use `bin/workflow-state-dir --session <sid> | --global | --roots`.

- `WORKFLOW_STATE_DIR` set (the pin) → every session uses it. It must be
  absolute (an MSYS `/c/...` spelling is converted); a relative value is
  refused, as for `WORKFLOW_PLANS_DIR`, since it would follow each reader's cwd.
- Unset → `~/.workflow-state/`. `getStateRoot()` is the root for sid-less
  files (`cache/`); `getSessionStateDir(sid)` is the root for one session;
  `listStateRoots()` is every root a scan must cover (sweeps, zombie cleanup,
  active-session enumeration, guards); the legacy root is listed even when
  absent, and every caller reads it as empty then. A missing primary root
  still leaves the active-session enumeration incomplete (fail-closed).
- commit-push `gate.js` alone passes `envFallback: false`: its pin comes from
  `.env`, never from the parent process environment.

While the legacy root still exists, an unpinned session routes per the
migration below.

## Worker logs

Worker logs are neither plan artifacts nor gate inputs, so they stay out of
PLANS_DIR, which syncs to the plans repository and has no retention for them (#2558).

- Location: `<sid>.control/<stamp>-<label>` when the run has a session id, else
  `<state root>/worker-logs/<stamp>-<label>`. An invalid sid falls back
  to `worker-logs/`.
- The dispatcher (`writeContext` in `bin/worker-dispatch.js`) decides the
  directory once per run; workers never pick one. fsguard's `log-dir` write
  scope confines writes to it.
- When the final path component is a symlink or a non-directory, no log is
  written and the worker reports `(none)`; there is no fallback location.
- Name SSOT: `bin/worker-dispatch/worker-log.js` (`stamp`, labels) and
  `hooks/workflow-state/state-io/control-dir.js` (`WORKER_LOGS_DIRNAME`).
- Exception: issue-reconcile's `<stamp>-issue-reconcile-worker.jsonl` is a
  worklist its caller reads, so it stays in PLANS_DIR.

## Resolving a control path

Every reader and writer goes through one entry point:

- JS: `controlPath(sid, name, {forWrite})` in
  `hooks/workflow-state/state-io/control-dir.js`. A read never creates the
  directory; `forWrite` creates `<sid>.control/` but not the file. A symlinked
  or non-directory `<sid>.control` is refused.
- Shell and prompts: `bin/workflow-control-dir --session <sid> [--file <name>] [--for-write]`.
  Exit 2 is a bad sid or name, 3 a legacy file that could not be migrated
  (`ControlMigrationError`), 1 any other refusal. Review-loop wrappers turn any
  nonzero exit into the public exit 4 (`skills/_shared/codex-review-loop/exit-codes.md`).
- The session-facts block exposes the directory as `CONTROL_DIR`.

Readers that bypass the entry point are caught by the import allowlist test and
by the RC-4 lint below.

## Canonical writer CLIs

| Need | CLI |
|---|---|
| Accept residual HIGH after exit 6 | `bin/accept-exit6-residual --session <sid> --format <security-code\|security-plan\|test-review> --reason <text>` |
| Raise a planner risk signal | `bin/record-risk-signal --session <sid> --planner <outline\|detail> --reason <one line>` (write-once) |
| Publish a worker payload | `bin/worker-dispatch-payload --session <sid> --worker <name> [--seq <n>] --draft <path>` (write-once) |
| Record an empty issue-close outcome | `bin/issue-close-write-outcome.js --session <sid> --empty` |

## Guard classes

The Write/Edit/Bash guard (`hooks/block-clearance-token-write/`) sorts a write
target into three classes:

| Class | Target | `WORKFLOW=off` |
|---|---|---|
| (a) | Protected tokens and OFF markers (`.off-clearance`, sentinels) | Still blocked |
| (b) `control-dir` | Anything under any state root, by spelling or through a symlink or junction (an unresolvable path counts as inside): control dirs, any session's `<sid>.json` and other sessions' files (#1814) | Allowed |
| (c) `plans-unregistered` | A PLANS_DIR entry that parses as control, ambiguous or unregistered | Allowed |

Reads are never judged. An unresolved sid is treated as `WORKFLOW=on`.
Detection expands `~`, `$HOME`, `$WORKFLOW_STATE_DIR`, `$WORKFLOW_PLANS_DIR`
and their `${X:-default}` forms (`hooks/lib/bash-write-targets/detection-expand.js`);
any other operator on a known alias fails closed.

Known limits: a PLANS_DIR write whose basename is fully dynamic is not blocked,
and an arbitrary variable that is unset at hook time is not expanded (#2233).

Accepted residual: the guard blocks writes under `WORKFLOW_STATE_DIR`, but deleting the directory root itself (e.g. `rm -rf` on it) is not detected — accepted because the NFR is a single-user PC and recovery rebuilds the state.

Division of labor: enforce-worktree decides *which worktree* a write may land
in; this guard decides *which state directory* a file may land in. Neither
relaxes the other.

## Migration (temporary)

Existing sessions keep control files under PLANS_DIR until they migrate. The
code lives in `hooks/lib/temporary-migrations/control-dir-split/` with the
manual face `bin/migrate-control-dir --session <sid> | --all`.

- **Gate**: only names that parse as a `MIGRATABLE_KINDS` control kind for the
  owning sid move; unregistered, ambiguous, artifact, lock and tmp files stay.
- **Triggers**: SessionStart runs `migrateAll` with a 2 s budget; a directory
  scan cursor (`<wf>/.control-migration-cursor.json`) skips unchanged
  directories. `controlPath` migrates the requested file of its own session
  on demand. Other sessions wait out a 10-minute quiet period so a running
  flow is never moved under its feet.
- **Atomic per session**: every file is staged as `<name>.migrating.*.tmp`,
  then published exclusively (hard link, or `wx` open where links are not
  supported). Any fault unwinds the whole batch: no destination file remains
  and the sources stay byte-identical. Path strings inside JSON files are
  rewritten to the control directory.
- **Conflict**: an existing destination with different bytes wins; the legacy
  file stays and one line goes to `<wf>/control-migration.log`.
- **Fail closed**: a file that cannot be migrated raises
  `ControlMigrationError` on read (evidence resolvers answer "no evidence") and
  exit 3 / exit 4 on the CLI and wrappers. It never falls back to the legacy
  path. A reader that degrades this way prints one stderr line per file per
  process, so "no evidence" is never silent.
- **Legacy-argument shims**: `--out`, `--signals-file`, `--output-file`,
  `concern-ledger --plans-dir` and payload path fields are still accepted when
  the value equals the expected legacy basename; the real I/O always uses the
  derived path.
- **Isolation**: never run an in-development worktree's bins or hooks against
  the live `WORKFLOW_STATE_DIR` / `WORKFLOW_PLANS_DIR` — isolate both (and
  `HOME`) to temp dirs; agents invoked from a worktree use
  `$AGENTS_CONFIG_DIR/bin`. A worktree's migration would otherwise move live
  sessions while main's hooks still write the legacy paths.

Dependency: guard (c) must not be weakened while the migration code remains,
because it is what stops a stale prompt from recreating a legacy control file
the migration would then move.

Deletion: every piece is wrapped in
`BEGIN/END temporary: plans-dir control files -> workflow control dir migration`
blocks with the deletion condition "remove after 2026-12-28". The daily
sweep (`sweep.yml` job `stale-migration-issue`) opens a "Stale temporary migration blocks (>90 days)" issue when a block
outlives it (`bin/open-stale-migration-issue.sh`); that job fails loudly
rather than `|| true`.

## State-root migration (temporary)

The default root moved from `~/.claude/projects/workflow/` to
`~/.workflow-state/` (#2511). A session started before the move keeps writing
the legacy root until session close moves it; new sessions never touch it.

- **Routing (M1)**: a session is new once `<new>/<sid>.json` exists — the
  single commit point, cached per process. Otherwise a legacy `<sid>.json` or
  `<sid>.control/` keeps it on the legacy root; anything else is new. A new
  `<sid>.control/` or `<sid>.instructions-loaded/` alone never decides, so a
  half-published move or an early receipt cannot split a session.
- **Re-acquire after lock**: the workflow-state lock (`withStateLock(sid)`)
  and the supervisor-state lock (`withSessionStateLock(sid)`) re-resolve the
  path right after acquiring; on a change they release and retry on the new
  root (at most twice), so a whole read-modify-write runs under one root.
- **Move**: SC-9 of `/session-close` runs
  `bin/state-dir-relocation move --session <sid>` under both locks. Entries
  are copied to a work dir, embedded legacy paths rewritten, then renamed in
  with `<sid>.json` last. A failure before that rename leaves the legacy root
  authoritative; the next move clears the leftovers. Still under the locks,
  legacy files changed, added or removed since the copy are carried across,
  then the legacy entries go. A session's entries are only the
  `<sid>.<suffix>` / `<sid>-<suffix>` names whose suffix is on the owned-suffix
  whitelist in `state-dir-relocation/legacy.js` (plus their transient tails), so
  neither `<sid>-other` nor a dotted `<sid>.peer` session is ever taken, and a sid
  shaped like another session's entry name is refused. The one-shot OFF-clearance
  token and claim are dropped from legacy, not migrated: an unlocked consumer could
  otherwise spend the legacy token and leave the copy as a second grant (fails
  closed; re-mint if needed). A small lock-free check-then-write race against
  unlocked marker writers remains in the post-commit reconcile (`reconcile.js`).
  Output is one stdout line
  (`RELOCATED` / `RELOCATE_SKIPPED` / `RELOCATE_FAILED`); a failure is
  reported to the supervisor once per session.
- **Deletion**: `bin/state-dir-relocation remaining` exits 0 when no legacy
  `<sid>.json` or `<sid>.control` is left (any sid shape). Then delete the
  `BEGIN/END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration`
  blocks in `state-root.js`, `state-lock.js` and `supervisor-state-writer/lock.js`,
  `hooks/lib/temporary-migrations/state-dir-relocation/`,
  `bin/state-dir-relocation`, `skills/session-close/scripts/relocate-session-state.sh`
  with SC-9, and this section.

## RC-4 lint

`bin/check-plans-artifacts` runs in CI (`migration-blocks-audit.yml`) and in the
pre-commit gate.

- `--source` scans `skills agents bin hooks rules docs` for a PLANS-dir token
  joined with a sid token and a literal remainder. Control, ambiguous and
  unregistered remainders are errors; only artifacts pass. Exceptions live in
  the registry's `SOURCE_LINT_EXCEPTIONS`, each with a mandatory reason; an
  unused exception is an error.
- `--dir <path>` classifies a real directory for investigation: control and
  ambiguous entries are errors, unregistered ones warnings. CI never runs it.

## Cleanup

- `zombie-cleanup` removes `<wf>/<sid>.control/` when `<sid>.json` is gone and
  the newest file inside is older than 30 days (migration preserves mtimes, so
  this never shortens the PLANS_DIR retention), and any `*.tmp` inside it
  (including `*.migrating.*.tmp`) after 24 hours. A worker log written after
  the session ended counts as the newest file, so it restarts the 30 days.
- `zombie-cleanup` removes regular files directly under `<wf>/worker-logs/`
  older than 30 days. It uses `lstat`: a symlinked `worker-logs` or entry is
  never followed, and subdirectories and the directory itself are kept.
- `sweep-plans.sh` keeps handling PLANS_DIR artifacts only. `sweep-worktrees`
  and session-close never delete a control directory.
