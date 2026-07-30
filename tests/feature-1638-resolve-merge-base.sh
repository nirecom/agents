#!/usr/bin/env bash
# tests/feature-1638-resolve-merge-base.sh
# Tests: bin/resolve-merge-base.sh, hooks/workflow-state/merge-base-baseline.js, bin/workflow/read-merge-base-baseline, bin/workflow/record-merge-base-baseline
# Tags: merge-base, ssot, baseline, anomaly-detection, scope:issue-specific, pwsh-not-required, TL2
#
# Issue #1638 — merge-base resolution picked a pre-history-rewrite commit and every consumer
# (select-tests.sh, run-quality-gates.sh, review-code-codex) inherited a 280k-line diff without
# anything on stdout saying the range was wrong. The fix is a single shared resolver that
# reports a STATE alongside the base, plus a recorded baseline written at branching time so the
# common case stops guessing at all.
#
# WHAT IS PINNED HERE, and why each half matters:
#   R1-R4   the recorded baseline (layer 1) and the three identity checks that must demote it.
#           A baseline adopted from another branch or another session is worse than no baseline.
#   R5-R7   layer 2: RESOLVED / FALLBACK / UNRESOLVED. UNRESOLVED is separated from FALLBACK
#           precisely because a root-commit repo has no HEAD~1 and handing one to the gates is
#           the regression #1638 caused in the first place.
#   R8-R10  the anomaly detector, both axes, and the asymmetry: it never runs on layer 1.
#   R11     post_session_head is a NOTE, not a demotion — the base is still a fact.
#   R12-R13 the two output contracts consumers parse.
#   R14-R17 the writer: write-once for the automatic path, and one deliberate override for the
#           user-approved path, with validation that keeps a bad sha out of the state file.
#   R18     --explain is diagnostics; it must not contaminate the machine-readable stdout.
#   R19     the degradation contract — the helper is a self-contained CLI, so a fixture that
#           copies the single file (tests/fix-quality-gates-not-found/) still exercises it.
#
# ISOLATION. Every fixture repository is local with NO remote, and every invocation passes
# --no-fetch, so no row can reach the network. CLAUDE_WORKFLOW_DIR is redirected to a temp
# directory so the developer's real session state is never read or written.
#
# TL3 gap (what this test does NOT catch):
# - a real `git fetch origin main` against a real remote whose default branch has moved:
#   every fixture here is fetch-free by construction.
# - the branching-handler actually calling recordMergeBaseBaseline inside a live Claude Code
#   session (hook registration is not exercised; only the module contract is).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$AGENTS_DIR/bin/resolve-merge-base.sh"
RECORD_CLI="$AGENTS_DIR/bin/workflow/record-merge-base-baseline"
READ_CLI="$AGENTS_DIR/bin/workflow/read-merge-base-baseline"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip_case() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}
check_match() { # <desc> <ere> <got>
  if printf '%s' "$3" | grep -qE "$2"; then pass "$1"; else fail "$1 -- [$3] does not match /$2/"; fi
}

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT
WFDIR="$TMPROOT/workflow"
mkdir -p "$WFDIR"

# ---- fixtures ---------------------------------------------------------------

# core.hooksPath is set GLOBALLY on a developer machine that uses this repo's own hooks, and a
# global setting reaches a throwaway repo under /tmp too — the agents pre-commit hook then
# refuses the fixture's commits and every row silently tests an empty repository. The
# repo-local override is what makes the fixture independent of who runs the suite.
new_repo() { # <branch> ; prints the repo path
  local r
  r="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  git -C "$r" init -q -b "$1" >/dev/null 2>&1
  git -C "$r" config core.hooksPath "$r/.git/no-such-hooks" >/dev/null 2>&1
  git -C "$r" config user.email test@example.com >/dev/null 2>&1
  git -C "$r" config user.name test >/dev/null 2>&1
  git -C "$r" config commit.gpgsign false >/dev/null 2>&1
  printf '%s' "$r"
}

commit_file() { # <repo> <path> <line-count> <message>
  local r="$1" p="$2" n="$3" m="$4" i
  mkdir -p "$r/$(dirname "$p")"
  : > "$r/$p"
  for ((i = 0; i < n; i++)); do printf 'line %s of %s\n' "$i" "$m" >> "$r/$p"; done
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q -m "$m" >/dev/null 2>&1
}

# main exists and is BEHIND the work branch, so `git merge-base main HEAD` answers with a real
# commit and the diff it implies is non-empty — the input both the RESOLVED and the SUSPECT rows
# need (they differ only in the threshold injected).
repo_with_main() { # prints the repo path
  local r
  r="$(new_repo main)"
  commit_file "$r" seed.txt 1 seed
  commit_file "$r" second.txt 1 second
  git -C "$r" switch -q -c work >/dev/null 2>&1
  commit_file "$r" third.txt 5 third
  printf '%s' "$r"
}

