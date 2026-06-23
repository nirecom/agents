---
name: session-close
description: Orchestrate session close — Phase 2 issue close + Final Report. Replaces CLAUDE.md WF-CODE-12. Handles both ENFORCE_WORKTREE on (worktree path) and off (branch/main path).
user-invocable: true
---

Session close orchestrator. Drives `/issue-close-finalize` (when applicable),
collects the outcome JSON written by Step L, and emits the Final Report by
substituting the skeleton from `hooks/lib/final-report-schema.renderSkeleton`.
Replaces the legacy "Step 7" emit inside `/worktree-end` so the Final Report
reflects every terminal action.

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- Caller context (under `ENFORCE_WORKTREE=on`): `/worktree-end` Steps 1–6i have
  already completed (worktree merged and removed; `<PLANS_DIR>/<session-id>-final-report-env.json` exists).
- Caller context (under `ENFORCE_WORKTREE=off`): the PR is merged. No worktree-end
  ran; the env file does not yet exist.

## Step SC-0 — Resolve PLANS_DIR and session id

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

## Step SC-1 — Detect ENFORCE_WORKTREE mode

Check via Bash:
`bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" ENFORCE_WORKTREE on'`

- stdout `ON` or `ERROR` → worktree path (SC-2A).
- stdout `OFF` → branch/main path (SC-2B).

## Step SC-2A — Worktree path: reuse existing env JSON

```bash
test -f "<PLANS_DIR>/<session-id>-final-report-env.json" \
  || { echo "ERROR: env JSON missing — /worktree-end must run first" >&2; exit 1; }
```

