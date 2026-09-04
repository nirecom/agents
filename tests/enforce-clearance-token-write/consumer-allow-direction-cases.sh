#!/usr/bin/env bash
# tests/enforce-clearance-token-write/consumer-allow-direction-cases.sh
# Tests: hooks/block-clearance-token-write/interpreter-scan.js, hooks/block-clearance-token-write/bash-scan.js, hooks/block-clearance-token-write/bash-scan/argv-scan.js, hooks/block-clearance-token-write/bash-target-context/classify.js
# Tags: anti-cheat, off-clearance, clearance-token, mention-gate, allow-direction, whitespace-path, partial-resolution, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: the hook firing on a real host — covered by tests/TL3-hook-clearance-token-write.sh.
# Every case here is an ALLOW/BLOCK PAIR (CPR-ORTH). The sibling sections prove the guard
# still catches things; a narrowing fix can only be judged against what it must STOP
# catching, and a hardening fix only against what it must not START catching. Covers the
# mention-gate consumers in interpreter-scan.js and bash-scan.js (#1821), partially
# resolving write targets (#1608 trust model), and whitespace-in-path targets (#1817)
# exercised against REAL on-disk files so the no-side-effect property is observable.

set -u

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"
# A REAL directory whose name contains a space, holding a REAL token file. #1817 is about
# argv words that carry whitespace, and only an on-disk target makes the "nothing moved"
# assertion at the end of this file meaningful.
SPDIR_FS="$TMP/wf notes"
mkdir -p "$SPDIR_FS"
printf '%s' '{"cleared":true}' > "$SPDIR_FS/wsid.off-clearance"
printf '%s' 'plain' > "$SPDIR_FS/notes.txt"
SPDIR="$TN/wf notes"

if [ "$HOOK_PRESENT" = "yes" ]; then pass "H0 hook file present"; else fail "H0 hook file MISSING at $HOOK - all cases below are vacuous"; fi

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
SP_BEFORE=$(sha_of "$SPDIR_FS/wsid.off-clearance")

# ============================================================================
# Table columns: name | want | payload (the payload must not itself contain '|').
# @TOK@ = absolute token path, @DIR@ = workflow dir, @SPDIR@ = the whitespace dir,
# @SPTOK@ = the whitespace-dir token, @INV@ = the sanctioned minter invitation.
# ============================================================================
INV='bash "$AGENTS_CONFIG_DIR/bin/request-off-clearance" --target workflow --category x --detail y'

while IFS='|' read -r name want payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"; payload="$(trim "$payload")"
    payload="${payload//@SPTOK@/$SPDIR/wsid.off-clearance}"
    payload="${payload//@SPDIR@/$SPDIR}"
    payload="${payload//@TOK@/$TOKEN}"
    payload="${payload//@DIR@/$TN}"
    payload="${payload//@INV@/$INV}"
    assert_verdict "$name" "$want" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
