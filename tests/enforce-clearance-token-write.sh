#!/usr/bin/env bash
# tests/enforce-clearance-token-write.sh
# Tests: hooks/block-clearance-token-write.js
# Tags: anti-cheat, off-clearance, issue-provenance, clearance-token, pretooluse, block-write, vector2, classifier, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook actually firing on a real host: this file invokes the classifier directly,
#   so it cannot fail when the PreToolUse registration is missing or misspelled.
#   Registration is asserted statically by tests/feat-1763-settings-registration.sh;
#   only a real `claude -p` turn proves the guard is reached before the tool runs.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# #1608 anti-cheat (best-effort): block direct writes to the clearance-token path
# (<workflowDir>/<sid>.off-clearance). Mirrors block-memory-direct.js + adds a vector2
# interpreter-body heuristic (node -e / python -c writing to the token dir).
#
# S11 (#1763) generalizes the guard from one token to the whole clearance-token CLASS
# (CPR-4): the issue-provenance markers are forgeable in exactly the same way, and the
# consumption record is worse — DELETING it re-enables an already-spent provenance token.
# The guard therefore covers, for both create/overwrite AND delete:
#   .off-clearance             (regression — original coverage)
#   .issue-provenance          (forging a user-explicit token)
#   .issue-provenance.tmp      (the atomic-write staging path)
#   .issue-provenance-consumed (erasing the single-use record — the C5 replay vector)
#   .session-transcript        (redirecting the transcript re-scan at a forged fixture)
#
# KNOWN-BYPASS (accepted limitation — detail plan "Anti-cheat 信頼モデル(確定)"):
#   Dynamic path construction (variable concat / base64 / alternate interpreter),
#   editing the examiner script / codex / this hook itself are NOT detectable.
#   The TRUE gate is Phase2 human approval + audit, NOT this best-effort block.
# Classifier symmetry (test-design.md L36): every block case is paired with a
# sanctioned unrelated-path APPROVE case so the hook does not over-block.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
OLD_HOOK="$AGENTS_DIR/hooks/block-off-clearance-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'offwrite'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

# run_hook <tmp_node> <hook-input-json> → prints stdout of the hook (empty if hook absent)
run_hook() {
    local tn="$1" input="$2"
    [ "$HOOK_PRESENT" = "yes" ] || { printf ''; return; }
    CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 12 node "$HOOK" <<< "$input" 2>/dev/null
}
mk_bash_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1]}}))" "$1"; }
mk_file_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:'wsid',tool_input:{file_path:process.argv[2]}}))" "$1" "$2"; }
is_block() { echo "$1" | grep -q '"decision":"block"'; }

assert_block() {  # <label> <hook-out>
    if is_block "$2"; then pass "$1 → block"
    else
        if [ "$HOOK_PRESENT" = "yes" ]; then fail "$1 must block (got: ${2:-<none>})"
        else fail "$1 → block  [RED-EXPECTED: block-clearance-token-write.js not yet created]"; fi
    fi
}
assert_approve() {  # <label> <hook-out>
    if is_block "$2"; then fail "$1 must NOT block (over-blocking; got: $2)"
    else pass "$1 → approve (not blocked)"; fi
}

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

echo "=== regression: .off-clearance (the original #1608 coverage) ==="
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

# --- approve: sanctioned unrelated paths (CPR-5 counterparts) ---
assert_approve "A1 redirect > unrelated file"  "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/notes.txt")")"
assert_approve "A2 Write unrelated file_path"  "$(run_hook "$TN" "$(mk_file_input Write "$TN/other.json")")"
assert_approve "A3 harmless node -e (no token)" "$(run_hook "$TN" "$(mk_bash_input "node -e \"console.log(1+1)\"")")"

echo ""
echo "=== S11: the guard covers the whole clearance-token class (CPR-4) ==="
# Every suffix below is a clearance token in the same sense: possessing or altering the
# file changes what the pipeline believes about user authorization.
for SUF in .issue-provenance .issue-provenance.tmp .issue-provenance-consumed .session-transcript; do
    P="$TN/wsid$SUF"
    assert_block "C-write($SUF) Write file_path"  "$(run_hook "$TN" "$(mk_file_input Write "$P")")"
    assert_block "C-write($SUF) Edit file_path"   "$(run_hook "$TN" "$(mk_file_input Edit "$P")")"
    assert_block "C-write($SUF) redirect >"       "$(run_hook "$TN" "$(mk_bash_input "echo forged > $P")")"
    assert_block "C-write($SUF) tee"              "$(run_hook "$TN" "$(mk_bash_input "printf x | tee $P")")"
done

