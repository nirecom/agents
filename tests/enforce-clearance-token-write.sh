#!/usr/bin/env bash
# tests/enforce-clearance-token-write.sh
# Tests: hooks/block-clearance-token-write.js
# Tags: anti-cheat, off-clearance, clearance-token, pretooluse, block-write, vector2, classifier, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap: the hook firing on a real host — this file invokes the classifier directly, so
# N3 only asserts PreToolUse registration statically; a real turn proves it
# (tests/TL3-hook-clearance-token-write.sh), gap-checked by bin/check-verification-gate.sh.
# #1608 anti-cheat (best-effort): block direct writes to <workflowDir>/<sid>.off-clearance,
# mirroring block-memory-direct.js plus a vector2 interpreter-body heuristic. The
# issue-provenance / .session-transcript suffixes are unreserved since #1763 (section R).
# KNOWN-BYPASS: dynamic paths, editing the hook — Phase2 human approval is the TRUE gate.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
OLD_HOOK="$AGENTS_DIR/hooks/block-off-clearance-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# Counters, run_hook, the input builders and the STRICT verdict classifier all live in
# the shared harness. assert_approve there demands rc=0 AND an explicit approve decision:
# the local copy this replaced scored "no block string in stdout" as approve, so a crash,
# a timeout or a garbled payload would have been recorded as a PASS (#1821 cycle-2 C9).
# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

echo "=== .off-clearance is the one reserved clearance token ==="
# --- block: Bash redirect / tee / cp to token path ---
assert_block "B1 redirect > token"        "$(run_hook "$TN" "$(mk_bash_input "echo x > $TOKEN")")"
assert_block "B2 tee token"               "$(run_hook "$TN" "$(mk_bash_input "echo x | tee $TOKEN")")"
assert_block "B3 cp to token"             "$(run_hook "$TN" "$(mk_bash_input "cp /etc/hosts $TOKEN")")"

# --- block: Write / Edit tool on token path ---
assert_block "B4 Write token file_path"   "$(run_hook "$TN" "$(mk_file_input Write "$TOKEN")")"
assert_block "B5 Edit token file_path"    "$(run_hook "$TN" "$(mk_file_input Edit "$TOKEN")")"

# --- block: vector2 interpreter-body heuristic (node -e writing into token dir) ---
V2CMD="node -e \"require('fs').writeFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.off-clearance','forged')\""
assert_block "B6 vector2 node -e .off-clearance" "$(run_hook "$TN" "$(mk_bash_input "$V2CMD")")"

# --- block: DELETE re-arms an already-used clearance, so it is as dangerous as write ---
assert_block "B7 rm token"                "$(run_hook "$TN" "$(mk_bash_input "rm -f $TOKEN")")"
assert_block "B8 rm -rf token"            "$(run_hook "$TN" "$(mk_bash_input "rm -rf $TOKEN")")"
assert_block "B9 mv token away"           "$(run_hook "$TN" "$(mk_bash_input "mv $TOKEN $TN/stash.bak")")"

# --- approve: sanctioned unrelated paths (CPR-ORTH counterparts) ---
assert_approve "A1 redirect > unrelated file"  "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/notes.txt")")"
assert_approve "A2 Write unrelated file_path"  "$(run_hook "$TN" "$(mk_file_input Write "$TN/other.json")")"
assert_approve "A3 harmless node -e (no token)" "$(run_hook "$TN" "$(mk_bash_input "node -e \"console.log(1+1)\"")")"
assert_approve "A4 rm unrelated file"          "$(run_hook "$TN" "$(mk_bash_input "rm -f $TN/scratch.txt")")"
assert_approve "A5 Write session state json"   "$(run_hook "$TN" "$(mk_file_input Write "$TN/wsid.json")")"
assert_approve "A6 harmless python -c"         "$(run_hook "$TN" "$(mk_bash_input "python -c \"print(2)\"")")"

echo ""
echo "=== R: the provenance-era suffixes are no longer reserved (#1763 removal) ==="
# The mechanism these names belonged to is gone. Blocking them now would be a reserved
# name protecting a token that can never be minted — pure over-blocking, and a false
# signal to anyone reading the guard that provenance is still enforced somewhere.
for SUF in .issue-provenance .issue-provenance.tmp .issue-provenance-consumed .session-transcript; do
    P="$TN/wsid$SUF"
    assert_approve "R-write($SUF) Write file_path" "$(run_hook "$TN" "$(mk_file_input Write "$P")")"
    assert_approve "R-write($SUF) redirect >"      "$(run_hook "$TN" "$(mk_bash_input "echo plain > $P")")"
    assert_approve "R-del($SUF) rm"                "$(run_hook "$TN" "$(mk_bash_input "rm -f $P")")"
