# shellcheck shell=bash
# Tests: bin/workflow/lib/next-step/steps.js
# Tags: TL1, workflow, next-step, release-phase, scope:issue-specific, issue-2527, pwsh-not-required
#
# Case group G (TL1, #2527): every release-phase step routes to a skill, so
# the only skill-less step left is branching_complete (final_report is the
# terminal step and carries no skill either). push_branch / merge_to_main carry a
# STEP_DESC entry, and require(steps.js) still passes assertInvariants.

run_release_skill_tests() {
  local dump rc
  dump="$(run_with_timeout node -e '
const S = require(process.env.STEPS_MODULE);
const T = S.STEP_TO_SKILL || {};
const own = (t, k) => Object.prototype.hasOwnProperty.call(t || {}, k);
const val = (k) => (own(T, k) ? String(T[k]) : "<absent>");
const empty = Object.keys(T).filter((k) => T[k] === "" && k !== "final_report").sort().join(",");
const rel = ["push_branch", "merge_to_main"];
const quoted = rel.some((k) => !own(S.STEP_DESC, k)) ? ["<missing entry>"]
  : rel.filter((k) => String(S.STEP_DESC[k]).indexOf("\x27") !== -1);
process.stdout.write([
  "push_branch=" + val("push_branch"),
  "user_verification=" + val("user_verification"),
  "merge_to_main=" + val("merge_to_main"),
  "cleanup=" + val("cleanup"),
  "pre_final_report_gate=" + val("pre_final_report_gate"),
  "empty=" + empty,
  "desc_push_branch=" + (own(S.STEP_DESC, "push_branch") ? "present" : "<absent>"),
  "desc_merge_to_main=" + (own(S.STEP_DESC, "merge_to_main") ? "present" : "<absent>"),
  "desc_quoted=" + (quoted.join(",") || "<none>"),
].join("\n") + "\n");
' 2>&1 || true)"

  check "G1: push_branch routes to /commit-push" "commit-push" "$(dump_field "$dump" push_branch)"
  check "G2: user_verification routes to /get-release-approval" "get-release-approval" "$(dump_field "$dump" user_verification)"
  check "G3: merge_to_main routes to /merge-to-main" "merge-to-main" "$(dump_field "$dump" merge_to_main)"
  check "G4: cleanup routes to /worktree-end" "worktree-end" "$(dump_field "$dump" cleanup)"
  check "G5: pre_final_report_gate routes to /session-close" "session-close" "$(dump_field "$dump" pre_final_report_gate)"
  check "G6: branching_complete is the only skill-less non-terminal step" "branching_complete" "$(dump_field "$dump" empty)"
  check "G7: STEP_DESC carries push_branch" "present" "$(dump_field "$dump" desc_push_branch)"
  check "G8: STEP_DESC carries merge_to_main" "present" "$(dump_field "$dump" desc_merge_to_main)"
  check "G9: push_branch / merge_to_main STEP_DESC carry no single quote" "<none>" "$(dump_field "$dump" desc_quoted)"

  rc=0
  run_with_timeout node -e 'require(process.env.STEPS_MODULE);' >/dev/null 2>&1 || rc=$?
  check "G10: require(steps.js) survives assertInvariants with the new steps (exit 0)" "0" "$rc"
}
