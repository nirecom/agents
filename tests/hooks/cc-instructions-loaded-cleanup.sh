#!/usr/bin/env bash
# tests/hooks/cc-instructions-loaded-cleanup.sh
# Tests: hooks/workflow-state/state-io/zombie-cleanup.js, hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, receipts, cleanup, retention, idempotency, TL2, scope:common, feature-2434, zombie-cleanup, control-dir

# The 7-day cleanupZombies sweep owns `<sid>.instructions-loaded/` receipts and (#2434) `<sid>.control/` dirs.
# Too eager destroys evidence an in-flight gate reads from ABSENCE (false-green); too lax is unbounded growth.
# Pins both edges, the boundary, and unparseable entries. TL2: real cleanupZombies, pinned fixture dir.
# TL3 gap: real session cleanup path and host mtime granularity — mitigated by bin/check-verification-gate.sh
# (category: hook-registration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEANUP_LIB="$AGENTS_DIR/hooks/workflow-state/state-io/zombie-cleanup.js"
RECEIPT_LIB="$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js"

PASS=0; FAIL=0
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"   # provides the per-case marker helpers
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
unset CLAUDE_CODE_SESSION_ID

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

# --- Z9-Z13 (#2434, merged from tests/hooks/feature-2434-zombie-cleanup-control-dir.sh):
# `<sid>.control/` dirs join the same sweep. Stale and orphaned -> removed; an
# active session's or a recent one -> kept; a stale migrating tmp inside -> reclaimed.
CTL_DRIVER="$BASE/ctl-driver.js"
cat > "$CTL_DRIVER" <<'JS'
const { cleanupZombies } = require(process.argv[2]);
const fs = require("fs"), path = require("path");
const WF = process.env.CLAUDE_WORKFLOW_DIR, DAY = 24 * 60 * 60 * 1000;
const P = (n) => path.join(WF, n);
const age = (p, days) => { const t = (Date.now() - days * DAY) / 1000; fs.utimesSync(p, t, t); };
const mkCtl = (n, days) => { fs.mkdirSync(P(n), { recursive: true }); age(P(n), days); };
const gone = (n) => String(!fs.existsSync(P(n)));
const ago = (days) => new Date(Date.now() - days * DAY).toISOString();
switch (process.argv[3]) {
  case "z9": mkCtl("z9ctrl.control", 31); cleanupZombies(7); console.log("ctrl_removed=" + gone("z9ctrl.control")); break;
  case "z10":
    mkCtl("z10ctrl.control", 31);
    fs.writeFileSync(P("z10ctrl.json"), JSON.stringify({ version: 2, session_id: "z10ctrl", created_at: ago(31),
      events: [{ seq: 1, at: ago(0.1), kind: "step_status", step: "run_tests", status: "in_progress",
        provenance: "observed", origin: "mark-step" }], current: { steps: {} } }));
    cleanupZombies(7); console.log("ctrl_removed=" + gone("z10ctrl.control")); break;
  case "z11": mkCtl("z11ctrl.control", 0.5); cleanupZombies(7); console.log("ctrl_removed=" + gone("z11ctrl.control")); break;
  case "z12": {
    const tmp = "z12ctrl.control/session-migrating-1701000000000.tmp";
    fs.mkdirSync(P("z12ctrl.control"), { recursive: true });
    fs.writeFileSync(P(tmp), "migrating state"); age(P(tmp), 2); age(P("z12ctrl.control"), 0.3);
    cleanupZombies(7); console.log("tmp_removed=" + gone(tmp)); break;
  }
  case "z13": mkCtl("non-uuid-z13.control", 31); cleanupZombies(7); console.log("ctrl_removed=" + gone("non-uuid-z13.control")); break;
  default: console.log("bad-scenario");
}
JS

# ctl_case <id> <label> <want-line> — one scenario through the real cleanupZombies.
ctl_case() {
    local out rc=0
    out="$(cd "$BASE" && node "$(node_path "$CTL_DRIVER")" "$(node_path "$CLEANUP_LIB")" "$1" 2>&1)" || rc=$?
    out="$(printf '%s' "$out" | tr -d '\r')"
    if [ "$rc" = "0" ] && [ "$out" = "$3" ]; then
        pass "$2"
    else
        fail "$2 — want $3; got rc=$rc: $out"
    fi
}

case_begin "control-dir-stale-orphan-removed" "hooks/workflow-state/state-io/zombie-cleanup.js"
ctl_case z9 "Z9: a 31-day-old <sid>.control/ with no state json is removed" "ctrl_removed=true"
ctl_case z13 "Z13: a non-UUID 31-day-old .control/ with no state json is also removed" "ctrl_removed=true"
case_end

case_begin "control-dir-active-or-recent-kept" "hooks/workflow-state/state-io/zombie-cleanup.js"
ctl_case z10 "Z10: a 31-day-old .control/ whose session json is active is kept" "ctrl_removed=false"
ctl_case z11 "Z11: a 12-hour-old .control/ is too recent to remove" "ctrl_removed=false"
case_end

case_begin "control-dir-stale-migrating-tmp-reclaimed" "hooks/workflow-state/state-io/zombie-cleanup.js"
ctl_case z12 "Z12: a 2-day-old migrating tmp inside a recent .control/ is reclaimed" "tmp_removed=true"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
