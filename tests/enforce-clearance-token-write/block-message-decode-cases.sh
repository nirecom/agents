#!/usr/bin/env bash
# tests/enforce-clearance-token-write/block-message-decode-cases.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/lib/off-clearance-invocation.js
# Tags: anti-cheat, off-clearance, clearance-token, block-message, invitation, spelling, dispatch, end-to-end, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: whether a real Claude Code session renders `reason` back to the model intact;
# see tests/TL3-hook-clearance-token-write.sh, gap-checked by bin/check-verification-gate.sh.

set -u

# #1821: the invitation is the ONLY way out of a block, and it only helps if it survives
# the trip through the real hook. Sibling suites assert on the dispatch CONSTANTS; nothing
# decoded a real blocked RESPONSE. D* drives real tool inputs through the entrypoint,
# JSON-decodes `reason`, and checks the SSOT invocation string against the same derived
# predicate the shipped code uses — `includes("request-off")` — never a hardcoded list.

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

if [ "$HOOK_PRESENT" = "yes" ]; then
    pass "D0 the hook entrypoint is present"
else
    fail "D0 $HOOK missing — every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"
MARKER="$TN/wsid.workflow-off"

# decode <expected-const-name> <raw stdout> -> "<match>|<advertises>|<carries-invitation>"
#   match:       exact | prefixed (UNPARSED_PREFIX ahead of it) | no | NO-SUCH-CONSTANT
#   advertises:  the SHIPPED predicate applied to that constant
#   carries:     whether the DECODED reason contains OFF_CLEARANCE_INVOCATION verbatim
decode() {
    "$RWT" 12 node -e '
const A = process.argv[1], want = process.argv[2], raw = process.argv[3];
const d = require(A + "/hooks/block-clearance-token-write/dispatch.js");
const inv = String(require(A + "/hooks/lib/off-clearance-invocation.js").OFF_CLEARANCE_INVOCATION || "");
let o; try { o = JSON.parse(raw); } catch (e) { process.stdout.write("UNPARSEABLE-JSON|?|?"); process.exit(0); }
const r = String(o.reason || "");
const c = d[want];
let match = "no";
if (typeof c !== "string") match = "NO-SUCH-CONSTANT";
else if (r === c) match = "exact";
else if (r.endsWith(c)) match = "prefixed";
const advertises = typeof c === "string" && c.includes("request-off");
process.stdout.write(match + "|" + advertises + "|" + (inv !== "" && r.includes(inv)));
' "$_AGENTS_DIR_NODE" "$1" "$2" 2>/dev/null
}

# probe <label> <expected-const> <expected-match> <hook-input-json>
probe() {
    local label="$1" want="$2" wmatch="$3" input="$4" raw out dec match adv has
    raw="$(run_hook "$TN" "$input")"
    if [ "$(classify "$raw")" != "block" ]; then
        fail "$label-a the hook did not block (got $(classify "$raw")) — the response carries no reason to decode"
        fail "$label-b invitation check unreachable: nothing was blocked"
        return
    fi
    out="$(hook_out "$raw")"
    dec="$(decode "$want" "$out")"
    match="${dec%%|*}"; adv="$(printf '%s' "$dec" | cut -d'|' -f2)"; has="$(printf '%s' "$dec" | cut -d'|' -f3)"
    if [ "$match" = "$wmatch" ]; then
        pass "$label-a blocked, and the decoded reason is the $wmatch form of $want"
    else
        fail "$label-a decoded reason is '$match' against $want, want '$wmatch'  [raw=$(printf '%.200s' "$out")]"
    fi
    # The SAME assertion in both directions (CPR-ORTH): a message that advertises the minter
    # MUST carry the runnable string, and one that does not MUST NOT — a message that offers
    # no way out while claiming to is as broken as a missing invitation.
    if [ "$has" = "$adv" ]; then
        if [ "$adv" = "true" ]; then
            pass "$label-b the decoded reason carries the SSOT invocation verbatim (this flavor advertises the minter)"
        else
            pass "$label-b the decoded reason carries no invocation, matching this flavor's non-advertising message"
        fi
    else
        fail "$label-b advertises=$adv but the decoded reason carries-invocation=$has — the invitation was lost or leaked in transit"
    fi
}

echo "=== D-pre: the derived predicate actually discriminates ==="
# Without both an advertising and a non-advertising constant, every -b case below would be
# asserting the same constant answer and the predicate would be decoration.
SPREAD="$("$RWT" 12 node -e '
const d = require(process.argv[1] + "/hooks/block-clearance-token-write/dispatch.js");
const names = Object.keys(d).filter((k) => /_BLOCK_MSG$/.test(k) && typeof d[k] === "string");
const yes = names.filter((n) => d[n].includes("request-off"));
process.stdout.write(yes.length + "/" + names.length);
' "$_AGENTS_DIR_NODE" 2>/dev/null)"
ADV_N="${SPREAD%%/*}"; ALL_N="${SPREAD##*/}"
if [ -n "$ALL_N" ] && [ "$ALL_N" -gt 1 ] && [ "$ADV_N" -gt 0 ] && [ "$ADV_N" -lt "$ALL_N" ]; then
    pass "D-pre the block messages split into advertising and non-advertising ($SPREAD advertise the minter)"
else
    fail "D-pre the advertising split is degenerate ($SPREAD) — every -b case below asserts the same constant answer"
fi

echo ""
echo "=== D1-D7: real blocked responses, decoded ==="
probe "D1 token write via Bash"     TOKEN_BLOCK_MSG            exact    "$(mk_bash_input "echo forged > $TOKEN")"
probe "D2 workflow-dir glob"        WORKFLOW_GLOB_BLOCK_MSG    exact    "$(mk_bash_input "rm -f $TN/*")"
probe "D3 workflow-dir dynamic arg" WORKFLOW_DYNAMIC_BLOCK_MSG exact    "$(mk_bash_input_cwd 'touch "note $UNSET_VAR file"' "$TN")"
probe "D4 unparsed token command"   TOKEN_BLOCK_MSG            prefixed "$(mk_bash_input "echo \"note $TOKEN")"
probe "D5 token write via Write"    TOKEN_BLOCK_MSG            exact    "$(mk_file_input Write "$TOKEN")"
# D6/D7 are the non-advertising counterparts: MARKER_BLOCK_MSG deliberately points at the
# sentinel procedure, not at the minter, so they pin the OTHER branch of the -b assertion.
probe "D6 session-override marker"  MARKER_BLOCK_MSG           exact    "$(mk_bash_input "echo x > $MARKER")"
probe "D7 unparsed marker command"  MARKER_BLOCK_MSG           prefixed "$(mk_bash_input "echo \"note $MARKER")"

rm -r -f "$TMP" 2>/dev/null || true
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
