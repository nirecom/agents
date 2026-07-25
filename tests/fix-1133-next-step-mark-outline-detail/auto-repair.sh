# ===========================================================================
# === A1-A9: outline/detail evidence-based auto-repair + mid-review guard ===
# ===========================================================================

# outline=pending with no later step complete (clean walk → currentStep=outline).
# Used by A3-A5 so the verdict is the plain `invoke make-outline-plan` path
# rather than the inconsistency abort that OUTLINE_PENDING_DETAIL_COMPLETE hits.
OUTLINE_PENDING_CLEAN() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1133],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "pending",  "updated_at": null},
    "detail":            {"status": "pending",  "updated_at": null},
    "branching_complete":{"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

# detail=pending with no later step complete (clean walk → currentStep=detail).
DETAIL_PENDING_CLEAN() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1133],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-06-20T10:03:00.000Z"},
    "detail":            {"status": "pending",  "updated_at": null},
    "branching_complete":{"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

echo ""
echo "=== A1: outline=pending + detail=complete + outline.md exists → auto-repair → branching_complete ==="

SID="a1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# Create the outline.md artifact in PLANS_DIR to trigger evidence-based auto-repair.
touch "$PLANS_DIR/${SID}-outline.md"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After auto-repair: outline=complete, detail=complete → next step is branching_complete.
check "A1. outline.md exists + detail=complete → ACTION=invoke (branching_complete)" \
  "invoke" "${ACTION:-}"
check "A1b. outline.md auto-repair → NEXT_SKILL='' (branching_complete has no skill)" \
  "" "${NEXT_SKILL:-}"
# The state should have been repaired: outline must now be complete.
check "A1c. outline.md auto-repair → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

rm -f "$PLANS_DIR/${SID}-outline.md"

echo ""
echo "=== A2: detail=pending + detail.md exists → auto-repair → branching_complete ==="

SID="a2-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
# Create the detail.md artifact in PLANS_DIR to trigger evidence-based auto-repair.
touch "$PLANS_DIR/${SID}-detail.md"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After auto-repair: detail=complete, branching_complete=complete → next step is write_tests.
check "A2. detail.md exists + branching_complete=complete → ACTION=invoke" \
  "invoke" "${ACTION:-}"
check "A2b. detail.md auto-repair → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"

rm -f "$PLANS_DIR/${SID}-detail.md"

# ---------------------------------------------------------------------------
# A3-A5 / A7-A8 (BLOCK): an in-flight codex review cycle marker for the SAME
# stage must suppress evidence-based auto-complete — the draft .md is
# overwritten every revision round, so its existence is not proof of approval.
# A6 / A9 (ALLOW, CPR-5 symmetry): a marker belonging to the OTHER stage must
# not block, since the marker prefix is stage-scoped (outline-plan-/detail-plan-).
# ---------------------------------------------------------------------------

echo ""
echo "=== A3: outline=pending + outline.md + outline-plan-round-number.txt → auto-complete blocked ==="

SID="a3-$$"
write_state "$SID" "$(OUTLINE_PENDING_CLEAN $SID)"
touch "$PLANS_DIR/${SID}-outline.md"
touch "$PLANS_DIR/${SID}-outline-plan-round-number.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A3. round-number marker present → outline stays pending" \
  "pending" "$(read_state_status "$SID" "outline")"
check "A3b. round-number marker present → NEXT_SKILL=make-outline-plan" \
  "make-outline-plan" "${NEXT_SKILL:-}"

# Idempotency: a second consultation while the marker is still on disk must not
# drift the state to complete (the guard is not a one-shot).
OUT=$(run_next_step --session "$SID")
NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true
check "A3c. re-run with marker still present → outline still pending" \
  "pending" "$(read_state_status "$SID" "outline")"
check "A3d. re-run with marker still present → NEXT_SKILL still make-outline-plan" \
  "make-outline-plan" "${NEXT_SKILL:-}"

rm -f "$PLANS_DIR/${SID}-outline.md" "$PLANS_DIR/${SID}-outline-plan-round-number.txt"

echo ""
echo "=== A4: outline=pending + outline.md + outline-plan-concern-ledger.txt → auto-complete blocked ==="

SID="a4-$$"
write_state "$SID" "$(OUTLINE_PENDING_CLEAN $SID)"
touch "$PLANS_DIR/${SID}-outline.md"
touch "$PLANS_DIR/${SID}-outline-plan-concern-ledger.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A4. concern-ledger marker present → outline stays pending" \
  "pending" "$(read_state_status "$SID" "outline")"
check "A4b. concern-ledger marker present → NEXT_SKILL=make-outline-plan" \
  "make-outline-plan" "${NEXT_SKILL:-}"

rm -f "$PLANS_DIR/${SID}-outline.md" "$PLANS_DIR/${SID}-outline-plan-concern-ledger.txt"

echo ""
echo "=== A5: outline=pending + outline.md + BOTH outline-plan markers → auto-complete blocked ==="

SID="a5-$$"
write_state "$SID" "$(OUTLINE_PENDING_CLEAN $SID)"
touch "$PLANS_DIR/${SID}-outline.md"
touch "$PLANS_DIR/${SID}-outline-plan-round-number.txt"
touch "$PLANS_DIR/${SID}-outline-plan-concern-ledger.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A5. both markers present → outline stays pending" \
  "pending" "$(read_state_status "$SID" "outline")"
check "A5b. both markers present → NEXT_SKILL=make-outline-plan" \
  "make-outline-plan" "${NEXT_SKILL:-}"

rm -f "$PLANS_DIR/${SID}-outline.md" \
      "$PLANS_DIR/${SID}-outline-plan-round-number.txt" \
      "$PLANS_DIR/${SID}-outline-plan-concern-ledger.txt"

echo ""
echo "=== A6: outline=pending + outline.md + UNRELATED detail-plan marker → auto-complete still fires ==="

SID="a6-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-outline.md"
# Marker belongs to the detail stage — must not gate the outline predicate.
touch "$PLANS_DIR/${SID}-detail-plan-round-number.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""
eval "$OUT" 2>/dev/null || true

check "A6. unrelated-stage marker → outline auto-completes" \
  "complete" "$(read_state_status "$SID" "outline")"
check "A6b. unrelated-stage marker → ACTION=invoke" \
  "invoke" "${ACTION:-}"

rm -f "$PLANS_DIR/${SID}-outline.md" "$PLANS_DIR/${SID}-detail-plan-round-number.txt"

echo ""
echo "=== A7: detail=pending + detail.md + detail-plan-round-number.txt → auto-complete blocked ==="

SID="a7-$$"
write_state "$SID" "$(DETAIL_PENDING_CLEAN $SID)"
touch "$PLANS_DIR/${SID}-detail.md"
touch "$PLANS_DIR/${SID}-detail-plan-round-number.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A7. round-number marker present → detail stays pending" \
  "pending" "$(read_state_status "$SID" "detail")"
check "A7b. round-number marker present → NEXT_SKILL=make-detail-plan" \
  "make-detail-plan" "${NEXT_SKILL:-}"

rm -f "$PLANS_DIR/${SID}-detail.md" "$PLANS_DIR/${SID}-detail-plan-round-number.txt"

echo ""
echo "=== A8: detail=pending + detail.md + detail-plan-concern-ledger.txt → auto-complete blocked ==="

SID="a8-$$"
write_state "$SID" "$(DETAIL_PENDING_CLEAN $SID)"
touch "$PLANS_DIR/${SID}-detail.md"
touch "$PLANS_DIR/${SID}-detail-plan-concern-ledger.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A8. concern-ledger marker present → detail stays pending" \
  "pending" "$(read_state_status "$SID" "detail")"
check "A8b. concern-ledger marker present → NEXT_SKILL=make-detail-plan" \
  "make-detail-plan" "${NEXT_SKILL:-}"

rm -f "$PLANS_DIR/${SID}-detail.md" "$PLANS_DIR/${SID}-detail-plan-concern-ledger.txt"

echo ""
echo "=== A9: detail=pending + detail.md + UNRELATED outline-plan marker → auto-complete still fires ==="

SID="a9-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-detail.md"
# Marker belongs to the outline stage — must not gate the detail predicate.
touch "$PLANS_DIR/${SID}-outline-plan-round-number.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""
eval "$OUT" 2>/dev/null || true

check "A9. unrelated-stage marker → detail auto-completes" \
  "complete" "$(read_state_status "$SID" "detail")"
check "A9b. unrelated-stage marker → ACTION=invoke" \
  "invoke" "${ACTION:-}"

rm -f "$PLANS_DIR/${SID}-detail.md" "$PLANS_DIR/${SID}-outline-plan-round-number.txt"
