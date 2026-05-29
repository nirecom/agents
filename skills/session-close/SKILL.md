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
  already completed (the worktree is merged and removed, the session cwd is
  the main worktree, and `<PLANS_DIR>/<session-id>-final-report-env.json` exists).
- Caller context (under `ENFORCE_WORKTREE=off`): the PR is merged. No
  worktree-end ran; the env file does not yet exist.

## Step 0 — Resolve PLANS_DIR and session id

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Substitute the absolute path for `<PLANS_DIR>` in every subsequent step.
Resolve `<session-id>` from `$CLAUDE_ENV_FILE` (`CLAUDE_SESSION_ID`) with the
fallback chain used by `--from-session` elsewhere. If unresolvable, abort:
`session id unresolved — cannot render Final Report`.

Note on shell state: every subsequent `Bash` tool invocation is independent —
shell variables do not persist between calls. `<PLANS_DIR>` and `<session-id>`
above are **LLM-substituted literals**, not runtime shell variables. Each Bash
block below recomputes any path it needs from these literals.

## Step 1 — Detect ENFORCE_WORKTREE mode

```bash
bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off ENFORCE_WORKTREE on && echo off || echo on'
```

- `on` → worktree path (Step 2A).
- `off` → branch/main path (Step 2B).

## Step 2A — Worktree path: reuse existing env JSON

```bash
ENV_FILE="<PLANS_DIR>/<session-id>-final-report-env.json"
test -f "$ENV_FILE" || { echo "ERROR: env JSON missing at $ENV_FILE — /worktree-end must run first under ENFORCE_WORKTREE=on" >&2; exit 1; }
```

Proceed to Step 3.

## Step 2B — Branch/main path: build minimal env JSON

`/worktree-end` did not run. Build a minimal env file with PR metadata only;
worktree/backup fields render as `(none)` via `safeEnv` defaults.

```bash
PR_NUMBER="$(gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --state all --limit 1 --json number --jq '.[0].number')"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: cannot resolve PR_NUMBER for current branch — /session-close requires a PR" >&2
  exit 1
fi
PR_INFO="$(gh pr view "$PR_NUMBER" --json title,url,state)"
PR_TITLE="$(printf '%s' "$PR_INFO" | node -e "var d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).title||''))")"
PR_URL="$(printf '%s' "$PR_INFO" | node -e "var d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).url||''))")"
PR_STATE="$(printf '%s' "$PR_INFO" | node -e "var d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).state||''))")"
ENV_FILE="<PLANS_DIR>/<session-id>-final-report-env.json"
PR_NUMBER="$PR_NUMBER" PR_TITLE="$PR_TITLE" PR_URL="$PR_URL" PR_STATE="$PR_STATE" ENV_FILE="$ENV_FILE" \
node -e "
var fs=require('fs');
var data={
  PR_NUMBER: process.env.PR_NUMBER||'',
  PR_TITLE:  process.env.PR_TITLE||'',
  PR_URL:    process.env.PR_URL||'',
  PR_STATE:  process.env.PR_STATE||'',
  BRANCH: '', WORKTREE_PATH: '', CREATED_DATE: '',
  BACKUP_MANIFEST_PATH: '', NOTES_BACKUP_PATH: '',
  CLAUDE_CODE_RESTART_REQUIRED: '',
  CC_RESTART_REQUIRED: '', CC_RESTART_REASON: '',
  VSCODE_RELOAD_REQUIRED: '', VSCODE_RELOAD_REASON: '',
  INSTALLER_RERUN_REQUIRED: '', INSTALLER_RERUN_REASON: '',
  OS_REBOOT_REQUIRED: '', OS_REBOOT_REASON: ''
};
fs.writeFileSync(process.env.ENV_FILE, JSON.stringify(data,null,2));
"
```

This single bash block builds all variables it needs inline — nothing carried
from prior calls. Each `$PR_*` value is local to this block. Proceed to Step 3.

## Step 3 — Non-GitHub pre-flight + issue close dispatch

### Step 3 — non-GitHub pre-flight (runs first)

Before invoking `/issue-close-finalize`, check whether the current remote is
GitHub. If not, write `skipped-non-github` outcomes for every `closes_issues`
entry and skip directly to Step 4 (Final Report). `/issue-close-finalize` is
**not** invoked on the non-GitHub path — its pre-flight already exits early
without writing outcomes, so the write must happen here.

```bash
bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"
NON_GITHUB_RC=$?
echo "NON_GITHUB_RC=$NON_GITHUB_RC"
```

- `NON_GITHUB_RC != 0` → non-GitHub remote. Execute the **non-GitHub outcome
  write** block below (single self-contained Bash call), then skip to Step 4.
- `NON_GITHUB_RC == 0` → GitHub remote. Proceed to Step 3a.

