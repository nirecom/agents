#!/usr/bin/env bash
# tests/enforce-off-emergency-provenance.sh
# Tests: hooks/record-off-skill-invocation.js, hooks/lib/off-emergency-provenance.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js, settings.json
# Tags: off-clearance, emergency-off, provenance, audit, userpromptsubmit, session-marker, security, scope:common, pwsh-not-required, TL2, hook-registration
# TL3 gap: synthetic stdin here, so real UserPromptSubmit firing for a typed
# slash command (P9 is static-only) and same-turn ordering are covered live by
# tests/TL3-hook-record-off-skill-invocation.sh instead.
# Defends #1780 M-2: the provenance marker is the only evidence that a HUMAN
# opened the EMERGENCY OFF escape hatch - written only on a real invocation
# (P1), unable to vouch later (P2/P3/P5/P6), never a GATE on the override
# (P4/P5/P7), unforgeable (P10), bound to skill+targets (P11).

set -u

# rules/test/fixture-isolation.md: the parent Claude Code session exports these,
# and the recorder falls back to them whenever a payload carries no usable
# session_id (P12) - inherited values would make those cases resolve the REAL
# session instead of the one the case names.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

RECORDER="$AGENTS_DIR/hooks/record-off-skill-invocation.js"
HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/off-clearance.js"
BLOCK_HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SETTINGS="$AGENTS_DIR/settings.json"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'offprov'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_file()   { if [ -f "$2" ]; then pass "$1"; else fail "$1 - missing file: $2"; fi; }
assert_absent() { if [ -f "$2" ]; then fail "$1 - file should NOT exist: $2"; else pass "$1"; fi; }
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 - missing substring $(printf '%q' "$2") in $(printf '%.300s' "$3")"; fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 - unexpected substring $(printf '%q' "$2")"; else pass "$1"; fi
}
# The audit file is PRETTY-PRINTED JSON while the override marker is compact, so
# audit-side field assertions must tolerate whitespace between key and value
# instead of assuming one encoding for both.
assert_json_field() { # <label> <key> <value> <text>
    if printf '%s' "$4" | grep -qE "\"$2\"[[:space:]]*:[[:space:]]*\"$3\""; then pass "$1"
    else fail "$1 - no \"$2\": \"$3\" in $(printf '%.400s' "$4")"; fi
}

# The sentinel strings are ASSEMBLED, never written literally: a test file that
# contains an emittable sentinel would arm the real hook whenever it is read
# aloud, pasted, or grepped into a transcript.
_S_OPEN="<<"
_S_CLOSE=">>"
emerg_cmd() { # <WORKFLOW|WORKTREE> <reason> -> the exact Bash command string
    printf 'echo "%sWORKFLOW_ENFORCE_%s_OFF_EMERGENCY: %s%s"' "$_S_OPEN" "$1" "$2" "$_S_CLOSE"
}

if [ ! -f "$RECORDER" ]; then
    fail "P0 hooks/record-off-skill-invocation.js missing at $RECORDER - provenance is unrecorded"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
if [ ! -f "$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers/off-clearance.js" ]; then
    fail "P0 enforce-override-handlers/off-clearance.js missing - nothing consumes provenance"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "P0 recorder and consumer both present"

# HERMETICITY: CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR point at this throwaway
# dir and every session id is a throwaway ("pv1sid" etc), so no real session
# marker, token or audit file is ever created, read or removed.
TMP=$(make_tmp)
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
    fail "P0 mktemp -d failed - refusing to derive fixture paths from an empty TMP"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
WF=$(node_path "$TMP")
MARKER_KIND=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).EMERGENCY_PROVENANCE_MARKER_KIND)" \
    "$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js" 2>/dev/null)
if [ -z "$MARKER_KIND" ]; then
    fail "P0 EMERGENCY_PROVENANCE_MARKER_KIND not exported by hooks/lib/protected-basenames.js"
    rm -rf "$TMP"; echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "P0 provenance marker kind derived from the SSOT: .$MARKER_KIND"

marker_of() { printf '%s/%s.%s' "$TMP" "$1" "$MARKER_KIND"; }
audit_of()  { printf '%s/%s-supervisor-state.json' "$TMP" "$1"; }

# The recorder's own stdout/stderr and exit status, kept OUT of the marker
# directory so a capture file can never be mistaken for a marker.
CAPDIR="$TMP/_capture"; mkdir -p "$CAPDIR"
CAP_OUT="$CAPDIR/stdout"; CAP_ERR="$CAPDIR/stderr"
LAST_RECORDER_STATUS=0; LAST_RECORDER_OUT=""; LAST_RECORDER_ERR=""
# A crash is not a "no marker" verdict: without this ledger a recorder that died
# (nonzero exit, signal kill, timeout) would leave every assert_absent below
# passing for the WRONG reason. Every invocation is checked; the offenders are
# named once at the end.
RECORDER_FAULTS=""
# The UserPromptSubmit contract: the hook prints one JSON object and nothing else.
RECORDER_OK_STDOUT='{}'

