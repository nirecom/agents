#!/bin/bash
# run-finalize-terminal.sh — phase=finalize_terminal for the issue-close-finalize worker
# Runs ICF-H (close), ICF-I (sentinels), ICF-J (wip clear), ICF-K (outcome), then the terminal state write.
# Usage: bash run-finalize-terminal.sh <state_file_path> <session_id> <outcome_file_path> [expected_token]
# Stdout (KEY=VALUE lines): STATUS  SUMMARY. Exit 0 always; check STATUS.
# COMPARE-AND-SWAP: <expected_token> is the sha256 of the state file's raw bytes as the caller
# validated them (run-loop-step.js 3rd-argument protocol). This script re-reads the file, so a
# replacement written in between would bring unvalidated values — re-check the digest BEFORE the read.
# Optional so a manual invocation still works; the worker always supplies it.
set -euo pipefail

STATE_FILE_PATH="${1:?state_file_path required}"
SESSION_ID="${2:?session_id required}"
OUTCOME_FILE_PATH="${3:?outcome_file_path required}"
EXPECTED_TOKEN="${4:-}"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=lib/kv-read.sh
. "$SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/scripts/lib/kv-read.sh"

export ISSUE_CLOSE_SKILL=1

# Same digest run-loop-step.js's tokenOf() computes: sha256 over the raw bytes.
# Node is used rather than sha256sum/shasum so the two sides cannot drift, and
# node is already a hard dependency of every other step in this chain.
state_token() {
    node -e "
const fs = require('fs');
const crypto = require('crypto');
console.log(crypto.createHash('sha256').update(fs.readFileSync(process.argv[1], 'utf8')).digest('hex'));
" "$STATE_FILE_PATH"
}

if [[ -n "$EXPECTED_TOKEN" ]]; then
    rc=0
    ACTUAL_TOKEN="$(state_token)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=state file could not be read for the compare-and-swap check\n'
        exit 0
    fi
    if [[ "$ACTUAL_TOKEN" != "$EXPECTED_TOKEN" ]]; then
        printf 'state file conflict: it changed between the caller validation and this pass\n' >&2
        printf 'STATUS=failed\nSUMMARY=state file conflict: it changed between the caller validation and this pass; re-run this pass\n'
        exit 0
    fi
fi

# Read required fields from state file. The accepted schema version and its mismatch message
# are the writer's own (state.js), so a version bump there cannot leave this reader behind.
# Exit 3 = schema-version mismatch; stdout then carries the one-line message.
STATE_WRITER="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/workers/issue-close-finalize/state.js"
read_state() {
    node -e "
const path = require('path');
const w = require(path.resolve(process.argv[2]));
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
if (s.schema_version !== w.SCHEMA_VERSION) { console.log(w.schemaVersionMismatchMessage(s.schema_version)); process.exit(3); }
// One line per key: a value is cut at its first line break, so it cannot emit another KEY= line.
const one = (v) => String(v).split(/[\r\n]/)[0];
console.log('CURRENT_ISSUE_NUMBER=' + one(s.current_issue_number));
console.log('OWNER_REPO=' + one(s.owner_repo));
console.log('TRIAGE_ACTION=' + one(s.triage_action));
console.log('MERGE_COMMIT=' + one(s.merge_commit || ''));
" "$STATE_FILE_PATH" "$STATE_WRITER"
}

rc=0
STATE_KV="$(read_state)" || rc=$?
if [[ "$rc" -eq 3 ]]; then
    printf 'STATUS=failed\nSUMMARY=%s\n' "${STATE_KV//$'\n'/ }"
    exit 0
elif [[ "$rc" -ne 0 ]]; then
    printf 'STATUS=failed\nSUMMARY=state file read failed\n'
    exit 0
fi
CURRENT_ISSUE_NUMBER="" OWNER_REPO="" TRIAGE_ACTION="" MERGE_COMMIT=""
kv_read "$STATE_KV" CURRENT_ISSUE_NUMBER OWNER_REPO TRIAGE_ACTION MERGE_COMMIT

# ICF-H: close issue (skipped when triage_action=resume_j — issue already closed)
ICF_H_STATUS=succeeded
if [[ "$TRIAGE_ACTION" != "resume_j" ]]; then
    rc=0
    bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/close-completed.sh" \
        --repo "$OWNER_REPO" "$CURRENT_ISSUE_NUMBER" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=ICF-H: gh issue close failed for #%s\n' "$CURRENT_ISSUE_NUMBER"
        exit 0
    fi
fi

# ICF-I: post-close sentinels (non-fatal)
bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/post-close-sentinels.sh" \
    "$CURRENT_ISSUE_NUMBER" "${MERGE_COMMIT:-}" || true
ICF_I_STATUS=succeeded

# ICF-J: wip clear (non-fatal)
bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh" clear "$CURRENT_ISSUE_NUMBER" || true
ICF_J_STATUS=succeeded

# ICF-K: determine history_entry_status and write outcome
case "$TRIAGE_ACTION" in
    auto_close_path)   HISTORY_ENTRY_STATUS=skipped_no_history_notes ;;
    admin_close_path)  HISTORY_ENTRY_STATUS=skipped_admin_close ;;
    *)                 HISTORY_ENTRY_STATUS=written_by_step_6h ;;
esac

node "$SCRIPT_CHECKOUT_ROOT/bin/issue-close-write-outcome.js" \
    --session-id "$SESSION_ID" \
    --out-file "$OUTCOME_FILE_PATH" \
    "$CURRENT_ISSUE_NUMBER" \
    "succeeded" \
    "$HISTORY_ENTRY_STATUS" \
    "succeeded" \
    "$ICF_I_STATUS" \
    "$ICF_J_STATUS" || true

# Write terminal state atomically. The temp name is unique per writer (as in run-loop-step.js):
# a fixed '<p>.tmp' is shared by every process writing this file.
node -e "
const fs = require('fs');
const crypto = require('crypto');
const p = process.argv[1];
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
s.phase = 'terminal';
const tmp = p + '.' + process.pid + '.' + crypto.randomBytes(6).toString('hex') + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
fs.renameSync(tmp, p);
" "$STATE_FILE_PATH"

printf 'STATUS=terminal\nSUMMARY=ICF-H..ICF-K complete for #%s\n' "$CURRENT_ISSUE_NUMBER"
