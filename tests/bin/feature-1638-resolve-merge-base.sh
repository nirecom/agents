#!/usr/bin/env bash
# tests/bin/feature-1638-resolve-merge-base.sh
# Tests: bin/resolve-merge-base.sh, hooks/workflow-state/merge-base-baseline.js, bin/workflow/read-merge-base-baseline, bin/workflow/record-merge-base-baseline
# Tags: merge-base, ssot, baseline, anomaly-detection, scope:issue-specific, pwsh-not-required, TL2
#
# Issue #1638 — merge-base resolution picked a pre-history-rewrite commit and every consumer
# inherited a 280k-line diff with nothing on stdout saying the range was wrong. R1-R27 pin, in
# order: the recorded baseline and the checks that demote it; layer-2 RESOLVED/FALLBACK/
# UNRESOLVED; the anomaly detector (never run on layer 1); the two parsed output contracts; the
# write-once writer and its user-approved override; the degradation contract; #1779's base ==
# HEAD case. ISOLATION: local remote-free fixtures, --no-fetch, workflow + plans dirs on temp.

set -uo pipefail

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$SCRIPT_CHECKOUT_ROOT/bin/resolve-merge-base.sh"
RECORD_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/record-merge-base-baseline"
READ_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/read-merge-base-baseline"

# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

skip_case() { skip "$1"; }
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
# Dual-pin (#1799): without WORKFLOW_PLANS_DIR the supervisor emitter still
# resolves the developer's real ~/.workflow-plans/ and appends there.
PLANSDIR="$TMPROOT/plans"
mkdir -p "$PLANSDIR"

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

