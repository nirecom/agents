#!/usr/bin/env bash
# Tests: bin/state-dir-relocation, hooks/lib/temporary-migrations/state-dir-relocation/move.js, hooks/lib/temporary-migrations/state-dir-relocation/copy.js, hooks/lib/temporary-migrations/state-dir-relocation/reconcile.js, hooks/lib/temporary-migrations/state-dir-relocation/legacy.js, hooks/lib/temporary-migrations/state-dir-relocation/rewrite-root.js, hooks/lib/temporary-migrations/state-dir-relocation/remaining.js, hooks/workflow-state/state-io/state-lock.js, skills/session-close/scripts/relocate-session-state.sh, skills/session-close/SKILL.md, bin/check-migration-blocks.sh
# Tags: workflow-state, state-root, relocation, migration, fault-injection, session-close, bin, scope:issue-specific, TL2
# #2511 stage 6: /session-close moves a legacy session (~/.claude/projects/workflow)
# into ~/.workflow-state, with the <sid>.json rename as the single commit point.
# The file pins state and plans dirs first; every move runs with the pin removed
# per call and HOME/USERPROFILE pointed at a throwaway home.
# TL3 gap: crashes are simulated with process.exit fault points; a real power loss
# or a Windows EPERM held by an antivirus scanner is what only a live host shows.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "$0")/../lib/harness.sh"
T="$(make_tmp)"
readonly T
harness_isolate "$T/iso"
export WORKFLOW_STATE_DIR="$T/iso/workflow-state"
trap 'rm -rf "$T"' EXIT

# The retired variable name, assembled so this file never carries the literal.
OLD_TOKEN="CLAUDE_""WORKFLOW_DIR"
A="$(np "$SCRIPT_CHECKOUT_ROOT")"
mkdir -p "$T/cwd" "$T/pins"
DENV=(env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" -u STATE_RELOCATION_FAULT -u CLAUDE_SESSION_ID
  -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE)
MV_EXTRA=()

sid_of() { printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }

# new_home <name> — a throwaway default-path home; sets H, NEW, LEG (node form).
new_home() {
  mkdir -p "$T/homes/$1"
  H="$(np "$T/homes/$1")"
  NEW="$H/.workflow-state"
  LEG="$H/.claude/projects/workflow"
}

# mv_run <sub> <args...> — bin/state-dir-relocation under the default env; FAULT selects
# a fault point, MV_EXTRA adds env. Sets MV_OUT (CR stripped), MV_ERR, MV_RC.
mv_run() {
  MV_RC=0
  MV_OUT="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
    ${FAULT:+"STATE_RELOCATION_FAULT=$FAULT"} ${MV_EXTRA[@]+"${MV_EXTRA[@]}"} \
    node "$A/bin/state-dir-relocation" "$@" 2>"$T/mv.err")" || MV_RC=$?
  MV_OUT="${MV_OUT//$'\r'/}"
  MV_ERR="$(cat "$T/mv.err")"
}

move() { FAULT="${2:-}" mv_run move --session "$1"; }

