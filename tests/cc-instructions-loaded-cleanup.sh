#!/usr/bin/env bash
# tests/cc-instructions-loaded-cleanup.sh
# Tests: hooks/workflow-state/state-io/zombie-cleanup.js, hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, receipts, cleanup, retention, idempotency, TL2, scope:common
#
# Receipts accumulate one directory per session, each holding one JSON file per rule
# the loader reported. Nothing else deletes them: without a sweep the workflow
# directory grows without bound for as long as the machine is used, and the growth is
# invisible because it lives under a dot-suffixed directory nobody lists. The detail
# plan therefore folds `<sid>.instructions-loaded/` into the existing 7-day
# cleanupZombies sweep, alongside the session-scoped marker files.
#
# A retention sweep has two failure directions and both are damaging: too eager
# destroys the evidence an in-flight off-switch gate is about to read (the gate
# concludes from ABSENCE, so a deleted receipt reads as a clean pass — a false green
# manufactured by the janitor), too lax is the unbounded growth it was added to stop.
# This file pins both edges, the exact boundary between them, and the behaviour on
# entries the sweep cannot parse.
# Layer: TL2 (runs the real cleanupZombies against a fully pinned fixture directory).
#
# TL3 gap (what this test does NOT catch):
# - Whether the sweep is actually reached on a real session's cleanup path, and
#   whether the host's mtime granularity matches the boundary asserted here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP_LIB="$AGENTS_DIR/hooks/workflow-state/state-io/zombie-cleanup.js"
RECEIPT_LIB="$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# --- Tier 1: implementation-missing guard, ahead of every other gate. -------------
MISSING=0
for f in "$CLEANUP_LIB" "$RECEIPT_LIB"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — detail plan S2-3 / S2-6)"
    exit 1
fi

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): the workflow dir and the plans
# dir are dual-pinned, the inherited session ids are dropped so nothing resolves the
# developer's live session, and the sweep runs from a neutral CWD.
WF="$BASE/wf"
PLANS="$BASE/plans"
mkdir -p "$WF" "$PLANS"
export CLAUDE_WORKFLOW_DIR="$(node_path "$WF")"
export WORKFLOW_PLANS_DIR="$(node_path "$PLANS")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

DAY=86400
NOW="$(date +%s)"

# mk_receipt_dir <sid> <age-seconds> [entry-count]
mk_receipt_dir() {
    # Separate `local` statements on purpose: bash expands ALL words of a `local`
    # command before performing any of its assignments, so `local sid="$1" d="$sid"`
    # reads an unset sid (and dies under `set -u`).
    local sid="$1"
    local age="$2"
    local n="${3:-2}"
    local i=0
    local d="$WF/$sid.instructions-loaded"
    mkdir -p "$d"
    while [ "$i" -lt "$n" ]; do
        printf '{"file_path":"rules/r%s.md","verdict":"ok"}\n' "$i" > "$d/entry$i.json"
        i=$((i + 1))
    done
    touch_age "$d" "$age"
}

# touch_age <path> <age-seconds> — set mtime to now-age. `touch -d @epoch` is GNU;
# the fallback keeps this runnable where it is not available rather than silently
# leaving a fresh mtime, which would turn every stale case into a false pass.
touch_age() {
    local p="$1" age="$2" ts
    ts=$((NOW - age))
    if ! touch -d "@$ts" "$p" 2>/dev/null; then
        node -e 'const fs=require("fs");const t=Number(process.argv[2]);fs.utimesSync(process.argv[1],t,t);' \
            "$(node_path "$p")" "$ts" 2>/dev/null
    fi
}

