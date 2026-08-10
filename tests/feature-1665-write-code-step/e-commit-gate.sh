# shellcheck shell=bash
# Tests: hooks/workflow-gate.js
# Tags: TL2, workflow, write-code, workflow-gate, commit-gate, classifier, scope:issue-specific, pwsh-not-required
#
# Case group E (TL2): the commit gate walks VALID_STEPS and blocks on anything
# not settled, so write_code must NOT join NON_GATE_STEPS — an unwritten (or
# still in-flight) implementation must not reach a commit. E3 is the symmetric
# verdict required by CPR-ORTH: with write_code complete the gate must approve,
# otherwise the step ships as permanent over-blocking.
#
# The gate runs as the real hook against a real fixture repo with a staged
# non-docs file, so the docs-only short-circuit and the staged-tests token path
# are both out of the way and write_code is the only variable.

# gate_verdict <sid> <write_code-status> — gate stdout for a git commit attempt.
gate_verdict() {
  local sid="$1" wc_status="$2" s spec=""
  for s in $STEPS_16; do
    [ "$s" = "write_code" ] && continue
    spec="$spec;$s=complete"
  done
  spec="${spec#;};write_code=$wc_status"
  build_state "$sid" complete "$spec"
  # The entry is stamped so the status is RECORDED rather than merely defaulted:
  # every other step here is complete, so an unstamped `pending` write_code would
  # be dropped by the v1->v2 migration and then backfilled complete by v2->v3
  # (#1665), and the gate would be judging a legacy-gap fixture instead of the
  # status this case names. See stamp_step_at in common.sh.
  stamp_step_at "$sid" write_code >/dev/null
  run_gate_commit "$sid" "$GATE_REPO_N"
}

run_commit_gate_tests() {
  local out

  out="$(gate_verdict e-pending pending)"
  check_contains "E1: pending write_code blocks the commit" "write_code" "$out"

  out="$(gate_verdict e-inprogress in_progress)"
  check_contains "E2: in_progress write_code blocks the commit" "write_code" "$out"

  out="$(gate_verdict e-complete complete)"
  check_not_contains "E3: complete write_code does not block the commit" "write_code" "$out"
  check_contains "E3b: complete write_code yields an approve decision" "approve" "$out"
}