# route <sid> — getSessionStateDir under the default env, `/` separators.
route() {
  (cd "$T/cwd" && run_with_timeout 30 "${DENV[@]}" HOME="$H" USERPROFILE="$H" node -e '
    try { const m = require(process.argv[1]);
      process.stdout.write(String(m.getSessionStateDir(process.argv[2])).replace(/\\/g, "/"));
    } catch (e) { process.stdout.write("ERR:" + String(e.message).split("\n")[0]); }' \
    "$A/hooks/workflow-state/state-io/state-root.js" "$1" 2>/dev/null) || true
}

# seed_session <root> <sid> — json, control dir, marker, instructions-loaded dir, turn marker.
# The turn marker uses the real writer's `<sid>.confirm-plan-turn-*` spelling: a
# `<sid>-<suffix>` name is another session's unless listed in SID_DASH_SUFFIXES (#2512 C3).
seed_session() {
  mkdir -p "$1/$2.control" "$1/$2.instructions-loaded"
  printf '{"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z"}\n' "$2" >"$1/$2.json"
  printf '{"layer1":{"findings":[]}}\n' >"$1/$2.control/supervisor-state.json"
  printf 'off\n' >"$1/$2.workflow-off"
  printf 'loaded\n' >"$1/$2.instructions-loaded/CLAUDE.md"
  printf '{"turn":1}\n' >"$1/$2.confirm-plan-turn-x.json"
}

# entries <root> <sid> — top-level names that are <sid>, <sid>.* or <sid>-*, comma-joined.
entries() {
  local f out=""
  for f in "$1/$2" "$1/$2".* "$1/$2"-*; do
    [[ -e "$f" ]] && out="$out${f##*/},"
  done
  printf '%s' "$out"
}

# snap <dir> — every path with a checksum for files; the failure-report marker is
# excluded because a failed move is allowed to create it in the legacy control dir.
snap() {
  [[ -d "$1" ]] || return 0
  (cd "$1" && find . -name relocation-failure-reported -prune -o -print | LC_ALL=C sort |
    while IFS= read -r f; do
      if [[ -f "$f" ]]; then printf '%s %s\n' "$f" "$(cksum <"$f")"; else printf '%s\n' "$f"; fi
    done)
}

lines() { printf '%s' "$1" | grep -c '' || true; }
workdirs() { find "$1" -maxdepth 1 -name ".relocating-$2-*" 2>/dev/null || true; }
# age_locks <dir> — a crashed mover's locks look abandoned once time has passed.
age_locks() { find "$1" -name '*.lock' -exec touch -d '2020-01-01 00:00:00' {} + 2>/dev/null || true; }

eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$3] got=[$(head -c 400 <<<"$2")]"; fi
}
like() {
  # shellcheck disable=SC2053
  if [[ "$2" == $3 ]]; then pass "$1"; else fail "$1" "want~[$3] got=[$(head -c 400 <<<"$2")]"; fi
}

. "$(dirname "$0")/feat-2511-session-relocation/move-cases.sh"
. "$(dirname "$0")/feat-2511-session-relocation/fault-cases.sh"
. "$(dirname "$0")/feat-2511-session-relocation/close-cases.sh"

case_begin "m1-pinned-skips" "bin/state-dir-relocation"
c_m1_pinned
case_end

case_begin "m2-move-legacy-session" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m2_move
case_end

case_begin "m3-rewrite-embedded-paths" "hooks/lib/temporary-migrations/state-dir-relocation/rewrite-root.js"
c_m3_rewrite
case_end

case_begin "m4-second-run-and-no-entries" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m4_idempotent
case_end

case_begin "m15-dash-sibling-untouched" "hooks/lib/temporary-migrations/state-dir-relocation/legacy.js"
c_m15_dash_sibling
case_end

case_begin "m15b-dot-sibling-untouched" "hooks/lib/temporary-migrations/state-dir-relocation/legacy.js"
c_m15b_dot_sibling
case_end

case_begin "m15c-entry-shaped-sid-refused" "hooks/lib/temporary-migrations/state-dir-relocation/legacy.js"
c_m15c_entry_shaped_sid
case_end

case_begin "m-invalid-sid-refused" "bin/state-dir-relocation"
c_m_invalid_sid
case_end

case_begin "m5-pre-commit-faults-keep-legacy" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m5_pre_commit_faults
case_end

case_begin "m6-old-delete-leftovers" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m6_old_delete
case_end

case_begin "m7-control-rename-crash-recovers" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m7_control_crash
case_end

case_begin "m7b-rollback-crash-recovers" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m7b_rollback_crash
case_end

case_begin "m7c-stale-off-clearance" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m7c_stale_clearance
case_end

case_begin "m8-stale-workdir-swept" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m8_stale_workdir
case_end

case_begin "m13-supervisor-lock-held" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m13_lock
case_end

case_begin "m13b-workflow-state-lock-held" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m13_state_lock
case_end

case_begin "m9-remaining" "hooks/lib/temporary-migrations/state-dir-relocation/remaining.js"
c_m9_remaining
case_end

case_begin "m10-failure-reported-once" "skills/session-close/scripts/relocate-session-state.sh"
c_m10_report_once
case_end

case_begin "m10b-success-not-reported" "skills/session-close/scripts/relocate-session-state.sh"
c_m10b_success_quiet
case_end

case_begin "m11-sc9-after-sc8" "skills/session-close/SKILL.md"
c_m11_skill
case_end

case_begin "m12-migration-blocks" "bin/check-migration-blocks.sh"
c_m12_blocks
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
