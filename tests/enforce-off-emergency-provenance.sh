#!/usr/bin/env bash
# tests/enforce-off-emergency-provenance.sh
# Tests: hooks/record-off-skill-invocation.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js
# Tags: off-clearance, emergency-off, provenance, audit, userpromptsubmit, session-marker, security, scope:common, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - That Claude Code actually fires UserPromptSubmit for a typed slash command and
#   delivers `prompt` verbatim. Here the hook is a node subprocess fed synthetic
#   stdin; P9 asserts the registration STATICALLY only. Only a real `claude -p`
#   session proves the event/payload contract - which is the whole basis for the
#   claim "the model cannot trigger this event".
# - Real end-to-end ordering (UserPromptSubmit -> sentinel in the same turn ->
#   workflow-mark). Sections P3-P8 drive the handler directly.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 M-2)
#
# The EMERGENCY OFF sentinel bypasses the Phase1 clearance examination on the
# strength of ONE claim: that a human invoked skills/enforce-workflow-off. Before
# M-2 the audit record read identically whether the user asked for it or the model
# emitted it unprompted, so the audit trail could not answer the only question
# that matters about an escape hatch: WHO OPENED IT. The provenance marker is the
# evidence, and it is trustworthy only if all of the following hold together:
#
#   (a) it is written ONLY on a real user prompt that invokes the skill (P1),
#   (b) it does not survive to vouch for a LATER emission - cleared on the next
#       prompt (P2), consumed on use (P3), and time-bounded (P5/P6),
#   (c) its absence NEVER blocks the override (P4/P5/P7) - provenance is evidence,
#       not a gate; a session whose examiner is broken must still escape, and
#   (d) it cannot be forged by the model through any write tool (P10) - without
#       that, provenance would be self-certifying and worth nothing.
#
# (c) is the one an over-zealous fix would break, and breaking it is worse than
# the original defect: it would turn an audit signal into a lock on the emergency
# exit. Every "unattributed" case below therefore asserts BOTH the provenance
# value AND that the override was still applied.
#
# HERMETICITY: CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR point at a throwaway temp
# dir and every session id is a throwaway ("pv1sid" etc). No real session marker,
# token or audit file is ever created, read or removed.
# ---------------------------------------------------------------------------

set -u

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

TMP=$(make_tmp); WF=$(node_path "$TMP")
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

# submit_prompt <sid> <prompt-text>: one synthetic UserPromptSubmit event.
submit_prompt() {
    local sid="$1" prompt="$2" esc
    esc=$(printf '%s' "$prompt" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"session_id":"%s","prompt":"%s"}' "$sid" "$esc" | \
        (cd "$TMP" && CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
            "$RWT" 15 node "$RECORDER" >/dev/null 2>&1)
}

# iso_at <delta-ms>: ISO timestamp offset from now (node, so macOS `date` quirks
# never enter the picture). The delta is interpolated INTO the script rather than
# passed as an argv element: a leading `-` in `node -e <script> -600000` is parsed
# by node as an option, which silently yields an empty timestamp - and an empty
# `invoked_at` reads as "not fresh", so every freshness case below would have
# passed VACUOUSLY. mk_marker guards that with an explicit check.
iso_at() { "$RWT" 10 node -e "process.stdout.write(new Date(Date.now()+($1)).toISOString())" 2>/dev/null; }

# The payload SHAPE is not restated here. It is produced by the writer's own
# contract function, hooks/lib/off-emergency-provenance.js buildProvenanceMarker()
# (CPR-SSOT) - the same function hooks/record-off-skill-invocation.js calls. The
# earlier hand-rolled `{invoked_at, source}` literal is exactly what went wrong:
# when M-4 bound the marker to a skill identity and a target set, the fixture
# froze the pre-M-4 shape and started asserting a downgrade the reader was RIGHT
# to apply, so a green freshness case would have meant nothing. Building the
# fixture from the SSOT means a future field addition updates these cases for
# free, and P11 below pins the short-shape downgrade DELIBERATELY instead of by
# accident.
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

