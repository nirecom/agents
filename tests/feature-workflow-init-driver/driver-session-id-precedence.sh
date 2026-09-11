#!/bin/bash
# tests/feature-workflow-init-driver/driver-session-id-precedence.sh
# Tests: bin/workflow/workflow-init-driver, bin/resolve-session-id
# Tags: workflow-init, driver, session-id, ssot, scope:issue-specific

# S1-S10 (#2270 H3) — the driver's own resolveSessionId() fast path names the
# checkpoint and context.md, so it is the WRITE side of a session every hook reads
# back through hooks/workflow-state/session-id.js. A fast path consulting only the
# legacy CLAUDE_SESSION_ID splits the two apart in silence.

# TL3 gap: no real Claude Code process supplies the env; both variables are set by
# the harness. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# The stand-in for the spawned SSOT resolver. _lib.sh's default echoes
# $CLAUDE_SESSION_ID, which is indistinguishable from a fast-path hit; a distinct
# sentinel makes "fast path missed and fell through" an observable outcome.
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

# The checkpoint is named <sid>-wi-checkpoint.json, so its basename IS the id the
# driver resolved (bin/workflow/lib/workflow-init/checkpoint.js checkpointPath).
sid_from_checkpoint() {
    local p
    p="$(get_kv CHECKPOINT)" || true
    p="${p##*/}"
    printf '%s' "${p%-wi-checkpoint.json}"
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

# --- S1: only the canonical variable is set -----------------------------------
# The non-native-LLM harness that exports CLAUDE_CODE_SESSION_ID and nothing else.
# The fast path must recognise it rather than fall through to a subprocess.
setup_case wid-s1
unset CLAUDE_SESSION_ID
export CLAUDE_CODE_SESSION_ID=wid-sid-canon
run_sid_probe
assert_kv "S1: the driver completes on the non-GitHub path" ACTION done
assert_sid "S1: CLAUDE_CODE_SESSION_ID alone resolves the session" wid-sid-canon
teardown_case

# --- S2: both variables set, same value ---------------------------------------
# The native Claude Code shape. Adding the canonical read must not disturb it.
setup_case wid-sid-both
export CLAUDE_CODE_SESSION_ID=wid-sid-both
run_sid_probe
assert_sid "S2: agreeing variables resolve to their shared value" wid-sid-both
assert_context_for "S2: context.md is written under that same id" wid-sid-both
teardown_case

# --- S3: both set and DIFFERENT -----------------------------------------------
# The defect proper. CLAUDE_CODE_SESSION_ID is the canonical variable and the one
# hooks prioritise, so the driver's write side has to agree with it; picking the
# legacy value splits checkpoint/context.md off from the hooks' state file.
setup_case wid-sid-legacy
export CLAUDE_CODE_SESSION_ID=wid-sid-canon
run_sid_probe
assert_sid "S3: the canonical variable outranks the legacy one" wid-sid-canon
assert_context_for "S3: context.md follows the canonical id" wid-sid-canon
teardown_case

# --- S4: only the legacy variable is set --------------------------------------
# Regression guard for #2270's core case: demoting CLAUDE_SESSION_ID must not
# remove it. A session that exports only the legacy name still resolves by it.
setup_case wid-sid-legacy-only
export CLAUDE_SESSION_ID=wid-sid-legacy
run_sid_probe
assert_sid "S4: legacy CLAUDE_SESSION_ID alone still resolves" wid-sid-legacy
teardown_case

# --- S5: neither variable is set ----------------------------------------------
# The negative control for S1-S4: with no env id the driver must fall through to
# the spawned SSOT resolver. Without it, a probe that always reported the fallback
# sentinel would let S1 and S3 pass on the wrong evidence.
setup_case wid-s5
unset CLAUDE_SESSION_ID
run_sid_probe
assert_sid "S5: no env session id falls through to bin/resolve-session-id" "$FALLBACK_SID"
teardown_case

# --- S6 [RED until H3]: legacy unresolvable, canonical resolvable -------------
# The delegation arm's near miss. "Both unresolvable" is the ONLY licence to spawn
# bin/resolve-session-id, so a legacy value that validSid() rejects must hand the
# decision to CLAUDE_CODE_SESSION_ID, not to a subprocess: the sentinel appearing
# here would mean the fast path skipped a variable it could already read.
setup_case wid-s6
export CLAUDE_SESSION_ID='wid.sid.dotted'
export CLAUDE_CODE_SESSION_ID=wid-sid-canon
run_sid_probe
assert_sid "S6: invalid legacy + valid canonical resolves without delegating" wid-sid-canon
teardown_case

# --- S7: BOTH unresolvable ----------------------------------------------------
# The delegation arm proper, and the half S5 cannot show: unset is not the only
# way to be unresolvable. Two values that both fail validSid() must reach the
# spawned SSOT resolver rather than being used raw or collapsing to the timestamp.
setup_case wid-s7
export CLAUDE_SESSION_ID='wid.sid.dotted'
export CLAUDE_CODE_SESSION_ID='wid sid spaced'
run_sid_probe
assert_sid "S7: both variables unresolvable -> delegate to bin/resolve-session-id" "$FALLBACK_SID"
teardown_case

# --- S8 [RED until H3]: validSid boundary — surrounding whitespace ------------
# validSid() trims before matching, so a padded canonical value is VALID and must
# win over a valid legacy one; the id that lands in the filename is the trimmed
# form. A driver that matched the raw string would silently demote it to S4.
setup_case wid-sid-legacy
export CLAUDE_CODE_SESSION_ID='  wid-sid-canon  '
run_sid_probe
assert_sid "S8: padded CLAUDE_CODE_SESSION_ID is trimmed, then outranks the legacy one" wid-sid-canon
teardown_case

# --- S9: validSid boundary — one character outside the alphabet ---------------
# The reject side of S8 (CPR-ORTH). A dot is not in ^[A-Za-z0-9_-]+$, so the
# canonical value falls through "as if it were unset" — to the legacy variable,
# never to the raw value and never past a still-readable source to the spawn.
setup_case wid-sid-legacy
export CLAUDE_CODE_SESSION_ID='wid.sid.canon'
run_sid_probe
assert_sid "S9: invalid CLAUDE_CODE_SESSION_ID falls through to the legacy one" wid-sid-legacy
teardown_case

# --- S10 [security, CWE-22]: traversal payload in the canonical variable -------
# The driver-side mirror of Case AE in cases-2270-envfile.sh: the same untrusted
# id, arriving through the env instead of a file. The sid is a path segment of the
# checkpoint and context.md, so a traversal payload must be rejected by validSid()
# before path.join() sees it — never merely escaped, never written outside PLANS.
setup_case wid-s10
unset CLAUDE_SESSION_ID
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