# No branch named main and no remote: both layer-2 attempts miss and HEAD~1 is the only answer
# left. TWO commits, so HEAD~1 actually resolves — a fixture whose fallback base does not exist
# would test the fallback against nothing.
repo_no_main() { # prints the repo path
  local r
  r="$(new_repo work)"
  commit_file "$r" seed.txt 1 seed
  commit_file "$r" second.txt 1 second
  printf '%s' "$r"
}

# One commit and no main: HEAD~1 does not resolve either, which is the ONLY input that may
# produce UNRESOLVED.
repo_root_only() { # prints the repo path
  local r
  r="$(new_repo work)"
  commit_file "$r" seed.txt 1 seed
  printf '%s' "$r"
}

# A commit that is NOT in HEAD's ancestry, for the two demotion rows that need one.
side_commit() { # <repo> ; prints the sha
  local r="$1" cur sha
  cur="$(git -C "$r" rev-parse --abbrev-ref HEAD)"
  git -C "$r" switch -q -c sidetrack >/dev/null 2>&1
  commit_file "$r" side.txt 1 side
  sha="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q "$cur" >/dev/null 2>&1
  printf '%s' "$sha"
}

# ---- state-file access via the module under test ----------------------------

STATE_JS="$TMPROOT/state-helper.js"
cat > "$STATE_JS" <<'NODEEOF'
"use strict";
// Test-side driver for the workflow-state barrel. Every subcommand prints one line so the
// shell can assert on it, and every failure prints ERR:<message> and exits 1 rather than
// throwing a stack trace the shell would mistake for output.
const path = require("path");
const fs = require("fs");
let ws;
try {
  ws = require(path.join(process.env.AGENTS_DIR, "hooks", "workflow-state"));
} catch (e) {
  process.stdout.write("ERR:require:" + e.message + "\n");
  process.exit(1);
}
const cmd = process.argv[2];
const sid = process.argv[3];
function statePath() {
  return path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json");
}
try {
  if (cmd === "init") {
    const st = ws.createInitialState(sid, { cwd: process.argv[4], git_branch: process.argv[5] || null });
    if (process.argv[6]) st.created_at = process.argv[6];
    ws.writeState(sid, st);
    process.stdout.write("OK\n");
  } else if (cmd === "setbaseline") {
    const st = JSON.parse(fs.readFileSync(statePath(), "utf8"));
    st.merge_base_baseline = JSON.parse(process.argv[4]);
    fs.writeFileSync(statePath(), JSON.stringify(st, null, 2), "utf8");
    process.stdout.write("OK\n");
  } else if (cmd === "field") {
    const st = JSON.parse(fs.readFileSync(statePath(), "utf8"));
    const b = st.merge_base_baseline;
    process.stdout.write(String(b ? b[process.argv[4]] : "NONE") + "\n");
  } else if (cmd === "record") {
    const r = ws.recordMergeBaseBaseline(sid, process.argv[4]);
    process.stdout.write(JSON.stringify(r) + "\n");
  } else if (cmd === "approve") {
    const r = ws.approveMergeBaseBaseline(sid, process.argv[4], process.argv[5], process.argv[6]);
    process.stdout.write(JSON.stringify(r) + "\n");
  } else if (cmd === "read") {
    const r = ws.readMergeBaseBaseline(sid);
    process.stdout.write(JSON.stringify(r) + "\n");
  } else {
    process.stdout.write("ERR:unknown-cmd:" + cmd + "\n");
    process.exit(1);
  }
} catch (e) {
  process.stdout.write("ERR:" + e.message + "\n");
  process.exit(1);
}
NODEEOF

NODE_RC=0
node_state() { # <subcommand> <sid> [args...] ; prints stdout, sets NODE_RC
  NODE_RC=0
  env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" "$@" 2>/dev/null || NODE_RC=$?
}

# Writes a baseline record straight into the state file, so the layer-1 rows control every
# field of the record without depending on the writer they are not testing.
put_baseline() { # <sid> <repo> <json>
  node_state init "$1" "$2" work >/dev/null
  node_state setbaseline "$1" "$3" >/dev/null
}

# ---- helper invocation ------------------------------------------------------

HELPER_ENV=()
HB_OUT=""
HB_ERR=""
HB_RC=0

