# Operations

Day-to-day operational procedures for the agents repo.

## GitHub Issues Workflow

Day-to-day task management using GitHub Issues. Full rules in [`rules/github-issues.md`](../rules/github-issues.md).

### Initial setup (once per repo)

```bash
bash bin/sync-labels.sh
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
`~/.claude/plans/` to strip the `intent-` prefix (e.g.
`intent-20260510-001819-intent.md` → `20260510-001819-intent.md`).
Run **once** after the PR for this change is merged. Idempotent.

**PowerShell (Windows):**
```powershell
cd ~/.claude/plans
foreach ($f in Get-ChildItem -Name "intent-*.md") {
    $target = $f -replace '^intent-', ''
    if (Test-Path $target) { Write-Warning "SKIP: $target already exists (not overwriting $f)"; continue }
    Rename-Item $f $target
}
```

**bash (WSL / macOS / Linux):**
```bash
cd ~/.claude/plans
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