# run_sweep [days] -> exit code of the real cleanupZombies
run_sweep() {
    local days="${1:-7}" rc=0
    ( cd "$BASE" && node -e '
const { cleanupZombies } = require(process.argv[1]);
cleanupZombies(Number(process.argv[2]));
' "$(node_path "$CLEANUP_LIB")" "$days" ) >"$BASE/sweep.log" 2>&1 || rc=$?
    echo "$rc"
}

exists() { [ -e "$WF/$1.instructions-loaded" ] && echo yes || echo no; }

# --- Z1 / Z2: the two edges. Both directions are asserted in ONE sweep so a sweep
# that deletes everything and a sweep that deletes nothing are each caught by exactly
# one of them; run separately, a no-op implementation would pass Z2 alone. ---
mk_receipt_dir stale-a "$((10 * DAY))"
mk_receipt_dir fresh-a "$((1 * DAY))"
mk_receipt_dir fresh-b 5
Z_RC="$(run_sweep 7)"
if [ "$Z_RC" != "0" ]; then
    fail "Z0: cleanupZombies exited $Z_RC — $(head -3 "$BASE/sweep.log" | tr '\n' ' ')"
else
    pass "Z0: the sweep completes normally over a directory containing receipt dirs"
fi
if [ "$(exists stale-a)" = "no" ]; then
    pass "Z1: a 10-day-old receipt directory is removed"
else
    fail "Z1: a 10-day-old receipt directory survived the 7-day sweep — receipts grow without bound"
fi
if [ "$(exists fresh-a)" = "yes" ] && [ "$(exists fresh-b)" = "yes" ]; then
    pass "Z2: 1-day-old and 5-second-old receipt directories are preserved"
else
    fail "Z2: the sweep deleted a fresh receipt directory (fresh-a=$(exists fresh-a) fresh-b=$(exists fresh-b)) — an in-flight gate would read the deletion as a clean absence"
fi

# --- Z3: the exact boundary. The sibling marker files use a STRICT `<` against
# `Date.now() - days`, so an entry sitting exactly on the cutoff survives. Asserting
# the boundary rather than "roughly a week" is what stops the retention window from
# drifting by a day the next time this code is touched.
# The exactly-on-the-cutoff entry is REPORTED, not asserted: real time passes between
# `touch` and the sweep, so "exactly 7 days old at comparison time" is not something a
# test can hold still. The two ±120s neighbours pin the boundary; asserting the exact
# instant as well would only add a flake. ---
mk_receipt_dir edge-exact "$((7 * DAY))"
mk_receipt_dir edge-just-under "$((7 * DAY - 120))"
mk_receipt_dir edge-just-over "$((7 * DAY + 120))"
Z3_RC="$(run_sweep 7)"
Z3_BAD=""
[ "$(exists edge-just-over)" = "yes" ] && Z3_BAD="$Z3_BAD [7d+120s survived]"
[ "$(exists edge-just-under)" = "no" ] && Z3_BAD="$Z3_BAD [7d-120s deleted]"
if [ -n "$Z3_BAD" ]; then
    fail "Z3: the retention boundary is not at $((7 * DAY))s —$Z3_BAD (sweep rc=$Z3_RC)"
else
    pass "Z3: the boundary sits exactly at 7 days (7d+120s deleted, 7d-120s kept; exactly-7d=$(exists edge-exact) under the strict < rule)"
fi

# --- Z4: unparseable content must not stop the sweep. A receipt written by a killed
# process, or a stray file inside the directory, is exactly the debris this sweep is
# for; a throw here leaves every LATER entry in the directory unswept, so the failure
# is not local to the bad entry. ---
mk_receipt_dir malformed-old "$((9 * DAY))" 0
printf 'not json at all {{{\n' > "$WF/malformed-old.instructions-loaded/broken.json"
printf 'plain text\n' > "$WF/malformed-old.instructions-loaded/notes.txt"
mkdir -p "$WF/malformed-old.instructions-loaded/nested/deeper"
printf '{}\n' > "$WF/malformed-old.instructions-loaded/nested/deeper/x.json"
touch_age "$WF/malformed-old.instructions-loaded" "$((9 * DAY))"
mk_receipt_dir after-malformed "$((9 * DAY))"
Z4_RC="$(run_sweep 7)"
if [ "$Z4_RC" != "0" ]; then
    fail "Z4: the sweep crashed on a malformed receipt directory (rc=$Z4_RC) — $(head -3 "$BASE/sweep.log" | tr '\n' ' ')"
elif [ "$(exists malformed-old)" = "yes" ]; then
    fail "Z4: a stale receipt directory containing unparseable entries was not removed"
elif [ "$(exists after-malformed)" = "yes" ]; then
    fail "Z4: the sweep stopped early — the stale directory after the malformed one survived"
else
    pass "Z4: a stale directory with unparseable and nested entries is removed, and the sweep continues past it"
fi

# --- Z5: an empty stale directory. The receipt writer creates the directory before it
# has anything to publish, so an interrupted session leaves one behind with no entries;
# the sweep must treat it as a receipt directory, not skip it for being empty. ---
mk_receipt_dir empty-old "$((9 * DAY))" 0
run_sweep 7 >/dev/null
if [ "$(exists empty-old)" = "no" ]; then
    pass "Z5: an empty stale receipt directory is removed"
else
    fail "Z5: an empty stale receipt directory survived — an interrupted session leaks one per run"
fi

# --- Z6: idempotency. The sweep runs on an ordinary session path, so it runs often.
# Two consecutive runs must reach the same state and the second must not fail on the
# entries the first removed. ---
mk_receipt_dir idem-stale "$((9 * DAY))"
mk_receipt_dir idem-fresh 30
Z6_RC1="$(run_sweep 7)"
Z6_STATE1="stale=$(exists idem-stale) fresh=$(exists idem-fresh)"
Z6_RC2="$(run_sweep 7)"
Z6_STATE2="stale=$(exists idem-stale) fresh=$(exists idem-fresh)"
if [ "$Z6_RC1" != "0" ] || [ "$Z6_RC2" != "0" ]; then
    fail "Z6: consecutive sweeps must both exit 0, got $Z6_RC1 then $Z6_RC2 — $(head -3 "$BASE/sweep.log" | tr '\n' ' ')"
elif [ "$Z6_STATE1" != "$Z6_STATE2" ]; then
    fail "Z6: the second sweep changed the outcome — after#1 [$Z6_STATE1] after#2 [$Z6_STATE2]"
elif [ "$Z6_STATE2" != "stale=no fresh=yes" ]; then
    fail "Z6: want [stale=no fresh=yes] after two sweeps, got [$Z6_STATE2]"
else
    pass "Z6: the sweep is idempotent — two consecutive runs agree and both exit 0"
fi

# --- Z7: containment. The sweep must confine itself to the pinned workflow directory;
# a receipt directory sitting elsewhere is not its business, and deleting outside the
# pin is the failure mode that would destroy a developer's real state during a test. ---
OUTSIDE="$BASE/outside"
mkdir -p "$OUTSIDE/victim-sid.instructions-loaded"
printf '{"verdict":"ok"}\n' > "$OUTSIDE/victim-sid.instructions-loaded/e.json"
touch_age "$OUTSIDE/victim-sid.instructions-loaded" "$((99 * DAY))"
run_sweep 7 >/dev/null
if [ -e "$OUTSIDE/victim-sid.instructions-loaded/e.json" ]; then
    pass "Z7: a receipt directory outside CLAUDE_WORKFLOW_DIR is untouched"
else
    fail "Z7: the sweep deleted a receipt directory OUTSIDE the pinned workflow dir"
fi

# --- Z8: the sweep must not widen to neighbouring names. `<sid>.instructions-loaded`
# is a suffix match; a sloppy `.includes()` would also claim
# `<sid>.instructions-loaded-notes` or a same-named .json state file. ---
mkdir -p "$WF/neighbour.instructions-loaded-notes"
printf 'keep me\n' > "$WF/neighbour.instructions-loaded-notes/x.txt"
touch_age "$WF/neighbour.instructions-loaded-notes" "$((99 * DAY))"
printf '{"version":3,"session_id":"keeper","created_at":"%s","events":[]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WF/keeper.json"
run_sweep 7 >/dev/null
Z8_BAD=""
[ -e "$WF/neighbour.instructions-loaded-notes/x.txt" ] || Z8_BAD="$Z8_BAD [neighbour dir deleted]"
[ -e "$WF/keeper.json" ] || Z8_BAD="$Z8_BAD [fresh state file deleted]"
if [ -z "$Z8_BAD" ]; then
    pass "Z8: the receipt-dir rule does not spill onto neighbouring names"
else
    fail "Z8: the sweep matched more than the receipt directories —$Z8_BAD"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
