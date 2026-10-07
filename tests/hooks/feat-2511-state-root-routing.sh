#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io/state-root.js, bin/workflow-state-dir, hooks/session-start.js, hooks/post-compact.js, hooks/lib/turn-marker.js, hooks/workflow-state/state-io/zombie-cleanup.js, hooks/lib/active-session-ids.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/block-clearance-token-write/placement-guard.js, hooks/lib/bash-write-targets/detection-expand.js, bin/lib/safe-state-path.sh, bin/sweep-supervisor-state.sh, bin/worker-dispatch/workers/commit-push/gate.js, bin/github-issues/lib/resolve-project.sh, hooks/workflow-state/state-io/state-lock.js, hooks/lib/supervisor-state-writer/lock.js
# Tags: workflow-state, state-root, routing, migration, lock, hooks, bin, scope:issue-specific, TL2
# Serial: the R22 lock races time a background waiter with fixed sleeps, so a loaded host breaks them
# #2511 stage 5: one default state root (~/.workflow-state) with M1 routing of
# legacy sessions to ~/.claude/projects/workflow, and lock re-acquire after a move.
# The file pins state and plans dirs first; default-path cases unset the pin per call
# and point HOME/USERPROFILE at a throwaway home.
# TL3 gap: the lock races use a foreign-host lock file as writer A; a real second
# hook process racing a real /session-close move is what only a live session shows.
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "$0")/../lib/harness.sh"
T="$(make_tmp)"
readonly T
harness_isolate "$T/iso"
export WORKFLOW_STATE_DIR="$T/iso/workflow-state"
trap 'rm -rf "$T"' EXIT

# The retired variable name, assembled so this file never carries the literal.
OLD_TOKEN="CLAUDE_""WORKFLOW_DIR"
# Every helper runs from a neutral cwd, so the repo path must be absolute.
AGENTS_DIR="$(cd "$AGENTS_DIR" && pwd)"
A="$(np "$AGENTS_DIR")"
PROBE="$(np "$AGENTS_DIR/tests/hooks/feat-2511-state-root-routing/probe.js")"
NOTX="$(np "$T/no-transcripts")"
mkdir -p "$T/cwd" "$T/no-transcripts" "$T/pins"
FIXTURE_REPO="$T/fixture-repo"
harness_git_init "$FIXTURE_REPO"

sid_of() { printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }

# new_home <name> — a throwaway default-path home; sets H, NEW, LEG (node form).
new_home() {
  mkdir -p "$T/homes/$1"
  H="$(np "$T/homes/$1")"
  NEW="$H/.workflow-state"
  LEG="$H/.claude/projects/workflow"
}

# dprobe <mode> <args...> — probe with the pin removed and HOME at $H.
dprobe() {
  (cd "$T/cwd" && run_with_timeout 30 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" USERPROFILE="$H" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$NOTX" node "$PROBE" "$A" "$@" 2>/dev/null) || true
}

