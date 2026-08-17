# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, dispatcher, scope:issue-specific, pwsh-not-required, TL2

# The one body the five tests/fix-1532-node-guard-*.sh entry points share. They
# exist as five separate FILES because bin/select-tests.sh Tier 1 selects on the
# filename stem alone; they hold no logic, so there is nothing there to drift.

DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$DISPATCH_DIR/common.sh"

# A miswired entry point must be loud. Defaulting to some target would run a green
# suite that never looked at the file the caller meant.
case " $TARGETS " in
  *" ${GUARD_TARGET:-} "*) ;;
  *)
    echo "FATAL: GUARD_TARGET='${GUARD_TARGET:-<unset>}' is not one of: $TARGETS" >&2
    exit 2
    ;;
esac

. "$DISPATCH_DIR/envelope-shape.sh"
. "$DISPATCH_DIR/node-diagnostic.sh"
. "$DISPATCH_DIR/eagain-retry.sh"
. "$DISPATCH_DIR/adversarial-path.sh"
. "$DISPATCH_DIR/absolute-contract.sh"
. "$DISPATCH_DIR/bash-invariance.sh"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
