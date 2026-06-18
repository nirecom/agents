# ---------------------------------------------------------------------------
# === workflow-mark: New hook ===
# ---------------------------------------------------------------------------
# TDD: workflow-mark.js does NOT exist yet. These tests are expected to FAIL
# with a "Cannot find module" / MODULE_NOT_FOUND style error until the hook is
# implemented. Each test asserts state changes (or lack thereof) via the state
# file rather than hook stdout so the failure mode is always a node error from
# the missing hook, surfaced as state==MISSING on our side.

echo ""
echo "=== workflow-mark: New hook — Normal cases ==="

# Test N1: echo "<<WORKFLOW_MARK_STEP:research:complete>>" (double-quoted)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N1_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$N1_JSON" >/dev/null
expect_state_step "N1. echo \"<<...>>\" (double-quoted) → research=complete" "test-session" "research" "complete"

# Test N2: echo '<<WORKFLOW_MARK_STEP_research_complete>>' (single-quoted)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N2_JSON=$(build_mark_json "echo '<<WORKFLOW_MARK_STEP_research_complete>>'")
run_mark_hook "$REPO" "$N2_JSON" >/dev/null
expect_state_step "N2. echo '<<...>>' (single-quoted) → research=complete" "test-session" "research" "complete"

# Test N3: status skipped on research → recorded
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N3_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_skipped>>"')
run_mark_hook "$REPO" "$N3_JSON" >/dev/null
expect_state_step "N3. status=skipped on research → recorded" "test-session" "research" "skipped"

# Test N4: MARK_STEP for write_tests is rejected (evidence-based step, stays pending)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N4_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_write_tests_in_progress>>"')
run_mark_hook "$REPO" "$N4_JSON" >/dev/null
expect_state_step "N4. MARK_STEP for write_tests → rejected (stays pending)" "test-session" "write_tests" "pending"

echo ""
echo "=== workflow-mark: New hook — Must-NOT-mark cases ==="

# Test F1: cat SKILL.md (marker in file contents, not a literal echo command)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F1_JSON=$(build_mark_json 'cat SKILL.md')
run_mark_hook "$REPO" "$F1_JSON" >/dev/null
expect_no_state_change "F1. cat SKILL.md with marker in stdout → unchanged" "test-session" "research" "pending"

# Test F2: git diff showing marker
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F2_JSON=$(build_mark_json 'git diff')
run_mark_hook "$REPO" "$F2_JSON" >/dev/null
expect_no_state_change "F2. git diff showing marker → unchanged" "test-session" "research" "pending"

# Test F3: grep WORKFLOW_MARK_STEP file.sh
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F3_JSON=$(build_mark_json 'grep WORKFLOW_MARK_STEP file.sh')
run_mark_hook "$REPO" "$F3_JSON" >/dev/null
expect_no_state_change "F3. grep WORKFLOW_MARK_STEP → unchanged" "test-session" "research" "pending"

# Test F4: echo piped to tee
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F4_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>" | tee /tmp/log')
run_mark_hook "$REPO" "$F4_JSON" >/dev/null
expect_no_state_change "F4. echo \"<<...>>\" | tee /tmp/log → unchanged" "test-session" "research" "pending"

# Test F5: cd /tmp && echo "<<...>>" (prefix chaining)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F5_JSON=$(build_mark_json 'cd /tmp && echo "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$F5_JSON" >/dev/null
expect_no_state_change "F5. cd /tmp && echo \"<<...>>\" (prefix chain) → unchanged" "test-session" "research" "pending"

# Test F6: echo "<<...>>" ; rm foo (trailing chain)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F6_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>" ; rm foo')
run_mark_hook "$REPO" "$F6_JSON" >/dev/null
expect_no_state_change "F6. echo \"<<...>>\" ; rm foo (trailing chain) → unchanged" "test-session" "research" "pending"

# Test F7: echo " <<...>> " (inner spaces around marker inside quotes)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F7_JSON=$(build_mark_json 'echo " <<WORKFLOW_MARK_STEP_research_complete>> "')
run_mark_hook "$REPO" "$F7_JSON" >/dev/null
expect_no_state_change "F7. echo \" <<...>> \" (inner spaces) → unchanged" "test-session" "research" "pending"

