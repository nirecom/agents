---
name: session-close
description: Orchestrate session close — Phase 2 issue close + Final Report. Replaces CLAUDE.md Step 10b. Handles both ENFORCE_WORKTREE on (worktree path) and off (branch/main path).
user-invocable: true
---

Session close orchestrator. Drives `/issue-close-finalize` (when applicable),
collects the outcome JSON written by Step L, and renders the Final Report via
`bin/worktree-final-report.js`. Replaces the legacy "Step 7" emit inside
`/worktree-end` so the Final Report reflects every terminal action.

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- Caller context (under `ENFORCE_WORKTREE=on`): `/worktree-end` Steps 1–6i have
  already completed (worktree merged and removed; `<PLANS_DIR>/<session-id>-final-report-env.json` exists).
- Caller context (under `ENFORCE_WORKTREE=off`): the PR is merged. No worktree-end
  ran; the env file does not yet exist.

## Step 0 — Resolve PLANS_DIR and session id

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Substitute the absolute path for `<PLANS_DIR>` in every subsequent step.
Resolve `<session-id>` from `$CLAUDE_ENV_FILE` (`CLAUDE_SESSION_ID`) with the
fallback chain used by `--from-session`. If unresolvable, abort:
`session id unresolved — cannot render Final Report`.

`<PLANS_DIR>` and `<session-id>` are **LLM-substituted literals** — shell variables
do not persist between Bash tool calls.

## Step 1 — Detect ENFORCE_WORKTREE mode

```bash
bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off ENFORCE_WORKTREE on && echo off || echo on'
```

- `on` → worktree path (Step 2A).
- `off` → branch/main path (Step 2B).

## Step 2A — Worktree path: reuse existing env JSON

```bash
test -f "<PLANS_DIR>/<session-id>-final-report-env.json" \
  || { echo "ERROR: env JSON missing — /worktree-end must run first" >&2; exit 1; }
```

Proceed to Step 3.

## Step 2B — Branch/main path: build minimal env JSON

```bash
node "$AGENTS_CONFIG_DIR/bin/session-close-build-env.js" "<PLANS_DIR>/<session-id>-final-report-env.json"
```

Exit 0 → proceed to Step 3. Non-zero → abort (PR unresolvable).

## Step 3 — Non-GitHub pre-flight + issue close dispatch

```bash
bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; echo "NON_GITHUB_RC=$?"
```

- Non-zero → non-GitHub remote. Write skipped outcomes (pass `'[]'` when
  `closes_issues` is empty), then skip to Step 4:

```bash
node "$AGENTS_CONFIG_DIR/bin/issue-close-write-outcome.js" \
  --non-github '<ISSUES_JSON_ARRAY>' \
  "<PLANS_DIR>/<session-id>-issue-close-outcome.json"
```

`<ISSUES_JSON_ARRAY>` is the JSON number array the LLM parses from intent.md
via `hooks/lib/parse-closes-issues.js`, inlined as a literal at substitution time.

- Zero → GitHub remote. Parse `closes_issues` from
  `<PLANS_DIR>/<session-id>-intent.md` via the canonical parser.
  - `[]` → write empty outcome, skip to Step 4:

```bash
printf '{"issues":[]}\n' > "<PLANS_DIR>/<session-id>-issue-close-outcome.json"
```

  - non-empty → Step 3a.

## Step 3a — Invoke /issue-close-finalize via the Skill tool

Invoke `/issue-close-finalize --from-session`. The sub-skill writes
`<PLANS_DIR>/<session-id>-issue-close-outcome.json` as its Step L.

If it terminates without writing that file, write a synthetic fallback:

```bash
node "$AGENTS_CONFIG_DIR/bin/issue-close-write-outcome.js" \
  --fallback "<PLANS_DIR>/<session-id>-intent.md" \
  "<PLANS_DIR>/<session-id>-issue-close-outcome.json"
```

## Step 4 — Render Final Report

```bash
ENV_FILE="<PLANS_DIR>/<session-id>-final-report-env.json"
OUTCOME_FILE="<PLANS_DIR>/<session-id>-issue-close-outcome.json"
NOTES_PATH="$(node -e "var fs=require('fs'); try { var j=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); process.stdout.write(j.NOTES_BACKUP_PATH||''); } catch(e) { process.stdout.write(''); }" "$ENV_FILE")"
OUTPUT="$(node "$AGENTS_CONFIG_DIR/bin/worktree-final-report.js" \
  "<PLANS_DIR>/<session-id>-intent.md" \
  "$NOTES_PATH" \
  "<session-id>" \
  --env-file "$ENV_FILE" \
  --outcome-file "$OUTCOME_FILE" 2>&1)"
EXIT_CODE=$?
SENTINEL='<<WORKFLOW_MARK_STEP_final_report_complete>>'
if [ $EXIT_CODE -eq 0 ] && echo "$OUTPUT" | grep -qF "$SENTINEL"; then
  echo "$OUTPUT" | grep -vF "$SENTINEL"
else
  echo "WARNING: Final Report renderer failed or sentinel missing (exit=$EXIT_CODE)" >&2
  echo "$OUTPUT"
  echo "Manual fallback: review env JSON at $ENV_FILE and outcome JSON at $OUTCOME_FILE"
fi
```

Paste the renderer output verbatim into your response (exclude the sentinel line).
`stop-final-report-guard.js` validates completion via two checks: (a) the renderer
stamps `reported: true` into the env file after a successful stdout emission, and
(b) at least one assistant text message in the transcript contains the heading
`## Final Report —` (prevents the renderer Bash tool result from being mistaken
for a verbatim paste — issue #700). The hook blocks if either condition is unmet.

## Rules

- Orchestrates only — never modifies workflow state directly.
- `/issue-close-finalize` is invoked via the Skill tool only (never `bash`/`spawnSync`).
- Non-GitHub remotes never invoke `/issue-close-finalize`; outcomes written by Step 3.
- Empty `closes_issues` → skip `/issue-close-finalize`, write `{"issues":[]}`, emit Final Report.
- Fail-open: `/issue-close-finalize` failures surface in outcome JSON; renderer still runs.
- Every Bash call is self-contained — no shell variable crosses call boundaries.