Non-GitHub outcome write (single Bash block; `<PLANS_DIR>` and `<session-id>`
are LLM-substituted; `<ISSUES_JSON_ARRAY>` is the JSON array of issue numbers
the LLM parses from intent.md via the canonical parser, inlined as a literal
JSON string into the command at substitution time):

```bash
OUTCOME_FILE="<PLANS_DIR>/<session-id>-issue-close-outcome.json"
node -e "
var fs=require('fs');
var issues=JSON.parse(process.argv[1]);
var p=process.argv[2];
var bag={issues:[]};
try { bag=JSON.parse(fs.readFileSync(p,'utf8')); if(!bag||!Array.isArray(bag.issues)) bag={issues:[]}; } catch(_){}
issues.forEach(function(n){
  bag.issues = bag.issues.filter(function(e){ return e && e.issueNumber !== n; });
  bag.issues.push({
    issueNumber: n, state: 'skipped-non-github',
    historyEntry: 'skipped', issueClosed: 'skipped',
    sentinelsPosted: 'skipped', wipCleared: 'skipped'
  });
});
fs.writeFileSync(p, JSON.stringify(bag,null,2));
" '<ISSUES_JSON_ARRAY>' "$OUTCOME_FILE"
```

If `closes_issues` is empty on the non-GitHub path, write `{"issues":[]}` and
skip to Step 4 (same as the GitHub-but-empty branch below).

### Step 3 — GitHub path: parse closes_issues

Parse `closes_issues` from `<PLANS_DIR>/<session-id>-intent.md` using the
canonical parser (`hooks/lib/parse-closes-issues.js`). The LLM observes the
parser output and routes:

- `[]` → write empty outcome file directly, skip to Step 4:

```bash
OUTCOME_FILE="<PLANS_DIR>/<session-id>-issue-close-outcome.json"
printf '{"issues":[]}\n' > "$OUTCOME_FILE"
```

- non-empty → Step 3a.

### Step 3a — Invoke /issue-close-finalize via the Skill tool

Invoke `/issue-close-finalize --from-session` using the Skill tool. The
sub-skill performs sub-issue gate / doc-append / close / sentinels / WIP clear
and **writes `<PLANS_DIR>/<session-id>-issue-close-outcome.json` as its Step L**.

If the sub-skill terminates abnormally without writing the outcome JSON,
write a synthetic fallback. This single bash block re-reads `intent.md` to
obtain the issue numbers — it does **not** rely on any variable set in a prior
Bash call.

```bash
OUTCOME_FILE="<PLANS_DIR>/<session-id>-issue-close-outcome.json"
INTENT_MD="<PLANS_DIR>/<session-id>-intent.md"
test -f "$OUTCOME_FILE" || node -e "
var fs=require('fs');
var p=require('$AGENTS_CONFIG_DIR/hooks/lib/parse-closes-issues.js');
var issues=p.parseClosesIssues(process.argv[1]);
var bag={issues:issues.map(function(n){
  return { issueNumber: n, state: 'failed',
           historyEntry: 'failed', issueClosed: 'failed',
           sentinelsPosted: 'failed', wipCleared: 'failed' };
})};
fs.writeFileSync(process.argv[2], JSON.stringify(bag,null,2));
" "$INTENT_MD" "$OUTCOME_FILE"
```

## Step 4 — Render Final Report

This single bash block computes `ENV_FILE`, `OUTCOME_FILE`, and `NOTES_PATH`
inline from the LLM-substituted `<PLANS_DIR>` and `<session-id>` literals —
nothing is carried from prior calls.

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

Paste the renderer output verbatim into the assistant message — the
`stop-final-report-guard.js` Stop hook validates every heading and every
content-level probe (including the new `### Closed Issue Outcomes` section,
which now requires at least one bullet directly below the heading).

## Rules

- This skill never modifies workflow state directly; it only orchestrates
  sub-skill invocations and a renderer.
- `/issue-close-finalize` is always invoked via the Skill tool when
  `closes_issues` is non-empty AND the remote is GitHub — never via
  `bash`/`spawnSync`.
- Non-GitHub remotes never invoke `/issue-close-finalize`; outcomes are
  written by Step 3 with state `skipped-non-github`.
- Empty `closes_issues` → skip `/issue-close-finalize`, write
  `{ "issues": [] }`, still emit Final Report.
- Fail-open: any failure inside `/issue-close-finalize` is reflected in the
  outcome JSON and surfaces in the Final Report; the renderer is still invoked.
- Final Report output is verbatim renderer stdout (sentinel excluded).
- Branch/main path (Step 2B) populates worktree/backup fields as empty strings;
  the renderer's `safeEnv` substitutes `(none)`. Intended fail-safe.
- This skill does NOT clean up worktrees, manage branches, or push commits.
- Every Bash tool call is self-contained — no shell variable crosses call
  boundaries. Paths derived from `<PLANS_DIR>` and `<session-id>` are
  LLM-substituted literals.
