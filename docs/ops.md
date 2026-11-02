# Operations

Day-to-day operational procedures for the agents repo.

## GitHub Issues Workflow

Task management using GitHub Issues as the single source of truth. Full rules in [`rules/github-issues.md`](../rules/github-issues.md).

For one-time migration from `docs/history.md` + `docs/todo.md` to GitHub Issues, see [`ops/migration-from-todo.md`](ops/migration-from-todo.md).

### New task — *Operations*

`/workflow-init` auto-creates a tracking task issue when you start a session
without an existing `#N`. To create an issue mid-workflow without starting
a fresh session, use `/issue-create` from within Claude Code. For incidents
or out-of-band creation, use `.github/ISSUE_TEMPLATE/incident.yml` (or
`task.yml`) on the GitHub web UI.
The templates carry no prefilled `value:`, so `validations: required` genuinely blocks an empty submission (#2098) — every field must actually be filled in.

### Close a task — *Operations*

```
# Phase 1 — run from the linked worktree before /commit-push
/issue-close-stage <N>

# Phase 2 — run from the main worktree after the PR is merged
/issue-close-finalize <N>
```

The two phases together run the full transaction-safe flow: sub-issue gate → pending sentinel comment → history.md append → parent body update → `gh issue close` → resolved-by + appended sentinel. **Never run `gh issue close` directly** — the `enforce-issue-close.js` hook will block it.

To close an issue as `status:migrated` or `status:cancelled` (uses `--reason "not planned"`):

```
/issue-close-migrated <N> --type migrated --into <M>   # migrated into issue M
/issue-close-migrated <N> --type cancelled             # cancelled with no successor
```

### Backfill Projects v2 board cards (catch-up) — *Migration (catch-up)*

For sessions that pre-date #548 where related issues never received a
Projects v2 board card / Content Date, backfill them:

```bash
bash bin/github-issues/migration/backfill-board-cards.sh <N1> <N2> ...
# or, with a file (one #N per line; blank/# lines skipped):
bash bin/github-issues/migration/backfill-board-cards.sh --from-file related-issues.txt
# or, via stdin:
echo -e "123\n456\n789" | bash bin/github-issues/migration/backfill-board-cards.sh
```

Safe to re-run — `ensure-board-card.sh` is idempotent (no-op when the card
and Content Date are already present).

### Recover from out-of-band closes — *Operations / Migration (catch-up)*

Issues closed via web UI, mobile, or another terminal bypass the hook. For **open** issues that need their close-side state reconciled:

```
/issue-reconcile
```

Run this weekly or whenever you close issues outside Claude Code. For **already-closed** issues missing J-1/J-2 comments, use Step 5 above instead.

### Sub-issues — *Operations*

Create via `gh api` (the `gh` CLI does not support sub-issues yet):

```bash
# Get child databaseId (integer — not GraphQL node id)
CHILD_ID=$(gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: CHILD_N) { databaseId } } }' --jq '.data.repository.issue.databaseId')
gh api -X POST repos/{owner}/{repo}/issues/<PARENT_N>/sub_issues \
  -F sub_issue_id="$CHILD_ID"
```

The parent cannot be closed while any child is `open` (`/issue-close-stage` and `/issue-close-finalize` enforce this automatically).

## Multi-issue session ops

A session may close multiple issues in a single PR. Quick reference:

- `closes_issues` is the flat list of issues the session closes. `ISSUES[0]`
  is the first entry in insertion order (no special representational status).
  All entries are treated alike for WIP, labels, history, and PR markers.
- One `history.md` entry per closed issue.
- One `Closes #<N>` line and one `<!-- issue-close-pr-of: <N> -->` marker
  per closed issue in the PR body.
- Phase 1 (`/issue-close-stage <N>`) runs once per N from the linked worktree.
- Phase 2 (`/issue-close-finalize --from-session`) iterates automatically.
- Path A multi-N: all issues are labeled `intent:clarified` by
  workflow-init Path A2 (fail-closed). If A2 aborts due to a gh
  failure, fix the gh failure and re-run /workflow-init — A2 is idempotent.
  See the abort marker file under drafts/ for the failed-issue list.

Canonical rules: [`rules/github-issues.md` § Session model](../rules/github-issues.md).

---

## Label Propagation PAT (PROPAGATE_LABELS_PAT)

The `propagate` job in `.github/workflows/sync-labels.yml` pushes canonical `.github/labels.yml`
changes from this repo to the sibling repos (`dotfiles`, `my-private-repo`) and syncs their
GitHub label API objects to match. It runs only after the self-sync `sync` job succeeds.

**Required scope:** `repo`. Because `my-private-repo` is a private repository, the narrower
`public_repo` scope is insufficient — the token must carry the full `repo` scope.

**Creating the token:** GitHub → Settings → Developer settings → Personal access tokens (classic)
→ Generate new token → select the `repo` scope → generate and copy the value. Then, in this repo:
Settings → Secrets and variables → Actions → New repository secret → name it `PROPAGATE_LABELS_PAT`
→ paste the token value → save.

**When the secret is absent:** the script first tries `gh auth token` as a fallback. In CI the
GITHUB_TOKEN returned this way typically lacks push access to sibling repos, so the propagation
effectively skips; in local developer runs `gh auth token` usually succeeds and propagation
proceeds normally. If both `PROPAGATE_LABELS_PAT` and `gh auth token` are unavailable, the script
exits 0 and logs `PROPAGATE_LABELS_PAT not set and gh auth token failed — skipping propagation`.

**First run:** once the PAT is registered, pushing any change to `.github/labels.yml` or
`bin/github-issues/sync-labels.sh` (or triggering a manual `workflow_dispatch`) fires the first
propagation. Each sibling's `labels.yml` is overwritten with the canonical label content
prefixed by the `# GENERATED — …` header, then committed and pushed.

**DELETE propagation:** `sync-labels.sh` deletes any label present on the remote repo but absent
from `.github/labels.yml`. This applies to all callers including `propagate-labels.sh` — orphaned
labels on sibling repos are removed automatically during propagation. Run with `--dry-run` to
preview what would be created, updated, or deleted before making live changes.

**Protected labels:** the `protected:` top-level key in `.github/labels.yml` lists label names that
`sync-labels.sh` never deletes, even in a normal sync. It shields the nine GitHub default labels
(`bug`, `enhancement`, `documentation`, `good first issue`, `invalid`, `duplicate`, `question`,
`wontfix`, `help wanted`) that sibling repos may still use on existing issues.

**Suppressing all deletes:** pass `--no-delete` to `sync-labels.sh` to run CREATE and UPDATE only,
skipping every DELETE (each is logged `[NO-DELETE] Skipped delete`). For propagation, set
`PROPAGATE_LABELS_NO_DELETE` to any non-empty value and `propagate-labels.sh` threads `--no-delete`
through to each sibling. Use this for a first-time additive sync to a repo whose existing labels
must be preserved.

**`PROPAGATE_LABELS_REPOS` directory entries:** an entry can be either a direct git repo path or a
parent directory. If the entry is a directory but not itself a git repo, `propagate-labels.sh`
scans one level of subdirectories and propagates to each git repo found there. An empty parent
(no git repos one level down) skips gracefully with exit 0.

**Asset propagation:** in addition to `.github/labels.yml`, each sibling receives copies of
`bin/github-issues/sync-labels.sh`, `.github/ISSUE_TEMPLATE/task.yml`, and
`.github/ISSUE_TEMPLATE/incident.yml` from the agents workspace. Missing source assets are
silently skipped; present ones are committed in the same commit as `labels.yml`.
`.github/workflows/sync-labels.yml` is deliberately excluded: pushing a workflow file requires
the `workflow` PAT scope, and siblings do not need their own copy because this job applies their
labels centrally via `sync-labels.sh --repo`.

**Self-reference guard:** an entry that resolves to the agents repo itself is skipped with a
`self-reference: ... — skipping` notice. Without it, the job rewrites the canonical `labels.yml`
as header+itself and pushes to `main`, which the workflow's `paths:` filter retriggers — an
unbounded self-push loop. The guard reads `GITHUB_REPOSITORY` inside Actions and falls back to
the `AGENTS_WORKSPACE` origin URL locally, so configuration mistakes cannot re-arm the loop.

**Branch-protection note:** if a sibling's `main` branch has branch protection enabled, the
direct push is rejected and that sibling is recorded as a failure (the others still proceed).
Neither sibling currently has branch protection, so the direct push succeeds today.

---

## Release phase / Merge Operations

### Who merges, and the one confirmation

The release phase is `push_branch` → `user_verification` → `merge_to_main` → `cleanup`, one skill each
(step list: [workflow.md](architecture/claude-code/workflow.md)). `/commit-push` stops at the PR;
`/get-release-approval` issues the single USER_VERIFIED dialog; `/merge-to-main` performs the squash-merge
of that PR by number (`gh pr merge <PR number> --squash --delete-branch`, or `glab mr merge` on
GitLab); `/worktree-end` only cleans up and never merges.

`/merge-to-main` reads the PR state with `bin/workflow/pr-state` first. A PR already `MERGED` completes the
step without a second merge, so pressing the GitHub UI merge button before `/merge-to-main` is safe:
`/get-release-approval` records the approval with a "merged via web UI" reason and `/merge-to-main` skips
the merge. If the PR number at merge time differs from the approved one, `/merge-to-main` stops and
`/get-release-approval` is re-run. The merge gate still blocks any merge or protected-branch push
until `user_verification` is complete.

### `AUTO_MERGE_PR=off` — you merge on the web

Applies only to pull_request delivery (`ENFORCE_WORKTREE=on`); the value is fixed for the session
when the branch is recorded, so change it before starting a session.

1. `/commit-push` opens the PR as usual.
2. `/get-release-approval` shows the PR URL and starts a background poller. There is no
   USER_VERIFIED dialog and no verification question: your merge on the web is the approval.
3. Merge the PR on GitHub / GitLab. The poller notices within about 30 seconds and the workflow
   continues to cleanup. `/merge-to-main` performs no merge.
4. The poller gives up after one hour. Send any message after merging and the flow resumes.

The merged PR counts only when its head commit is the session's local HEAD; a PR that lacks a local
commit not yet pushed, or an older PR of the same branch name, does not complete the step — push
first. Closing the PR without merging stops the flow; reopen it or re-run `/commit-push`.

Claude's own merge (`gh pr merge`, `glab mr merge`, a push to a protected branch) is refused by
`workflow-gate.js` while `off` is in force, and `WORKFLOW_OFF` does not lift that. The refusal
recognises those command forms only — keep branch protection on the forge as the real barrier.

---

## CodeGraph

Opt-in code-intelligence index behind the `CODEGRAPH` flag. Full setup, verification, off-switch,
and troubleshooting: [`ops/codegraph.md`](ops/codegraph.md).

Sessions in a worktree that predates the flag need one manual step, self-contained here:
[`ops/codegraph.md` § One-time worktree init](ops/codegraph.md#one-time-worktree-init).

---

## Plans Directory Migration

One-time operator runbook: rename `intent-<timestamp>-*.md` files in the
active plans directory to strip the `intent-` prefix (e.g.
`intent-20260510-001819-intent.md` → `20260510-001819-intent.md`).
Run **once** after the PR for this change is merged. Idempotent.

**Setup (resolve the active plans directory once per shell):**
```bash
bash "$AGENTS_MAIN_ROOT/bin/workflow-plans-dir"
```
It prints the active plans directory — defaults to `~/.workflow-plans`, and respects a
`WORKFLOW_PLANS_DIR` override from `.env`. Read the printed path and use it literally below.

**PowerShell (Windows):**
```powershell
cd ~/.workflow-plans  # default; use $PLANS_DIR if WORKFLOW_PLANS_DIR is set
foreach ($f in Get-ChildItem -Name "intent-*.md") {
    $target = $f -replace '^intent-', ''
    if (Test-Path $target) { Write-Warning "SKIP: $target already exists (not overwriting $f)"; continue }
    Rename-Item $f $target
}
```

**bash (WSL / macOS / Linux):**
```bash
cd "$PLANS_DIR"  # default ~/.workflow-plans; respects WORKFLOW_PLANS_DIR
for f in intent-*.md; do
  [[ -f "$f" ]] || continue
  target="${f#intent-}"
  if [[ -f "$target" ]]; then
    echo "SKIP: $target already exists (not overwriting $f)" >&2
    continue
  fi
  mv "$f" "$target"
done
```

After migration, all session artifacts (`-intent.md`, `-outline.md`,
`-detail.md`, `drafts/-context.md`) share a prefix-less session-ID stem.

## Claude Code TL3 Tests

E2E tests that spawn real `claude -p` sessions are opt-in. They are gated on the
`RUN_TL3` config flag — `bin/get-config-var --is-off RUN_TL3 off && exit 77`
makes the test skip with TAP exit code 77 when the flag is off. Set
`RUN_TL3=on` in the agents config `.env` to run them locally.

The verification-gate ask is gated separately on `RUN_TL4`. When `RUN_TL4=off` it is suppressed: matched risk categories are still recorded to `WORKTREE_NOTES.md ## Unverified Categories` as a log-only trace, but no `AskUserQuestion` is raised. The ask fires before commit (the `ENFORCE_WORKTREE=off` commit-push path) or before merge (the `/get-release-approval` preflight, `pull_request` path); set `RUN_TL4=on` to re-activate it.

When `claude` is not on `PATH`, gates also exit 77
(`command -v claude >/dev/null 2>&1 || exit 77`). This keeps CI green on hosts
where Claude Code is unavailable.

Each `claude -p` invocation is wrapped in `run_with_timeout 180` per
[`rules/test/macos-timeout.md`](../rules/test/macos-timeout.md). The 180-second
budget covers cold-start + plan + execute + Stop hook on a typical workstation.

Native-environment caveat: WSL sessions launched through the Windows-native
Claude Code binary do not propagate `CLAUDECODE` into the WSL shell and read
settings from the Windows profile. Tests that pass under WSL-via-Windows may
still fail on a macOS-native or Linux-native install. Always verify on a true
native environment before declaring an E2E test green. See
[`rules/test/claude-e2e.md`](../rules/test/claude-e2e.md) for the full
precaution list and acceptance criteria.

## Test parallelism calibration

With `AUTO_CONFIG_TEST_MAX_JOBS=on` (the default) an uncalibrated host runs tests at the
default max jobs per host (4), and the measured record, the calibration offer and load
scale-in apply. With `off` the host is fully manual: only `TEST_MAX_JOBS_PER_HOST` (4
when empty) and `TEST_MAX_JOBS_PER_RUN` count. Measure the real knee once per host, from
the repo root:

- bash: `RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh`
- PowerShell: `$env:RUN_CALIBRATION = "1"; bash bin/calibrate-test-parallelism.sh`

It takes up to 90 minutes; `--time-limit <min>` changes the cap. Add `--dry-run` to see
the plan and its cost without measuring, and `--print` to show the current record.

/run-tests asks once per session on an uncalibrated host: calibrate now, or not now.
Choosing "calibrate now" first prints the estimated minutes. To stop the question for
good, set `AUTO_CONFIG_TEST_MAX_JOBS=off` in `.env`. A leftover
`calibration-never-ask.conf` under `~/.claude/run-all` (or `RUN_ALL_CACHE_DIR`) is no
longer read and may be deleted.

To pin a value, set `TEST_MAX_JOBS_PER_HOST` in `.env`. In mode `on` a pin is a ceiling
on the measured record, so calibrating leaves the effective value unchanged when the pin
is lower, and /run-tests reports `source=dotenv` (or `env`) after the run. The order in
which the layers resolve is owned by
[test-host-lanes.md](architecture/claude-code/test-host-lanes.md) ("Resolution order of
max jobs per host").

### Watching the lanes

`bash bin/test-lanes-status.sh` is read-only and prints, in order:

1. The lane pool line: `max_jobs_per_host`, `source`, `mode`, `runs`, plus any
   `record=`, `recalibrate=` or `capped=` notes.
2. The `load` line, the run-all lane allocation sample (`~/.claude/run-all/load/sample`):
   `state`, `age_s`, `external_centicores`, `reserved_cores`, `scale_in`,
   `host_busy_centicores`, `mem_scope`, `mem_avail_mb`, `mem_reserve_mb`, `mem_cap`
   and `pool`. `load state=none` means no valid sample yet.
3. The fixed label `load is the run-all lane allocation sample`, naming line 2.

Then one row per lane (kind, pid, environment, age, state) and one per run with its
width, ssthresh, run-all per-run lane cap and `decided_by`: `per-run-cap`,
`cpu-load-limit`, `memory-limit` or `slow-start` (still growing; a run reaches its cap
over several heartbeats). External load counts only processes outside the test trees and
`claude`; it shrinks lanes only above the reserved cores (logical CPUs minus the
calibrated value). The mechanism is owned by
[test-host-lanes.md](architecture/claude-code/test-host-lanes.md).

Design rationale: [test-runner-parallelism.md](architecture/claude-code/test-runner-parallelism.md) Section 5.

## Jev

Jev is the first judge for task complexity and for the outline / detail skip
decisions; a subagent answers whatever Jev is not confident about. Default is off.

Enable:

1. In the global agents `.env` (under the agents main root), set `JEV=on` and `TYPESAFE_API_KEY=<key>`. A project `.env.local` cannot set either key (they are refused there). See `.env.example`.
2. Verify in a linked worktree first.

Disable: set `JEV=off` in the same `.env`, or remove the line. Every judgment
then goes to the subagent. Jev never blocks a judgment: an outage, missing key,
or bad response delegates to the subagent, and a failure of the procedure itself
resolves to the safe side (highest complexity level, or run the planning stage).

A `FALLBACK=<reason>` line from `jev-judge finalize` names why the output was demoted, `source-changed` included; the reasons are listed under Missing answer in [two-stage-broker.md](architecture/jev/two-stage-broker.md#failure-paths).

What each point sends to `api.typesafe.ai`: [jev.md](architecture/jev.md#what-is-sent-to-jev).

### Reading the report

```
node bin/jev-report
node bin/jev-report --point detail-skip --json
node bin/jev-report --log <path> --no-sweep
```

Flags: `--log <path>` (default decision log), `--point <name>` (one judgment point), `--json`, `--no-sweep` (skip the orphan sweep and 7-day state retention that run by default). It reads local files only and never contacts Jev.

| Section | What to look at |
|---|---|
| Adoption | **LLM call rate**: how often a subagent dispatch was requested — the cost Jev is meant to remove. `adopted` and `by_mode` show whose answers decided. |
| Adoption | Short-circuit rate (skip points): how often one confident "run" answer decided the point. Watch its trend; it is the everyday view of the run direction. |
| Adoption | `answer_missing`, `finalize_absent`: dispatches whose answer never arrived, and tickets nobody finalized. Persistent non-zero values mean a caller is not completing the procedure. |
| Adoption | `input_insufficient`: tickets where Jev was not asked because a required section was not whole. At `write-tests` / `write-code` the required section is the issue body, plus at least one plan section (detail, outline or intent) that is whole or truncated with its copy intact. Read its breakdown (issue body, detail, `copy-failed`, `over-cap`). It happens when the required sections do not fit the Jev input budget (`MAX_JEV_INPUT_CHARS`), or when every plan section is absent or its copy failed. |
| Adoption | `superseded_count`: non-zero means two callers advanced the same step in parallel. The newer judgment is the valid one; the older caller stopped without writing. |
| Retune | Per-key agreement and, per candidate threshold, whether lowering is supported (below). |
| Legacy | Version 1 records from the shadow period, with their original metrics. Never mixed into the sections above. |

`duplicate_ticket_records`, `unknown_version` and unreadable log generations are data-quality counters; each should be zero.

### Lowering a skip threshold

The skip points shipped with 0.7 for the run direction, 0.9 for the skip
direction, and short-circuit on "run". Those values come from a threshold sweep
that traded precision against the share of judgments Jev decides alone. They
are estimates: the sweep measured earlier questions with different wording, and
`so_c2` has no measurement at all — it borrows `so_c1`'s value.

The only retune this procedure covers is lowering the skip-direction threshold.

1. Run `node bin/jev-report --point <outline-skip|detail-skip>` and read the retune section.
2. A candidate is supported when it shows `retune_ready=true`. The conditions (candidate values, minimum answer count, minimum agreement) are `RETUNE_POLICY` in `bin/lib/jev-report-aggregate/retune.js`; the report prints them.
3. Decide. `retune_ready` is evidence, not an instruction — a person makes the change, in `hooks/lib/jev/registry.js`.

Each candidate `t` is judged only on answers in the band `[t, current)`: the
answers that would newly be adopted. Answers at or above the current threshold
are not counted — lowering the threshold does not change them, and a ticket Jev
decided alone has no subagent answer, so counting them would skew the figure
toward tickets that happened to need a subagent.

To measure run-direction agreement, set the point's `mode` to `"shadow"` for a
while, let `run_direction` fill, then set it back to `"production"`.

### Rolling back

A registry change takes effect from the next ticket queried; a ticket already
queried finishes under the policy it started with (at most its one-hour lifetime).

- **Jev's adoption** — by data, no revert: set the point's `mode` to `"shadow"` in `hooks/lib/jev/registry.js` (the subagent judges every key, Jev is logged only), raise a threshold there, or set `JEV=off`.
- **Everything else that shipped with the switch** — `git revert` only: the retired complexity signals, the end of the zero-signal automatic skip, the retired skip verifier and its scripts, the replaced detail-skip criteria. Changing `mode` does not restore them.

### Where things live

- State: `$AGENTS_STATE_DIR/jev` (default `~/.agents/jev`), one directory per session.
- Decision log: `jev-decisions.jsonl`, rotated by size. Deleting it loses only the evidence collected so far.
- Retention: session state idle for more than 7 days is removed by a sweep that runs at most once a day.

Details: [architecture/jev.md](architecture/jev.md).

## Restoring session list order after VS Code restart

After a VS Code restart, the Claude Code extension appends metadata-only lines
(`ai-title`, `mode`, `pr-link`) to recent session JSONL files. These lines have no
`timestamp` field, so the file's mtime is bumped to the restart time rather than the
actual last-message time — causing sessions to appear out of order in the session list.

### bash

```sh
cc-session-mtime --dry-run        # preview: show files and the mtime that would be applied
cc-session-mtime                  # apply: restore mtime from last timestamp entry
```

`--claude-dir <dir>` targets a directory other than `~/.claude`.

### PowerShell

```powershell
cc-session-mtime.ps1 -DryRun      # preview
cc-session-mtime.ps1              # apply
```

### When to use `session-sync reset` instead

Use `session-sync reset` when you also want to sync with the remote git repository
(it restores mtime as part of the reset). Use `cc-session-mtime` when you only need
mtime repair without a full git sync.

## Windows: every Bash command exits 127

Symptom: on Windows, each Bash tool call fails with `Exit code 127` (command not found). Cause: the session's shell snapshot captured `PATH` in Windows form (`C:\...;C:\...`).

- Automatic: the SessionStart and PostToolUse(Failure) hooks rewrite the `PATH` line to POSIX form and add an `additionalContext` notice. The fix applies from the next Bash call; re-run the failed command only after checking that it did not change state before exiting 127.
- If the notice says `not rewritten (windows-form, cygpath-unavailable)` or `windows-unrepairable`: restart Claude Code so it takes a fresh snapshot, then run `/sweep-shell-snapshots --dry-run` to list stale snapshots (older than 1440 minutes only).
- `bin/shell-snapshot-path-classify.js -- <file>...` classifies snapshots read-only.

Details: [architecture/claude-code/shell-snapshot-repair.md](architecture/claude-code/shell-snapshot-repair.md).

## Lightweight measurement

```sh
bin/measure-norm-docs                 # bytes/lines of always-loaded normative docs
bin/measure-norm-docs --ref v1.2.3    # the same reading taken at a past commit/tag
bin/count-subagents                   # subagent_type tallies for this repo's sessions
bin/review-comment-block-size --all   # longest comment block per tracked/untracked code file
```

`measure-norm-docs` counts root `CLAUDE.md` plus every `rules/**/*.md` without a `paths:`
frontmatter key; read the `norm-docs-summary:` line and compare two `--ref` runs to see
growth. Readings from before the frontmatter convention landed reflect the convention of
that time and are not directly comparable.

`count-subagents` prints one row per subagent type, most-used first. Exit 1 means the scan
was incomplete for any reason — a session file was unreadable, a directory could not be
enumerated, the scan budget truncated the run, or a named `--session` was not found — so
treat the tally as a lower bound and read the warnings for which. `--all` widens the scan
beyond the current repo, `--json` emits machine-readable output.

Both `--json` outputs carry their own incompleteness: every `measure-norm-docs` file entry
has a `warning` field (`null` when clean) and the report has a top-level `errors` array, so
a stored artifact is never mistaken for a complete measurement once separated from its exit
status. Symlinks are excluded from both tools, and `--ref` values starting with `-` are
rejected rather than passed through to `git`.

`review-comment-block-size --all` lists every code file holding a comment block longer than
the threshold, judged on absolute state — that is what separates the inventory from the
commit-time warning, which reports a staged file only when its comment blocks grew. A blank
line or a lone no-op token (`;`, `:`, `{}`, `()`, `,`) bridges a block instead of splitting
it. It under-detects on purpose: `#`, `//`, and `/* … */` are the only comment
forms it knows, so `--`, `%`, and Python docstrings read as code, and a first-line
shebang is never counted. Files past the size or count caps are reported as skipped rather
than dropped in silence, and the exit status never reflects findings — only whether the scan
itself could run.

Per-step elapsed time is read from the session state file's event stream via
`computeIntervals` (`hooks/workflow-state/state-io/intervals.js`), which returns one row per
event spanning the previous instant to that event's own. It needs no opt-in setting: since
#1733 the stream records every transition, so the durations are always reconstructible.
`RECORD_STEP_TIMESTAMPS` and the `started_at` field it wrote are retired — a keyed map that
overwrote `updated_at` in place is what made the toggle necessary in the first place.

Two row fields carry the measurement's own limits. `estimated: true` marks a duration
computed against a reconstructed timestamp (a `backfilled` event, or one flagged
`at_estimated`) — never present it as measured. `out_of_order: true` marks a pair whose
later event carries the earlier timestamp; `duration_ms` stays `null` rather than going
negative. Rows stop at the first `final_report` status event: anything appended after the
session's terminal step is post-report bookkeeping, not elapsed work.
