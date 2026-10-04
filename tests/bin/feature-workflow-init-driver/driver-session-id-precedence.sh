#!/bin/bash
# tests/bin/feature-workflow-init-driver/driver-session-id-precedence.sh
# Tests: bin/workflow/workflow-init-driver, bin/resolve-session-id
# Tags: workflow-init, driver, session-id, ssot, scope:issue-specific

# S1-S10 (#2270 H3, #1091) — the driver's own resolveSessionId() fast path names the
# checkpoint and context.md, so it is the WRITE side of a session every hook reads
# back through hooks/workflow-state/session-id.js. Its chain is two steps:
# CLAUDE_CODE_SESSION_ID, then the spawned bin/resolve-session-id bridge.

# TL3 gap: no real Claude Code process supplies the env; the variable is set by
# the harness. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# The stand-in for the spawned SSOT resolver. _lib.sh's default echoes
# $CLAUDE_CODE_SESSION_ID, which is indistinguishable from a fast-path hit; a
# distinct sentinel makes "fast path missed and fell through" an observable outcome.
FALLBACK_SID="wid-sid-fallback"

stub_resolve_sid() {
    printf '#!/bin/bash\necho "%s"\n' "$FALLBACK_SID" > "$CFG/bin/resolve-session-id"
    chmod +x "$CFG/bin/resolve-session-id"
}

# NON_GITHUB=1 is the shortest path that still runs write-context and the
# checkpoint write, so the resolved id is observable with no gh traffic at all.
run_sid_probe() {
    stub_resolve_sid
    export NON_GITHUB=1
    run_driver
}

# The checkpoint lives at <wf>/<sid>.control/wi-checkpoint.json (#2434), so its parent
# directory name IS the id the driver resolved (checkpoint.js checkpointPath).
sid_from_checkpoint() {
    local p
    p="$(get_kv CHECKPOINT)" || true
    case "$p" in
        */wi-checkpoint.json) p="${p%/wi-checkpoint.json}"; p="${p##*/}"; printf '%s' "${p%.control}" ;;
        *) printf '<unexpected:%s>' "$p" ;;
    esac
}

assert_sid() {  # <label> <want>
    local got
    got="$(sid_from_checkpoint)"
    if [ "$got" = "$2" ]; then
        pass "$1"
    else
        fail "$1: want sid=$2 got '$got' (ACTION=$(get_kv ACTION) rc=$DRIVER_RC)"
    fi
}

assert_context_for() {  # <label> <sid>
    if [ -f "$PLANS/$2-context.md" ]; then
        pass "$1"
    else
        fail "$1: $2-context.md absent; plans dir holds: $(ls "$PLANS" 2>/dev/null | tr '\n' ' ')"
    fi
}

# --- S1: the canonical variable is set ----------------------------------------
# The fast path must recognise it rather than fall through to a subprocess, and
# the checkpoint and context.md must both land under that id.
setup_case wid-s1
export CLAUDE_CODE_SESSION_ID=wid-sid-canon
run_sid_probe
assert_kv "S1: the driver completes on the non-GitHub path" ACTION done
assert_sid "S1: CLAUDE_CODE_SESSION_ID resolves the session" wid-sid-canon
assert_context_for "S1: context.md is written under that same id" wid-sid-canon
teardown_case

# --- S5: the variable is not set ----------------------------------------------
# The negative control for S1: with no env id the driver must fall through to the
# spawned SSOT resolver. Without it, a probe that always reported the fallback
# sentinel would let S1 pass on the wrong evidence.
setup_case wid-s5
unset CLAUDE_CODE_SESSION_ID
run_sid_probe
assert_sid "S5: no env session id falls through to bin/resolve-session-id" "$FALLBACK_SID"
teardown_case

# --- S7: the variable is unresolvable -----------------------------------------
# Unset is not the only way to be unresolvable. A value that fails validSid() must
# reach the spawned SSOT resolver rather than being used raw or collapsing to the
# timestamp.
setup_case wid-s7
export CLAUDE_CODE_SESSION_ID='wid sid spaced'
run_sid_probe
assert_sid "S7: unresolvable variable -> delegate to bin/resolve-session-id" "$FALLBACK_SID"
teardown_case

# --- S8: validSid boundary — surrounding whitespace ---------------------------
# validSid() trims before matching, so a padded value is VALID; the id that lands
# in the filename is the trimmed form, and no delegation happens.
setup_case wid-s8
export CLAUDE_CODE_SESSION_ID='  wid-sid-canon  '
run_sid_probe
assert_sid "S8: padded CLAUDE_CODE_SESSION_ID is trimmed and resolves" wid-sid-canon
teardown_case

# --- S9: validSid boundary — one character outside the alphabet ---------------
# The reject side of S8 (CPR-ORTH). A dot is not in ^[A-Za-z0-9_-]+$, so the value
# falls through "as if it were unset" to the spawned resolver, never used raw.
setup_case wid-s9
export CLAUDE_CODE_SESSION_ID='wid.sid.canon'
run_sid_probe
assert_sid "S9: invalid CLAUDE_CODE_SESSION_ID falls through to bin/resolve-session-id" "$FALLBACK_SID"
teardown_case

# --- S10 [security, CWE-22]: traversal payload in the canonical variable -------
# The driver-side mirror of Case AE in cases-2270-envfile.sh: the same untrusted
# id, arriving through the env instead of a file. The sid is a path segment of the
# checkpoint and context.md, so a traversal payload must be rejected by validSid()
# before path.join() sees it — never merely escaped, never written outside PLANS.
setup_case wid-s10
export CLAUDE_CODE_SESSION_ID='../../../../wid-evil'
run_sid_probe
assert_sid "S10: traversal payload is rejected, resolution delegates instead" "$FALLBACK_SID"
CKPT_PATH="$(get_kv CHECKPOINT)" || true
case "$CKPT_PATH" in
    *..*|*wid-evil*) fail "S10: traversal payload reached the checkpoint path: '$CKPT_PATH'" ;;
    *) pass "S10: no traversal segment in the checkpoint path" ;;
esac
ESCAPED="$(find "$ROOT_TMP" -name '*wid-evil*' 2>/dev/null | head -n 3)"
if [ -z "$ESCAPED" ]; then
    pass "S10: nothing named after the payload was written anywhere under the fixture root"
else
    fail "S10: payload-named artifacts were written: $ESCAPED"
fi
teardown_case

finish
