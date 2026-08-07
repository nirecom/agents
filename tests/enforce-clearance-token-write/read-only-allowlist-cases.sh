#!/usr/bin/env bash
# tests/enforce-clearance-token-write/read-only-allowlist-cases.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/bash-scan.js, hooks/block-clearance-token-write/bash-scan/argv-scan.js, hooks/block-clearance-token-write/interpreter-scan.js
# Tags: anti-cheat, off-clearance, clearance-token, pretooluse, classifier, read-only-allowlist, interpolation, redos, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook firing on a real host. Covered by tests/TL3-hook-clearance-token-write.sh.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# Split out of tests/enforce-off-clearance-write.sh (rules/coding/file-split.md Pattern
# A) when that file's single-file layout was retired in favour of main's 3-file
# enforce-clearance-token-write* structure (#1780 merge with origin/main). The parent
# files (enforce-clearance-token-write.sh, parser-cases.sh) assert the token-path
# block/approve boundary and the malformed-payload contract; THIS file asserts the two
# properties that have no other end-to-end (full-hook, not unit-level) coverage:
#
#   1. The positive READ-ONLY ALLOWLIST (#1709b S-3): a legitimate read of the token
#      (cat, Get-Content, node -e readFileSync(process.env.X)) must stay approved, and
#      an INTERPOLATION_RE prefilter must reject any shell subexpression/backtick/
#      f-string BEFORE a shape is allowed to vouch for its own argument (IP1-IP7) — so
#      a payload that merely LOOKS like a read cannot smuggle a write through it.
#      hooks/fix-1780-round12-parser-unit-tables/cases-*.sh exercise the same regexes
#      at the unit level (individual exported functions); this file proves the SAME
#      grammar holds when driven through the real hook end-to-end via stdin, which is
#      the only way a registration/wiring regression between the modules would surface.
#   2. The classify() STRICT VERDICT CONTRACT: a hook CRASH or TIMEOUT must never
#      silently score as "approved". main's is_block()-based assert_block/assert_approve
#      (see the parent file) treats "does not contain a block decision" as approve,
#      which is exactly the false-green this file's classify() closes.
#
# ASSERTION CONTRACT (classify() below) — same rationale as the pre-merge single-file
# version this was split from: the hook ALWAYS exits 0 and ALWAYS writes a JSON
# decision to stdout. An allow is only an allow when the process exited 0 AND
# affirmatively said so; every other observation (non-zero exit, 124 timeout, empty
# stdout, unparseable stdout, hook file missing) is its own distinct verdict token.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'clearancero'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

# run_hook <tmp_node> <hook-input-json> -> "<rc>|<stdout, newlines stripped>"
# stderr is discarded on purpose: a crashing hook must be detected by rc/stdout, not
# by eyeballing a stack trace.
run_hook() {
    local tn="$1" input="$2" out rc
    [ -f "$HOOK" ] || { printf 'absent|'; return; }
    out=$(CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 12 node "$HOOK" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# classify "<rc>|<out>" -> approve | block | timeout | crash:<rc> | empty | unrecognized | hook-absent
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124)    printf 'timeout'; return ;;
        0)      ;;
        *)      printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    case "$out" in
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)              printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# assert_verdict <label> <want> <raw "rc|out">
assert_verdict() {
    local label="$1" want="$2" raw="$3" got
    got="$(classify "$raw")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [raw=$(printf '%.200s' "$raw")]"; fi
}
assert_block()   { assert_verdict "$1" block "$2"; }
assert_approve() { assert_verdict "$1" approve "$2"; }

mk_bash_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1]}}))" "$1"; }

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

if [ "$HOOK_PRESENT" = "yes" ]; then pass "H0 hook file present"; else fail "H0 hook file MISSING at $HOOK - all cases below are vacuous"; fi

# ============================================================================
# #1709b (S-3) read/write classification: positive read-only ALLOWLIST + the
# INTERPOLATION_RE prefilter that runs BEFORE any shape is allowed to match, so a
# read-looking shell never gets to vouch for its own argument.
# Table-driven per skills/_shared/test-design/parser-regex-tests.md. Columns:
# name | want | payload (payload may itself contain '|'; none currently does).
# ============================================================================
while IFS='|' read -r name want payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"; payload="$(trim "$payload")"
    payload="${payload//@TOK@/$TOKEN}"
    payload="${payload//@DIR@/$TN}"
    assert_verdict "$name" "$want" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