# --- P1: the marker is written ONLY for a real skill invocation ------------
sid=pv1sid
submit_prompt "$sid" "/enforce-workflow-off PRIVATEPROMPTTEXT"
assert_file "P1 slash command writes the provenance marker" "$(marker_of "$sid")"
body=$(cat "$(marker_of "$sid")" 2>/dev/null)
assert_contains "P1 marker records source=user_skill_invocation" '"source":"user_skill_invocation"' "$body"
assert_contains "P1 marker records invoked_at" '"invoked_at"' "$body"
# The prompt text itself must never be persisted - prompts carry private content
# and the FACT of invocation is the entire signal.
assert_not_contains "P1 marker does not persist the prompt text" 'PRIVATEPROMPTTEXT' "$body"

for variant in "/enforce-workflow-off examiner is broken" "/agents:enforce-workflow-off" "  /enforce-workflow-off"; do
    sid=pv1v; rm -f "$(marker_of "$sid")"
    submit_prompt "$sid" "$variant"
    assert_file "P1 variant writes marker: [$variant]" "$(marker_of "$sid")"
done
rm -f "$(marker_of pv1v)"

# Near-misses must NOT write: prose mentioning the skill is not an invocation, and
# a longer slash command that merely starts with the same letters is a different
# command entirely.
for near in "please enforce-workflow-off for me" "/enforce-workflow-offline" "/enforce-workflow-off-now" "/workflow-init" "read rules/workflow-off.md"; do
    sid=pv1n; rm -f "$(marker_of "$sid")"
    submit_prompt "$sid" "$near"
    assert_absent "P1 near-miss writes no marker: [$near]" "$(marker_of "$sid")"
done

# --- P2: any other prompt clears a stale marker ----------------------------
# The sentinel is emitted in the same turn as the invocation, so a marker that
# survives into the next prompt is stale by construction and must not be able to
# vouch for whatever the model does later.
sid=pv2sid
submit_prompt "$sid" "/enforce-workflow-off"
assert_file "P2 precondition: marker present" "$(marker_of "$sid")"
submit_prompt "$sid" "now please refactor the parser"
assert_absent "P2 an unrelated later prompt clears the stale marker" "$(marker_of "$sid")"

# Clearing is session-scoped: another session's marker must survive.
sid=pv2sid; other=pv2other
submit_prompt "$other" "/enforce-workflow-off"
submit_prompt "$sid" "unrelated prompt"
assert_file "P2 clearing is session-scoped (other session's marker survives)" "$(marker_of "$other")"
rm -f "$(marker_of "$other")"

# --- P3: fresh marker -> attributed, stamped in BOTH records, consumed -----
sid=pv3sid
submit_prompt "$sid" "/enforce-workflow-off"
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'examiner is broken')")
assert_contains "P3 handler reports the sentinel as handled" '"handled":true' "$out"
assert_file "P3 override marker written" "$TMP/$sid.workflow-off"
assert_eq "P3 override marker stamped provenance=user_skill_invocation" "user_skill_invocation" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_file "P3 audit record written" "$(audit_of "$sid")"
audit=$(cat "$(audit_of "$sid")" 2>/dev/null)
assert_json_field "P3 audit record_type=escape_hatch_event" record_type escape_hatch_event "$audit"
assert_json_field "P3 audit stamped provenance=user_skill_invocation" provenance user_skill_invocation "$audit"
assert_absent "P3 provenance marker is CONSUMED (single-use)" "$(marker_of "$sid")"

# --- P4: no marker -> unattributed, and the override STILL applies ---------
# Re-emitting straight after P3 is the exact replay the single-use rule exists to
# stop: the marker is gone, so the second activation must be recorded honestly -
# and must still succeed.
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'second emission, no marker')")
assert_contains "P4 replay still handled" '"handled":true' "$out"
assert_eq "P4 replay without a marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P4 override still applied (no fatal)" '"fatal":[]' "$out"
audit=$(cat "$(audit_of "$sid")" 2>/dev/null)
assert_json_field "P4 audit records the unattributed activation" provenance unattributed "$audit"

