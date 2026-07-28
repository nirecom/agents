# shellcheck shell=bash
# Tests: hooks/session-start.js, hooks/lib/workflow-state/completion-approval.js, hooks/lib/workflow-state/state-io.js
# Tags: workflow, approval-gate, session-start, inheritance, artifact-hash, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G15 (F2): a new session inheriting a prior session's steps must also inherit
# its plan_approvals, each record bound to the session that OWNS the approved
# artifact (<owner-sid>-<step>.md) via artifact_session_id.
# fail-before-fix: session-start copied only `steps`, so writeState re-evaluated
# outline/detail as pending->complete for the NEW session, threw
# no-approval-record, and the new session ended up with NO state file at all.
# Even with approvals copied, hashing against the CURRENT session id would look
# for a nonexistent <new-sid>-outline.md and fail artifact-hash-unverifiable —
# hence the artifact_session_id assertions below.
# The negative controls prove the carry-forward is NOT unconditional trust.
# ===========================================================================

echo ""
echo "=== G15 (F2): session-start carries plan_approvals across the session boundary ==="

SESSION_START="$AGENTS_DIR/hooks/session-start.js"

# sha256_of <file> → hex digest (same algorithm as computeArtifactSha)
sha256_of() {
  run_with_timeout node -e "const fs=require('fs'),c=require('crypto');console.log(c.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'));" "$1"
}

# resolved_cwd <dir> → path.resolve() form, as getCurrentContext() computes it
resolved_cwd() {
  run_with_timeout node -e "console.log(require('path').resolve(process.argv[1]));" "$1"
}

# transcript_dir_for <resolved-cwd> → the encoded transcript directory name
transcript_dir_for() {
  run_with_timeout node -e "console.log(process.argv[1].toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'));" "$1"
}

# seed_prior_session <old-sid> <proj-dir> <transcript-base> <state-json>
# Writes the prior session's state file plus the JSONL breadcrumb that
# findLatestStateForContext() follows to discover it.
seed_prior_session() {
  local old_sid="$1" proj="$2" tbase="$3" json="$4"
  write_state "$old_sid" "$json"
  local rcwd tdir
  rcwd="$(resolved_cwd "$proj")"
  tdir="$tbase/$(transcript_dir_for "$rcwd")"
  mkdir -p "$tdir"
  run_with_timeout node -e '
    const fs = require("fs");
    const line = JSON.stringify({
      type: "attachment",
      attachment: {
        exitCode: 0,
        hookEvent: "SessionStart",
        stdout: "Current workflow session_id: " + process.argv[2] + "\n",
      },
    });
    fs.writeFileSync(process.argv[1], line + "\n");
  ' "$tdir/prior.jsonl" "$old_sid"
}

# run_session_start <new-sid> <proj-dir> <transcript-base> → global SS_OUT
run_session_start() {
  local new_sid="$1" proj="$2" tbase="$3"
  SS_OUT="$(printf '{"session_id":"%s"}' "$new_sid" | \
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    AGENTS_CONFIG_DIR="$CONFIG_DIR_ON" CLAUDE_PROJECT_DIR="$proj" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$tbase" CONFIRM_OUTLINE=on CONFIRM_DETAIL=on \
    run_with_timeout node "$SESSION_START" 2>&1 || true)"
}

# read_approval_field <sid> <step> <field> → value or "MISSING"
read_approval_field() {
  local f="$WORKFLOW_DIR/${1}.json"
  [ -f "$f" ] || { echo "MISSING"; return; }
  node -e "try{const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));const a=(s.plan_approvals||{})[process.argv[2]];const v=a?a[process.argv[3]]:null;console.log(v==null?'MISSING':String(v));}catch(e){console.log('ERR');}" "$f" "$2" "$3" 2>/dev/null || echo "ERR"
}

TBASE="$TMPDIR_BASE/transcripts"

# --- G15 positive: outline + detail approved in the prior session, artifacts intact.

OLD_SID="g15old-$$"
NEW_SID="g15new-$$"
PROJ_OK="$(setup_repo)"
printf 'approved outline body\n' > "$PLANS_DIR/${OLD_SID}-outline.md"
printf 'approved detail body\n' > "$PLANS_DIR/${OLD_SID}-detail.md"
SHA_O="$(sha256_of "$PLANS_DIR/${OLD_SID}-outline.md")"
SHA_D="$(sha256_of "$PLANS_DIR/${OLD_SID}-detail.md")"
BRANCH_OK="$(git -C "$PROJ_OK" rev-parse --abbrev-ref HEAD)"
CWD_OK="$(resolved_cwd "$PROJ_OK")"

# NB: the records deliberately OMIT artifact_session_id — session-start must
# backfill it from the prior session id (records written before F2 landed).
OLD_EXTRA="$(run_with_timeout node -e '
  const [cwd, branch, sid, shaO, shaD] = process.argv.slice(1);
  const rec = (sha) => ({ source: "confirm-sentinel", reason: null, artifact_sha256: sha,
    artifact_hash_status: "verified", recorded_at: "2026-06-20T10:00:00.000Z" });
  process.stdout.write(JSON.stringify({ cwd, git_branch: branch, session_id: sid,
    plan_approvals: { outline: rec(shaO), detail: rec(shaD) } }));
' "$CWD_OK" "$BRANCH_OK" "$OLD_SID" "$SHA_O" "$SHA_D")"