# #1779. main has real commits and the work branch was cut from it and has committed NOTHING.
# `git merge-base main HEAD` therefore answers with HEAD itself, and every consumer that diffs
# `<base>...HEAD` gets a structurally empty range while the branch is full of staged/unstaged/
# untracked work. The base is not wrong — it is correct AND useless — so the resolver has to
# say so in a field rather than by inventing a new state.
repo_zero_commit() { # prints the repo path
  local r
  r="$(new_repo main)"
  commit_file "$r" seed.txt 1 seed
  commit_file "$r" second.txt 1 second
  git -C "$r" switch -q -c work >/dev/null 2>&1
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
  ws = require(path.join(process.env.SCRIPT_CHECKOUT_ROOT_NODE, "hooks", "workflow-state"));
} catch (e) {
  process.stdout.write("ERR:require:" + e.message + "\n");
  process.exit(1);
}
const cmd = process.argv[2];
const sid = process.argv[3];
function statePath() {
  return path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json");
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
  } else if (cmd === "approvedetail") {
    // BRANCHING_COMPLETE now needs the detail gate approved; the off-waiver record is the fixture's.
    require(path.join(process.env.SCRIPT_CHECKOUT_ROOT_NODE, "hooks", "workflow-state", "completion-approval"))
      .recordPlanApproval(sid, "detail", { source: "confirm-flag-off", reason: "fixture" });
    process.stdout.write("OK\n");
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
  env "SCRIPT_CHECKOUT_ROOT_NODE=$SCRIPT_CHECKOUT_ROOT" "WORKFLOW_STATE_DIR=$WFDIR" "WORKFLOW_PLANS_DIR=$PLANSDIR" \
    node "$STATE_JS" "$@" 2>/dev/null || NODE_RC=$?
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
  # env(1) is last-wins: the isolation pins follow HELPER_ENV so a caller-supplied
  # row can never unpin the fixture workflow/plans dirs.
  env ${HELPER_ENV[@]+"${HELPER_ENV[@]}"} \
    "WORKFLOW_STATE_DIR=$WFDIR" "WORKFLOW_PLANS_DIR=$PLANSDIR" \
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
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/recorded-baseline.sh"
# shellcheck source=./feature-1638-resolve-merge-base/resolution-and-anomaly.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/resolution-and-anomaly.sh"
# shellcheck source=./feature-1638-resolve-merge-base/writer-and-degradation.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/writer-and-degradation.sh"
# shellcheck source=./feature-1638-resolve-merge-base/branching-integration.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/branching-integration.sh"
# shellcheck source=./feature-1638-resolve-merge-base/thresholds-and-edges.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/thresholds-and-edges.sh"
# shellcheck source=./feature-1638-resolve-merge-base/baseline-errors.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/baseline-errors.sh"
# shellcheck source=./feature-1638-resolve-merge-base/approval-cli.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/approval-cli.sh"
# shellcheck source=./feature-1638-resolve-merge-base/merge-in-progress.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1638-resolve-merge-base/merge-in-progress.sh"

# ---- run --------------------------------------------------------------------

if [ ! -f "$HELPER" ]; then
  echo "NOTE: $HELPER does not exist yet — the rows below fail RED by design (fail-before-fix)."
fi

HAVE_NODE=0
command -v node >/dev/null 2>&1 && HAVE_NODE=1
# Rows that need node are skipped one by one without it; rows that also need the approval CLI
# fail with <missing> when it is absent (no <missing>: skipped, as m11 always was).
node_row() { # <row-fn>
  if [ "$HAVE_NODE" = 1 ]; then "$1"; else skip_case "$1 (node is not available on this host)"; fi
}
cli_row() { # <row-fn> [<missing>]
  if [ "$HAVE_NODE" != 1 ]; then skip_case "$1 (node is not available on this host)"
  elif [ -f "$RECORD_CLI" ]; then "$1"
  elif [ -n "${2:-}" ]; then fail "$2"
  else skip_case "$1 (bin/workflow/record-merge-base-baseline does not exist)"
  fi
}
A_MISSING="A0-P4: bin/workflow/record-merge-base-baseline does not exist (the approval path cannot be exercised)"
a0_with_fixture() { setup_approval_fixture; a0_success_is_the_control; }

case_begin "recorded-baseline-is-adopted" "bin/resolve-merge-base.sh"
r1_recorded_is_adopted
case_end
case_begin "branch-mismatch-demotes" "bin/resolve-merge-base.sh"
r2_branch_mismatch_demotes
case_end
case_begin "stale-branch-head-demotes" "bin/resolve-merge-base.sh"
r3_stale_branch_head_demotes
case_end
case_begin "non-ancestor-base-demotes" "bin/resolve-merge-base.sh"
r4_non_ancestor_base_demotes
case_end
case_begin "resolved-against-main" "bin/resolve-merge-base.sh"
r5_resolved_against_main
case_end
case_begin "fallback-to-head-parent" "bin/resolve-merge-base.sh"
r6_fallback_to_head_parent
case_end
case_begin "unresolved-on-root-commit" "bin/resolve-merge-base.sh"
r7_unresolved_on_root_commit
case_end
case_begin "suspect-on-line-threshold" "bin/resolve-merge-base.sh"
r8_suspect_on_line_threshold
case_end
case_begin "suspect-on-file-threshold" "bin/resolve-merge-base.sh"
r9_suspect_on_file_threshold
case_end
case_begin "recorded-is-exempt-from-thresholds" "bin/resolve-merge-base.sh"
r10_recorded_is_exempt_from_thresholds
case_end
case_begin "post-session-head-is-a-note" "bin/resolve-merge-base.sh"
r11_post_session_head_is_a_note
case_end
case_begin "format-base" "bin/resolve-merge-base.sh"
r12_format_base
case_end
case_begin "all-kv-keys-present" "bin/resolve-merge-base.sh"
r13_all_kv_keys_present
case_end

# R20-R27 (#1779) — the zero-commit branch: base == HEAD, plus the working-tree census the
# consumers need in order to fall back to something non-empty.
case_begin "base-is-head-false-when-ahead" "bin/resolve-merge-base.sh"
r20_base_is_head_false_when_ahead
case_end
case_begin "base-is-head-true-on-zero-commit" "bin/resolve-merge-base.sh"
r21_base_is_head_true_on_zero_commit
case_end
case_begin "uncommitted-counts-match-git" "bin/resolve-merge-base.sh"
r22_uncommitted_counts_match_git
case_end
case_begin "untracked-is-counted-separately" "bin/resolve-merge-base.sh"
r23_untracked_is_counted_separately
case_end
case_begin "clean-tree-counts-are-zero" "bin/resolve-merge-base.sh"
r24_clean_tree_counts_are_zero
case_end
case_begin "staged-only-change-is-counted" "bin/resolve-merge-base.sh"
r25_staged_only_change_is_counted
case_end
case_begin "untracked-count-is-exact" "bin/resolve-merge-base.sh"
r26_untracked_count_is_exact
case_end
case_begin "gitignored-file-is-not-untracked" "bin/resolve-merge-base.sh"
r27_gitignored_file_is_not_untracked
case_end

# T — where the thresholds come from, and N/N+1 on both axes.
case_begin "threshold-builtin-defaults" "bin/resolve-merge-base.sh"
t1_builtin_defaults
case_end
case_begin "threshold-config-file-is-read" "bin/resolve-merge-base.sh"
t2_config_file_is_read
case_end
case_begin "threshold-env-beats-config" "bin/resolve-merge-base.sh"
t3_env_beats_config
case_end
case_begin "threshold-partial-override-keeps-other-axis" "bin/resolve-merge-base.sh"
t4_partial_override_keeps_the_other_axis
case_end
case_begin "threshold-counts-match-git" "bin/resolve-merge-base.sh"
t5_counts_match_git
case_end
case_begin "threshold-line-axis-boundary" "bin/resolve-merge-base.sh"
t6_line_axis_boundary
case_end
case_begin "threshold-file-axis-boundary" "bin/resolve-merge-base.sh"
t7_file_axis_boundary
case_end
case_begin "binary-counts-as-a-file-not-lines" "bin/resolve-merge-base.sh"
t8_binary_counts_as_a_file_not_lines
case_end

case_begin "record-is-write-once" "hooks/workflow-state/merge-base-baseline.js"
node_row r14_record_is_write_once
case_end
case_begin "base-is-branching-head" "hooks/workflow-state/merge-base-baseline.js"
node_row r15_base_is_branching_head
case_end
case_begin "approve-overrides-write-once" "hooks/workflow-state/merge-base-baseline.js"
node_row r16_approve_overrides_write_once
case_end
case_begin "approve-rejects-bad-base" "bin/workflow/record-merge-base-baseline"
cli_row r17_approve_rejects_bad_base "R17: bin/workflow/record-merge-base-baseline does not exist"
case_end

# B — the writer's only automatic caller, through a real sentinel dispatch.
case_begin "records-for-the-resolved-worktree" "hooks/workflow-state/merge-base-baseline.js"
node_row b1_records_for_the_resolved_worktree
case_end
case_begin "second-dispatch-does-not-overwrite" "hooks/workflow-state/merge-base-baseline.js"
node_row b2_second_dispatch_does_not_overwrite
case_end
case_begin "recording-failure-is-not-fatal" "hooks/workflow-state/merge-base-baseline.js"
node_row b3_recording_failure_is_not_fatal
case_end
case_begin "main-worktree-session-still-records" "hooks/workflow-state/merge-base-baseline.js"
node_row b4_main_worktree_session_still_records
case_end

# E — the recorded baseline when the evidence is bad.
case_begin "absent-state-file" "bin/resolve-merge-base.sh"
node_row e1_absent_state_file
case_end
case_begin "corrupt-state-file" "bin/resolve-merge-base.sh"
node_row e2_corrupt_state_file
case_end
case_begin "missing-required-fields" "bin/resolve-merge-base.sh"
node_row e3_missing_required_fields
case_end
case_begin "git-failure-during-verification" "bin/resolve-merge-base.sh"
node_row e4_git_failure_during_verification
case_end
case_begin "null-alt-base-is-the-absent-marker" "bin/resolve-merge-base.sh"
node_row e5_null_alt_base_is_the_absent_marker
case_end
case_begin "post-session-head-boundary" "hooks/workflow-state/merge-base-baseline.js"
node_row e6_post_session_head_boundary
case_end
case_begin "write-failure-leaves-state-intact" "hooks/workflow-state/merge-base-baseline.js"
node_row e7_write_failure_leaves_state_intact
case_end

# M — #2631: layer 1 while an uncommitted merge is in progress.
case_begin "merge-head-base-is-adopted-during-merge" "bin/resolve-merge-base.sh"
node_row m1_merge_head_base_is_adopted_during_merge
case_end
case_begin "merge-head-base-survives-the-merge-commit" "bin/resolve-merge-base.sh"
node_row m2_merge_head_base_survives_the_merge_commit
case_end
case_begin "unrelated-base-is-demoted-during-merge" "bin/resolve-merge-base.sh"
node_row m3_unrelated_base_is_demoted_during_merge
case_end
case_begin "branch-head-stays-head-only-during-merge" "bin/resolve-merge-base.sh"
node_row m4_branch_head_stays_head_only_during_merge
case_end
case_begin "merge-head-extended-rows" "bin/resolve-merge-base.sh"
node_row m5_to_m7_merge_head_extended_rows
case_end
case_begin "head-side-base-is-adopted-during-conflicted-merge" "bin/resolve-merge-base.sh"
node_row m8_head_side_base_is_adopted_during_conflicted_merge
case_end
case_begin "merge-head-line-format-table" "bin/resolve-merge-base.sh"
node_row m9_merge_head_line_format_table
case_end
case_begin "sha256-merge-head-side-base-is-adopted" "bin/resolve-merge-base.sh"
node_row m10_sha256_merge_head_side_base_is_adopted
case_end
case_begin "sha256-cli-approval-is-adopted-by-resolver" "bin/workflow/record-merge-base-baseline"
cli_row m11_sha256_cli_approval_is_adopted_by_resolver
case_end

# A — the approval CLI's arguments; P — the recovery it exists for.
case_begin "approval-success-is-the-control" "bin/workflow/record-merge-base-baseline"
cli_row a0_with_fixture "$A_MISSING"
case_end
case_begin "approval-reason-is-mandatory" "bin/workflow/record-merge-base-baseline"
cli_row a1_reason_is_mandatory
case_end
case_begin "approval-required-and-unknown-flags" "bin/workflow/record-merge-base-baseline"
cli_row a4_required_flags_and_unknown_flags
case_end
case_begin "approval-malicious-session-id" "bin/workflow/record-merge-base-baseline"
cli_row a8_malicious_session_id
case_end
case_begin "approval-malicious-reason" "bin/workflow/record-merge-base-baseline"
cli_row a10_malicious_reason
case_end
case_begin "approval-repository-argument" "bin/workflow/record-merge-base-baseline"
cli_row a11_repository_argument
case_end
case_begin "approval-recovery-end-to-end" "bin/workflow/record-merge-base-baseline"
cli_row p_recovery_end_to_end
case_end

case_begin "explain-goes-to-stderr" "bin/resolve-merge-base.sh"
r18_explain_goes_to_stderr
case_end
case_begin "standalone-copy-still-works" "bin/resolve-merge-base.sh"
r19_standalone_copy_still_works
case_end

# READ_CLI is referenced by the helper's layer 1; its absence is a distinct fact from the
# helper's absence, so it gets its own line rather than being folded into a row above.
case_begin "read-cli-is-present" "bin/workflow/read-merge-base-baseline"
if [ ! -f "$READ_CLI" ]; then
  fail "R0: bin/workflow/read-merge-base-baseline does not exist (layer 1 cannot be reached)"
else
  pass "R0: bin/workflow/read-merge-base-baseline is present"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
