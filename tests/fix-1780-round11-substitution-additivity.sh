#!/usr/bin/env bash
# tests/fix-1780-round11-substitution-additivity.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/bash-scan/argv-scan.js, hooks/block-clearance-token-write/bash-scan/scan.js, hooks/lib/command-parser.js, hooks/lib/command-ir.js, hooks/lib/protected-basenames.js
# Tags: off-clearance, session-marker, bash-scan, substitution, command-substitution, backtick, argv-operand, workflow-dir, classifier, additivity, security, pretooluse, block-write, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The hook firing as a REAL PreToolUse hook in a live claude -p session; here it
#   is a node subprocess fed synthetic stdin. Registration is covered statically by
#   tests/enforce-protected-marker-write.sh (X6).
# - Real shell expansion actually creating the file. The shell's behaviour is the
#   PREMISE; what is asserted is the hook's reading of the spelling.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-11 CAUSE-1 + CAUSE-2)
#
# hooks/lib/session-markers.js authorizes on a marker file's EXISTENCE alone, so a
# single forged `<sid>.workflow-off` (or an `.off-clearance` token) is full session
# clearance. Two independent classifier defects let a shell ASSEMBLE such a name
# out of pieces and slip it past the scanner:
#
#   CAUSE-1 (bash-scan/argv-scan.js) — the argv loop selected between two readings
#     with `looksLikePath = /[\\/]/.test(sp) || !/\s/.test(sp)`. A token holding
#     interior whitespace and no `/` took the word-split branch ONLY, so
#     classifyBashWriteTarget — the reading that carries the workflow-dir /
#     dynamic-target qualifiers — never saw it. `touch "$(printf '%s%s' … …)"`
#     was measured ALLOW while the byte-equivalent spelling with a `/` BLOCKed.
#     Both readings are now unconditional and ADDITIVE.
#
#   CAUSE-2 (bash-scan/scan.js) — the ordinary parse TEARS an unquoted `$( )` /
#     backtick span apart (`(` `)` are separators; the tokenizer splits on the
#     whitespace inside the span), so no fragment was ever the path the shell
#     writes to. substitutionSpanSegments() adds a SECOND parse
#     (`preserveSubstitutionSpans: true`) that keeps the span whole, and appends
#     the segments the first parse did not produce.
#
# Both fixes are STRICTLY ADDITIVE to a denylist: a reading may only ADD a
# candidate block, never clear one. That is why Sections D and O carry as much
# weight as Sections A and B — the ordinary `( )` split is load-bearing (it is
# what promotes `$(rm <marker>)` and `tee >(cat > <marker>)` to scanned segments),
# and a fix that traded it away, or that swept in ordinary substitution use, would
# be a regression this file must fail on.
#
# Sections:
#   A  CAUSE-1 regression — whitespace-bearing substitution results  (must BLOCK)
#   B  CAUSE-2 regression — unquoted span as target / redirect target (must BLOCK)
#   C  symmetric non-protected controls, same shapes                 (must ALLOW)
#   D  additivity — substitution BODY still scanned as command text  (must BLOCK)
#   O  over-block sizing — ordinary adjacent shapes                  (must ALLOW)
#   X  cross-hook non-interference — the parser option stays opt-in
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PB_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
SCAN_NODE="$_AGENTS_DIR_NODE/hooks/block-clearance-token-write/bash-scan/scan.js"
IR_NODE="$_AGENTS_DIR_NODE/hooks/lib/command-ir.js"
SCAN_REL="hooks/block-clearance-token-write/bash-scan/scan.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'sub1780'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# rules/test/fixture-isolation.md: never let the hook resolve the live session.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# H0 - harness self-check: without the hook every verdict below is vacuous.
if [ -f "$HOOK" ]; then pass "H0 hook file present"
else
    fail "H0 hook file MISSING at $HOOK - every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# --- sandbox: a throwaway workflow dir. Dual-pinned (CLAUDE_WORKFLOW_DIR AND
# WORKFLOW_PLANS_DIR) per rules/test/fixture-isolation.md — pinning one only is
# the classic contamination bug. The hook creates no files; the pin also keeps
# the workflow-dir qualifier resolving to the fixture rather than the real dir.
SANDBOX=$(make_tmp); WF=$(node_path "$SANDBOX")
cleanup() { [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -r -f "$SANDBOX" 2>/dev/null; return 0; }
trap cleanup EXIT

# --- protected names DERIVED from the SSOT, never hardcoded ----------------
MARKER_SUFFIX=$("$RWT" 10 node -e \
    "process.stdout.write('.' + require(process.argv[1]).SESSION_MARKER_KINDS[0])" "$PB_NODE" 2>/dev/null)
TOKEN_SUFFIX=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).OFF_CLEARANCE_TOKEN_SUFFIXES[0])" "$PB_NODE" 2>/dev/null)
if [ -z "$MARKER_SUFFIX" ] || [ -z "$TOKEN_SUFFIX" ]; then
    fail "H1 protected-basename SSOT is introspectable (hooks/lib/protected-basenames.js exports)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 protected-basename SSOT introspected: marker=[$MARKER_SUFFIX] token=[$TOKEN_SUFFIX]"

