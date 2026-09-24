# shellcheck shell=bash
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/effective-state.js, bin/workflow/lib/next-step/steps.js
# Tags: TL1, workflow, write-code, vocabulary, scope:issue-specific, pwsh-not-required
#
# Case group A (TL1): the step vocabulary itself. write_code must be a real
# VALID_STEPS member at index 8 (between review_tests and run_tests), must NOT be
# skippable (the implementation body cannot be opted out of), must be auto-skipped
# in wf-meta sessions, and must carry an entry in every next-step lookup table —
# STEP_TO_SKILL / STEP_DESC are enforced by steps.js assertInvariants(), which
# process.exit(1)s at require() time when either is missing.

# dump_field <dump> <key> — value of "<key>=..." in a key=value dump.
dump_field() {
  printf '%s\n' "$1" | grep -E "^$2=" | head -n1 | cut -d= -f2- || true
}

run_vocabulary_tests() {
  local core_dump steps_dump rc

  core_dump="$(run_with_timeout node -e '
const wf = require(process.env.WFSTATE_MODULE);
const V = Array.isArray(wf.VALID_STEPS) ? wf.VALID_STEPS : [];
const SK = Array.isArray(wf.SKIPPABLE_STEPS) ? wf.SKIPPABLE_STEPS : [];
const meta = wf.WF_META_AUTO_SKIP;
const has = (m, k) => !!(m && (typeof m.has === "function" ? m.has(k) : m.indexOf && m.indexOf(k) !== -1));
process.stdout.write([
  "len=" + V.length,
  "idx=" + V.indexOf("write_code"),
  "at7=" + (V[7] === undefined ? "<none>" : V[7]),
  "at9=" + (V[9] === undefined ? "<none>" : V[9]),
  "skippable=" + (SK.indexOf("write_code") !== -1),
  "wfmeta=" + has(meta, "write_code"),
].join("\n") + "\n");
' 2>&1 || true)"

  check "A1: VALID_STEPS has 16 members" "16" "$(dump_field "$core_dump" len)"
  check "A2: write_code sits at VALID_STEPS index 8" "8" "$(dump_field "$core_dump" idx)"
  check "A3: index 7 is review_tests (write_code's predecessor)" "review_tests" "$(dump_field "$core_dump" at7)"
  check "A4: index 9 is run_tests (write_code's successor)" "run_tests" "$(dump_field "$core_dump" at9)"
  check "A5: write_code is NOT in SKIPPABLE_STEPS" "false" "$(dump_field "$core_dump" skippable)"
  check "A6: write_code IS in WF_META_AUTO_SKIP" "true" "$(dump_field "$core_dump" wfmeta)"

  steps_dump="$(run_with_timeout node -e '
const S = require(process.env.STEPS_MODULE);
const val = (t, k) => (Object.prototype.hasOwnProperty.call(t || {}, k) ? String(t[k]) : "<absent>");
process.stdout.write([
  "skill=" + val(S.STEP_TO_SKILL, "write_code"),
  "desc=" + (Object.prototype.hasOwnProperty.call(S.STEP_DESC || {}, "write_code") ? "present" : "<absent>"),
  "hint=" + (Object.prototype.hasOwnProperty.call(S.STEP_HINT || {}, "write_code") ? "present" : "<absent>"),
].join("\n") + "\n");
' 2>&1 || true)"

  check "A7: STEP_TO_SKILL routes write_code to the write-code skill" \
    "write-code" "$(dump_field "$steps_dump" skill)"
  check "A8: STEP_DESC carries a write_code entry" "present" "$(dump_field "$steps_dump" desc)"
  # A9 pins the complement invariant (CPR-ORTH/CPR-NRS): STEP_HINT holds exactly
  # the steps STEP_TO_SKILL leaves skill-less. verdict.js reads
  #   hint = skill ? "Run /<skill> ..." : (STEP_HINT[step] || step)
  # so any STEP_HINT entry for a skill-backed step is unreachable dead text.
  # write_code IS skill-backed (A7), therefore it must be ABSENT from STEP_HINT.
  check "A9: STEP_HINT has NO write_code entry (skill-backed steps are hint-less)" \
    "<absent>" "$(dump_field "$steps_dump" hint)"

  # A10 is the guard behind A7/A8: assertInvariants() runs at require() time and
  # kills the process when a VALID_STEPS member is missing from either table, so
  # a half-landed change breaks every next-step subcommand, not just this step.
  rc=0
  run_with_timeout node -e 'require(process.env.STEPS_MODULE);' >/dev/null 2>&1 || rc=$?
  check "A10: require(steps.js) survives assertInvariants (exit 0)" "0" "$rc"
}