# pprobe <pin> <mode> <args...> — probe pinned to <pin>, HOME still at $H.
pprobe() {
  local pin="$1"
  shift
  (cd "$T/cwd" && run_with_timeout 30 env -u "$OLD_TOKEN" WORKFLOW_STATE_DIR="$pin" HOME="$H" USERPROFILE="$H" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$NOTX" node "$PROBE" "$A" "$@" 2>/dev/null) || true
}

# probe_seed <root> <sid> [json] — the root dir is made here too, so a seed failure
# shows up as FAIL lines rather than aborting the file on a later redirect.
probe_seed() {
  mkdir -p "$1"
  dprobe seed "$@" >/dev/null
}

# dcli <node-cli> <args...> — a polyglot bin under the default env; keeps its exit code.
dcli() {
  (cd "$T/cwd" && run_with_timeout 30 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" USERPROFILE="$H" \
    node "$@" 2>/dev/null)
}

# dhook <hook.js> <stdin-json> — a hook under the default env, neutral cwd, fixture project.
dhook() {
  (cd "$T/cwd" && printf '%s' "$2" | run_with_timeout 60 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" \
    USERPROFILE="$H" CLAUDE_TRANSCRIPT_BASE_DIR="$NOTX" CLAUDE_PROJECT_DIR="$(np "$FIXTURE_REPO")" \
    node "$1" 2>/dev/null) || true
}

# dsh <lib.sh> <fn> <args...> — source a shell lib and call one function, default env.
dsh() {
  local lib="$1"
  shift
  (cd "$T/cwd" && run_with_timeout 30 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" USERPROFILE="$H" \
    bash -c '. "$1"; shift; "$@"' _ "$lib" "$@" 2>/dev/null) || true
}

# drun <script> <args...> — run a shell script under the default env.
drun() {
  (cd "$T/cwd" && run_with_timeout 60 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" USERPROFILE="$H" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$NOTX" bash "$@" 2>/dev/null) || true
}

roots_np() {
  local l out=""
  while IFS= read -r l; do
    [[ -n "$l" ]] && out="$out${out:+,}$(np "${l%$'\r'}")"
  done <<<"$1"
  printf '%s' "$out"
}

eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "want=[$3] got=[$(head -c 400 <<<"$2")]"
  fi
}

. "$(dirname "$0")/feat-2511-state-root-routing/resolver-cases.sh"
. "$(dirname "$0")/feat-2511-state-root-routing/callers-cases.sh"
. "$(dirname "$0")/feat-2511-state-root-routing/gate-cases.sh"
. "$(dirname "$0")/feat-2511-state-root-routing/lock-cases.sh"
. "$(dirname "$0")/feat-2511-state-root-routing/static-cases.sh"
. "$(dirname "$0")/feat-2511-state-root-routing/hardening-cases.sh"

case_begin "r1-pinned-never-routes" "hooks/workflow-state/state-io/state-root.js"
c_r1_pinned
case_end

case_begin "r2-r6-routing-table" "hooks/workflow-state/state-io/state-root.js"
c_r2_r6_routing
case_end

case_begin "r7-new-root-cached" "hooks/workflow-state/state-io/state-root.js"
c_r7_cache
case_end

case_begin "r8-r9-roots-and-root" "hooks/workflow-state/state-io/state-root.js"
c_r8_r9_roots
case_end

case_begin "r10-cli" "bin/workflow-state-dir"
c_r10_cli
case_end

case_begin "r11-session-start-fresh-sid" "hooks/session-start.js"
c_r11_session_start_fresh
case_end

case_begin "r12-legacy-session-hooks" "hooks/lib/turn-marker.js"
c_r12_legacy_session_hooks
case_end

case_begin "r13-zombies-both-roots" "hooks/workflow-state/state-io/zombie-cleanup.js"
c_r13_zombies_both_roots
case_end

case_begin "r14-active-ids-union" "hooks/lib/active-session-ids.js"
c_r14_active_union
case_end

case_begin "r15-marker-gate-both-roots" "hooks/enforce-worktree/bash-write-scope/marker-gate.js"
c_r15_marker_gate
case_end

case_begin "r16-placement-both-roots" "hooks/block-clearance-token-write/placement-guard.js"
c_r16_placement
case_end

case_begin "r17-detection-expand" "hooks/lib/bash-write-targets/detection-expand.js"
c_r17_expand
case_end

case_begin "r18-sp-control-dir" "bin/lib/safe-state-path.sh"
c_r18_sp_control_dir
case_end

case_begin "r19-sweep-both-roots" "bin/sweep-supervisor-state.sh"
c_r19_sweep_both_roots
case_end

case_begin "r20-gate-routes-session" "bin/worker-dispatch/workers/commit-push/gate.js"
c_r20_gate_routes_session
case_end

case_begin "r20b-gate-ignores-parent-env" "bin/worker-dispatch/workers/commit-push/gate.js"
c_r20b_gate_ignores_parent_env
case_end

case_begin "r20c-env-fallback-off" "hooks/workflow-state/state-io/state-root.js"
c_r20c_env_fallback_off
case_end

case_begin "r21-state-file-line" "hooks/post-compact.js"
c_r21_state_file_line
case_end

case_begin "r22-update-top-level-reacquire" "hooks/workflow-state/state-io/state-lock.js"
c_r22_update_top_level
case_end

case_begin "r22b-other-writers-reacquire" "hooks/workflow-state/state-io/state-lock.js"
c_r22b_other_writers
case_end

case_begin "r22c-supervisor-reacquire" "hooks/lib/supervisor-state-writer/lock.js"
c_r22c_supervisor_lock
case_end

case_begin "r22d-retry-limit" "hooks/workflow-state/state-io/state-lock.js"
c_r22d_retry_limit
case_end

case_begin "r23-project-cache-new-root" "bin/github-issues/lib/resolve-project.sh"
c_r23_project_cache
case_end

case_begin "r24-static-residue" "hooks/workflow-state/state-io/state-root.js"
c_r24_static
case_end

case_begin "r25-sid-contract" "hooks/workflow-state/state-io/state-root.js"
c_r25_sid_contract
case_end

case_begin "r26-relative-pin-refused" "hooks/workflow-state/state-io/state-root.js"
c_r26_relative_pin
case_end

case_begin "r26b-driveless-pin-on-windows" "hooks/workflow-state/state-io/state-root.js"
c_r26b_driveless_pin
case_end

case_begin "r26c-marker-gate-relative-pin" "hooks/enforce-worktree/bash-write-scope/marker-gate.js"
c_r26c_marker_gate_relative_pin
case_end

case_begin "r27-absent-legacy-root-listed" "hooks/lib/active-session-ids.js"
c_r27_absent_legacy_root
case_end

case_begin "r28-linked-placement" "hooks/block-clearance-token-write/placement-guard.js"
c_r28_linked_placement
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
