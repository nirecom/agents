---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
---

Inventory and preserve gitignored state, merge the PR, then remove the worktree safely.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Before any tool call below that references <PLANS_DIR>, run the following Bash command exactly once:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every <PLANS_DIR>
placeholder in the remainder of this SKILL.md. Subagent prompts must receive
the resolved absolute path as a literal string (subagents cannot expand $VAR).
Reuse across all subsequent steps in this skill invocation — do not re-resolve.

Canonical documentation: skills/_shared/resolve-plans-dir.md.

1. **Pre-flight checks:**
   - `gh --version` — abort with installation guidance if gh is not found.
   - Verify cwd is inside a linked worktree (not the main worktree):
     `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`.
     If they are equal, abort: the user must `cd` into the worktree first.

2. **PR resolution (idempotent):**
   Push the current branch if not already pushed (`git push -u origin <branch>`).
   Then check for an existing open PR:
   ```
   gh pr view --json state,url
   ```
   - `state == OPEN` → reuse the existing PR URL (do NOT create a duplicate).
   - No PR or closed → `gh pr create --fill`.
   Display the PR URL.

   Capture: `PR_NUMBER=$(gh pr view --json number --jq .number)`
   Abort if empty — skill cannot proceed without a resolved PR.

3. **Merge decision:**

   **PR state gate** (runs before AUTO_MERGE_PR check — applies to both on/off modes):
   `gh pr view "$PR_NUMBER" --json state --jq .state`
   - `MERGED` → step 3b (skip AUTO_MERGE_PR check and step 4).
   - `CLOSED` → surface error "PR #<N> was closed without merging." and stop.
   - `OPEN` → continue below.
   - error / empty / any other state → surface error "Unable to determine PR #<N> state." and stop.

   Output `PR #<N> is open: [<url>](<url>)`

   Check `AUTO_MERGE_PR` (default `on`):
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off AUTO_MERGE_PR on && echo OFF || echo ON'`

   - **`on`**: Announce `AUTO_MERGE_PR=on → merging now.` → step 4.
   - **`off`**: `AskUserQuestion`: "PR #<N> — merge, wait-for-web-merge, or abort?"
     - **merge** → step 4.
     - **wait-for-web-merge** → step 3a.
     - **abort** → stop; no cleanup; no sentinel.

   If `AskUserQuestion` unavailable, default to **wait-for-web-merge**.

3a. **Web-merge wait:**

   Display `PR #<N>: merge via GitHub UI, then reply here.` and the PR URL. Stop.
   On user reply: `gh pr view "$PR_NUMBER" --json state`
   - `MERGED` → step 3b.
   - `OPEN` / `CLOSED` / error → re-display and stop again.

   `$PR_NUMBER` is session-local; `/clear` or new session requires re-invoking `/worktree-end`.

3b. **Post-web-merge sync:**

   `git fetch --prune origin`
   Follow `skills/_shared/user-verified.md` to emit the sentinel
   (description: `"User confirmed PR #<N> merged via web UI"`). The PreToolUse hook
   re-surfaces the PR URL above the permission dialog.
   → step 5. Skip step 4.

4. **Local merge:**

   Follow `skills/_shared/user-verified.md` to emit the sentinel
   (description: `"PR #<N> — approving merge to main"`). The PreToolUse hook
   surfaces the PR URL above the permission dialog so the user approves from
   an informed position. Then:
   ```
   gh pr merge --squash --delete-branch
   ```
   If merge fails: surface error and stop. Do **not** force-merge or bypass checks.