done
V2A="node -e \"require('fs').writeFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.issue-provenance','x')\""
assert_approve "R-v2 node -e writes .issue-provenance" "$(run_hook "$TN" "$(mk_bash_input "$V2A")")"
V2B="python -c \"import os; os.remove(os.environ['CLAUDE_WORKFLOW_DIR'] + '/wsid.issue-provenance-consumed')\""
assert_approve "R-v2 python -c unlinks the old record"  "$(run_hook "$TN" "$(mk_bash_input "$V2B")")"

echo ""
echo "=== negative assertions: the protected file is byte-for-byte unchanged ==="
# Asserting only the classifier's verdict leaves the actual property untested. The
# guard runs as PreToolUse, i.e. BEFORE the tool executes, so the only correct
# observable is that nothing about the protected file moved: same bytes, same size,
# still present. A guard that read-modified-wrote (normalising, truncating, or
# "cleaning up") a token while inspecting it would pass every assert_block above.
FIXDIR=$(make_tmp); FIXN=$(node_path "$FIXDIR")
printf '%s' '{"cleared":true}' > "$FIXDIR/wsid.off-clearance"

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

F="$FIXDIR/wsid.off-clearance"; P="$FIXN/wsid.off-clearance"
BEFORE=$(sha_of "$F"); SZ_BEFORE=$(wc -c < "$F" | tr -d ' ')
# Exercise every route at once against the same real file.
run_hook "$FIXN" "$(mk_file_input Write "$P")" >/dev/null
run_hook "$FIXN" "$(mk_file_input Edit  "$P")" >/dev/null
run_hook "$FIXN" "$(mk_bash_input "echo forged > $P")" >/dev/null
run_hook "$FIXN" "$(mk_bash_input "rm -f $P")" >/dev/null
run_hook "$FIXN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$P','forged')\"")" >/dev/null
if [ ! -f "$F" ]; then
    fail "NEG the protected file was removed while the guard inspected it"
elif [ "$(sha_of "$F")" != "$BEFORE" ]; then
    fail "NEG the protected file's contents changed (guard must be side-effect free)"
elif [ "$(wc -c < "$F" | tr -d ' ')" != "$SZ_BEFORE" ]; then
    fail "NEG the protected file's size changed"
else
    pass "NEG unchanged byte-for-byte after every attempted route"
fi

echo ""
echo "=== attack scenarios: routes that a naive substring match would miss ==="
# These are all forms that reach the same path without spelling it the obvious way.
# The suffix is still literally present in the command, so the guard is expected to
# catch them — this is the boundary of what a lexical guard can reasonably cover.
assert_block "ATK append >> token"          "$(run_hook "$FIXN" "$(mk_bash_input "echo forged >> $P")")"
assert_block "ATK truncate -s 0"            "$(run_hook "$FIXN" "$(mk_bash_input "truncate -s 0 $P")")"
assert_block "ATK dd of= token"             "$(run_hook "$FIXN" "$(mk_bash_input "dd if=/dev/null of=$P")")"
assert_block "ATK sed -i in place"          "$(run_hook "$FIXN" "$(mk_bash_input "sed -i 's/true/false/' $P")")"
assert_block "ATK command prefix bypass"    "$(run_hook "$FIXN" "$(mk_bash_input "command rm -f $P")")"
assert_block "ATK env prefix bypass"        "$(run_hook "$FIXN" "$(mk_bash_input "env -i rm -f $P")")"
assert_block "ATK chained after ;"          "$(run_hook "$FIXN" "$(mk_bash_input "echo hi ; rm -f $P")")"
assert_block "ATK chained after &&"         "$(run_hook "$FIXN" "$(mk_bash_input "true && echo forged > $P")")"
assert_block "ATK subshell"                 "$(run_hook "$FIXN" "$(mk_bash_input "( rm -f $P )")")"
assert_block "ATK cat heredoc into token"   "$(run_hook "$FIXN" "$(mk_bash_input "cat <<EOF > $P
forged
EOF")")"