sid=pv4sid
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'never invoked the skill')")
assert_file "P4 override applied with no marker ever present" "$TMP/$sid.workflow-off"
assert_eq "P4 provenance=unattributed when no marker ever existed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P4 absence of provenance never gates the escape hatch" '"fatal":[]' "$out"

# --- P5: a marker older than the freshness bound is not evidence -----------
# The bound is belt-and-braces behind P2's clearing: if a marker somehow survives
# (crash, killed session, out-of-band write), age alone must disqualify it - while
# still being consumed so it cannot accumulate.
sid=pv5sid
mk_marker "$sid" -660000
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'stale marker present')")
assert_eq "P5 marker older than the 10-minute bound is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_absent "P5 stale marker is consumed anyway" "$(marker_of "$sid")"
assert_contains "P5 override still applied despite the stale marker" '"fatal":[]' "$out"

# A marker just inside the bound must still count, or the bound would be a
# coin-flip rather than a rule.
sid=pv5fresh
mk_marker "$sid" -60000
run_emergency "$sid" "$(emerg_cmd WORKFLOW 'one minute old marker')" >/dev/null
assert_eq "P5 marker inside the bound is attributed" "user_skill_invocation" "$(provenance_in "$TMP/$sid.workflow-off")"

# --- P6: a future-dated marker cannot buy attribution ----------------------
# Without the lower bound, `invoked_at` far in the future would stay "fresh"
# indefinitely - a single forged timestamp would vouch for every later emission.
sid=pv6sid
mk_marker "$sid" 600000
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'future dated marker')")
assert_eq "P6 future-dated marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P6 override still applied" '"fatal":[]' "$out"

# --- P7: an unreadable marker degrades to unattributed, never to a failure -
sid=pv7sid
printf 'not json at all' > "$(marker_of "$sid")"
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'corrupt marker')")
assert_eq "P7 corrupt marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_absent "P7 corrupt marker is consumed" "$(marker_of "$sid")"
assert_contains "P7 override still applied" '"fatal":[]' "$out"

# --- P8: CPR-ORTH - the WORKTREE emergency gets identical treatment ----------
sid=pv8sid
submit_prompt "$sid" "/enforce-workflow-off"
out=$(run_emergency "$sid" "$(emerg_cmd WORKTREE 'worktree emergency')")
assert_file "P8 worktree emergency writes .worktree-off" "$TMP/$sid.worktree-off"
assert_eq "P8 worktree emergency is provenance-stamped too" "user_skill_invocation" "$(provenance_in "$TMP/$sid.worktree-off")"
assert_absent "P8 worktree emergency consumes the marker" "$(marker_of "$sid")"

