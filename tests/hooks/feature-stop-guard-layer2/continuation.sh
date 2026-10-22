# shellcheck shell=bash
# #2650 Stop-hook continuation branch: N1-N21 and T6 (driver: continuation-driver.js).
# Sourced by ../feature-stop-guard-layer2.sh (needs pass, fail, run_with_timeout, SCRIPT_CHECKOUT_ROOT_NATIVE).
# WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR are pinned by the parent:
# isolation: inherits-from ../feature-stop-guard-layer2.sh

echo "=== #2650 continuation branch (N1-N21, T6) ==="
SG2_CONT_DRIVER="$SCRIPT_CHECKOUT_ROOT_NATIVE/tests/hooks/feature-stop-guard-layer2/continuation-driver.js"
SG2_CONT_OUT="$(run_with_timeout node "$SG2_CONT_DRIVER" 2>&1)"
SG2_CONT_RC=$?
if [ -z "$SG2_CONT_OUT" ]; then
  fail "#2650 continuation driver produced no assertions (exit $SG2_CONT_RC)"
fi
while IFS= read -r SG2_LINE; do
  [ -z "$SG2_LINE" ] && continue
  SG2_REST="${SG2_LINE#*|}"
  case "$SG2_LINE" in
    PASS\|*) pass "$SG2_REST" ;;
    FAIL\|*) fail "${SG2_REST%%|*} — ${SG2_REST#*|}" ;;
    *) fail "#2650 continuation driver: unparsed line: $SG2_LINE" ;;
  esac
done <<< "$SG2_CONT_OUT"
if [ "$SG2_CONT_RC" -ne 0 ]; then
  fail "#2650 continuation driver exited $SG2_CONT_RC"
fi