echo ""
echo "=== S11: DELETE is as dangerous as overwrite (erasing the single-use record) ==="
# Deleting .issue-provenance-consumed replays an already-spent provenance token (C5);
# deleting .off-clearance re-arms an already-used clearance. Both must be blocked.
for SUF in .off-clearance .issue-provenance .issue-provenance-consumed .session-transcript; do
    P="$TN/wsid$SUF"
    assert_block "C-del($SUF) rm"        "$(run_hook "$TN" "$(mk_bash_input "rm -f $P")")"
    assert_block "C-del($SUF) rm -rf"    "$(run_hook "$TN" "$(mk_bash_input "rm -rf $P")")"
    assert_block "C-del($SUF) mv away"   "$(run_hook "$TN" "$(mk_bash_input "mv $P $TN/stash.bak")")"
done

echo ""
echo "=== S11: vector2 interpreter bodies targeting the new tokens ==="
V2A="node -e \"require('fs').writeFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.issue-provenance','forged')\""
assert_block "C-v2 node -e writes .issue-provenance" "$(run_hook "$TN" "$(mk_bash_input "$V2A")")"
V2B="node -e \"require('fs').unlinkSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.issue-provenance-consumed')\""
assert_block "C-v2 node -e unlinks consumption record" "$(run_hook "$TN" "$(mk_bash_input "$V2B")")"
V2C="python -c \"import os; os.remove(os.environ['CLAUDE_WORKFLOW_DIR'] + '/wsid.issue-provenance-consumed')\""
assert_block "C-v2 python -c unlinks consumption record" "$(run_hook "$TN" "$(mk_bash_input "$V2C")")"

echo ""
echo "=== classifier symmetry: sanctioned neighbours must NOT be blocked ==="
# Similar-looking but unrelated paths and the workflow's own state file stay writable —
# only the clearance-token suffixes are reserved.
assert_approve "A4 rm unrelated file"                 "$(run_hook "$TN" "$(mk_bash_input "rm -f $TN/scratch.txt")")"
assert_approve "A5 Write session state json"          "$(run_hook "$TN" "$(mk_file_input Write "$TN/wsid.json")")"
assert_approve "A6 Write .issue-provenance-notes.md"  "$(run_hook "$TN" "$(mk_file_input Write "$TN/issue-provenance-notes.md")")"
assert_approve "A7 Write repo doc mentioning suffix"  "$(run_hook "$TN" "$(mk_file_input Write "$_AGENTS_DIR_NODE/docs/issue-provenance.md")")"
assert_approve "A8 rm unrelated transcript-ish file"  "$(run_hook "$TN" "$(mk_bash_input "rm -f $TN/session-transcript-sample.jsonl")")"
assert_approve "A9 harmless python -c"                "$(run_hook "$TN" "$(mk_bash_input "python -c \"print(2)\"")")"

echo ""
echo "=== negative assertions: the protected files are byte-for-byte unchanged ==="
# Asserting only the classifier's verdict leaves the actual property untested. The
# guard runs as PreToolUse, i.e. BEFORE the tool executes, so the only correct
# observable is that nothing about the protected file moved: same bytes, same size,
# still present. A guard that read-modified-wrote (normalising, truncating, or
# "cleaning up") a token while inspecting it would pass every assert_block above.
FIXDIR=$(make_tmp); FIXN=$(node_path "$FIXDIR")
declare_fixture() {  # <suffix> <content>
    printf '%s' "$2" > "$FIXDIR/wsid$1"
}
declare_fixture .off-clearance             '{"cleared":true}'
declare_fixture .issue-provenance          '{"provenance":"user-explicit","target":"issue-create"}'
declare_fixture .issue-provenance-consumed '{"consumed":["0:abc123"]}'
declare_fixture .session-transcript        '/some/path/transcript.jsonl'

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

for SUF in .off-clearance .issue-provenance .issue-provenance-consumed .session-transcript; do
    F="$FIXDIR/wsid$SUF"; P="$FIXN/wsid$SUF"
    BEFORE=$(sha_of "$F"); SZ_BEFORE=$(wc -c < "$F" | tr -d ' ')
    # Exercise every route at once against the same real file.
    run_hook "$FIXN" "$(mk_file_input Write "$P")" >/dev/null
    run_hook "$FIXN" "$(mk_file_input Edit  "$P")" >/dev/null
    run_hook "$FIXN" "$(mk_bash_input "echo forged > $P")" >/dev/null
    run_hook "$FIXN" "$(mk_bash_input "rm -f $P")" >/dev/null
    run_hook "$FIXN" "$(mk_bash_input "node -e \"require('fs').writeFileSync('$P','forged')\"")" >/dev/null
    if [ ! -f "$F" ]; then
        fail "NEG($SUF) the protected file was removed while the guard inspected it"
    elif [ "$(sha_of "$F")" != "$BEFORE" ]; then
        fail "NEG($SUF) the protected file's contents changed (guard must be side-effect free)"
    elif [ "$(wc -c < "$F" | tr -d ' ')" != "$SZ_BEFORE" ]; then
        fail "NEG($SUF) the protected file's size changed"
    else
        pass "NEG($SUF) unchanged byte-for-byte after every attempted route"
    fi