done <<'TABLE'
# --- APPROVE: read-only shapes the allowlist must recognise ---
RD1 node -e readFileSync(process.env.X + '/...off-clearance')      | approve | node -e "console.log(require('fs').readFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.off-clearance','utf8'))"
RD2 python3 -c open(<token>).read()                        | approve | uv run python -c "print(open('@TOK@').read())"
RD3 pwsh Get-Content -Raw '<token>' (single-quoted arg)    | approve | pwsh -Command "Get-Content -Raw '@TOK@'"
RD4 pwsh Get-Content -Raw $env:OFF_TOKEN (bare env form)   | approve | pwsh -Command 'Get-Content -Raw $env:OFF_TOKEN'
RD5 cat <token> (plain read, non-interpreter)              | approve | cat @TOK@
RD6 ls <workflow dir> (directory listing)                  | approve | ls @DIR@
# --- BLOCK: write paths that superficially resemble a read shape ---
WR1 node -e execSync('touch <token>') (indirect write)     | block   | node -e "require('child_process').execSync('touch @TOK@')"
WR2 python3 -c os.system('rm <token>')                     | block   | uv run python -c "import os; os.system('rm @TOK@')"
WR3 python3 -c pathlib Path(<token>).touch()               | block   | uv run python -c "from pathlib import Path; Path('@TOK@').touch()"
WR4 read shape + trailing unlinkSync (prefix is not a read)| block   | node -e "console.log(require('fs').readFileSync('@TOK@')); require('fs').unlinkSync('@TOK@')"
WR6 unrelated node -e with output redirect -> approve (M1)  | approve | node -e "console.log(1)" > out.txt
WR7 unrelated node -e chained with && -> approve (M1)       | approve | node -e "console.log(1)" && echo done
WR14 cd into off-clearance-named dir + clean node -e -> approve | approve | cd /some/off-clearance-1780/dir && node -e "console.log(1)"
WR15b clean node -e && unrelated --detail NAMES token, no separator -> approve | approve | node -e "console.log(1)" && bin/supervisor-report --detail "about the off-clearance token feature"
# --- INTERPOLATION_RE runs BEFORE shape matching, so a read-looking shell never ---
# --- gets to vouch for its own argument.                                        ---
IP1 pwsh Get-Content "$( Remove-Item <token> )"            | block   | pwsh -Command "Get-Content \"$( Remove-Item '@TOK@' )\""
IP2 pwsh double-quoted $env: arg (unconditionally refused) | block   | pwsh -Command "Get-Content \"$env:CLAUDE_WORKFLOW_DIR/wsid.off-clearance\""
IP3 powershell array subexpression @( Remove-Item <token> )| block   | powershell -Command "Get-Content @(Remove-Item '@TOK@')"
IP4 node template literal (backtick + ${ }) -> prefilter   | block   | node -e "console.log(require('fs').readFileSync(`${process.env.X}/x.off-clearance`))"
IP5 python f-string executing popen('rm <token>') in path  | block   | uv run python -c "print(open(f'{__import__(\"os\").popen(\"rm @TOK@\").read()}').read())"
IP6 backslash-containing literal -> block (accepted)       | block   | pwsh -Command "Get-Content 'C:\Users\x\.off-clearance'"
TABLE

rm -r -f "$TMP" 2>/dev/null || true

# ---------------------------------------------------------------------------
# WR16 timing companion (H-B, ReDoS regression guard). scanQuotedBody() walks a
# quoted interpreter body once, consuming each backtick-escape pair in O(1), so a
# long backtick run must stay linear-time (the old backtracking regex could take
# seconds to minutes on the same input). Loose 5s bound to avoid CI flakiness.
# ---------------------------------------------------------------------------
TMP2=$(make_tmp); TN2=$(node_path "$TMP2")
TOKEN2="$TN2/wsid.off-clearance"
BT500=''
while IFS= read -r __l; do BT500="$__l"; done <<'CMD'
node -e "````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````@TOK@"
CMD
BT500="${BT500//@TOK@/$TOKEN2}"
_BT_START_NS=$(date +%s%N 2>/dev/null || echo 0)
BT500_RAW="$(run_hook "$TN2" "$(mk_bash_input "$BT500")")"
_BT_END_NS=$(date +%s%N 2>/dev/null || echo 0)
if [ "$_BT_START_NS" != "0" ] && [ "$_BT_END_NS" != "0" ] && [ "$_BT_END_NS" -gt "$_BT_START_NS" ]; then
    _BT_MS=$(( (_BT_END_NS - _BT_START_NS) / 1000000 ))
    if [ "$_BT_MS" -lt 5000 ]; then pass "WR16b 500-backtick body completes under 5s (${_BT_MS}ms, H-B)"
    else fail "WR16b 500-backtick body took ${_BT_MS}ms (>=5000ms, H-B ReDoS regression?)"; fi
else
    echo "NOTE: WR16b timing skipped - date +%s%N unsupported/non-monotonic on this platform"
fi
# Re-classify the same run rather than re-invoking the hook a second time, so the
# timing measurement above and the verdict below are the SAME call.
assert_block "WR16b 500-backtick body verdict (same run as timing)" "$BT500_RAW"
rm -r -f "$TMP2" 2>/dev/null || true

# ---------------------------------------------------------------------------
# NOT PORTED from the pre-merge single-file version (recorded here so a future
# reader does not go looking for it):
#   - WR5/WR8-13, H2-*, H3-*, SA5-*, F1C-* — these exercise argv-scan.js /
#     interpreter-scan.js / bash-scan/assignment-text.js internals that already
#     have dedicated end-to-end AND unit-level coverage: see
#     tests/fix-1780-round11-substitution-additivity.sh,
#     tests/fix-1780-round12-classifier-attack-shapes.sh,
#     tests/fix-1780-round12-parser-unit-tables/cases-*.sh,
#     tests/enforce-protected-marker-write/cases-round9-flagcluster.sh,
#     tests/enforce-protected-marker-write/cases-round8-operand.sh.
#   - DIFF-* (not-weaker-than-pre-PR differential harness against a hardcoded
#     C:/git/agents pre-PR checkout) — this compared the in-progress branch
#     against origin/main DURING development of #1780. Now that this branch and
#     main have been merged, "main" and "this branch" are the same tree, so the
#     differential has no remaining reference point to diff against; the
#     regression it guarded against is covered going forward by this file's own
#     RD/WR/IP assertions plus the round-11..14 suites.
#   - KB1 'deno eval' known-bypass note — recorded (not asserted) in
#     tests/enforce-clearance-token-write.sh's KB1/KB2 block, which already
#     covers the same "guard survives + does not mutate on an undecidable
#     command" property with a small corpus of dynamic-construction payloads.
# ---------------------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
