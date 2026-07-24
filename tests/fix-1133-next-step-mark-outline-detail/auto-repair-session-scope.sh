# ===========================================================================
# === A10-A11: review-cycle marker is SESSION-scoped as well as stage-scoped ===
# ===========================================================================
#
# The review-cycle guard keys its marker filenames on the session id
# (<sid>-outline-plan-round-number.txt). A marker belonging to a DIFFERENT
# session must not block this session's auto-complete — otherwise a concurrent
# session's in-flight review would freeze an unrelated session.
# Session-scope counterpart of the stage-scope symmetry covered by A6/A9.
#
# Non-vacuity: the foreign filenames below differ from the own-sid filenames
# ONLY in the sid component, and the own-sid form is already proven to BLOCK by
# A3 (outline round-number) and A8 (detail concern-ledger). The foreign sid is
# deliberately not a prefix-extension of $SID, so a substring-based
# implementation could not match it by accident either.

echo ""
echo "=== A10: outline=pending + outline.md + FOREIGN-session outline-plan marker → auto-complete still fires ==="

SID="a10-$$"
FOREIGN_SID="foreign-a10-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-outline.md"
# Same stage, same marker name — but keyed to another session's id.
touch "$PLANS_DIR/${FOREIGN_SID}-outline-plan-round-number.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""
eval "$OUT" 2>/dev/null || true

check "A10. foreign-session marker → outline auto-completes" \
  "complete" "$(read_state_status "$SID" "outline")"
check "A10b. foreign-session marker → ACTION=invoke" \
  "invoke" "${ACTION:-}"

rm -f "$PLANS_DIR/${SID}-outline.md" "$PLANS_DIR/${FOREIGN_SID}-outline-plan-round-number.txt"

echo ""
echo "=== A11: detail=pending + detail.md + FOREIGN-session detail-plan marker → auto-complete still fires ==="

SID="a11-$$"
FOREIGN_SID="foreign-a11-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-detail.md"
touch "$PLANS_DIR/${FOREIGN_SID}-detail-plan-concern-ledger.txt"

OUT=$(run_next_step --session "$SID")
ACTION=""
eval "$OUT" 2>/dev/null || true

check "A11. foreign-session marker → detail auto-completes" \
  "complete" "$(read_state_status "$SID" "detail")"
check "A11b. foreign-session marker → ACTION=invoke" \
  "invoke" "${ACTION:-}"

rm -f "$PLANS_DIR/${SID}-detail.md" "$PLANS_DIR/${FOREIGN_SID}-detail-plan-concern-ledger.txt"