SID="s1"
MARKER="${SID}${MARKER_SUFFIX}"                      # e.g. s1.workflow-off
TOKEN="${SID}${TOKEN_SUFFIX}"                        # e.g. s1.off-clearance
# The two halves an attacker feeds a name-assembling command. The split point is
# arbitrary (any command that concatenates works — CPR-8); the last 3 characters
# keep the tail off the first fragment so neither half is protected on its own.
MK1="${MARKER:0:${#MARKER}-3}"; MK2="${MARKER: -3}"
TK1="${TOKEN:0:${#TOKEN}-3}";   TK2="${TOKEN: -3}"

# --- hook invocation --------------------------------------------------------
# run_hook <command> -> "<rc>|<stdout, newlines stripped>"
run_hook() {
    local cmd="$1" input out rc
    input=$("$RWT" 10 node -e \
        'process.stdout.write(JSON.stringify({tool_name:"Bash",session_id:"s1",cwd:process.argv[2],tool_input:{command:process.argv[1]}}))' \
        "$cmd" "$WF" 2>/dev/null)
    [ -z "$input" ] && { printf 'nopayload|'; return; }
    out=$(printf '%s' "$input" | CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 15 node "$HOOK" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# classify "<rc>|<out>" -> approve | block | timeout | crash:<rc> | empty |
#                          unrecognized | nopayload
# An allow is only an allow when the hook exited 0 AND affirmatively said so;
# a crash, a timeout or unparseable stdout can never be confused with "approve".
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        nopayload) printf 'nopayload'; return ;;
        124)       printf 'timeout'; return ;;
        0)         ;;
        *)         printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    case "$out" in
        *'"permissionDecision":"deny"'*)  printf 'block'; return ;;
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)              printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# assert_verdict <label> <want> <command>
assert_verdict() {
    local label="$1" want="$2" cmd="$3" got
    got="$(classify "$(run_hook "$cmd")")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [cmd=$(printf '%.180s' "$cmd")]"; fi
}
assert_block()   { assert_verdict "$1" block "$2"; }
assert_approve() { assert_verdict "$1" approve "$2"; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# ===== Section A: CAUSE-1 — whitespace-bearing substitution result as target ==
# Every one of these was measured ALLOW before the argv loop's two readings were
# made additive. The `printf` is incidental: A4 assembles the same name with
# `echo | tr -d ' '` to show the defect is in the CLASSIFIER, not in one verb.
assert_block "A1 cd + touch quoted \$( ) result (marker, interior whitespace)" \
    "cd $WF && touch \"\$(printf '%s%s' $MK1 $MK2)\""
assert_block "A2 cd + tee quoted \$( ) result (marker, interior whitespace)" \
    "cd $WF && tee \"\$(printf '%s%s' $MK1 $MK2)\" < /dev/null"
assert_block "A3 cd + touch quoted \$( ) result (TOKEN family, CPR-5 sibling)" \
    "cd $WF && touch \"\$(printf '%s%s' $TK1 $TK2)\""
assert_block "A4 whitespace introduced by a transform (echo | tr -d ' ')" \
    "cd $WF && touch \"\$(echo $MK1 $MK2 | tr -d ' ')\""
assert_block "A5 absolute-path variant, no cd (dir + stem + suffix)" \
    "touch \"\$(printf '%s%s%s' $WF/ $MK1 $MK2)\""

# ===== Section B: CAUSE-2 — an UNQUOTED span torn apart by the ordinary parse ==
assert_block "B1 backtick span as absolute write target" \
    "touch \`printf '%s%s' $WF/$MK1 $MK2\`"
assert_block "B2 \$( ) unquoted span as absolute write target" \
    "touch \$(printf '%s%s' $WF/$MK1 $MK2)"
assert_block "B3 backtick span as a REDIRECT target" \
    "echo x > \`printf '%s%s' $WF/$MK1 $MK2\`"
assert_block "B4 backtick span + cd, relative resolution" \
    "cd $WF && touch \`printf '%s%s' $MK1 $MK2\`"
assert_block "B5 backtick span, TOKEN family (CPR-5 sibling of B1)" \
    "touch \`printf '%s%s' $WF/$TK1 $TK2\`"

# B6/B7: the MECHANISM, asserted directly. Without this, A/B could pass for an
# unrelated reason and a later refactor could delete substitutionSpanSegments()
# without any case here turning red. B7 is the other direction: the second parse
# must contribute NOTHING for text with no unquoted span, or the dedup key is
# broken and every command is being scanned twice.
span_extra_count() {
    "$RWT" 15 node -e '
const { substitutionSpanSegments } = require(process.argv[1]);
const { parse } = require(process.argv[2]);
const cmd = process.argv[3];
process.stdout.write(String(substitutionSpanSegments(cmd, parse(cmd)).length));
' "$SCAN_NODE" "$IR_NODE" "$1" 2>/dev/null
}
if [ -f "$AGENTS_DIR/$SCAN_REL" ]; then
    assert_eq "B6 substitutionSpanSegments() contributes the whole-span segment the ordinary parse lost" \
        "1" "$(span_extra_count "touch \`printf '%s%s' $WF/$MK1 $MK2\`")"
    assert_eq "B7 ... and contributes NOTHING for text with no unquoted span (dedup key intact)" \
        "0" "$(span_extra_count "echo hello world")"
else
    skip "B6/B7 $SCAN_REL absent"
    skip "B6/B7 (second half)"
fi

# ===== Section C: symmetric non-protected controls — the SAME shapes ==========
# A guard that over-blocks ordinary work is a different, equally real defect
# (CPR-5). Each case here is the byte-shape of a Section A/B case with a
# non-protected target.
assert_approve "C1 quoted \$( ) result with interior whitespace -> /tmp path" \
    "touch \"\$(printf '%s%s' /tmp/ordinary -name)\""
assert_approve "C2 backtick span -> /tmp path" \
    "touch \`printf '%s%s' /tmp/ordinary -name\`"
assert_approve "C3 \$( ) unquoted span -> /tmp path" \
    "touch \$(printf '%s%s' /tmp/ordinary -name)"
assert_approve "C4 redirect into a \$( ) result (mktemp)" \
    "echo x > \"\$(mktemp)\""
assert_approve "C5 prose with spaces in a commit message" \
    "git commit -m \"some prose with spaces mentioning nothing protected\""
assert_approve "C6 backtick inside an ordinary /tmp redirect target" \
    "echo x > /tmp/\`date +%s\`.log"

# ===== Section D: ADDITIVITY — the substitution BODY is still command text ====
# The ordinary `( )` split is what promotes a substitution / subshell / process-
# substitution body to its own scanned segment. A CAUSE-2 fix that replaced the
# ordinary reading instead of adding to it would silently trade these four blocks
# away. They are pre-existing behaviour and must never regress.
assert_block "D1 \$( ) body executes rm on a marker" \
    "\$(rm $WF/$MARKER)"
assert_block "D2 backtick body executes rm on a marker" \
    "\`rm $WF/$MARKER\`"
assert_block "D3 process substitution body writes a marker" \
    "tee >(cat > $WF/$MARKER)"
assert_block "D4 subshell body cd's in and touches a marker" \
    "(cd $WF && touch $MARKER)"

# ===== Section O: over-block sizing — ordinary adjacent shapes stay approved ==
# The workflow dir is a normal directory to read from. None of these names a
# protected basename, so none may be swept in by either fix.
assert_approve "O1 plain read of a non-protected file in the workflow dir" \
    "cat $WF/some-nonprotected-file.json"
assert_approve "O2 assignment from \$( ) reading a non-protected file" \
    "SID=\$(cat $WF/some-nonprotected-file.json)"
assert_approve "O3 process substitution READING two non-protected files" \
    "diff <(cat $WF/a.json) <(cat $WF/b.json)"
assert_approve "O4 substitution that never touches the workflow dir" \
    "echo \"\$(git rev-parse HEAD)\" > /tmp/sha"

# ===== Section X: cross-hook non-interference ================================
# preserveSubstitutionSpans is an OPT-IN parser option, default OFF. Exactly one
# call site may pass it: the CAUSE-2 reading in bash-scan/scan.js. Any second
# caller would change another hook's blast radius (command-parser.js /
# command-ir.js are shared by enforce-worktree.js among others) without any test
# in this file noticing.
if command -v grep >/dev/null 2>&1; then
    X_HITS=$(cd "$AGENTS_DIR" && grep -rn --binary-files=text --include='*.js' \
        'preserveSubstitutionSpans[[:space:]]*:[[:space:]]*true' hooks/ 2>/dev/null \
        | grep -v "^$SCAN_REL:" | wc -l | tr -d ' ')
    assert_eq "X1 preserveSubstitutionSpans:true is passed ONLY from $SCAN_REL" "0" "$X_HITS"
    X_SELF=$(cd "$AGENTS_DIR" && grep -c --binary-files=text \
        'preserveSubstitutionSpans[[:space:]]*:[[:space:]]*true' "$SCAN_REL" 2>/dev/null | tr -d ' ')
    assert_eq "X2 ... and X1 is not vacuous: the one sanctioned call site is present" "1" "$X_SELF"
    X_DEFAULT=$(cd "$AGENTS_DIR" && grep -c --binary-files=text \
        'preserveSubstitutionSpans' hooks/lib/command-parser.js 2>/dev/null | tr -d ' ')
    if [ "${X_DEFAULT:-0}" -ge 1 ]; then
        pass "X3 hooks/lib/command-parser.js models the option (opt-in, read from opts)"
    else
        fail "X3 hooks/lib/command-parser.js no longer mentions preserveSubstitutionSpans"
    fi
else
    skip "X1 grep unavailable"; skip "X2 grep unavailable"; skip "X3 grep unavailable"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
