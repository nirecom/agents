# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js, bin/workflow/lib/next-step/
# Tags: workflow, approval-gate, outline, detail, approval-revert, scope:common
# (Sourced fragment of tests/hooks/fix-1133-1148-approval-gate.sh — not run standalone.)
# G06 (#1133): writeState accepts opts.sanctioned only from the frozen SANCTIONED_SOURCES
# set; an unknown token fails closed with unknown-sanctioned-token. G06c (#2633-1):
# "session-inherit" left that set, so inheritance can no longer mint a bypass.

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

SID_C="g06c-$$"
write_state "$SID_C" "$(gen_state '{}')"
OUT_C=$(node_probe '
  const ws = require(process.argv[1]);
  const sid = process.argv[2];
  try { ws.writeState(sid, ws.readState(sid), { sanctioned: "session-inherit" }); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID_C")
check "G06c. session-inherit is no longer a sanctioned token" "THREW:unknown-sanctioned-token" "$OUT_C"
OUT_C2=$(node_probe '
  const ws = require(process.argv[1]);
  try { ws.writeState(process.argv[2], ws.readState(process.argv[2]), { sanctioned: "confirm-sentinel" }); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID_C")
check "G06c2. confirm-sentinel stays a sanctioned token" "NOERROR" "$OUT_C2"
