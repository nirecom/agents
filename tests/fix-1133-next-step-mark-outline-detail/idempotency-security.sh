# ===========================================================================
# === I1: --mark idempotency ===
# ===========================================================================

echo ""
echo "=== I1: --mark outline complete twice → idempotent (exit 0 both, state=complete) ==="

SID="i1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
run_next_step_rc --session "$SID" --mark outline complete
check "I1. first --mark outline complete → exit 0" "0" "$RC"
check "I1b. first --mark → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"
run_next_step_rc --session "$SID" --mark outline complete
check "I1c. second --mark outline complete → exit 0 (idempotent)" "0" "$RC"
check "I1d. second --mark → state still outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

# ===========================================================================
# === S1-S2: Session-ID validation rejects path traversal ===
# ===========================================================================

echo ""
echo "=== S1: --session '../escape' → nonzero exit (SESSION_ID_VALID_RE guard) ==="

# evidence-resolver.js uses SESSION_ID_VALID_RE to prevent path traversal when
# constructing <PLANS_DIR>/<session-id>-outline.md paths.  The CLI must reject
# session IDs that contain '/' or '..' before any file operation occurs.
run_next_step_rc --session "../escape" --mark outline complete
check_nonzero "S1. --session '../escape' → nonzero exit (path traversal rejected)" "$RC"

echo ""
echo "=== S2: --session '' → nonzero exit (empty session ID rejected) ==="

run_next_step_rc --session "" --mark outline complete
check_nonzero "S2. --session '' → nonzero exit (empty session ID rejected)" "$RC"