_note_recorder_run() { # <label>
    if [ "$LAST_RECORDER_STATUS" -ne 0 ]; then
        RECORDER_FAULTS="$RECORDER_FAULTS [$1 exit=$LAST_RECORDER_STATUS]"
    fi
    if [ "$LAST_RECORDER_OUT" != "$RECORDER_OK_STDOUT" ]; then
        RECORDER_FAULTS="$RECORDER_FAULTS [$1 stdout=$(printf '%.80s' "$LAST_RECORDER_OUT")]"
    fi
}
# _run_recorder <label> <json-payload> [env-var-name] [env-var-value]
_run_recorder() {
    local label="$1" payload="$2" var="${3:-}" val="${4:-}"
    printf '%s' "$payload" | \
        (cd "$TMP" && if [ -n "$var" ]; then export "$var=$val"; fi
            CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
                "$RWT" 15 node "$RECORDER" >"$CAP_OUT" 2>"$CAP_ERR")
    LAST_RECORDER_STATUS=$?
    LAST_RECORDER_OUT=$(cat "$CAP_OUT" 2>/dev/null)
    LAST_RECORDER_ERR=$(cat "$CAP_ERR" 2>/dev/null)
    _note_recorder_run "$label"
}

json_escape() { # <text> -> the body of a JSON string literal
    local esc
    esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    # A raw newline inside a JSON string literal is a parse error, so without
    # this fold a multi-line prompt never reaches the recorder at all. Bash
    # parameter expansion, not sed's N/branch idiom - that one is a GNU
    # extension that folds nothing on BSD/macOS sed. A no-op for single-line
    # prompts, so every pre-existing case is untouched.
    printf '%s' "${esc//$'\n'/\\n}"
}

# submit_prompt <sid> <prompt-text>: one synthetic UserPromptSubmit event. The
# session id is JSON-escaped too: P12 feeds it hostile spellings, and an
# unescaped `..\evil` would abort the parse - testing JSON handling rather than
# the session-id validation the case is about.
submit_prompt() {
    _run_recorder "sid=$1" "$(printf '{"session_id":"%s","prompt":"%s"}' "$(json_escape "$1")" "$(json_escape "$2")")"
}

# submit_prompt_env <env-var> <env-value> <sid-field> <prompt>: same event, with
# one session-id env var set for the recorder's fallback resolution.
submit_prompt_env() {
    _run_recorder "sid=$3/env=$1" \
        "$(printf '{"session_id":"%s","prompt":"%s"}' "$(json_escape "$3")" "$(json_escape "$4")")" "$1" "$2"
}

# submit_prompt_sidless <env-var> <sid> <prompt>: a payload with NO session_id,
# so the recorder must resolve one from the environment (P12).
submit_prompt_sidless() {
    _run_recorder "env=$1" "$(printf '{"prompt":"%s"}' "$(json_escape "$3")")" "$1" "$2"
}

# File modes are not real everywhere (Git Bash on Windows reports 644 whatever
# was chmod'd), so the 0600 assertion is PROBED for and skipped by name where it
# would be meaningless - same idiom as tests/fix-2025-recovery-artifact-mode.sh.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
MODES_OK=no
: > "$CAPDIR/.mode-probe"
chmod 600 "$CAPDIR/.mode-probe" 2>/dev/null || true
[ "$(file_mode "$CAPDIR/.mode-probe")" = "600" ] && MODES_OK=yes
# assert_owner_only <label> <file>: the marker is evidence in a shared state dir,
# so it must not be world- or group-readable.
assert_owner_only() {
    if [ "$MODES_OK" != "yes" ]; then skip "$1 (this filesystem does not keep modes)"; return; fi
    assert_eq "$1" "600" "$(file_mode "$2")"
}

# iso_at <delta-ms>: ISO timestamp offset from now (node, so macOS `date` quirks
# never enter the picture). The delta is interpolated INTO the script rather than
# passed as an argv element: a leading `-` in `node -e <script> -600000` is parsed
# by node as an option, which silently yields an empty timestamp - and an empty
# `invoked_at` reads as "not fresh", so every freshness case below would have
# passed VACUOUSLY. mk_marker guards that with an explicit check.
iso_at() { "$RWT" 10 node -e "process.stdout.write(new Date(Date.now()+($1)).toISOString())" 2>/dev/null; }

