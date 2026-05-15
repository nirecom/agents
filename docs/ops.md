# Operations

Day-to-day operational procedures for the agents repo.

## GitHub Issues Workflow

Day-to-day task management using GitHub Issues. Full rules in [`rules/github-issues.md`](../rules/github-issues.md).

### Initial setup (once per repo)

```bash
bash bin/github-issues/sync-labels.sh
```

Creates `type:task`, `type:incident`, `status:cancelled`, `status:migrated`, and `priority:*` labels from `.github/labels.yml`. Safe to re-run (uses `--force`).

### New task

1. Create the issue on GitHub (use `.github/ISSUE_TEMPLATE/task.yml` or `incident.yml`).
2. Append to `docs/todo.md`:
   ```
   - [ ] #N Short title
   ```

### Close a task

```
/issue-close <N>
```

This runs the full transaction-safe flow: sub-issue gate → sentinel comment → history.md append → `gh issue close` → todo.md line removal. **Never run `gh issue close` directly** — the `enforce-issue-close.js` hook will block it.

### Recover from out-of-band closes

Issues closed via web UI, mobile, or another terminal bypass the hook. Backfill with:

```
/issue-reconcile
```

Run this weekly or whenever you close issues outside Claude Code.

### Retroactive backfill of J-1/J-2 comments (one-time migration)

Use this when closed issues are missing the "Resolved by commit" comment (J-1) and/or
the machine-readable sentinel (J-2) that `/issue-close` normally posts.
Typical triggers: issues closed via web UI, `closes #N` PR keyword, or before this
workflow was in place.

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
# Step 1 — Dry-run: see what will be posted without touching GitHub
bash bin/github-issues/backfill-commit-comments.sh --dry-run
```

Output format: `[dry-run class=CLASS] #N hash=HASH_OR_none`

Read the classification summary. Confirm the hashes look correct for `hash-from-history`
and `hash-from-gitlog` entries (spot-check a few against the actual history.md entries or
git log). `no-hash` issues will get a sentinel-only comment — acceptable.

```bash
# Step 2 — Canary: post to 1 issue per class (max 3 total)
bash bin/github-issues/backfill-commit-comments.sh --canary
```

After this runs, open each posted comment on GitHub and verify:
- `hash-from-history` / `hash-from-gitlog` issues: both a "Resolved by commit" comment
  and a sentinel comment appear, with the correct hash.
- `no-hash` issues: only the sentinel comment appears (no "Resolved by" line).

Once satisfied, proceed to the full run.

```bash
# Step 3 — Full run: process all remaining closed issues
bash bin/github-issues/backfill-commit-comments.sh
```

The canary issues are automatically skipped (idempotency check on the sentinel comment).
Final output: `Backfilled: N, Skipped: M`

**Re-running is safe** — issues that already have an appended sentinel are skipped.

### Sub-issues

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
