#!/usr/bin/env bash
# Tests: hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/interpreter-scan.js
# Tags: anti-cheat, off-clearance, clearance-token, pretooluse, unicode, mention-gate, boundary, over-blocking, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook firing on a real host. Covered by tests/TL3-hook-clearance-token-write.sh.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
# End-to-end companion to mention-gate-boundary-cases.sh, which measures the Tier-1 gate
# alone. JS `\w` is ASCII-only, so `(?![\w.-])` cannot reject a multi-byte continuation
# and mentionsProtectedName over-arms; these rows measure what the WHOLE hook then says.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

TMP=$(make_tmp); TN=$(node_path "$TMP")

# A canonical session-id stem, so SID_CANONICAL_*_RE recognises it on shape alone and the
# classifier's verdict does not depend on whether active session ids are observable here.
SID="31a44471-4aac-44cd-8126-7a230f95351c"
TOKEN="$TN/$SID.off-clearance"

# Built from explicit UTF-8 bytes rather than typed literals so no editor or tool can
# silently swap precomposed for decomposed and change what is under test.
B_ACUTE="$SID.off-clearance$(printf '\xc3\xa9')"                                # precomposed e-acute
B_COMB="$SID.off-clearance$(printf '\xcc\x81')"                                 # combining acute on the trailing 'e'
B_CJK="$SID.off-clearance$(printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e').txt"  # CJK continuation
B_FW1="$SID.off-clearance$(printf '\xef\xbc\x91')"                              # fullwidth digit one
B_UNREL="$(printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e')note.txt"              # non-ASCII, no protected stem
B_WORD="$SID.off-clearanceX"      # the ASCII sibling of B_ACUTE / B_FW1
B_HYPH="$SID.off-clearance-note"  # the ASCII sibling reached through the '-' branch

if [ "$HOOK_PRESENT" = "yes" ]; then pass "H0 hook file present"; else fail "H0 hook file MISSING at $HOOK - all cases below are vacuous"; fi

# The contract these rows are written against, stated at the source rather than assumed:
# classifyProtectedPath decides whether a path IS the protected resource, and it returns
# null for every continuation below while returning "token" for the bare stem. A name the
# classifier disowns must stay writable, so `approve` is correct for all of them —
# whatever today's end-to-end verdict happens to be.
probe="$("$RWT" 20 node -e '
const pb = require(process.argv[1] + "/hooks/lib/protected-basenames.js");
const out = [];
for (const t of process.argv.slice(2)) out.push(String(pb.classifyProtectedPath(t, {})));
process.stdout.write(out.join(" "));
' "$_AGENTS_DIR_NODE" "$SID.off-clearance" "$B_ACUTE" "$B_COMB" "$B_CJK" "$B_FW1" "$B_UNREL" "$B_WORD" "$B_HYPH" 2>&1)"
if [ "$probe" = "token null null null null null null null" ]; then
    pass "UB0 the classifier owns the bare stem and disowns every continuation (approve is the correct contract)"
else
    fail "UB0 classifier verdicts changed - want 'token null null null null null null null' got '$probe'; re-derive the contract before trusting the rows below"
fi

# ---- GREEN: routes whose end-to-end verdict already matches that contract -----------
assert_approve "UB-redir-acute redirect into a precomposed-accent continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/$B_ACUTE")")"
assert_approve "UB-redir-comb redirect into a combining-mark continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/$B_COMB")")"
assert_approve "UB-redir-cjk redirect into a CJK continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/$B_CJK")")"
assert_approve "UB-redir-fw redirect into a fullwidth-digit continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/$B_FW1")")"
assert_approve "UB-redir-unrelated redirect into an unrelated non-ASCII filename" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/$B_UNREL")")"
assert_approve "UB-touch-cjk touch on a CJK continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "touch $TN/$B_CJK")")"
assert_approve "UB-write-tool-acute Write tool targeting a precomposed-accent continuation" \
    "$(run_hook "$TN" "$(mk_file_input Write "$TN/$B_ACUTE")")"
assert_approve "UB-write-tool-cjk Write tool targeting a CJK continuation" \
    "$(run_hook "$TN" "$(mk_file_input Write "$TN/$B_CJK")")"

# Positive controls: the real token must still block on the very routes just approved,
# otherwise every approval above would be indistinguishable from a disarmed hook.
assert_block "UB-ctrl-redir the real token still blocks on the redirect route" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $TOKEN")")"
assert_block "UB-ctrl-write-tool the real token still blocks on the Write-tool route" \
    "$(run_hook "$TN" "$(mk_file_input Write "$TOKEN")")"
assert_block "UB-ctrl-interp node -e writing the real token still blocks" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TOKEN','x')\"")")"

