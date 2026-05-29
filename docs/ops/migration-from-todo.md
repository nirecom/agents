# Migration: docs/history.md + docs/todo.md → GitHub Issues

One-time migration recipe for moving a repo from `docs/history.md` + `docs/todo.md` to GitHub Issues. Run Steps 1–5 in order — Step 2 must finish before Step 3 so chronological history occupies the early issue numbers and active TODOs land in later numbers.

> **Recommended:** Use `/migrate-repo` skill for automated canary-gated execution.
> The commands below document individual steps for manual recovery only.

Each section is labeled:
- *Setup* — once per repo, idempotent
- *Migration (one-time)* — bulk one-shot operation; re-running creates duplicates
- *Migration (catch-up)* — safe to re-run (idempotent or range-scoped)

## Step 1 — Label sync — *Setup*

```bash
bash bin/github-issues/sync-labels.sh
```

Creates `type:task`, `type:incident`, `status:cancelled`, `status:migrated`, and `priority:*` labels from `.github/labels.yml`. Safe to re-run (uses `--force`).

## Step 2 — Migrate docs/history.md → closed issues — *Migration (one-time)*

Each `--stage` invocation runs ONE canary unit and exits. Inspect the created
issues on GitHub between stages. Confirm with the user before the next command.

```bash
bash bin/github-issues/migration/preview-history.sh <repo_dir>                            # review titles + counts
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --dry-run                      # final check, no API calls
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 2 --stage canary-1
#   → inspect GitHub. Confirm with user.
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 2 --stage canary-2
#   → inspect GitHub. Confirm with user.
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 2 --stage full
```

Each `### entry` in `docs/history.md` and `docs/history/*.md` becomes one **closed** issue with:
- `type:task` or `type:incident` (auto-detected by the `INCIDENT:` prefix)
- `status:migrated`

These get the **early issue numbers** (#1 onward) so the chronological record sits at the start of the issue list.

⚠️ **Re-running creates duplicates.** Safe to dry-run, but only execute the bulk-create once. Verify counts against `preview-history.sh` output before running.

## Step 3 — Migrate docs/todo.md → open issues — *Migration (one-time)*

Same stage-by-stage structure as Step 2.

```bash
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 3 --stage canary-1
#   → inspect GitHub. Confirm with user.
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 3 --stage canary-2
#   → inspect GitHub. Confirm with user.
bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 3 --stage full
```

Each `## section` in `docs/todo.md` becomes one **open** issue with `type:task`.
After `--stage full` completes (all sections done), `docs/todo.md` is rewritten as a thin ID index pointing to the issues.

These get the **later issue numbers** (continuing after Step 2 completes).

⚠️ **Run only after Step 2 completes**, so the numbering cleanly separates history (early) from active work (later). Re-running creates duplicate issues AND overwrites `todo.md` — commit the rewritten `todo.md` before considering whether to re-run.

## Step 4 — Backfill Projects v2 Content Date — *Migration (catch-up)*

```bash
MIGRATE_PROJECT_NUM=<n> MIGRATE_PROJECT_ID=<PVT_…> MIGRATE_FIELD_ID=<PVTF_…> \
  bash bin/github-issues/migration/backfill-content-date.sh <repo_dir>
```

Extracts `YYYY-MM-DD` from each migrated issue's first body line and sets the Projects v2 "Content Date" field. Iterates over the issue numbers recorded in `.migration-state.json` (`.history.migrated[].issue_number`) — `/migrate-repo` wires the env vars from `create-project.sh` automatically.

Required only if Projects v2 is in use.

## Step 5 — Backfill J-1/J-2 sentinel comments — *Migration (catch-up)*

Use this when closed issues are missing the "Resolved by commit" comment (J-1) and/or
the machine-readable sentinel (J-2) that `/issue-close-finalize` normally posts.
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
- `REPO_DIR` (or `AGENTS_CONFIG_DIR` as fallback) points to the target repo root
- `gh auth status` is authenticated
- Run from inside the target repo, or pass `REPO_DIR=/path/to/repo` env var

**Migration procedure:**

```bash
# 5a — Dry-run: see what will be posted without touching GitHub
REPO_DIR=/path/to/repo bash bin/github-issues/backfill-commit-comments.sh --dry-run
```

Output format: `[dry-run class=CLASS] #N hash=HASH_OR_none`

Read the classification summary. Confirm the hashes look correct for `hash-from-history`
and `hash-from-gitlog` entries (spot-check a few against the actual history.md entries or
git log). `no-hash` issues will get a sentinel-only comment — acceptable.

```bash
# 5b — Canary: post to 1 issue per class (max 6 total)
REPO_DIR=/path/to/repo bash bin/github-issues/backfill-commit-comments.sh --canary
```

After this runs, open each posted comment on GitHub and verify:
- `hash-from-history` / `hash-from-gitlog` issues: both a "Resolved by commit" comment
  and a sentinel comment appear, with the correct hash.
- `no-hash` issues: only the sentinel comment appears (no "Resolved by" line).

Once satisfied, proceed to the full run.

```bash
# 5c — Full run: process all remaining closed issues
REPO_DIR=/path/to/repo bash bin/github-issues/backfill-commit-comments.sh
```

The canary issues are automatically skipped (idempotency check on the sentinel comment).
Final output: `Backfilled: N, Skipped: M`

**Re-running is safe** — issues that already have an appended sentinel are skipped.

> **Note on jq regex:** The idempotency check uses `(^|\\n)<!-- issue-close-sentinel: appended` (no `"m"` flag). jq's `m` flag is Oniguruma's multi-line dot mode — it does **not** make `^` match line starts. The `(^|\\n)` prefix handles both line-1 and line-2+ sentinels (the merged J-1+J-2 format places the sentinel on line 2).
