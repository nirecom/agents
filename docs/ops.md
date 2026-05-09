# Operations

Day-to-day operational procedures for the agents repo.

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