done <<TABLE
# --- C2a: interpreter-scan.js Tier-1 (the mentionsProtectedName prefilter at the top of ---
# --- the interpreter path). The BLOCK row is the reason the prefilter exists; the ---
# --- APPROVE rows are bodies whose only "mention" is the minter this guard advertises. ---
# --- The approve rows are RED before the narrowing fix. ---
IS-block node -e body naming the real token             | block   | node -e "require('fs').writeFileSync('@TOK@','forged')"
IS-allow1 node -e body echoing the minter path          | approve | node -e "console.log('bin/request-off-clearance')"
IS-allow2 python3 -c body echoing the minter path       | approve | python3 -c "print('run bin/request-off-clearance --target workflow')"
IS-allow3 node -e body naming the re-spelled minter     | approve | node -e "console.log('bin/request-off-mode-clearance')"
# --- AC: the interpreter one-liner is an ARGUMENT to a different cmd0 (echo, git, ---
# --- printf, grep), not an invocation. INTERPRETER_RE scans the whole command line, so ---
# --- these reach the same Tier-1 gate as IS-* above with cmd0 innocent — the row set ---
# --- that decides whether the #1821 narrowing holds when nothing is executed at all. ---
# --- Each allow row's block twin differs only in the name it quotes. ---
AC-block1 echo of a python3 -c one-liner reading the token | block | echo "python3 -c 'open(\"@TOK@\").read()'"
AC-allow1 echo of a python3 -c one-liner naming the minter | approve | echo "python3 -c 'print(1)' uses bin/request-off-clearance"
AC-block2 commit message naming the token beside node -e | block   | git commit -m "node -e demo; do not touch wsid.off-clearance"
AC-allow2 commit message naming the minter beside node -e | approve | git commit -m "node -e demo; see bin/request-off-clearance"
AC-block3 echo of a node -e writeFileSync one-liner      | block   | echo "node -e require('fs').writeFileSync('@TOK@','x')"
AC-allow3 printf of a node -e one-liner naming the minter | approve | printf '%s' "node -e console.log('bin/request-off-clearance')"
AC-allow4 grep for the flag shape in the minter's doc    | approve | grep -n "python3 -c" docs/request-off-clearance.md
# --- C2b: bash-scan.js unparsedVerdict — when the command cannot be parsed the gate ---
# --- decides on the RAW TEXT alone, so it is the most over-blocking-prone consumer. ---
# --- Same unterminated-quote shape either side; only the named path differs. ---
US-block unterminated quote naming the real token       | block   | echo "note @TOK@
US-allow1 unterminated quote naming only the minter     | approve | echo "reminder: run @INV@
US-allow2 unterminated single quote naming only the minter | approve | echo 'reminder: run bin/request-off-clearance --target workflow
# --- C3: partially resolving write targets. A target whose PREFIX is an unresolved ---
# --- variable but whose BASENAME is the protected name is exactly the residual- ---
# --- indirection case classify.js exists for. Every allow row below CONTAINS the ---
# --- literal off-clearance and differs from its block row only in failing the ---
# --- dot-adjacency rule — that is what makes it fail-before-fix evidence rather than ---
# --- a payload the bare gate would have let through anyway. ---
PR-block1 redirect into \$WF/wsid.off-clearance          | block   | echo forged > "\$WF/wsid.off-clearance"
PR-block2 same target, prefix resolved by an assignment | block   | WF="@DIR@"; echo forged > "\$WF/wsid.off-clearance"
PR-block3 unresolved prefix, mint intermediate basename | block   | echo forged > "\$WF/wsid.off-clearance.mint.tmp"
PR-allow1 unresolved prefix, log named after the minter | approve | echo plain > "\$WF/request-off-clearance.log"
PR-allow2 resolved prefix, issue-numbered note file     | approve | WF="@DIR@"; echo plain > "\$WF/off-clearance-1780.md"
PR-allow3 unresolved prefix, wrong extension after dot  | approve | echo plain > "\$WF/x.off-clearance.txt"
PR-allow4 unresolved prefix, unreserved #1763 suffix    | approve | echo plain > "\$WF/wsid.session-transcript"
# --- C4: #1817 whitespace-in-path, against the REAL files created above. Each block ---
# --- row and its allow row differ only in the BASENAME, so a narrowing that keys on ---
# --- "contains a space" instead of on the basename fails the pair. ---
WS-block1 cp into the whitespace dir token (quoted)     | block   | cp /etc/hosts "@SPTOK@"
WS-block2 touch the whitespace dir token (unquoted)     | block   | touch @SPTOK@
WS-block3 rm the whitespace dir token                   | block   | rm -f "@SPTOK@"
WS-allow1 cp into the whitespace dir, minter-named log  | approve | cp /etc/hosts "@SPDIR@/request-off-clearance.log"
WS-allow2 touch an issue-numbered note in the same dir  | approve | touch "@SPDIR@/off-clearance-1780.md"
WS-allow3 read the whitespace dir token with cat        | approve | cat "@SPTOK@"
TABLE

# The guard runs as PreToolUse, so the only end-to-end observable is that the real token
# it just refused is still exactly where it was. Asserting verdicts alone would pass even
# for a guard that "normalised" the file while inspecting it.
if [ ! -f "$SPDIR_FS/wsid.off-clearance" ]; then
    fail "WS-NEG the whitespace-path token was removed while the guard inspected it"
elif [ "$(sha_of "$SPDIR_FS/wsid.off-clearance")" != "$SP_BEFORE" ]; then
    fail "WS-NEG the whitespace-path token's contents changed (the guard must be side-effect free)"
else
    pass "WS-NEG the whitespace-path token is unchanged byte-for-byte after every route"
fi
# Symmetric: the allow rows must not have been executed either — PreToolUse only decides.
if [ -f "$SPDIR_FS/off-clearance-1780.md" ]; then
    fail "WS-NEG2 an approved command's side effect appeared — the hook is executing input"
else
    pass "WS-NEG2 approving a command does not execute it"
fi

rm -r -f "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
