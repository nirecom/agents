# shellcheck shell=bash
# Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/workflow-state/record-step-verdict.js, bin/workflow/lib/next-step/repo-dir.js, bin/workflow/lib/next-step/advance-shared.js
# Tags: tl2, workflow, security, skip-authorization, forged-env, classifier, scope:issue-specific
# C7 group 2 — the trust boundary under adversarial input: forged inline env
# prefixes and a forged CLAUDE_PROJECT_DIR. Sourced by the dispatcher.

run_forged_cases() {
  echo ""
  echo "=== C7-4: SECURITY — a forged inline env prefix must not grant the bypass ==="
  # Pattern 2 attack scenario: the exact shape a model-issued Bash command would
  # take, `CONFIRM_TESTS=off node bin/workflow/next-step --advance ...`, against a
  # config file that says on. The CLI door reads the FILE only, so it must refuse.
  at_write_tests w4a
  STATE_BEFORE="$(state_bytes w4a)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  run_ns "$REPO_CODE" "$CFG_ON" "$REPO_CODE_N" CONFIRM_TESTS=off -- \
    --session w4a --advance --step write_tests --status skipped --skip-reason "$REASON"
  assert_refused "C7-4a forged CONFIRM_TESTS=off over a file that says on" w4a write_tests

  # Same forgery against a file that simply has no such key — the more common real
  # configuration, and the one where "the env var leaks in" would be easiest to miss.
  at_write_tests w4b
  STATE_BEFORE="$(state_bytes w4b)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  run_ns "$REPO_CODE" "$CFG_UNSET" "$REPO_CODE_N" CONFIRM_TESTS=off -- \
    --session w4b --advance --step write_tests --status skipped --skip-reason "$REASON"
  assert_refused "C7-4b forged CONFIRM_TESTS=off over a file with no key" w4b write_tests

  # The boundary is total, not one-directional: an inline `CONFIRM_TESTS=on` must
  # not be able to REVOKE a file-granted authorization either. Without this arm,
  # C7-4a would also pass on an implementation that merely preferred the file.
  at_write_tests w4c
  run_ns "$REPO_CODE" "$CFG_OFF" "$REPO_CODE_N" CONFIRM_TESTS=on -- \
    --session w4c --advance --step write_tests --status skipped --skip-reason "$REASON"
  check "C7-4c: an inline CONFIRM_TESTS=on cannot revoke the file's grant" 0 "$RC"
  check "C7-4c: write_tests is still skipped" '"skipped"' "$(step_status w4c write_tests)"

  echo ""
  echo "=== C7-5: AGENTS_CONFIG_DIR is a different question from the VALUE ==="
  # Pointing AGENTS_CONFIG_DIR at an attacker-written .env DOES open the gate: the
  # variable names WHICH config file is canonical, and the CLI has no second
  # source to cross-check it against. Recorded here so the boundary's actual shape
  # is unambiguous — the hardening is about the VALUE being forgeable inline, not
  # about the config location being authenticated. Every other case in this file
  # pins AGENTS_CONFIG_DIR itself, so this is the assumption they all rest on.
  at_write_tests w5
  run_ns "$REPO_CODE" "$CFG_OFF" "$REPO_CODE_N" -- \
    --session w5 --advance --step write_tests --status skipped --skip-reason "$REASON"
  check "C7-5: AGENTS_CONFIG_DIR selects the config file that decides" 0 "$RC"
  check "C7-5: write_tests is skipped from the pointed-at config" '"skipped"' "$(step_status w5 write_tests)"

  echo ""
  echo "=== C7-6: SECURITY — a forged CLAUDE_PROJECT_DIR cannot fake docs-only ==="
  # run_tests has no config key: its authorization is the docs-only staged-set
  # proof. record-step-verdict.js resolveTrustedRepoDirForRunTestsSkip resolves the
  # repo with `git rev-parse --show-toplevel` from the REAL process cwd and
  # deliberately ignores opts.repoDir, which flows from CLAUDE_PROJECT_DIR.
  #
  # The attack: run from inside the protected code repo, but point
  # CLAUDE_PROJECT_DIR at the attacker's docs-only repo so the proof is taken
  # there. Must be refused, and the protected repo must be untouched.
  at_run_tests r6a
  STATE_BEFORE="$(state_bytes r6a)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  local docs_before; docs_before="$(repo_fingerprint "$REPO_DOCS")"
  run_ns "$REPO_CODE" "$CFG_OFF" "$REPO_DOCS_N" -- \
    --session r6a --advance --step run_tests --status skipped --skip-reason "$REASON"
  assert_refused "C7-6a forged CLAUDE_PROJECT_DIR -> docs-only repo" r6a run_tests
  check_contains "C7-6a: the diagnostic names the docs-only requirement" \
    "the staged set is not human-facing docs only" "$ERR"
  # The attacker-controlled repo is untouched too — the refusal must not have
  # written anything anywhere.
  check "C7-6a: the attacker repo is untouched as well" "$docs_before" "$(repo_fingerprint "$REPO_DOCS")"
  # CONFIRM_TESTS=off was in force for this call and did NOT help: run_tests is not
  # in STAGE_FOR_STEP, so no CONFIRM_* key can ever authorize it.
  check "C7-6a: CONFIRM_TESTS=off does not reach the run_tests door" '"pending"' "$(step_status r6a run_tests)"

  # The mirrored forgery: run from the attacker's docs-only repo while
  # CLAUDE_PROJECT_DIR points at the protected one. The trusted resolution is the
  # cwd, so this one is ALLOWED — which is exactly why cwd, not the env var, has
  # to be the thing the model cannot choose freely.
  at_run_tests r6b
  run_ns "$REPO_DOCS" "$CFG_OFF" "$REPO_CODE_N" -- \
    --session r6b --advance --step run_tests --status skipped --skip-reason "$REASON"
  check "C7-6b: the trusted axis is the real cwd, not CLAUDE_PROJECT_DIR" 0 "$RC"
  check "C7-6b: run_tests is skipped from the genuinely docs-only cwd" '"skipped"' "$(step_status r6b run_tests)"
  check "C7-6b: the protected code repo is still untouched" "$REPO_BEFORE" "$(repo_fingerprint "$REPO_CODE")"

  echo ""
  echo "=== C7-7: steps with no CLI-side approval route refuse regardless of config ==="
  # Pattern 4 control: C7-1 would also pass on an implementation that granted every
  # skip once CONFIRM_TESTS=off. clarify_intent has no CLI approval route at all,
  # so the most permissive config in this file must still refuse it.
  at_write_tests w7
  STATE_BEFORE="$(state_bytes w7)"; REPO_BEFORE="$(repo_fingerprint "$REPO_CODE")"
  run_ns "$REPO_CODE" "$CFG_OFF" "$REPO_CODE_N" -- \
    --session w7 --advance --step clarify_intent --status skipped --skip-reason "$REASON"
  check "C7-7: clarify_intent skip is refused with exit 3" 3 "$RC"
  check "C7-7: the state file is byte-for-byte unchanged" "$STATE_BEFORE" "$(state_bytes w7)"
  check "C7-7: the protected repo is untouched" "$REPO_BEFORE" "$(repo_fingerprint "$REPO_CODE")"
  check_contains "C7-7: the diagnostic names the sentinel the user must approve" \
    "WORKFLOW_CLARIFY_INTENT_NOT_NEEDED" "$ERR"
}