# The payload SHAPE is not restated here: it comes from the writer's own contract
# function, hooks/lib/off-emergency-provenance.js buildProvenanceMarker()
# (CPR-SSOT). The earlier hand-rolled `{invoked_at, source}` literal is exactly
# what went wrong - when M-4 bound the marker to a skill identity and a target
# set, the fixture froze the pre-M-4 shape and asserted a downgrade the reader
# was RIGHT to apply, so a green freshness case meant nothing. P11 below pins
# the short-shape downgrade DELIBERATELY instead.
PROVENANCE_SSOT="$_AGENTS_DIR_NODE/hooks/lib/off-emergency-provenance.js"
# mk_marker <sid> <delta-ms>: a current-contract provenance marker dated relative
# to now. The delta travels by ENV, never argv - see iso_at's note on `-600000`.
mk_marker() {
    local body
    body=$(MK_DELTA_MS="$2" "$RWT" 10 node -e '
"use strict";
const { buildProvenanceMarker } = require(process.argv[1]);
const delta = Number(process.env.MK_DELTA_MS);
if (!isFinite(delta)) process.exit(1);
process.stdout.write(JSON.stringify(buildProvenanceMarker(Date.now() + delta)));
' "$PROVENANCE_SSOT" 2>/dev/null)
    # Every field the reader checks must be present, or the freshness/binding
    # cases would pass for the wrong reason (a downgrade, not a timestamp).
    case "$body" in
        *'"invoked_at":"'????-??-??T*'"source":"user_skill_invocation"'*'"skill":"enforce-workflow-off"'*'"targets":['*) ;;
        *) fail "harness: buildProvenanceMarker(delta=$2) produced no usable payload ($(printf '%q' "$body")) - provenance cases would be vacuous"; return 1 ;;
    esac
    printf '%s' "$body" > "$(marker_of "$1")"
}
# mk_raw_marker <sid> <json>: a marker written VERBATIM, for shapes the SSOT
# builder can no longer produce (legacy payloads, forged bindings).
mk_raw_marker() { printf '%s' "$2" > "$(marker_of "$1")"; }

# Driver: calls handleEmergencyOff() directly with an injected ctx, so the assertion
# is on the handler's own contract rather than on the shim that reaches it.
DRIVER="$TMP/emerg-driver.js"
cat > "$DRIVER" <<'DRIVER_EOF'
"use strict";
const h = require(process.argv[2]);
const msgs = [], fatal = [];
let handled = null, err = null;
try {
  handled = h.handleEmergencyOff({
    cmd: process.argv[3],
    sessionId: process.argv[4],
    pushMessage: (m) => msgs.push(String(m)),
    signalFatal: (m) => fatal.push(String(m)),
  });
} catch (e) { err = (e && e.message) || String(e); }
process.stdout.write(JSON.stringify({ handled, msgs, fatal, err }));
DRIVER_EOF

run_emergency() { # <sid> <cmd> -> driver JSON on stdout
    (cd "$TMP" && CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 20 node "$DRIVER" "$HANDLER_NODE" "$2" "$1" 2>/dev/null)
}
# provenance_in <file>: the provenance value recorded in a marker/audit JSON.
provenance_in() { grep -o '"provenance":"[a-z_]*"' "$1" 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//'; }

PARTS_DIR="$AGENTS_DIR/tests/enforce-off-emergency-provenance"
# shellcheck source=./enforce-off-emergency-provenance/cases-p1-invocation.sh
. "$PARTS_DIR/cases-p1-invocation.sh"
# shellcheck source=./enforce-off-emergency-provenance/cases-p2-p8-lifecycle.sh
. "$PARTS_DIR/cases-p2-p8-lifecycle.sh"
# shellcheck source=./enforce-off-emergency-provenance/cases-p9-p11-integrity.sh
. "$PARTS_DIR/cases-p9-p11-integrity.sh"
# shellcheck source=./enforce-off-emergency-provenance/cases-p12-session-id.sh
. "$PARTS_DIR/cases-p12-session-id.sh"
# shellcheck source=./enforce-off-emergency-provenance/cases-p13-verify-bounds.sh
. "$PARTS_DIR/cases-p13-verify-bounds.sh"

run_P1_invocation
run_P2_stale_marker
run_P3_P4_attribution
run_P5_freshness
run_P6_future
run_P7_corrupt
run_P8_worktree_orth
run_P9_registration
run_P10_forgery
run_P11_bindings
run_P12_session_id
run_P13_verify_bounds

# --- PY: no assertion above was decided by a DEAD recorder -----------------
# assert_absent is only evidence when the process that should have written the
# file actually ran to completion. One ledger, checked once, covers every
# invocation this file made.
assert_eq "PY every recorder invocation exited 0 with the empty-JSON stdout" "" "$RECORDER_FAULTS"

# --- cleanup: leave nothing behind ----------------------------------------
chmod -R u+w "$TMP" 2>/dev/null
rm -r -f "$TMP" 2>/dev/null
if [ -d "$TMP" ]; then fail "PZ sandbox not removed: $TMP"; else pass "PZ sandbox removed - no stray marker or audit files"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