5. **Gitignored state inventory** (before removing the worktree):
   Run all three commands (NUL-delimited, handles spaces and non-ASCII paths):
   ```
   git -C <worktree> ls-files --others --ignored --exclude-standard -z
   git -C <worktree> ls-files --others --exclude-standard -z
   git -C <worktree> status --porcelain=v1 -z
   ```
   Also read `WORKTREE_NOTES.md` if it exists (created by `/worktree-start`).

   **Generate backup manifest** — for each gitignored file: path, size, mtime, sha256.
   Do NOT include secret values in the manifest — metadata only.

   **Docker bind mount impact detection** (both running and stopped containers):
   ```
   docker ps -a --format json
   ```
   Check whether any `.Mounts.Source` or `env_file` entry references the worktree path.
   Normalize across path formats (WSL `/mnt/<drive>/`, Windows `<DRIVE>:\`, MSYS `/drive/`)
   before comparing. Report stopped containers too: "Stopped containers included."

   **Present DRY RUN summary to the user:**
   - Paths to be deleted / untracked count / ignored count
   - Preservation candidates (from inventory + WORKTREE_NOTES.md)
   - Docker mount impact (if any)
   - Proposed backup destination:
     - **Default:** `<main_root>/.worktree-backup/<branch>/` (gitignored via `.git/info/exclude`)
     - Alternatives: main worktree at same relative path, user-specified directory, discard
   - Commands that will be executed

   After user approval: copy preservation targets to the chosen destination.
   Set backup-path variables for use in Steps 5.5 and 7:
   ```
   BACKUP_DIR="<resolved destination>"
   mkdir -p "$BACKUP_DIR"
   BACKUP_MANIFEST_PATH="$BACKUP_DIR/manifest.json"
   ```
   If the user chose "discard" and no files were copied, set `BACKUP_MANIFEST_PATH=(none)`.
   (`NOTES_BACKUP_PATH` is defined in Step 5.5 after copying `WORKTREE_NOTES.md`.)
   If Docker containers reference the worktree path, stop them and restart from the main path.
   Never delete gitignored state silently — always present the inventory first.

### Step 5.5

5.5. **Capture for Final Report** (must run before Step 6c — worktree removal):

   a. Last-chance findings review: append any outstanding bugs/related/next-task findings to `<worktree>/WORKTREE_NOTES.md`. **This is the capture cutoff** — findings after Step 5.5 will not appear in the Final Report.

   (a.5) **Fallback path** — Issue-create promotion for unconverted WORKTREE_NOTES.md entries
         (entries written via the fallback path of `CLAUDE.md` `## Mid-workflow finding capture`
         — i.e. recorded when the primary path `/issue-create` was unavailable or deferred).
         Runs before backup.

     This step exists as a safety net for fallback-captured findings. The primary path is to
     invoke `/issue-create` directly from the linked worktree at discovery time (see `CLAUDE.md`
     `## Mid-workflow finding capture` — primary path). Use this step only for entries
     accumulated via the fallback path (non-interactive sessions, explicit user deferral, etc.).

     Note: `/issue-create`'s Mid-workflow gate is informational-only (never aborts). Exit-code
     semantics here remain unchanged: 0 = success, non-zero = actual failure.


     1. Check remote and list entries:
          bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" || skip this sub-step silently.
          node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" list "$WORKTREE_PATH/WORKTREE_NOTES.md"
        Filter the JSON output to entries with `hasMarker: false` (already-promoted entries are excluded).
        If filtered list is empty → skip to (b) silently.
        Non-interactive (claude -p): emit stderr warning listing unpromoted entries verbatim, skip to (b).
            stderr: "[worktree-end] WARN: N WORKTREE_NOTES entries not promoted (non-interactive)"

     2. Confirm selection via AskUserQuestion (multi-select): present each unpromoted entry as an option.
        User selects which entries to promote (all / subset / none).

     3. For each selected entry (process sequentially, not in parallel):
          a. Invoke /issue-create (full skill — Gather/Survey/Confirm/Dispatch phases).
          b. Extract issue number from /issue-create stdout (last line):
                 N=$(echo "$OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$')
          c. Annotate: node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" annotate \
                            "$WORKTREE_PATH/WORKTREE_NOTES.md" "$LINE_NUMBER" "$N"
          d. On /issue-create failure: emit stderr warning, skip annotate, proceed to next entry.
        Proceed to (b) when all selected entries are processed.

     Note: (a.5) must complete before (b) so annotations are reflected in the backup.
     Note: ## History Notes and ## Changelog Notes sections are NOT triage targets.

   **(b–d) fat-call — env collection + JSON persist (one Bash call, must not be split)**

   Run as a single Bash tool invocation. `<worktree>`, `<owner>/<repo>`, `<backup-dir>`,
   `<session-id>` are literal placeholders the model substitutes at execution time.
   The block MUST execute as one Bash tool invocation; do not split.

   ```bash
   # Step 1: Re-fetch PR_NUMBER (env reset safe — uses explicit repo and branch anchors)
   BRANCH_NAME="$(git -C "<worktree>" rev-parse --abbrev-ref HEAD)"
   PR_NUMBER="$(gh -R "<owner>/<repo>" pr list \
     --head "$BRANCH_NAME" --state all --limit 1 \
     --json number --jq '.[0].number')"
   if [ -z "$PR_NUMBER" ]; then
     printf "ERROR: PR_NUMBER unresolved in Step 5.5 fat-call\n" >&2
     exit 1
   fi

   # Step 2: Fetch PR metadata
   PR_INFO="$(gh -R "<owner>/<repo>" pr view "$PR_NUMBER" \
     --json title,url,state --jq '{title:.title,url:.url,state:.state}')"
   PR_TITLE="$(printf '%s' "$PR_INFO" | node -e "var d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).title||''))")"
   PR_URL="$(printf '%s' "$PR_INFO" | node -e "var d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).url||''))")"
   PR_STATE="$(printf '%s' "$PR_INFO" | node -e "var d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).state||''))")"
   MERGE_SHA="$(gh -R "<owner>/<repo>" pr view "$PR_NUMBER" --json mergeCommit --jq '.mergeCommit.oid // empty')"
   CLAUDE_CODE_RESTART_REQUIRED="$(bash "$AGENTS_CONFIG_DIR/skills/worktree-end/lib/detect-restart.sh" "$PR_NUMBER")"

   # Step 3: Collect remaining env vars
   BRANCH="$(git -C "<worktree>" rev-parse --abbrev-ref HEAD)"
   WORKTREE_PATH="<worktree>"
   CREATED_DATE="$(date -u +%Y-%m-%d)"
   BACKUP_MANIFEST_PATH="<backup-dir>/manifest.json"

   # Step 4: Copy WORKTREE_NOTES.md to backup dir and capture path
   if [ -f "<worktree>/WORKTREE_NOTES.md" ]; then
     cp -p "<worktree>/WORKTREE_NOTES.md" "<backup-dir>/WORKTREE_NOTES.md" && \
       NOTES_BACKUP_PATH="<backup-dir>/WORKTREE_NOTES.md" || NOTES_BACKUP_PATH=""
   else
     NOTES_BACKUP_PATH=""
   fi

   # Step 5: Write JSON to plans dir (BRANCH_DELETED intentionally omitted — tracked separately)
   ENV_FILE="$HOME/.workflow-plans/<session-id>-final-report-env.json"
   PR_NUMBER="$PR_NUMBER" PR_TITLE="$PR_TITLE" PR_URL="$PR_URL" PR_STATE="$PR_STATE" \
   BRANCH="$BRANCH" WORKTREE_PATH="$WORKTREE_PATH" CREATED_DATE="$CREATED_DATE" \
   BACKUP_MANIFEST_PATH="$BACKUP_MANIFEST_PATH" NOTES_BACKUP_PATH="$NOTES_BACKUP_PATH" \
   CLAUDE_CODE_RESTART_REQUIRED="$CLAUDE_CODE_RESTART_REQUIRED" ENV_FILE="$ENV_FILE" \
   node -e "
   var fs=require('fs');
   var data={
     PR_NUMBER:process.env.PR_NUMBER||'',
     PR_TITLE:process.env.PR_TITLE||'',
     PR_URL:process.env.PR_URL||'',
     PR_STATE:process.env.PR_STATE||'',
     BRANCH:process.env.BRANCH||'',
     WORKTREE_PATH:process.env.WORKTREE_PATH||'',
     CREATED_DATE:process.env.CREATED_DATE||'',
     BACKUP_MANIFEST_PATH:process.env.BACKUP_MANIFEST_PATH||'',
     NOTES_BACKUP_PATH:process.env.NOTES_BACKUP_PATH||'',
     CLAUDE_CODE_RESTART_REQUIRED:process.env.CLAUDE_CODE_RESTART_REQUIRED||''
   };
   fs.writeFileSync(process.env.ENV_FILE,JSON.stringify(data,null,2));
   " 2>&1
   if [ $? -eq 0 ]; then
     echo "env JSON written: $ENV_FILE"
   else
     echo "ERROR: env JSON write failed — aborting Step 5.5 to prevent loss of Final Report state" >&2
     exit 1
   fi
   ```

   **Note:** `BRANCH_DELETED` is intentionally absent from the JSON output. It renders as `(none)` in the Final Report — this is the correct fail-safe per issue #504 scope decision.

### Step 6

6. **Cleanup** (only after confirmed merge success and inventory — never before):
   a. Resolve the main repo root from the worktree's `.git` file.
   b. **Switch the session CWD to the main worktree** before step 6c.
      Run as its own Bash call (literal absolute path — no `$VAR` / `~`):
      ```
      cd "<main-worktree-root>"
      ```
      Releases Windows CWD lock (#251) and keeps `process.cwd()` healthy (#268, #321).
   c. `git -C <main> worktree remove <path>` (never `--force` — see rules).
   c.1. If `git worktree remove` exits non-zero (EPERM, busy, not-empty, or any error):
      - Print to stderr:
        ```
        [worktree-end] WARN: git worktree remove failed for <path> (likely Windows CWD lock).
        The worktree directory and its branch will be cleaned up automatically by
        /sweep-worktrees (nightly cron, or run manually via `/sweep`). No action
        required. Proceeding to step 6g (fetch/pull); orphan-dir cleanup and branch
        deletion are deferred to /sweep-worktrees.
        ```
      - Skip steps 6e (orphan-dir cleanup) and 6f (branch -D).
        Step 6e is skipped because the worktree dir is occupied; it self-resolves when
        the next sweep cycle removes the worktree. Step 6f is skipped because git's
        cascade rule prevents `branch -D` while the worktree is registered.
      - Proceed directly to step 6g (fetch/pull).
   d. `git -C <main> worktree prune`
   e. **Orphan-dir cleanup** at `<WORKTREE_BASE_DIR>/<task-name>`:
      ```
      node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" "<WORKTREE_BASE_DIR>/<task-name>"
      ```
      If it refuses with "not empty" (Windows recreated files after 6c),
      re-run with `--force-if-not-registered` — requires the step 5
      inventory to be complete (issue #322).
   f. `WORKTREE_END_SKILL=1 git -C <main> branch -D <branch>` — `-D` (force) is
      required because squash-merge produces a new commit not recognised by
      `-d`'s "fully merged" check. The inline `WORKTREE_END_SKILL=1` prefix is
      the authorization token for `enforce-worktree.js` (skill-only force-delete);
      the worktree was already removed in step 6c so the branch is no longer
      checked out anywhere.
   g. `git -C <main> fetch --prune origin`
      `git -C <main> pull --ff-only`
   h. Compose doc-append entries (main worktree; only when NOTES_BACKUP_PATH is non-empty).

      Parse closes_issues from <PLANS_DIR>/<session-id>-intent.md.
      When closes_issues is non-empty: Phase 1/2 already committed history.md; CHANGELOG.md is not yet written.
        Append --skip-history to skip the history target.
      When closes_issues is empty: run without --skip-history (both targets active).

        COMPOSE_DOC_APPEND_SKILL=1 bash "$AGENTS_CONFIG_DIR/bin/compose-doc-append-entry" \
          --notes "$NOTES_BACKUP_PATH" \
          --branch "$BRANCH" \
          --pr "$PR_NUMBER" \
          --merge-commit "$MERGE_SHA" \
          --background "$PR_TITLE" \
          [--skip-history when closes_issues non-empty]

      `closes_issues` parse: if intent.md is missing or lacks the field,
      treat as empty (fire CLI without --skip-history; CLI bails with exit 0 if notes sections empty).
      CLI is always-safe: exits 0 with no commits when both sections are
      empty. On non-zero exit: do NOT suppress — let stderr surface. Step 6i
      and Step 7 still run.
      Push-failure recovery: COMPOSE_DOC_APPEND_SKILL=1 git push origin main.
      Resume/retry: CLI idempotency prevents duplicate entries on re-run.

   i. Verify cleanup: `git -C <main> worktree list` — confirm no stale entries.

### Step 7

7. **Final report:** Run these Bash calls in sequence.

   **7a — Read NOTES_BACKUP_PATH from the JSON env file:**
   ```bash
   ENV_FILE="$HOME/.workflow-plans/<session-id>-final-report-env.json"
   NOTES_PATH="$(node -e "var fs=require('fs'); try { var j=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); process.stdout.write(j.NOTES_BACKUP_PATH||''); } catch(e) { process.stdout.write(''); }" "$ENV_FILE")"
   ```

   **7b — Run the Final Report renderer:**
   ```bash
   OUTPUT="$(node "$AGENTS_CONFIG_DIR/bin/worktree-final-report.js" \
     "$HOME/.workflow-plans/<session-id>-intent.md" \
     "$NOTES_PATH" \
     "<session-id>" \
     --env-file "$ENV_FILE" 2>&1)"
   EXIT_CODE=$?
   ```

   **7c — Check sentinel and display:**
   ```bash
   SENTINEL='<<WORKFLOW_MARK_STEP_final_report_complete>>'
   if [ $EXIT_CODE -eq 0 ] && echo "$OUTPUT" | grep -qF "$SENTINEL"; then
     echo "$OUTPUT" | grep -vF "$SENTINEL"
   else
     echo "WARNING: Final Report renderer failed or sentinel missing (exit=$EXIT_CODE)" >&2
     echo "$OUTPUT"
     echo "Manual fallback: review the Final Report data in $ENV_FILE"
   fi
   ```

   Do NOT hand-write a Markdown Final Report as a fallback — if the sentinel is absent, warn and show raw output only.
   Do not call `gh` here — all PR/branch state was captured in Step 5.5.

## Rules

- **wait / abort paths: no destructive steps.** Only merge-success path runs cleanup.
- `git worktree remove --force` is prohibited (see `rules/ops.md` decision path).
- Branch deletion (`git branch -D`) only in step 6f, allowed via the inline `WORKTREE_END_SKILL=1` env prefix (enforce-worktree gates `-D` on skill authorization; non-force `-d` is allowed for any branch not checked out per `git worktree list --porcelain`).
- Do not run cleanup if merge step failed or was skipped.
- Always propose `.worktree-backup/<branch>/` as the default backup destination.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup (6e) — never `rm -rf`/`Remove-Item -Recurse -Force`.
- `gh --version` must succeed before any gh command.
- `<<WORKFLOW_USER_VERIFIED: <reason>>>` is emitted in step 4 (before `gh pr merge`) or step 3b
  (after `state == MERGED`), via `skills/_shared/user-verified.md`. Never on abort
  or while polling.
- Step 3 PR state gate runs before the AUTO_MERGE_PR check; applies to both on/off modes; `MERGED` always routes to step 3b.
- `AUTO_MERGE_PR=on` skips `AskUserQuestion` in step 3 (worktree mode only).
- `$PR_NUMBER` captured in step 2; used explicitly in step 3a. Session-local only.
- This skill does NOT modify `workflow-gate.js`.
- Step 5.5 (b–d) MUST execute as one Bash tool call (survives Windows env reset, #504). Do not split into separate calls.
- Step 5.5 JSON output MUST NOT include `BRANCH_DELETED` (accuracy fix tracked separately; renderer renders `(none)` as fail-safe, #504).
- Step 7 sentinel check is mandatory; absence of `<<WORKFLOW_MARK_STEP_final_report_complete>>` in renderer output = failure. No silent fallback, no hand-written Markdown.
- Step 7 MUST read `NOTES_BACKUP_PATH` from the JSON via `node -e`, not from a shell variable (shell vars don't survive Windows Bash tool call boundaries).
- Step 7 MUST invoke renderer with `--env-file $HOME/.workflow-plans/<session-id>-final-report-env.json`.
