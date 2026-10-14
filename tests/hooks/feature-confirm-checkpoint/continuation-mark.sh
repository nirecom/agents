# shellcheck shell=bash
# #2650 continuation marks in hooks/lib/turn-marker.js (driver: continuation-mark-driver.js).
# Sourced by ../feature-confirm-checkpoint.sh (needs pass, fail, run_with_timeout, SCRIPT_CHECKOUT_ROOT_NATIVE).
# WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR are pinned by the parent:
# isolation: inherits-from ../feature-confirm-checkpoint.sh

echo "=== #2650 continuation marks (turn-marker.js) ==="
CM_OUT="$(run_with_timeout node "$SCRIPT_CHECKOUT_ROOT_NATIVE/tests/hooks/feature-confirm-checkpoint/continuation-mark-driver.js" 2>&1)"
CM_RC=$?
[ -z "$CM_OUT" ] && fail "#2650 continuation-mark driver produced no assertions (exit $CM_RC)"
while IFS= read -r CM_LINE; do
  [ -z "$CM_LINE" ] && continue
  CM_REST="${CM_LINE#*|}"
  case "$CM_LINE" in
    PASS\|*) pass "$CM_REST" ;;
    FAIL\|*) fail "${CM_REST%%|*} — ${CM_REST#*|}" ;;
    *) fail "#2650 continuation-mark driver: unparsed line: $CM_LINE" ;;
  esac
done <<< "$CM_OUT"
[ "$CM_RC" -ne 0 ] && fail "#2650 continuation-mark driver exited $CM_RC"
