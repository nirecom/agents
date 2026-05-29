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

### Close a task — *Operations*

```
# Phase 1 — run from the linked worktree before /commit-push
/issue-close-stage <N>

# Phase 2 — run from the main worktree after the PR is merged
/issue-close-finalize <N>
```

The two phases together run the full transaction-safe flow: sub-issue gate → pending sentinel comment → history.md append → parent body update → `gh issue close` → resolved-by + appended sentinel. **Never run `gh issue close` directly** — the `enforce-issue-close.js` hook will block it.

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
CHILD_ID=$(gh issue view <CHILD_N> --json databaseId --jq .databaseId)
gh api -X POST repos/{owner}/{repo}/issues/<PARENT_N>/sub_issues \
  -F sub_issue_id="$CHILD_ID"
```

The parent cannot be closed while any child is `open` (`/issue-close-stage` and `/issue-close-finalize` enforce this automatically).

## Multi-issue session ops

A session may close multiple issues in a single PR. Quick reference:

- `closes_issues` order matters — index 0 is the **primary** (drives WIP state
  and Projects v2 tracking). The primary is confirmed exactly once per
  session, at workflow-init Step 1 (b) OR at clarify-intent Completion
  (whichever first sees N>=2). The two triggers are mutually exclusive.
- One `history.md` entry per closed issue.
- One `Closes #<N>` line and one `<!-- issue-close-pr-of: <N> -->` marker
  per closed issue in the PR body.
- Phase 1 (`/issue-close-stage <N>`) runs once per N from the linked worktree.
- Phase 2 (`/issue-close-finalize --from-session`) iterates automatically.
- Path A multi-N: related issues are labeled `intent:clarified` by
  workflow-init Step 1 A1.5 (fail-closed). If A1.5 aborts due to a gh
  failure, fix the gh failure and re-run /workflow-init — A1.5 is idempotent.
  See the abort marker file under drafts/ for the failed-issue list.

Canonical rules: [`rules/github-issues.md` § Session model](../rules/github-issues.md).

---

## Worktree-end / Merge Operations

### `AUTO_MERGE_PR=on` — do not press the GitHub UI merge button

Under the default `AUTO_MERGE_PR=on` mode, `/worktree-end` performs the squash-merge
locally via `gh pr merge --squash --delete-branch`. The skill **does not** currently
detect a PR that was already merged via the GitHub web UI before `/worktree-end` ran —
the `on` path jumps straight from Step 3 to Step 4 without a `gh pr view --json state`
pre-check. If you press "Squash & merge" on the web first, the local `gh pr merge`
call fails on a PR that is already MERGED, and the cleanup path stalls.

**Constraint:** with `AUTO_MERGE_PR=on`, leave the merge to Claude Code — do not press
the GitHub UI merge button. Tracked in #358 (auto-detect of pre-merged PRs); when
that lands, this constraint goes away.

The `off` mode (`AUTO_MERGE_PR=off`) already supports a `wait-for-web-merge` branch
that polls `gh pr view --json state` for `MERGED`. If you prefer the UI-merge workflow,
set `AUTO_MERGE_PR=off` in `.env`.

---

## Plans Directory Migration

One-time operator runbook: rename `intent-<timestamp>-*.md` files in the
active plans directory to strip the `intent-` prefix (e.g.
`intent-20260510-001819-intent.md` → `20260510-001819-intent.md`).
Run **once** after the PR for this change is merged. Idempotent.

**Setup (resolve the active plans directory once per shell):**
```bash
# Defaults to ~/.workflow-plans; respects WORKFLOW_PLANS_DIR override in .env.
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")
echo "PLANS_DIR=$PLANS_DIR"
```

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
