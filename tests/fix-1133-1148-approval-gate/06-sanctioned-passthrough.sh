# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js
# Tags: workflow, approval-gate, outline, detail, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G06: sanctioned-source passthrough is a closed set (#1133). writeState accepts
# an opts.sanctioned token only when it is a member of the frozen
# SANCTIONED_SOURCES set; an unknown token is rejected fail-closed with the
# unknown-sanctioned-token code. This prevents callers from minting arbitrary
# "sanctioned" bypasses of the approval invariant.
# fail-before-fix: pre-fix writeState ignores any extra arg → NOERROR.
# ===========================================================================

echo ""
echo "=== G06: unknown sanctioned token is rejected fail-closed ==="

# #1733: readState() returns a read-only projection -- mutating .steps on it
# throws immediately (refusing Proxy), before writeState() is even reached.
# The unknown-sanctioned-token check this case targets
# (applyCompletionBoundaryInvariant in state-io/core.js) validates opts.sanctioned
# unconditionally, independent of any step transition, so no .steps mutation is
# needed to exercise it -- pass the unmodified projection straight through.
SID="g06-$$"
write_state "$SID" "$(gen_state '{}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  const sid = process.argv[2];
  const s = ws.readState(sid);
  try { ws.writeState(sid, s, { sanctioned: "bogus-token" }); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")

check_contains "G06a. unknown sanctioned token throws" "THREW" "$OUT"
check_contains "G06a2. throw identifies the unknown-sanctioned-token failure" "sanctioned" "$OUT"
check_ne "G06b. outline was NOT persisted complete via the bogus token" "complete" "$(read_state_status "$SID" outline)"
