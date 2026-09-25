#!/bin/bash
# tests/feature-1665-seq-cascade/i-c4-exemption.sh
# Tests: hooks/stop-premature-stop-guard.js, hooks/workflow-state/lifecycle.js
# Tags: workflow-state, write-code, stop-guard, c4, exemption, ttl, fail-closed, guard, scope:issue-specific, pwsh-not-required, TL2
#
# I — the C4 premature-stop guard must stay quiet while write_code is genuinely
# in flight.
#
# WHY: /write-code runs for many turns without settling a tracked next-step step,
# so without an exemption C4 re-nudges the session on every Stop. The exemption is
# TTL-bounded (4h) and fail-CLOSED: a missing, non-string, or unparseable
# timestamp means "cannot prove it is in flight", which must resolve to BLOCK —
# an unbounded quiet window would silently disable the guard for the rest of the
# session.
#
# Classifier coverage (CPR-ORTH): both verdicts are exercised, plus a second,
# pre-existing exemption row (pre-workflow-init) so a change that accidentally
# short-circuits the whole exemption chain is caught here too.
#
# TL3 gap (what this test does NOT catch):
# - Whether the Stop event actually reaches this script in the deployed
#   settings.json wiring (the hook is spawned directly here).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG=i
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

REPO="$TMPROOT/repo-i"
mk_repo "$REPO"
REPO_N="$(nrm "$REPO")"
export CLAUDE_PROJECT_DIR="$REPO_N"

# The guard resolves bin/workflow/next-step relative to AGENTS_CONFIG_DIR; point
# it at the real repo for this case only (an empty config dir makes the guard
# exit 0 unconditionally, which would make every block assertion vacuous).
run_c4() { # env: C4_SID
    printf '%s' "{\"session_id\":\"$C4_SID\",\"cwd\":\"$REPO_N\",\"stop_hook_active\":false}" \
        | AGENTS_CONFIG_DIR="$AGENTS_DIR_N" "$RWT" 120 node "$M_GUARD" 2>&1
    return 0
}

seed_started() { # env: SEED_SID
    "$RWT" 120 node -e '
const S = require(process.env.M_SIO);
S.markStep(process.env.SEED_SID, "workflow_init", "complete");
S.markStep(process.env.SEED_SID, "clarify_intent", "complete");
' >/dev/null 2>&1
}

mark_write_code() { # env: SEED_SID, WC_STEP, WC_NOW ("" = current clock)
    js_g '
const S = require(process.env.M_SIO);
const opts = process.env.WC_NOW ? { now: process.env.WC_NOW } : {};
S.markStep(process.env.SEED_SID, process.env.WC_STEP || "write_code", "in_progress", {}, opts);
console.log("marked=" + (process.env.WC_STEP || "write_code"));
'
}

# --- I0: no exemption -> BLOCK (baseline; proves the guard is live) -----------
SEED_SID="seq1665-i0"; export SEED_SID; seed_started
C4_SID="$SEED_SID"; export C4_SID
OUT_I0="$(run_c4)"
assert_contains "I0 baseline: guard blocks a started session with nothing in flight" '"decision":"block"' "$OUT_I0"

# --- I1: write_code in_progress now -> quiet ---------------------------------
SEED_SID="seq1665-i1"; export SEED_SID; seed_started
WC_NOW=""; WC_STEP="write_code"; export WC_NOW WC_STEP; mark_write_code
require_js_ok "I1 precondition: write_code can be marked in_progress" && \
    assert_js "I1 precondition recorded" marked "write_code"
C4_SID="$SEED_SID"; export C4_SID
OUT_I1="$(run_c4)"
assert_not_contains "I1 write_code in flight silences C4" '"decision":"block"' "$OUT_I1"

# --- I2: TTL expiry (5h old) -> BLOCK ----------------------------------------
SEED_SID="seq1665-i2"; export SEED_SID; seed_started
OLD="$("$RWT" 120 node -e 'console.log(new Date(Date.now() - 5*3600*1000).toISOString())')"
WC_NOW="$OLD"; export WC_NOW; mark_write_code
require_js_ok "I2 precondition: backdated write_code marker recorded"
C4_SID="$SEED_SID"; export C4_SID
OUT_I2="$(run_c4)"
assert_contains "I2 expired write_code marker no longer exempts (4h TTL)" '"decision":"block"' "$OUT_I2"

# --- I3/I4: unparseable timestamp -> fail-CLOSED -----------------------------
# `at` is edited in place; `seq` is left untouched so assertStreamIntegrity still
# accepts the stream and the guard genuinely reaches the TTL comparison.
corrupt_at() { # env: SEED_SID, CORRUPT_MODE = drop|number
    "$RWT" 120 node -e '
const fs = require("fs");
const path = require("path");
const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.SEED_SID + ".json");
const st = JSON.parse(fs.readFileSync(p, "utf8"));
for (const e of st.events) {
  if (e.kind === "step_status" && e.step === "write_code") {
    if (process.env.CORRUPT_MODE === "drop") delete e.at;
    else e.at = 12345;
  }
}
fs.writeFileSync(p, JSON.stringify(st, null, 2));
' 2>&1
}

SEED_SID="seq1665-i3"; export SEED_SID; seed_started
WC_NOW=""; export WC_NOW; mark_write_code
require_js_ok "I3 precondition: write_code marker recorded"
CORRUPT_MODE="drop"; export CORRUPT_MODE; corrupt_at >/dev/null
C4_SID="$SEED_SID"; export C4_SID
OUT_I3="$(run_c4)"
assert_contains "I3 missing timestamp is fail-CLOSED (still blocks)" '"decision":"block"' "$OUT_I3"

SEED_SID="seq1665-i4"; export SEED_SID; seed_started
WC_NOW=""; export WC_NOW; mark_write_code
require_js_ok "I4 precondition: write_code marker recorded"
CORRUPT_MODE="number"; export CORRUPT_MODE; corrupt_at >/dev/null
C4_SID="$SEED_SID"; export C4_SID
OUT_I4="$(run_c4)"
assert_contains "I4 non-string timestamp is fail-CLOSED (still blocks)" '"decision":"block"' "$OUT_I4"

# --- I5: a different step in flight must NOT exempt --------------------------
SEED_SID="seq1665-i5"; export SEED_SID; seed_started
WC_NOW=""; WC_STEP="docs"; export WC_NOW WC_STEP; mark_write_code
C4_SID="$SEED_SID"; export C4_SID
OUT_I5="$(run_c4)"
assert_contains "I5 an unrelated in_progress step does not exempt" '"decision":"block"' "$OUT_I5"
WC_STEP="write_code"; export WC_STEP

# --- I6: pre-existing exemption row still works (CPR-ORTH) -------------------
C4_SID="seq1665-i6-never-started"; export C4_SID
OUT_I6="$(run_c4)"
assert_not_contains "I6 pre-workflow-init exemption still silences C4" '"decision":"block"' "$OUT_I6"

finish
