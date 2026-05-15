# Operations

Day-to-day operational procedures for the agents repo.

## GitHub Issues Workflow

Task management using GitHub Issues as the single source of truth. Full rules in [`rules/github-issues.md`](../rules/github-issues.md).

**Steps 1–5 are the one-time migration recipe** for moving a repo from
`docs/history.md` + `docs/todo.md` to GitHub Issues. Run in order — Step 2 must
finish before Step 3 so chronological history occupies the early issue numbers
and active TODOs land in later numbers.

After migration, the **Operations** sections cover ongoing work.

Each section is labeled:
- *Setup* — once per repo, idempotent
- *Migration (one-time)* — bulk one-shot operation; re-running creates duplicates
- *Migration (catch-up)* — safe to re-run (idempotent or range-scoped)
- *Operations* — ongoing day-to-day work

### Step 1 — Label sync — *Setup*

```bash
bash bin/github-issues/sync-labels.sh
```

Creates `type:task`, `type:incident`, `status:cancelled`, `status:migrated`, and `priority:*` labels from `.github/labels.yml`. Safe to re-run (uses `--force`).

### Step 2 — Migrate docs/history.md → closed issues — *Migration (one-time)*

```bash
bash bin/github-issues/migration/preview-history.sh           # review titles + counts
bash bin/github-issues/migration/migrate-history.sh --dry-run # final check, no API calls
bash bin/github-issues/migration/migrate-history.sh           # creates closed issues
```

Each `### entry` in `docs/history.md` and `docs/history/*.md` becomes one **closed** issue with:
- `type:task` or `type:incident` (auto-detected by the `INCIDENT:` prefix)
- `status:migrated`