# The ASCII siblings on the interpreter route. #1821 fixed exactly these (both block on
# main @HEAD), which is what makes the Unicode rows below a residual rather than a design.
assert_approve "UB-ascii-word node -e writing an ASCII word continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_WORD','x')\"")")"
assert_approve "UB-ascii-hyph node -e writing an ASCII hyphen continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_HYPH','x')\"")")"
# Non-ASCII alone is not what arms the gate - this filename carries no protected stem at
# all and approves on the same route, isolating the boundary as the single variable.
assert_approve "UB-interp-unrelated node -e writing an unrelated non-ASCII filename" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_UNREL','x')\"")")"

# ---- The #1821 over-block on the interpreter route, now closed ----------------------
# These four measured `block` on main @HEAD while UB-ascii-word / UB-ascii-hyph - the same
# call with an ASCII continuation - approved: the interpreter route refused paths the
# classifier disowns, purely because `\w` in the Tier-1 right boundary is ASCII-only.
# The strict boundary in this PR is what makes them approve; they are the regression
# fence for it, so they must never be relaxed back to `block`.
assert_approve "UB-interp-acute node -e writing a precomposed-accent continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_ACUTE','x')\"")")"
assert_approve "UB-interp-comb node -e writing a combining-mark continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_COMB','x')\"")")"
assert_approve "UB-interp-cjk node -e writing a CJK continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_CJK','x')\"")")"
assert_approve "UB-interp-fw node -e writing a fullwidth-digit continuation" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TN/$B_FW1','x')\"")")"

# ---- UBZ: bodyDerefsProtectedViaAssignment(), both directions -----------------------
# Every row above puts the path LITERALLY in the interpreter body. The strict-boundary
# call this PR changed inside bodyDerefsProtectedViaAssignment() is reached only by the
# INDIRECT shape - path in a preceding assignment, stdin-delivered body dereferencing
# process.env - so without these rows that branch keeps no both-direction coverage
# (Pattern 4, skills/_shared/test-design/protection-fix-tests.md).
Z_CLEAN="$TN/zzz.off-clearance"
Z_CONT="$TN/zzz.off-clearance$(printf '\xe6\x97\xa5')"   # same shape, CJK continuation
Z_DEREF="require('fs').writeFileSync(process.env.P,'x')"
Z_RONLY="require('fs').readFileSync(process.env.P)"

# The stem is deliberately NOT session-id shaped: with a canonical stem the argv route
# classifies the assignment VALUE as the protected resource and blocks first, so `block`
# would not be attributable to the predicate under test. `zzz` is mention-yes /
# classify-no, and UBZ-direct below measures that isolation instead of assuming it.
unitz="$("$RWT" 20 node -e '
const ip = require(process.argv[1] + "/hooks/block-clearance-token-write/interpreter-scan.js");
const out = [];
for (const g of process.argv.slice(3)) out.push(String(ip.bodyDerefsProtectedViaAssignment(process.argv[2], g)));
process.stdout.write(out.join(" "));
' "$_AGENTS_DIR_NODE" "process.env.P" "P=$Z_CONT node <<< \"$Z_DEREF\"" "P=$Z_CLEAN node <<< \"$Z_DEREF\"" 2>&1)"
if [ "$unitz" = "false true" ]; then
    pass "UBZ0 bodyDerefsProtectedViaAssignment rejects the continuation, accepts the exact suffix"
else
    fail "UBZ0 want 'false true' got '$unitz' - the strict right boundary stopped discriminating"
fi

assert_approve "UBZ-cont indirect deref of a CJK continuation stays writable" \
    "$(run_hook "$TN" "$(mk_bash_input "P=$Z_CONT node <<< \"$Z_DEREF\"")")"
assert_block "UBZ-clean the identical shape, value ending exactly in the token suffix, blocks" \
    "$(run_hook "$TN" "$(mk_bash_input "P=$Z_CLEAN node <<< \"$Z_DEREF\"")")"
assert_approve "UBZ-readonly the same exact-suffix assignment with a read-only body stays allowed" \
    "$(run_hook "$TN" "$(mk_bash_input "P=$Z_CLEAN node <<< \"$Z_RONLY\"")")"
# Isolation control: this stem is not clearance-bearing, so the direct redirect route
# approves it - which is what makes UBZ-clean's block attributable to the deref branch
# and not to path classification. Its counterpart is UB-ctrl-redir, blocking on the
# same route with a canonical stem.
assert_approve "UBZ-direct the plain redirect onto the same value approves (stem is classify-no)" \
    "$(run_hook "$TN" "$(mk_bash_input "echo x > $Z_CLEAN")")"

rm -r -f "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