echo ""
echo "=== KNOWN-BYPASS routes: pinned as unblocked-but-harmless, not silently ignored ==="
# Per the accepted trust model above, dynamic construction is NOT detectable. Testing
# it matters anyway: the guard must neither crash nor mutate anything when it cannot
# decide, so that the real gate (Phase 2 human approval + audit) still sees a
# consistent filesystem. Recording these explicitly also stops a future reader from
# assuming they are covered.
KB_BEFORE=$(sha_of "$F")
KB_CRASH=0
for CMD in \
    'S=".off-clear"; T="ance"; rm -f "$CLAUDE_WORKFLOW_DIR/wsid$S$T"' \
    'rm -f "$CLAUDE_WORKFLOW_DIR"/wsid.off-clear*' \
    'eval "$(printf %s cm0gLWYgY29ucw== | base64 -d)"' \
    'perl -e "unlink glob qq{$ENV{CLAUDE_WORKFLOW_DIR}/wsid.off-clear*}"' \
    ; do
    KB_V=$(classify "$(run_hook "$FIXN" "$(mk_bash_input "$CMD")")")
    # "Answered at all" is the property here — block and approve are both acceptable
    # verdicts for an undecidable command. Anything else (a crash, a timeout, empty or
    # unparseable output) means the guard failed to produce one, which is the bug.
    case "$KB_V" in
        block|approve) ;;
        hook-absent)   ;;
        *) KB_CRASH=$((KB_CRASH + 1)); echo "  (KB1 detail: '$CMD' -> $KB_V)" ;;
    esac
done
if [ "$HOOK_PRESENT" != "yes" ]; then
    fail "KB1 guard survives undecidable commands  [RED-EXPECTED: block-clearance-token-write.js not yet created]"
    fail "KB2 undecidable commands leave the token untouched  [RED-EXPECTED: block-clearance-token-write.js not yet created]"
else
    [ "$KB_CRASH" -eq 0 ] && pass "KB1 guard survives undecidable commands (no crash, always answers)" \
        || fail "KB1 the guard produced no verdict for $KB_CRASH undecidable command(s)"
    [ "$(sha_of "$F")" = "$KB_BEFORE" ] && pass "KB2 undecidable commands leave the token untouched" \
        || fail "KB2 the clearance token changed while classifying an undecidable command"
fi

rm -rf "$FIXDIR" 2>/dev/null || true

echo ""
echo "=== the rename left nothing behind, and the hook is still registered ==="
if [ -f "$OLD_HOOK" ]; then
    fail "N1 old hooks/block-off-clearance-write.js still present after the rename"
else
    pass "N1 old hook file removed by the rename"
fi
if grep -qF 'block-off-clearance-write' "$AGENTS_DIR/settings.json" 2>/dev/null; then
    fail "N2 settings.json still references the old hook name"
else
    pass "N2 settings.json no longer references the old hook name"
fi
# The whole file exercises the classifier directly, so without this the guard could be
# unregistered — never reached on a real turn — and every assertion above would still pass.
if grep -qF 'block-clearance-token-write' "$AGENTS_DIR/settings.json" 2>/dev/null; then
    pass "N3 settings.json registers block-clearance-token-write.js"
else
    fail "N3 settings.json does not register block-clearance-token-write.js — the guard would never fire"
fi

echo ""
echo "=== #1821: the sanctioned minter invocation must not be blocked by its own guard ==="
# comment-5 reproduction matrix. The mention gate is a bare substring match today, so a
# script whose NAME merely contains the suffix (the minter this hook itself tells the
# user to run) arms it. A-off1..A-off4 use the re-spelled entrypoint, A-off5b the old
# one; both must be approved, and both are the same class of false positive (CPR-E2C).
assert_approve 'A-off1 new spelling, quoted' \
    "$(run_hook "$TN" "$(mk_bash_input 'bash "$AGENTS_CONFIG_DIR/bin/request-off-mode-clearance" --target workflow --category x --detail y')")"
assert_approve 'A-off2 new spelling, unquoted' \
    "$(run_hook "$TN" "$(mk_bash_input 'bash $AGENTS_CONFIG_DIR/bin/request-off-mode-clearance --target workflow --category x --detail y')")"
assert_approve 'A-off3 new spelling via $FOO assignment' \
    "$(run_hook "$TN" "$(mk_bash_input 'F="$AGENTS_CONFIG_DIR/bin/request-off-mode-clearance"; bash "$F" --target workflow --category x --detail y')")"
assert_approve 'A-off4 new spelling after an echo segment' \
    "$(run_hook "$TN" "$(mk_bash_input 'echo running; bash "$AGENTS_CONFIG_DIR/bin/request-off-mode-clearance" --target workflow --category x --detail y')")"

assert_approve 'A-off5b1 old spelling, quoted' \
    "$(run_hook "$TN" "$(mk_bash_input 'bash "$AGENTS_CONFIG_DIR/bin/request-off-clearance" --target workflow --category x --detail y')")"