# Test F8: 10KB padded command containing 'echo' as a substring but not as the command
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F8_PAD=$(printf 'x%.0s' {1..10000})
F8_JSON=$(build_mark_json "node run.js --msg echoes-${F8_PAD}-end")
run_mark_hook "$REPO" "$F8_JSON" >/dev/null
expect_no_state_change "F8. 10KB padded command with 'echo' as substring → unchanged" "test-session" "research" "pending"

# Test F9: printf instead of echo
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F9_JSON=$(build_mark_json 'printf "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$F9_JSON" >/dev/null
expect_no_state_change "F9. printf \"<<...>>\" (not echo) → unchanged" "test-session" "research" "pending"

echo ""
echo "=== workflow-mark: New hook — Error / edge cases ==="

# Test E1: unknown step "foo" → state unchanged, hook exit 0
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E1_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_foo_complete>>"')
run_mark_hook "$REPO" "$E1_JSON" >/dev/null
expect_no_state_change "E1. unknown step 'foo' → research unchanged" "test-session" "research" "pending"

# Test E2: unknown status "done" → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E2_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_done>>"')
run_mark_hook "$REPO" "$E2_JSON" >/dev/null
expect_no_state_change "E2. unknown status 'done' → research unchanged" "test-session" "research" "pending"

# Test E3: user_verification_complete via marker → REJECTED
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E3_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_user_verification_complete>>"')
run_mark_hook "$REPO" "$E3_JSON" >/dev/null
expect_no_state_change "E3. user_verification_complete via marker → REJECTED" "test-session" "user_verification" "pending"

# Test E4: user_verification_skipped via marker → REJECTED
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E4_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_user_verification_skipped>>"')
run_mark_hook "$REPO" "$E4_JSON" >/dev/null
expect_no_state_change "E4. user_verification_skipped via marker → REJECTED" "test-session" "user_verification" "pending"

# Test E5: session_id not in stdin AND CLAUDE_ENV_FILE unset →
#   state unchanged, hook stdout JSON contains "systemMessage", exit 0
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E5_CMD='echo "<<WORKFLOW_MARK_STEP_research_complete>>"'
E5_ESC=${E5_CMD//\"/\\\"}
E5_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""}}' "$E5_ESC" "$E5_ESC")
E5_OUT=$(echo "$E5_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null || true)
E5_EXIT=$?
expect_no_state_change "E5a. no session_id → research unchanged" "test-session" "research" "pending"
if echo "$E5_OUT" | grep -q "additionalContext"; then
    pass "E5b. no session_id → stdout JSON contains additionalContext"
else
    fail "E5b. no session_id → expected additionalContext in stdout, got: $E5_OUT"
fi
if [ "$E5_EXIT" = "0" ]; then
    pass "E5c. no session_id → hook exit 0"
else
    fail "E5c. no session_id → expected exit 0, got: $E5_EXIT"
fi

# Test E6: private repo test deferred — hard to fake without network.
# TODO: Add test once we can stub is-private-repo.js or use a fixture repo
# with a known-private remote URL. For now, skip.

# Test E7: tool_response.exit_code=1 → state unchanged (echo supposedly failed)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E7_CMD='echo "<<WORKFLOW_MARK_STEP_research_complete>>"'
E7_ESC=${E7_CMD//\"/\\\"}
E7_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":1,"stdout":"","stderr":"oops"},"session_id":"test-session"}' "$E7_ESC")
run_mark_hook "$REPO" "$E7_JSON" >/dev/null
expect_no_state_change "E7. tool_response.exit_code=1 → unchanged" "test-session" "research" "pending"

# Test E8: tool_name != Bash (e.g. Write) → ignored, state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E8_JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/foo","content":"<<WORKFLOW_MARK_STEP_research_complete>>"},"tool_response":{"success":true},"session_id":"test-session"}'
run_mark_hook "$REPO" "$E8_JSON" >/dev/null
expect_no_state_change "E8. tool_name=Write → unchanged" "test-session" "research" "pending"

echo ""
echo "=== workflow-mark: New hook — Idempotency ==="

# Test I1: same marker applied twice → state valid, status=complete
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
I1_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$I1_JSON" >/dev/null
run_mark_hook "$REPO" "$I1_JSON" >/dev/null
expect_state_step "I1. same marker applied twice → research=complete (idempotent)" "test-session" "research" "complete"

# Test I2: concurrent write race — deferred. Platform-dependent and requires
# deterministic interleaving; skip until we have a fixture for file-lock testing.

# ---------------------------------------------------------------------------
# === workflow-mark: RESET_FROM marker ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-mark: RESET_FROM marker — Normal cases ==="

# Test R1: RESET_FROM_write_tests on ALL_COMPLETE → research=complete, plan=complete,
#          write_tests=pending, review_security=pending, run_tests=pending, docs=pending,
#          user_verification=pending
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
R1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$R1_JSON" >/dev/null
expect_state_step "R1a. RESET_FROM:write_tests → research=complete"        "test-session" "research"        "complete"
expect_state_step "R1b. RESET_FROM:write_tests → outline=complete"         "test-session" "outline"         "complete"
expect_state_step "R1b2. RESET_FROM:write_tests → detail=complete"         "test-session" "detail"          "complete"
expect_state_step "R1c. RESET_FROM:write_tests → write_tests=pending"      "test-session" "write_tests"     "pending"
expect_state_step "R1d. RESET_FROM:write_tests → review_security=pending"  "test-session" "review_security" "pending"
expect_state_step "R1e. RESET_FROM:write_tests → run_tests=pending"        "test-session" "run_tests"       "pending"
expect_state_step "R1f. RESET_FROM:write_tests → docs=pending"             "test-session" "docs"            "pending"
expect_state_step "R1g. RESET_FROM:write_tests → user_verification=pending" "test-session" "user_verification" "pending"

# Test R2: RESET_FROM_research → all steps pending (nothing before research)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
R2_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_research>>"')
run_mark_hook "$REPO" "$R2_JSON" >/dev/null
expect_state_step "R2a. RESET_FROM:research → research=pending"             "test-session" "research"          "pending"
expect_state_step "R2b. RESET_FROM:research → outline=pending"              "test-session" "outline"           "pending"
expect_state_step "R2b2. RESET_FROM:research → detail=pending"              "test-session" "detail"            "pending"
expect_state_step "R2c. RESET_FROM:research → write_tests=pending"          "test-session" "write_tests"       "pending"
expect_state_step "R2d. RESET_FROM:research → review_security=pending"      "test-session" "review_security"   "pending"
expect_state_step "R2e. RESET_FROM:research → run_tests=pending"            "test-session" "run_tests"         "pending"
expect_state_step "R2f. RESET_FROM:research → docs=pending"                 "test-session" "docs"              "pending"
expect_state_step "R2g. RESET_FROM:research → user_verification=pending"    "test-session" "user_verification" "pending"

# Test R3: RESET_FROM_user_verification → all steps before it complete, user_verification=pending
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
R3_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_user_verification>>"')
run_mark_hook "$REPO" "$R3_JSON" >/dev/null
expect_state_step "R3a. RESET_FROM:user_verification → research=complete"        "test-session" "research"          "complete"
expect_state_step "R3b. RESET_FROM:user_verification → outline=complete"         "test-session" "outline"           "complete"
expect_state_step "R3b2. RESET_FROM:user_verification → detail=complete"         "test-session" "detail"            "complete"
expect_state_step "R3c. RESET_FROM:user_verification → write_tests=complete"     "test-session" "write_tests"       "complete"
expect_state_step "R3d. RESET_FROM:user_verification → review_security=complete" "test-session" "review_security"   "complete"
expect_state_step "R3e. RESET_FROM:user_verification → run_tests=complete"       "test-session" "run_tests"         "complete"
expect_state_step "R3f. RESET_FROM:user_verification → docs=complete"            "test-session" "docs"              "complete"
expect_state_step "R3g. RESET_FROM:user_verification → user_verification=pending" "test-session" "user_verification" "pending"

# Test R4: single-quote variant → NOT processed (SQ RESET_FROM removed from source)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
R4_JSON=$(build_reset_json "echo '<<WORKFLOW_RESET_FROM_write_tests>>'")
run_mark_hook "$REPO" "$R4_JSON" >/dev/null
expect_no_state_change "R4a. single-quote RESET_FROM → research unchanged (complete)"    "test-session" "research"    "complete"
expect_no_state_change "R4b. single-quote RESET_FROM → outline unchanged (complete)"     "test-session" "outline"     "complete"
expect_no_state_change "R4b2. single-quote RESET_FROM → detail unchanged (complete)"     "test-session" "detail"      "complete"
expect_no_state_change "R4c. single-quote RESET_FROM → write_tests unchanged (complete)" "test-session" "write_tests" "complete"
expect_no_state_change "R4d. single-quote RESET_FROM → run_tests unchanged (complete)"   "test-session" "run_tests"   "complete"

echo ""
echo "=== workflow-mark: RESET_FROM marker — Must-NOT-match cases ==="

# Test RF1: echo "<<WORKFLOW_RESET_FROM_write_tests>>" | tee /tmp/log → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RF1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>" | tee /tmp/log')
run_mark_hook "$REPO" "$RF1_JSON" >/dev/null
expect_no_state_change "RF1. echo \"<<...>>\" | tee /tmp/log → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

# Test RF2: cd /tmp && echo "<<WORKFLOW_RESET_FROM_write_tests>>" → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RF2_JSON=$(build_reset_json 'cd /tmp && echo "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$RF2_JSON" >/dev/null
expect_no_state_change "RF2. cd && echo \"<<...>>\" (prefix chain) → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

# Test RF3: printf "<<WORKFLOW_RESET_FROM_write_tests>>" → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RF3_JSON=$(build_reset_json 'printf "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$RF3_JSON" >/dev/null
expect_no_state_change "RF3. printf \"<<...>>\" (not echo) → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

echo ""
echo "=== workflow-mark: RESET_FROM marker — Error / edge cases ==="

# Test RE1: unknown step "foo" → state unchanged, hook exit 0
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RE1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_foo>>"')
run_mark_hook "$REPO" "$RE1_JSON" >/dev/null
expect_no_state_change "RE1. unknown step 'foo' → research unchanged (complete)" "test-session" "research" "complete"

# Test RE2: missing session_id → state unchanged, hook exit 0, stdout has additionalContext
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RE2_CMD='echo "<<WORKFLOW_RESET_FROM_write_tests>>"'
RE2_ESC=${RE2_CMD//\"/\\\"}
RE2_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""}}' "$RE2_ESC" "$RE2_ESC")
RE2_OUT=$(echo "$RE2_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null || true)
RE2_EXIT=$?
expect_no_state_change "RE2a. no session_id → write_tests unchanged (complete)" "test-session" "write_tests" "complete"
if echo "$RE2_OUT" | grep -q "additionalContext"; then
    pass "RE2b. no session_id → stdout JSON contains additionalContext"
else
    fail "RE2b. no session_id → expected additionalContext in stdout, got: $RE2_OUT"
fi
if [ "$RE2_EXIT" = "0" ]; then
    pass "RE2c. no session_id → hook exit 0"
else
    fail "RE2c. no session_id → expected exit 0, got: $RE2_EXIT"
fi

# Test RE3: exit_code=1 → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RE3_CMD='echo "<<WORKFLOW_RESET_FROM_write_tests>>"'
RE3_ESC=${RE3_CMD//\"/\\\"}
RE3_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":1,"stdout":"","stderr":"oops"},"session_id":"test-session"}' "$RE3_ESC")
run_mark_hook "$REPO" "$RE3_JSON" >/dev/null
expect_no_state_change "RE3. exit_code=1 → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

echo ""
echo "=== workflow-mark: RESET_FROM marker — Idempotency ==="

# Test RI1: apply R1 twice → same final state (no crash, write_tests still pending)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RI1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$RI1_JSON" >/dev/null
run_mark_hook "$REPO" "$RI1_JSON" >/dev/null
expect_state_step "RI1a. RESET_FROM applied twice → research=complete (idempotent)"    "test-session" "research"    "complete"
expect_state_step "RI1b. RESET_FROM applied twice → write_tests=pending (idempotent)"  "test-session" "write_tests"  "pending"
expect_state_step "RI1c. RESET_FROM applied twice → run_tests=pending (idempotent)"    "test-session" "run_tests"    "pending"
