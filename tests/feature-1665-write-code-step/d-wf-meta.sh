# shellcheck shell=bash
# Tests: hooks/workflow-state/effective-state.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/list.js
# Tags: TL2, workflow, write-code, wf-meta, next-step, scope:issue-specific, pwsh-not-required
#
# Case group D (TL2): the wf-meta / wf-code split. A planning-only session has no
# implementation to write, so write_code must join its WF_META_AUTO_SKIP siblings
# (write_tests, review_tests, run_tests, ...) and never become the current step —
# otherwise every meta session stalls forever on a step it can never satisfy.
# D4/D5 are the CPR-ORTH counterpart: the same position in a wf-code session must
# route TO write-code, so a blanket skip cannot pass this group either.

run_wf_meta_tests() {
  local out list_out row ACTION NEXT_SKILL NEXT_HINT REASON

  # wf-meta at the end of planning: every non-applicable step still pending.
  build_state d-meta pending \
    "workflow_init=complete;clarify_intent=complete;research=complete;outline=complete;detail=complete" \
    '"workflow_type":"wf-meta",'

  list_out="$(run_next_step --list --session d-meta 2>/dev/null || true)"
  row="$(printf '%s\n' "$list_out" | grep -E 'write_code' | head -n1 || true)"
  check_contains "D1: wf-meta renders write_code as skipped [-]" "[-]" "$row"

  ACTION=""; NEXT_SKILL="SENTINEL"; NEXT_HINT=""; REASON=""
  out="$(run_next_step --session d-meta 2>/dev/null || true)"
  eval "$out" 2>/dev/null || true

  check "D2: wf-meta session keeps advancing (ACTION=invoke)" "invoke" "${ACTION:-}"
  check_not_contains "D3: wf-meta never advises the write-code skill" \
    "write-code" "${NEXT_SKILL:-}"

  # wf-code control at the equivalent position: tests are settled, implementation
  # is not. This is the step's primary path.
  build_state d-code pending \
    "workflow_init=complete;clarify_intent=complete;research=complete;outline=complete;detail=complete;branching_complete=complete;write_tests=complete;review_tests=complete"

  ACTION=""; NEXT_SKILL=""; NEXT_HINT=""; REASON=""
  out="$(run_next_step --session d-code 2>/dev/null || true)"
  eval "$out" 2>/dev/null || true

  check "D4: wf-code session advances to write_code (ACTION=invoke)" "invoke" "${ACTION:-}"
  check "D5: wf-code session advises the write-code skill" "write-code" "${NEXT_SKILL:-}"
}