These get the **early issue numbers** (#1 onward) so the chronological record sits at the start of the issue list.

⚠️ **Re-running creates duplicates.** Safe to dry-run, but only execute the bulk-create once. Verify counts against `preview-history.sh` output before running.

### Step 3 — Migrate docs/todo.md → open issues — *Migration (one-time)*

```bash
bash bin/github-issues/migration/migrate-todo.sh --dry-run
bash bin/github-issues/migration/migrate-todo.sh
```

Each `### section` in `docs/todo.md` becomes one **open** issue with `type:task`.
After running, `docs/todo.md` is rewritten as a thin ID index pointing to the issues.

These get the **later issue numbers** (continuing after Step 2 completes).

⚠️ **Run only after Step 2 completes**, so the numbering cleanly separates history (early) from active work (later). Re-running creates duplicate issues AND overwrites `todo.md` — commit the rewritten `todo.md` before considering whether to re-run.

### Step 4 — Backfill Projects v2 Content Date — *Migration (catch-up)*

```bash
bash bin/github-issues/migration/backfill-content-date.sh <from> <to>
```

Extracts `YYYY-MM-DD` from each migrated issue's first body line and sets the Projects v2 "Content Date" field. Range-based — can be re-run for any subrange to catch up new entries.

Required only if Projects v2 is in use. The `OWNER` / `REPO` / `PROJECT_NUM` / `PROJECT_ID` / `FIELD_ID` constants in the script are repo-specific — edit before running on a new repo.

### Step 5 — Backfill J-1/J-2 sentinel comments — *Migration (catch-up) / Operations*

Use this when closed issues are missing the "Resolved by commit" comment (J-1) and/or
the machine-readable sentinel (J-2) that `/issue-close` normally posts.
Triggers: completing Step 2 (migrated issues have neither comment), `closes #N` PR
auto-close, web UI / mobile / out-of-band close.

**What the script posts:**

| Class | J-1 (human-readable) | J-2 (sentinel) |
|---|---|---|
| `hash-from-history` | `Resolved by commit \`HASH\`.` | `<!-- issue-close-sentinel: appended (resolved-by: backfill, commit=HASH) -->` |
| `hash-from-gitlog` | `Resolved by commit \`HASH\`.` | `<!-- issue-close-sentinel: appended (resolved-by: backfill-gitlog, commit=HASH) -->` |
| `no-hash` | _(not posted)_ | `<!-- issue-close-sentinel: appended (resolved-by: backfill-no-hash) -->` |

**Hash discovery order (per issue):**
1. `docs/history.md` and `docs/history/*.md` heading bracket — e.g. `(2026-05-10, abc1234, #42)` → `abc1234`
2. `git log --all --grep="#N([^0-9]|$)"` — boundary-safe to prevent `#42` matching `#420`
3. No hash found → no-hash class (J-2 only)

**Prerequisites:**
- `AGENTS_CONFIG_DIR` must be set (points to the agents repo root)
- `gh auth status` is authenticated
- Run from the agents repo directory

**Migration procedure:**

```bash
# 5a — Dry-run: see what will be posted without touching GitHub
bash bin/github-issues/backfill-commit-comments.sh --dry-run
```

Output format: `[dry-run class=CLASS] #N hash=HASH_OR_none`

Read the classification summary. Confirm the hashes look correct for `hash-from-history`
and `hash-from-gitlog` entries (spot-check a few against the actual history.md entries or
git log). `no-hash` issues will get a sentinel-only comment — acceptable.

```bash
# 5b — Canary: post to 1 issue per class (max 3 total)
bash bin/github-issues/backfill-commit-comments.sh --canary
```

After this runs, open each posted comment on GitHub and verify:
- `hash-from-history` / `hash-from-gitlog` issues: both a "Resolved by commit" comment
  and a sentinel comment appear, with the correct hash.
- `no-hash` issues: only the sentinel comment appears (no "Resolved by" line).

Once satisfied, proceed to the full run.

```bash
# 5c — Full run: process all remaining closed issues
bash bin/github-issues/backfill-commit-comments.sh
```

The canary issues are automatically skipped (idempotency check on the sentinel comment).
Final output: `Backfilled: N, Skipped: M`

**Re-running is safe** — issues that already have an appended sentinel are skipped.

### New task — *Operations*

`/workflow-init` auto-creates a tracking task issue when you start a session
without an existing `#N`. To create an issue mid-workflow without starting
a fresh session, use `/issue-create` from within Claude Code. For incidents
or out-of-band creation, use `.github/ISSUE_TEMPLATE/incident.yml` (or
`task.yml`) on the GitHub web UI.

### Close a task — *Operations*

```
/issue-close <N>
```

This runs the full transaction-safe flow: sub-issue gate → sentinel comment → history.md append → `gh issue close`. **Never run `gh issue close` directly** — the `enforce-issue-close.js` hook will block it.

### Recover from out-of-band closes — *Operations / Migration (catch-up)*

Issues closed via web UI, mobile, or another terminal bypass the hook. For **open** issues that need their close-side state reconciled:

```
/issue-reconcile
```

Run this weekly or whenever you close issues outside Claude Code. For **already-closed** issues missing J-1/J-2 comments, use Step 5 above instead.

### Sub-issues — *Operations*

Create via `gh api` (the `gh` CLI does not support sub-issues yet):

```bash
# Get parent database id (not issue number)
PARENT_ID=$(gh issue view <PARENT_N> --json id --jq .id)
CHILD_ID=$(gh issue view <CHILD_N> --json id --jq .id)
gh api repos/{owner}/{repo}/issues/<PARENT_N>/sub_issues \
  -f sub_issue_id="$CHILD_ID"
```

The parent cannot be closed while any child is `open` (`/issue-close` enforces this automatically).

---

## Plans Directory Migration

One-time operator runbook: rename `intent-<timestamp>-*.md` files in
`~/.workflow-plans/` to strip the `intent-` prefix (e.g.
`intent-20260510-001819-intent.md` → `20260510-001819-intent.md`).
Run **once** after the PR for this change is merged. Idempotent.

**PowerShell (Windows):**
```powershell
cd ~/.workflow-plans
foreach ($f in Get-ChildItem -Name "intent-*.md") {
    $target = $f -replace '^intent-', ''
    if (Test-Path $target) { Write-Warning "SKIP: $target already exists (not overwriting $f)"; continue }
    Rename-Item $f $target
}
```

**bash (WSL / macOS / Linux):**
```bash
cd ~/.workflow-plans
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