run_helper() { # <repo> <sid|-> [extra helper args...]
  local repo="$1" sid="$2"
  shift 2
  local o e
  o="$(mktemp "$TMPROOT/out.XXXXXX")"
  e="$(mktemp "$TMPROOT/err.XXXXXX")"
  local -a args=(-C "$repo" --no-fetch)
  [ "$sid" = "-" ] || args+=(--session "$sid")
  args+=("$@")
  HB_RC=0
  env "CLAUDE_WORKFLOW_DIR=$WFDIR" ${HELPER_ENV[@]+"${HELPER_ENV[@]}"} \
    bash "$HELPER" "${args[@]}" >"$o" 2>"$e" || HB_RC=$?
  HB_OUT="$(cat "$o")"
  HB_ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

kv() { printf '%s\n' "$HB_OUT" | sed -n "s/^$1=//p" | head -1; }

# ---- parts ------------------------------------------------------------------
#
# The rows are split by SUBJECT, not by size: which layer answered (recorded-baseline),
# what layer 2 produced and whether it is plausible (resolution-and-anomaly), and who is
# allowed to write the record (writer-and-degradation). Each part is sourced, not run —
# the fixtures, the state driver and the invocation helper above are shared by all three.

# shellcheck source=./feature-1638-resolve-merge-base/recorded-baseline.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/recorded-baseline.sh"
# shellcheck source=./feature-1638-resolve-merge-base/resolution-and-anomaly.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/resolution-and-anomaly.sh"
# shellcheck source=./feature-1638-resolve-merge-base/writer-and-degradation.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/writer-and-degradation.sh"
# shellcheck source=./feature-1638-resolve-merge-base/branching-integration.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/branching-integration.sh"
# shellcheck source=./feature-1638-resolve-merge-base/thresholds-and-edges.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/thresholds-and-edges.sh"
# shellcheck source=./feature-1638-resolve-merge-base/baseline-errors.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/baseline-errors.sh"
# shellcheck source=./feature-1638-resolve-merge-base/approval-cli.sh
. "$AGENTS_DIR/tests/feature-1638-resolve-merge-base/approval-cli.sh"

# ---- run --------------------------------------------------------------------

if [ ! -f "$HELPER" ]; then
  echo "NOTE: $HELPER does not exist yet — the rows below fail RED by design (fail-before-fix)."
fi

r1_recorded_is_adopted
r2_branch_mismatch_demotes
r3_stale_branch_head_demotes
r4_non_ancestor_base_demotes
r5_resolved_against_main
r6_fallback_to_head_parent
r7_unresolved_on_root_commit
r8_suspect_on_line_threshold
r9_suspect_on_file_threshold
r10_recorded_is_exempt_from_thresholds
r11_post_session_head_is_a_note
r12_format_base
r13_all_kv_keys_present

# T — where the thresholds come from, and N/N+1 on both axes.
t1_builtin_defaults
t2_config_file_is_read
t3_env_beats_config
t4_partial_override_keeps_the_other_axis
t5_counts_match_git
t6_line_axis_boundary
t7_file_axis_boundary
t8_binary_counts_as_a_file_not_lines

if command -v node >/dev/null 2>&1; then
  r14_record_is_write_once
  r15_base_is_branching_head
  r16_approve_overrides_write_once
  if [ -f "$RECORD_CLI" ]; then
    r17_approve_rejects_bad_base
  else
    fail "R17: bin/workflow/record-merge-base-baseline does not exist"
  fi

  # B — the writer's only automatic caller, through a real sentinel dispatch.
  b1_records_for_the_resolved_worktree
  b2_second_dispatch_does_not_overwrite
  b3_recording_failure_is_not_fatal
  b4_main_worktree_session_still_records

  # E — the recorded baseline when the evidence is bad.
  e1_absent_state_file
  e2_corrupt_state_file
  e3_missing_required_fields
  e4_git_failure_during_verification
  e5_null_alt_base_is_the_absent_marker
  e6_post_session_head_boundary
  e7_write_failure_leaves_state_intact

  # A — the approval CLI's arguments; P — the recovery it exists for.
  if [ -f "$RECORD_CLI" ]; then
    setup_approval_fixture
    a0_success_is_the_control
    a1_reason_is_mandatory
    a4_required_flags_and_unknown_flags
    a8_malicious_session_id
    a10_malicious_reason
    a11_repository_argument
    p_recovery_end_to_end
  else
    fail "A0-P4: bin/workflow/record-merge-base-baseline does not exist (the approval path cannot be exercised)"
  fi
else
  skip_case "R14-R17, B1-B4, E1-E7, A0-P4 (node is not available on this host)"
fi

r18_explain_goes_to_stderr
r19_standalone_copy_still_works

# READ_CLI is referenced by the helper's layer 1; its absence is a distinct fact from the
# helper's absence, so it gets its own line rather than being folded into a row above.
if [ ! -f "$READ_CLI" ]; then
  fail "R0: bin/workflow/read-merge-base-baseline does not exist (layer 1 cannot be reached)"
else
  pass "R0: bin/workflow/read-merge-base-baseline is present"
fi

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
