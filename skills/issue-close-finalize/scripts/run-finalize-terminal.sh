#!/bin/bash
# run-finalize-terminal.sh — phase=finalize_terminal for the issue-close-finalize worker
# Steps H (close), I (sentinels), J (wip clear), K (outcome), then terminal state write.
# Usage: bash run-finalize-terminal.sh <state_file_path> <session_id> <outcome_file_path> [expected_token]
# Env:   AGENTS_CONFIG_DIR  FINALIZE_SCRIPTS_DIR
# Stdout (eval-able KEY=VALUE): STATUS  SUMMARY
# Exit 0 always; check STATUS.
#
# COMPARE-AND-SWAP. <expected_token> is the sha256 hex digest of the state file's
# raw bytes as the calling worker validated them — the same protocol
# run-loop-step.js speaks on its own 3rd argument. The caller's check happens in
# another process; this script re-reads the file and EVALS what it finds, so a
# replacement written in between would slip past that check entirely and bring
# live shell syntax with it. The digest is therefore re-computed here and
# compared BEFORE the eval. Optional so a manual invocation still works; the
# worker always supplies it.
set -euo pipefail

STATE_FILE_PATH="${1:?state_file_path required}"
SESSION_ID="${2:?session_id required}"
OUTCOME_FILE_PATH="${3:?outcome_file_path required}"
EXPECTED_TOKEN="${4:-}"
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

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

# Read required fields from state file
read_state() {
    node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
if (s.schema_version !== 3) { process.stderr.write('schema_version must be 3\n'); process.exit(1); }
console.log('CURRENT_ISSUE_NUMBER=' + s.current_issue_number);
console.log('OWNER_REPO=' + s.owner_repo);
console.log('TRIAGE_ACTION=' + s.triage_action);
console.log('MERGE_COMMIT=' + (s.merge_commit || ''));
" "$STATE_FILE_PATH"
}

rc=0
eval "$(read_state)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    printf 'STATUS=failed\nSUMMARY=state file read failed\n'
    exit 0
fi

# Step ICF-H: close issue (skipped when triage_action=resume_j — issue already closed)
ICF_H_STATUS=succeeded
if [[ "$TRIAGE_ACTION" != "resume_j" ]]; then
    rc=0
    bash "$AGENTS_CONFIG_DIR/bin/github-issues/close-completed.sh" \
        --repo "$OWNER_REPO" "$CURRENT_ISSUE_NUMBER" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=Step ICF-H: gh issue close failed for #%s\n' "$CURRENT_ISSUE_NUMBER"
        exit 0
    fi
fi

# Step ICF-I: post-close sentinels (non-fatal)
bash "$AGENTS_CONFIG_DIR/bin/github-issues/post-close-sentinels.sh" \
    "$CURRENT_ISSUE_NUMBER" "${MERGE_COMMIT:-}" || true
ICF_I_STATUS=succeeded

# Step ICF-J: wip clear (non-fatal)
bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" clear "$CURRENT_ISSUE_NUMBER" || true
ICF_J_STATUS=succeeded

# Step ICF-K: determine history_entry_status and write outcome
case "$TRIAGE_ACTION" in
    auto_close_path)   HISTORY_ENTRY_STATUS=skipped_no_history_notes ;;
    admin_close_path)  HISTORY_ENTRY_STATUS=skipped_admin_close ;;
    *)                 HISTORY_ENTRY_STATUS=written_by_step_6h ;;
esac

node "$AGENTS_CONFIG_DIR/bin/issue-close-write-outcome.js" \
    --session-id "$SESSION_ID" \
    --out-file "$OUTCOME_FILE_PATH" \
    "$CURRENT_ISSUE_NUMBER" \
    "succeeded" \
    "$HISTORY_ENTRY_STATUS" \
    "succeeded" \
    "$ICF_I_STATUS" \
    "$ICF_J_STATUS" || true

# Write terminal state atomically
node -e "
const fs = require('fs');
const p = process.argv[1];
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
s.phase = 'terminal';
const tmp = p + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
fs.renameSync(tmp, p);
" "$STATE_FILE_PATH"

printf 'STATUS=terminal\nSUMMARY=Steps H/I/J/K complete for #%s\n' "$CURRENT_ISSUE_NUMBER"