done

echo ""
echo "=== attack scenarios: routes that a naive substring match would miss ==="
# These are all forms that reach the same path without spelling it the obvious way.
# The suffix is still literally present in the command, so the guard is expected to
# catch them — this is the boundary of what a lexical guard can reasonably cover.
PROV="$FIXN/wsid.issue-provenance"
CONS="$FIXN/wsid.issue-provenance-consumed"
assert_block "ATK append >> token"          "$(run_hook "$FIXN" "$(mk_bash_input "echo forged >> $PROV")")"
assert_block "ATK truncate -s 0"            "$(run_hook "$FIXN" "$(mk_bash_input "truncate -s 0 $CONS")")"
assert_block "ATK dd of= token"             "$(run_hook "$FIXN" "$(mk_bash_input "dd if=/dev/null of=$CONS")")"
assert_block "ATK sed -i in place"          "$(run_hook "$FIXN" "$(mk_bash_input "sed -i 's/mid/user/' $PROV")")"
assert_block "ATK command prefix bypass"    "$(run_hook "$FIXN" "$(mk_bash_input "command rm -f $CONS")")"
assert_block "ATK env prefix bypass"        "$(run_hook "$FIXN" "$(mk_bash_input "env -i rm -f $CONS")")"
assert_block "ATK chained after ;"          "$(run_hook "$FIXN" "$(mk_bash_input "echo hi ; rm -f $CONS")")"
assert_block "ATK chained after &&"         "$(run_hook "$FIXN" "$(mk_bash_input "true && echo forged > $PROV")")"
assert_block "ATK subshell"                 "$(run_hook "$FIXN" "$(mk_bash_input "( rm -f $CONS )")")"
assert_block "ATK cat heredoc into token"   "$(run_hook "$FIXN" "$(mk_bash_input "cat <<EOF > $PROV
forged
EOF")")"

echo ""
echo "=== KNOWN-BYPASS routes: pinned as unblocked-but-harmless, not silently ignored ==="
# Per the accepted trust model above, dynamic construction is NOT detectable. Testing
# it matters anyway: the guard must neither crash nor mutate anything when it cannot
# decide, so that the real gate (Phase 2 human approval + audit) still sees a
# consistent filesystem. Recording these explicitly also stops a future reader from
# assuming they are covered.
CONS_FILE="$FIXDIR/wsid.issue-provenance-consumed"
KB_BEFORE=$(sha_of "$CONS_FILE")
KB_CRASH=0
for CMD in \
    'S=".issue-prov"; T="enance-consumed"; rm -f "$CLAUDE_WORKFLOW_DIR/wsid$S$T"' \
    'rm -f "$CLAUDE_WORKFLOW_DIR"/wsid.issue-prov*' \
    'eval "$(printf %s cm0gLWYgY29ucw== | base64 -d)"' \
    'perl -e "unlink glob qq{$ENV{CLAUDE_WORKFLOW_DIR}/wsid.issue-prov*}"' \
    ; do
    OUT=$(run_hook "$FIXN" "$(mk_bash_input "$CMD")")
    # A crash would surface as a non-JSON / empty response while the hook is present.
    if [ "$HOOK_PRESENT" = "yes" ] && [ -z "$OUT" ]; then KB_CRASH=$((KB_CRASH + 1)); fi
done
if [ "$HOOK_PRESENT" != "yes" ]; then
    fail "KB1 guard survives undecidable commands  [RED-EXPECTED: block-clearance-token-write.js not yet created]"
    fail "KB2 undecidable commands leave the record untouched  [RED-EXPECTED: block-clearance-token-write.js not yet created]"
else
    [ "$KB_CRASH" -eq 0 ] && pass "KB1 guard survives undecidable commands (no crash, always answers)" \
        || fail "KB1 the guard produced no verdict for $KB_CRASH undecidable command(s)"
    [ "$(sha_of "$CONS_FILE")" = "$KB_BEFORE" ] && pass "KB2 undecidable commands leave the record untouched" \
        || fail "KB2 the consumption record changed while classifying an undecidable command"
fi

rm -rf "$FIXDIR" 2>/dev/null || true

echo ""
echo "=== the rename left nothing behind ==="
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

rm -rf "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