# --- P9: registration - an unregistered recorder records nothing ----------
if [ -f "$SETTINGS" ]; then
    reg=$("$RWT" 10 node -e '
const s = require(process.argv[1]);
const hooks = ((s.hooks || {}).UserPromptSubmit || []);
const cmds = hooks.flatMap((h) => (h.hooks || []).map((x) => String(x.command || "")));
process.stdout.write(cmds.some((c) => c.includes("record-off-skill-invocation.js")) ? "yes" : "no");
' "$(node_path "$SETTINGS")" 2>/dev/null)
    assert_eq "P9 settings.json registers the recorder under UserPromptSubmit" "yes" "$reg"
else
    skip "P9 settings.json not found"
fi

# --- P10: the marker must be unforgeable, or provenance self-certifies -----
# This is the load-bearing tie to hooks/block-clearance-token-write.js: if the model
# could Write its own <sid>.off-emergency-invoked, it could manufacture
# user_skill_invocation for an emission the user never asked for, and every
# assertion above would be theatre.
if [ -f "$BLOCK_HOOK" ]; then
    for shape in "bare" "tmp"; do
        target="$WF/forgesid.$MARKER_KIND"; [ "$shape" = "tmp" ] && target="$target.tmp"
        verdict=$(printf '{"tool_name":"Write","session_id":"forgesid","cwd":"%s","tool_input":{"file_path":"%s"}}' "$WF" "$target" | \
            (cd "$TMP" && CLAUDE_WORKFLOW_DIR="$WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 15 node "$BLOCK_HOOK" 2>/dev/null))
        assert_contains "P10 forging the provenance marker via Write is blocked [$shape]" '"decision":"block"' "$verdict"
    done
    verdict=$(printf '{"tool_name":"Bash","session_id":"forgesid","cwd":"%s","tool_input":{"command":"printf x > %s/forgesid.%s"}}' "$WF" "$WF" "$MARKER_KIND" | \
        (cd "$TMP" && CLAUDE_WORKFLOW_DIR="$WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 15 node "$BLOCK_HOOK" 2>/dev/null))
    assert_contains "P10 forging the provenance marker via Bash is blocked" '"decision":"block"' "$verdict"
else
    skip "P10 hooks/block-clearance-token-write.js not found"
fi

# --- P11: the M-4 bindings - a marker only vouches for what it names -------
# The marker used to carry `invoked_at` + `source` and nothing else. Two things
# it therefore could NOT say are now required (hooks/lib/off-emergency-provenance.js
# M-4): WHICH SKILL was invoked, and WHICH OVERRIDE TARGETS that skill authorizes.
# Each case below removes exactly one binding and asserts the downgrade - and
# each is paired with the counterpart assertion that the override still applied,
# because provenance is evidence and never a gate.
#
# P11a is the LEGACY payload, kept deliberately rather than as a side effect of a
# stale fixture: any marker minted before M-4 (or by a writer that regressed to
# the short shape) must be treated as not-provably-user-invoked. Writing it out
# in full is the point - the moment it is built from the SSOT it stops testing
# the legacy shape at all.
sid=pv11legacy
mk_raw_marker "$sid" "$(printf '{"invoked_at":"%s","source":"user_skill_invocation"}' "$(iso_at -1000)")"
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'legacy pre-M-4 marker')")
assert_eq "P11a legacy {invoked_at,source} marker is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_absent "P11a legacy marker is consumed anyway" "$(marker_of "$sid")"
assert_contains "P11a override still applied despite the legacy marker" '"fatal":[]' "$out"

# P11b: the typed slash-command namespace is attacker-choosable prompt text, so
# the marker records a CONSTANT skill name and the reader requires exactly it.
sid=pv11skill
mk_raw_marker "$sid" "$(printf '{"invoked_at":"%s","source":"user_skill_invocation","skill":"attacker-chosen-skill","targets":["workflow","worktree"]}' "$(iso_at -1000)")"
out=$(run_emergency "$sid" "$(emerg_cmd WORKFLOW 'marker names a different skill')")
assert_eq "P11b marker naming a different skill is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.workflow-off")"
assert_contains "P11b override still applied" '"fatal":[]' "$out"

# P11c: provenance for one target must not vouch for the other. A marker that
# authorizes only `workflow` cannot attribute a WORKTREE activation.
sid=pv11target
mk_raw_marker "$sid" "$(printf '{"invoked_at":"%s","source":"user_skill_invocation","skill":"enforce-workflow-off","targets":["workflow"]}' "$(iso_at -1000)")"
out=$(run_emergency "$sid" "$(emerg_cmd WORKTREE 'marker does not authorize worktree')")
assert_eq "P11c marker not authorizing the requested target is unattributed" "unattributed" "$(provenance_in "$TMP/$sid.worktree-off")"
assert_contains "P11c override still applied" '"fatal":[]' "$out"

# P11d: CONTROL. Same WORKTREE emission, but the marker the real writer produces.
# Without it, P11a-P11c could all be passing because nothing is ever attributed.
sid=pv11ok
mk_marker "$sid" -1000
run_emergency "$sid" "$(emerg_cmd WORKTREE 'current-contract marker')" >/dev/null
assert_eq "P11d control: a current-contract marker DOES attribute the same emission" "user_skill_invocation" "$(provenance_in "$TMP/$sid.worktree-off")"

# --- cleanup: leave nothing behind ----------------------------------------
chmod -R u+w "$TMP" 2>/dev/null
rm -r -f "$TMP" 2>/dev/null
if [ -d "$TMP" ]; then fail "PZ sandbox not removed: $TMP"; else pass "PZ sandbox removed - no stray marker or audit files"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