Then write the late-finding L2 eligibility flag (#997):
  node "$AGENTS_CONFIG_DIR/bin/supervisor-write-layer2" --session-id "<session-id>" --set-l2-eligible-phase post_final_report_window
Proceed to SC-3.

## Step SC-2B — Branch/main path: build minimal env JSON

```bash
node "$AGENTS_CONFIG_DIR/bin/session-close-build-env.js" "<PLANS_DIR>/<session-id>-final-report-env.json"
```

Exit 0 → write the late-finding L2 eligibility flag (#997):
  node "$AGENTS_CONFIG_DIR/bin/supervisor-write-layer2" --session-id "<session-id>" --set-l2-eligible-phase post_final_report_window
Then proceed to SC-3. Non-zero → abort (PR unresolvable).

## Step SC-3 — Non-GitHub pre-flight + issue close dispatch

```bash
bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; echo "NON_GITHUB_RC=$?"
```

- Non-zero → non-GitHub remote. Write skipped outcomes (pass `'[]'` when
  `closes_issues` is empty), then skip to SC-6:

```bash
node "$AGENTS_CONFIG_DIR/bin/issue-close-write-outcome.js" \
  --non-github '<ISSUES_JSON_ARRAY>' \
  "<PLANS_DIR>/<session-id>-issue-close-outcome.json"
```

`<ISSUES_JSON_ARRAY>` is the JSON number array the LLM parses from intent.md
via `hooks/lib/parse-closes-issues.js`, inlined as a literal at substitution time.

- Zero → GitHub remote. Parse `closes_issues` from
  `<PLANS_DIR>/<session-id>-intent.md` via the canonical parser.
  - `[]` → write empty outcome, skip to SC-6:

```bash
printf '{"issues":[]}\n' > "<PLANS_DIR>/<session-id>-issue-close-outcome.json"
```

  - non-empty → SC-3a.

## Step SC-3a — Invoke /issue-close-finalize via the Skill tool

Invoke `/issue-close-finalize --from-session`. The sub-skill writes
`<PLANS_DIR>/<session-id>-issue-close-outcome.json` as its Step L.

If it terminates without writing that file, write a synthetic fallback:

```bash
node "$AGENTS_CONFIG_DIR/bin/issue-close-write-outcome.js" \
  --fallback "<PLANS_DIR>/<session-id>-intent.md" \
  "<PLANS_DIR>/<session-id>-issue-close-outcome.json"
```

## Step SC-4 — Retrospective pass (write-only)

Before rendering the Final Report, scan the session for any unreported observations (fallback paths taken, sanctioned-command false-blocks, step degradations). For each one, run `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity notice --detail "<observation>" --reporter session-close` (session-id auto-resolves). Findings are written to `layer1.findings` for the audit trail only. The final-report-env.json anchor (established at Step 2A) prevents these findings from arming a new L2 cycle for this session.

## Step SC-5 — Pre-Final-Report L2 gate

Read `<PLANS_DIR>/<session-id>-supervisor-state.json` (Read tool) and check `layer2.l2_phase`:

- `"pending"` and `l2_armed_at !== null`: check `last_run_at`:
  - `last_run_at !== null` (#961 heuristic: L2 ran but `--set-l2-phase done` was not committed):
    1. Repair state: `node "$AGENTS_CONFIG_DIR/bin/supervisor-write-layer2" --session-id "<session-id>" --set-l2-phase done --clear-l2-armed-at`
    2. Record audit finding: `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity notice --detail "#961 heuristic: l2_phase=pending with last_run_at set — repaired to done" --reporter session-close`
    3. Proceed to SC-6.
  - `last_run_at === null`:
    - If `Date.parse(l2_armed_at)` is NaN **or** `(now_ms - Date.parse(l2_armed_at)) > 600000` (10 minutes, the **L2_TIMEOUT_MS** threshold): L2 never fired — elapsed-time fallback. Run `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity warning --detail "SC-5 elapsed-time fallback: l2_phase=pending, l2_armed_at=<value>, last_run_at=null, elapsed >10 min (or l2_armed_at unparseable)" --reporter session-close` and proceed to SC-6.
    - Otherwise: L2 not yet run. Emit the gate sentinel and yield — do not emit the Final Report this turn:
    `echo "<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>"`
    The next Stop fires `supervisor-guard.js`, which runs L2. The supervisor writes `--set-l2-phase done`. When the session resumes, this gate detects `done` and proceeds to SC-6.
    Note: the state-writer guard in `ensureLayer2Scheduled` prevents findings written during Step SC-4 from re-arming `next_check_at` after the final-report-env.json anchor is established (Step SC-2A). This gate therefore reads a stable value.

- `"pending"` and `l2_armed_at === null` (anomalous state — writer set `l2_phase=pending` without `l2_armed_at`, indicating an interrupted write or upstream writer bug): record an **error** finding via `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity error --detail "SC-5 anomalous state: l2_phase=pending, l2_armed_at=null; supervisor-state snapshot: <one-line JSON of layer2 object>" --reporter session-close` and proceed to SC-6.
  **No L2 review is promised by this branch.** Because the final-report-env.json anchor (Step SC-2A) has already been written, `ensureLayer2Scheduled` is a no-op (frozen schedule). The finding is recorded for audit trail only.

- `"done"` or `null`: proceed to SC-6. (`null` = L2 was never scheduled this session.)

- `"frozen"`: proceed to SC-6. (Final Report re-emit scenario; idempotent.)

- State file absent: treat as `null` and proceed to SC-6.

### SC-5b — L3 stale-pending repair

Read `layer3.l3_phase` from the same state file.

- If `"pending"` and `l3_last_run_at` is a non-null string (#1051 heuristic: L3 ran but `--set-l3-phase done` was not committed): repair via `node "$AGENTS_CONFIG_DIR/bin/supervisor-write-layer3" --set-l3-phase done --clear-l3-armed-at` (omit `--session-id` — auto-resolves and mirrors both stores), record a `notice` finding (`detail`: `#1051 heuristic: l3_phase=pending with l3_last_run_at set — repaired to done`), proceed to SC-6.
- If `"pending"` and `l3_last_run_at === null` and `Date.parse(l3_armed_at)` is NaN OR `(now_ms - Date.parse(l3_armed_at)) > 600000` (L3_TIMEOUT_MS = 10 min): record a `warning` finding (`detail`: `SC-5 L3 elapsed-time fallback: l3_phase=pending, elapsed >10 min`) and proceed to SC-6.
- If `"pending"` and within the window: same yield pattern as L2 — emit `<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>` and return (the next Stop fires L3 review).
- If `"done"`, `"frozen"`, `null`, or state-file absent: proceed to SC-6.

## Step SC-6 — Emit Final Report directly into assistant text

Read four input files via the Read tool:
- `<PLANS_DIR>/<session-id>-final-report-env.json`
- `<PLANS_DIR>/<session-id>-issue-close-outcome.json`
- `<PLANS_DIR>/<session-id>-intent.md`
- The WORKTREE_NOTES.md backup path from the `NOTES_BACKUP_PATH` field in the env JSON

Generate the skeleton (run this Bash command):
  node -e "process.stdout.write(require(process.env.AGENTS_CONFIG_DIR + '/hooks/lib/final-report-schema').renderSkeleton('<session-id>'))"
(`<session-id>` must match `^[A-Za-z0-9_-]+$` — abort if it does not)

Substitute every `<PLACEHOLDER>` token in the skeleton using the values you read:
- `<PR_NUMBER>`, `<PR_TITLE>`, `<PR_URL>`, `<PR_STATE>` → env JSON fields (use `(none)` when empty)
- `<BRANCH>`, `<WORKTREE_PATH>`, `<CREATED_DATE>`, `<BACKUP_MANIFEST_PATH>`, `<BRANCH_DELETED>` → env JSON fields (use `(none)` when empty)
- `<CLOSED_ISSUES_LIST>` → parse `closes_issues` from intent.md; render as `- #N` lines or `- (none)`
- `<CLOSED_ISSUE_OUTCOMES>` → one line per issue from outcome JSON `issues[]`: `- #N: <state> (history: <historyEntry>, closed: <issueClosed>, sentinels: <sentinelsPosted>, wip: <wipCleared>)`; when outcome JSON missing or `issues` empty: `- (outcome data not found — investigate)`
- `<CC_RESTART_REQUIRED_DECISION>` → `required (<CC_RESTART_REASON>)` when `CC_RESTART_REQUIRED` is `required`, otherwise `not_required`
- `<VSCODE_RELOAD_REQUIRED_DECISION>` → same pattern using `VSCODE_RELOAD_REQUIRED` / `VSCODE_RELOAD_REASON`
- `<INSTALLER_RERUN_REQUIRED_DECISION>` → same pattern using `INSTALLER_RERUN_REQUIRED` / `INSTALLER_RERUN_REASON`
- `<OS_REBOOT_REQUIRED_DECISION>` → same pattern using `OS_REBOOT_REQUIRED` / `OS_REBOOT_REASON`
- `<BUGS_FOUND>`, `<RELATED_TASKS>`, `<NEXT_TASKS>` → extract the matching `##` section content from WORKTREE_NOTES.md backup; or `- (none)` when file absent

Do not leave any `<PLACEHOLDER>` tokens unsubstituted. Emit the substituted text verbatim into your assistant text reply — no preamble, no summarization, no section reordering, no merging.

After emitting, mark completion:
  node "$AGENTS_CONFIG_DIR/bin/supervisor-write-layer2" --session-id "<session-id>" --set-l2-phase frozen
  echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"

`stop-final-report-guard.js` validates completion by checking all 10 Final Report headings from `getSectionHeadings()` appear after the `## Final Report — <session-id>` line. Missing any heading, or any unsubstituted `<TOKEN>` present → `decision: block` + exit 2 + re-prompt with a specific list.

## Step SC-7 — Surface Layer 2 findings (post-Final-Report)

Read `<PLANS_DIR>/<session-id>-supervisor-state.json` (Read tool). If absent, or `layer2.findings` is empty, or `layer2.findings_surfaced_at` is already set, skip to the sentinel and return.

Compute the render:

  node -e "const r=require(process.env.AGENTS_CONFIG_DIR+'/hooks/lib/supervisor-findings-render');const s=require('fs');const st=JSON.parse(s.readFileSync('<PLANS_DIR>/<session-id>-supervisor-state.json','utf8'));const out=r.formatLayer2Findings(st.layer2.findings||[],{sessionId:'<session-id>',workflowSessionId:process.env.CLAUDE_SESSION_ID||null,supervisorPath:process.env.AGENTS_CONFIG_DIR+'/agents/supervisor.md',stateFilePath:'<PLANS_DIR>/<session-id>-supervisor-state.json'});if(out)process.stdout.write(out+'\n');"

When the render is non-empty: emit the text verbatim into the assistant reply (no preamble, no wrapping).

Mark surfaced and complete:
  node "$AGENTS_CONFIG_DIR/bin/supervisor-write-layer2" --session-id "<session-id>" --mark-findings-surfaced
  echo "<<WORKFLOW_MARK_STEP_l2_findings_surfaced_complete>>"

## Rules

- Orchestrates only — never modifies workflow state directly.
- `/issue-close-finalize` is invoked via the Skill tool only (never `bash`/`spawnSync`).
- Non-GitHub remotes never invoke `/issue-close-finalize`; outcomes written by SC-3.
- Empty `closes_issues` → skip `/issue-close-finalize`, write `{"issues":[]}`, emit Final Report.
- Fail-open: `/issue-close-finalize` failures surface in outcome JSON; renderer still runs.
- Every Bash call is self-contained — no shell variable crosses call boundaries.
- On fallback or step degradation (synthetic outcome fallback, non-GitHub skip path): run `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity warning --detail "<describe fallback>" --reporter session-close` (session-id auto-resolves).
- Report observations per rules/supervisor-reporting.md.