assert_approve 'A-off5b2 old spelling, unquoted' \
    "$(run_hook "$TN" "$(mk_bash_input 'bash $AGENTS_CONFIG_DIR/bin/request-off-clearance --target workflow --category x --detail y')")"
assert_approve 'A-off5b3 old spelling via $FOO assignment' \
    "$(run_hook "$TN" "$(mk_bash_input 'F="$AGENTS_CONFIG_DIR/bin/request-off-clearance"; bash "$F" --target workflow --category x --detail y')")"
assert_approve 'A-off5b4 old spelling after an echo segment' \
    "$(run_hook "$TN" "$(mk_bash_input 'echo running; bash "$AGENTS_CONFIG_DIR/bin/request-off-clearance" --target workflow --category x --detail y')")"

# The documented workaround (absolute path, no $AGENTS_CONFIG_DIR) must keep working.
assert_approve 'A-off5 absolute-path workaround' \
    "$(run_hook "$TN" "$(mk_bash_input 'bash "/abs/bin/request-off-clearance" --target workflow --category x --detail y')")"

# A-off6: the block MESSAGE itself names the invitation, so pasting or echoing the
# guard's own remediation text must not be blocked by the guard (issue comment 5 asks
# for this explicitly). Asserted against the classifier directly so the assertion is
# about the message CONSTANT, not about a hand-copied duplicate of it. Env pinned exactly
# as run_hook pins it (rules/test/fixture-isolation.md): both dirs dual-pinned at the
# fixture, both inherited session ids dropped, and NO cwd — mk_bash_input sends none
# either, so this reads the same context a real Bash turn reaches the classifier with.
# All four exported messages are covered in the derived S1b matrix of the sibling
# spelling-ssot-static.sh; this row keeps the parent suite's own regression anchor.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
A_OFF6="$(CLAUDE_WORKFLOW_DIR="$TN" WORKFLOW_PLANS_DIR="$TN/plans" "$RWT" 12 node -e "const d=require(process.argv[1]+'/hooks/block-clearance-token-write/dispatch.js');const {bashHitsProtected}=require(process.argv[1]+'/hooks/block-clearance-token-write/bash-scan.js');process.stdout.write(String(bashHitsProtected(d.TOKEN_BLOCK_MSG,{})))" "$_AGENTS_DIR_NODE" 2>/dev/null)"
if [ "$A_OFF6" = "null" ]; then
    pass "A-off6 TOKEN_BLOCK_MSG is not itself blocked (got null)"
else
    fail "A-off6 the guard blocks its own remediation text (bashHitsProtected -> ${A_OFF6:-<no output>})"
fi

# B-off1: positive control for the narrowing above. Narrowing the mention gate must not
# stop a REAL token write from blocking; if this ever flips, the fix went too far.
assert_block "B-off1a redirect into the live token"  "$(run_hook "$TN" "$(mk_bash_input "echo forged > $TOKEN")")"
assert_block "B-off1b node -e writeFileSync literal token" \
    "$(run_hook "$TN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$TOKEN','forged')\"")")"

rm -rf "$TMP" 2>/dev/null || true

# --- CI wiring (#1821 cycle-2 C3): tests/run-all.sh globs tests/*.sh (TOP LEVEL only),
# so every file under tests/enforce-clearance-token-write/ is dead code in CI until it
# is reached from here. parser-cases.sh was already unwired before this change; it is
# folded in with the other two rather than left as a half-fixed instance of the same
# defect (CPR-E2C/CPR-E2E).
SECTION_DIR="$AGENTS_DIR/tests/enforce-clearance-token-write"
# shellcheck source=tests/lib/section-runner.sh
. "$AGENTS_DIR/tests/lib/section-runner.sh"
run_section "parser-cases.sh" 120
run_section "read-only-allowlist-cases.sh" 240
run_section "flag-cluster-coverage-cases.sh" 240
run_section "mention-gate-boundary-cases.sh" 90
run_section "mention-gate-strict-boundary-cases.sh" 90
run_section "clearance-stem-observation-cases.sh" 180
run_section "unicode-boundary-e2e-cases.sh" 180
run_section "interpreter-language-scope-cases.sh" 300
run_section "consumer-allow-direction-cases.sh" 180
run_section "spelling-ssot-static.sh" 120
run_section "wrapper-equivalence-cases.sh" 240
run_section "wrapper-signal-transparency-cases.sh" 180
run_section "wrapper-invocation-context-cases.sh" 300
run_section "block-message-decode-cases.sh" 180
run_section "interpreter-widening-evidence-cases.sh" 120

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