seed_prior_session "$OLD_SID" "$PROJ_OK" "$TBASE" \
  "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete","detail":"complete"}' wf-code "$OLD_EXTRA")"

check "G15-pre. prior session has outline complete" "complete" "$(read_state_status "$OLD_SID" outline)"

run_session_start "$NEW_SID" "$PROJ_OK" "$TBASE"

check "G15a. new session inherits outline=complete (state file created, not dropped)" \
  "complete" "$(read_state_status "$NEW_SID" outline)"
check "G15a2. new session inherits detail=complete" \
  "complete" "$(read_state_status "$NEW_SID" detail)"
check "G15b. inherited outline approval carries its confirm-sentinel source" \
  "confirm-sentinel" "$(read_approval_source "$NEW_SID" outline)"
check "G15c. outline approval stays bound to the artifact-owning session" \
  "$OLD_SID" "$(read_approval_field "$NEW_SID" outline artifact_session_id)"
check "G15c2. detail approval stays bound to the artifact-owning session" \
  "$OLD_SID" "$(read_approval_field "$NEW_SID" detail artifact_session_id)"
check "G15c3. inherited outline hash is the prior session's artifact hash" \
  "$SHA_O" "$(read_approval_field "$NEW_SID" outline artifact_sha256)"
check_contains "G15d. session-start reports the inheritance" \
  "Inherited workflow steps from session $OLD_SID" "$SS_OUT"
check_not_contains "G15e. no swallowed state-write failure" \
  "workflow state file could NOT be created" "$SS_OUT"

# --- G15f/g negative control: artifact TAMPERED after approval was recorded.
# The carried record must not be trusted on its own — the hash re-check runs
# against <old-sid>-outline.md and must fail closed for the new session.

OLD_BAD="g15oldbad-$$"
NEW_BAD="g15newbad-$$"
PROJ_BAD="$(setup_repo)"
printf 'approved outline body\n' > "$PLANS_DIR/${OLD_BAD}-outline.md"
SHA_BAD="$(sha256_of "$PLANS_DIR/${OLD_BAD}-outline.md")"
BRANCH_BAD="$(git -C "$PROJ_BAD" rev-parse --abbrev-ref HEAD)"
CWD_BAD="$(resolved_cwd "$PROJ_BAD")"
BAD_EXTRA="$(run_with_timeout node -e '
  const [cwd, branch, sid, sha] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({ cwd, git_branch: branch, session_id: sid,
    plan_approvals: { outline: { source: "confirm-sentinel", reason: null,
      artifact_sha256: sha, artifact_session_id: sid,
      artifact_hash_status: "verified", recorded_at: "2026-06-20T10:00:00.000Z" } } }));
' "$CWD_BAD" "$BRANCH_BAD" "$OLD_BAD" "$SHA_BAD")"

seed_prior_session "$OLD_BAD" "$PROJ_BAD" "$TBASE" \
  "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete"}' wf-code "$BAD_EXTRA")"

# Tamper AFTER the approval hash was recorded.
printf 'silently rewritten outline body\n' > "$PLANS_DIR/${OLD_BAD}-outline.md"

run_session_start "$NEW_BAD" "$PROJ_BAD" "$TBASE"

check "G15f. tampered artifact: inherited completion is refused (no state file)" \
  "MISSING" "$(read_state_status "$NEW_BAD" outline)"
check_contains "G15f2. failure is surfaced, not swallowed" \
  "workflow state file could NOT be created" "$SS_OUT"
check_contains "G15f3. rejection reason is the artifact hash mismatch" \
  "artifact-hash-mismatch" "$SS_OUT"

# --- G15h negative control: artifact DELETED after approval was recorded.

OLD_DEL="g15olddel-$$"
NEW_DEL="g15newdel-$$"
PROJ_DEL="$(setup_repo)"
printf 'approved outline body\n' > "$PLANS_DIR/${OLD_DEL}-outline.md"
SHA_DEL="$(sha256_of "$PLANS_DIR/${OLD_DEL}-outline.md")"
BRANCH_DEL="$(git -C "$PROJ_DEL" rev-parse --abbrev-ref HEAD)"
CWD_DEL="$(resolved_cwd "$PROJ_DEL")"
DEL_EXTRA="$(run_with_timeout node -e '
  const [cwd, branch, sid, sha] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({ cwd, git_branch: branch, session_id: sid,
    plan_approvals: { outline: { source: "confirm-sentinel", reason: null,
      artifact_sha256: sha, artifact_session_id: sid,
      artifact_hash_status: "verified", recorded_at: "2026-06-20T10:00:00.000Z" } } }));
' "$CWD_DEL" "$BRANCH_DEL" "$OLD_DEL" "$SHA_DEL")"

seed_prior_session "$OLD_DEL" "$PROJ_DEL" "$TBASE" \
  "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete"}' wf-code "$DEL_EXTRA")"

rm -f "$PLANS_DIR/${OLD_DEL}-outline.md"

run_session_start "$NEW_DEL" "$PROJ_DEL" "$TBASE"

check "G15h. deleted artifact: inherited completion is refused (no state file)" \
  "MISSING" "$(read_state_status "$NEW_DEL" outline)"
check_contains "G15h2. rejection reason is the unverifiable artifact hash" \
  "artifact-hash-unverifiable" "$SS_OUT"
