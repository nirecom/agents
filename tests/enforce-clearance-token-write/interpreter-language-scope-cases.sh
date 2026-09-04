#!/usr/bin/env bash
# tests/enforce-clearance-token-write/interpreter-language-scope-cases.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/lib/protected-basenames.js
# Tags: anti-cheat, off-clearance, clearance-token, pretooluse, read-only-allowlist, interpreter-scan, language-scope, ruby, stdin-route, heredoc, here-string, table-driven, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook firing on a real host (tests/TL3-hook-clearance-token-write.sh covers it).
# - Whether a real ruby spawns a shell for a leading '|' (asserted from Kernel#open docs).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
# #1821: READONLY_BODY_SHAPES matches without the DELIVERING interpreter's identity, so
# python's bare open() shape also vouches for Ruby's Kernel#open ('|' = shell command).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

if [ "$HOOK_PRESENT" = "yes" ]; then pass "LS0 hook file present"; else fail "LS0 hook file MISSING at $HOOK - all cases below are vacuous"; fi

echo "=== LS: read-only shapes must be scoped to the language that delivered the body ==="
# Columns: name | want | payload (payload must not itself contain '|').
while IFS='|' read -r name want payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"; payload="$(trim "$payload")"
    payload="${payload//@TOK@/$TOKEN}"
    assert_verdict "$name" "$want" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
done <<'TABLE'
# --- ruby: Kernel#open is NOT a proven-inert read. A leading '|' makes the argument a ---
# --- shell command, and no shape in READONLY_BODY_SHAPES was written against ruby's ---
# --- grammar, so the only safe verdict for a ruby body naming the token is block. ---
RB-open ruby -e open(token), python's shape must not vouch for ruby | block | ruby -e "open('@TOK@')"
RB-gt ruby -e open('>token') leading redirect literal     | block   | ruby -e "open('>@TOK@')"
RB-lt ruby -e open('<token') leading '<' literal          | block   | ruby -e "open('<@TOK@')"
# --- NON-REGRESSION: the rows the read-only allowlist genuinely owns must not move. ---
RB-write ruby -e File.write(token) still blocks           | block   | ruby -e "File.write('@TOK@','x')"
LS-ro1 node -e bare readFileSync(token) stays approved    | approve | node -e "require('fs').readFileSync('@TOK@')"
LS-ro2 python3 -c bare open(token).read() stays approved  | approve | python3 -c "open('@TOK@').read()"
LS-ro3 python3 -c print(open(token).read()) stays approved| approve | python3 -c "print(open('@TOK@').read())"
# --- ALLOW DIRECTION (CPR-ORTH): scoping the shape by language must not turn every ---
# --- ruby one-liner into a block — a body naming no protected path never arms Tier-1. ---
LS-allow1 ruby -e open on an unrelated path               | approve | ruby -e "open('/tmp/notes.txt')"
LS-allow2 ruby -e naming the minter, not the token        | approve | ruby -e "puts('run bin/request-off-clearance')"
TABLE

# ---------------------------------------------------------------------------
# The two payloads that matter most cannot live in the '|'-delimited table above:
# the pipe IS the attack. Same standalone treatment as WR-1816d / WR-1817c in
# read-only-allowlist-cases.sh. Ruby's Kernel#open runs `rm -f <token>` as a shell
# command here, so approving these deletes or forges the clearance token outright.
# ---------------------------------------------------------------------------
assert_block "RB-pipe-rm ruby -e open(pipe rm -f token) is a shell command, not a read" \
    "$(run_hook "$TN" "$(mk_bash_input "ruby -e \"open('|rm -f $TOKEN')\"")")"
assert_block "RB-pipe-write ruby -e open(pipe echo forged into token) forges the token" \
    "$(run_hook "$TN" "$(mk_bash_input "ruby -e \"open('|echo forged > $TOKEN')\"")")"

echo ""
echo "=== SR: the same language scoping, for program text delivered on STDIN ==="
# --- Every row above hands the body to the classifier through ARGV. Stdin delivery
# --- crosses a different module boundary — nested-bodies.js extracts the body and
# --- tags it with the RECEIVING command's interpreter word, bash-scan/scan.js carries
# --- that tag to interpreter-scan.js — and the language scoping is only real at the
# --- hook's edge if the tag survives that hop. Each row is the stdin twin of an argv
# --- row above with the SAME verdict, so a tag dropped in transit shows up whichever
# --- language the loss falls back to: as node/python rows blocking, or ruby/perl
# --- rows approving. `<` rows exercise the third route (fileTargets), where the
# --- stdin word is a PATH the interpreter executes rather than a body.
while IFS='|' read -r name want payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"; payload="$(trim "$payload")"
    payload="${payload//@TOK@/$TOKEN}"
    assert_verdict "$name" "$want" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
done <<'TABLE'
SR-hs1 node here-string, bare readFileSync         | approve | node <<< "require('fs').readFileSync('@TOK@')"
SR-hs2 nodejs here-string, bare readFileSync       | approve | nodejs <<< "require('fs').readFileSync('@TOK@')"
SR-hs3 python3 here-string, bare open(t).read()    | approve | python3 <<< "open('@TOK@').read()"
SR-hs4 python3 here-string, print(open(t).read())  | approve | python3 <<< "print(open('@TOK@').read())"
SR-hs5 ruby here-string, Kernel#open on the token  | block   | ruby <<< "open('@TOK@')"
SR-hs6 perl here-string, open on the token         | block   | perl <<< "open(F,'@TOK@')"
SR-hs7 node here-string, writeFileSync             | block   | node <<< "require('fs').writeFileSync('@TOK@','x')"
SR-hs8 python3 here-string, open(t,w).write        | block   | python3 <<< "open('@TOK@','w').write('x')"
# --- ALLOW DIRECTION: the ruby/perl blocks above must be the language scope, not a ---
# --- blanket ban on those two readers reaching the gate at all. ---
SR-hs9 ruby here-string naming only the minter     | approve | ruby <<< "puts('bin/request-off-clearance')"
SR-hs10 perl here-string naming only the minter    | approve | perl <<< "print('bin/request-off-clearance')"
SR-hs11 node here-string naming only the minter    | approve | node <<< "console.log('bin/request-off-clearance')"
# --- `< path` EXECUTES the file, so it is classified as a path, not by mention: the ---
# --- cat row is the control that keeps a plain redirected read approved. ---
SR-lt1 node executing the token as its program     | block   | node < @TOK@
SR-lt2 ruby executing the token as its program     | block   | ruby < @TOK@
SR-lt3 cat reading the token through a redirect    | approve | cat < @TOK@
SR-lt4 node executing the minter script            | approve | node < bin/request-off-clearance
TABLE

# The pipe payloads again — same reason they were pulled out of the table above, now
# on the stdin route, where ruby's Kernel#open is reached without a `-e` anywhere.
assert_block "SR-hs-pipe-rm ruby here-string open(pipe rm -f token)" \
    "$(run_hook "$TN" "$(mk_bash_input "ruby <<< \"open('|rm -f $TOKEN')\"")")"
assert_block "SR-hs-pipe-write ruby here-string open(pipe echo forged into token)" \
    "$(run_hook "$TN" "$(mk_bash_input "ruby <<< \"open('|echo forged > $TOKEN')\"")")"

echo ""
echo "=== SR-HD: heredoc bodies, routed by the READER's interpreter identity ==="
# Multi-line payloads cannot live in the '|'-delimited table above.
hd_payload() { printf "%s <<'EOF'\n%s\nEOF\n" "$1" "$2"; }
hd_unterminated() { printf "%s <<EOF\n%s\n" "$1" "$2"; }
hd_case() {  # <name> <want> <reader> <body> [open]
    local mk=hd_payload
    [ "${5:-}" = "open" ] && mk=hd_unterminated
    assert_verdict "$1" "$2" "$(run_hook "$TN" "$(mk_bash_input "$($mk "$3" "$4")")")"
}
HD_TOKEN_BODY="x = '$TOKEN'"
HD_MINTER_BODY="x = 'bin/request-off-clearance'"
HD_READ_BODY="require('fs').readFileSync('$TOKEN')"

# --- The node/cat PAIR is the evidence: identical body, identical delivery, and only ---
# --- the reader word differs. cat is not an interpreter, so its heredoc is data and ---
# --- approves; node's is program text and blocks. If readerInterpreterOfHead stopped ---
# --- identifying the reader, both would approve together. ---
hd_case "SR-hd1 node heredoc naming the token" block node "$HD_TOKEN_BODY"
hd_case "SR-hd2 cat heredoc, same body, non-interpreter reader" approve cat "$HD_TOKEN_BODY"
hd_case "SR-hd3 node heredoc naming only the minter" approve node "$HD_MINTER_BODY"
hd_case "SR-hd4 ruby heredoc naming the token" block ruby "$HD_TOKEN_BODY"

# --- KNOWN LIMITATION (measured, not desired): a heredoc body containing PARENTHESES ---
# --- never reaches the language classifier. command-ir treats `(`/`)` as segment ---
# --- separators, so the body splits into segments — one of them the bare token path — ---
# --- and the scan fails closed before the stdin route runs. Every recognized read-only ---
# --- shape has parentheses, so no heredoc-delivered read can be approved today.
# --- SR-hd6 is the discriminator: cat, which has no stdin route at all, blocks on the ---
# --- SAME body. That is what proves the block is the parse pre-emption above and not ---
# --- the language scoping — SR-hd2 shows this same reader/body pairing approving once ---
# --- the parentheses are gone.
hd_case "SR-hd5 node heredoc, recognized read-only shape, blocked anyway" block node "$HD_READ_BODY"
hd_case "SR-hd6 cat heredoc, same shape, blocks identically (parse pre-emption)" block cat "$HD_READ_BODY"

# --- An UNTERMINATED heredoc delivers a body at runtime that no regex can extract, so ---
# --- the reader's identity is the only thing left to decide on: interpreter readers ---
# --- fail closed on mention alone, cat does not. The minter row keeps that fail-closed ---
# --- branch from degenerating into "any unterminated heredoc blocks". ---
hd_case "SR-hdu1 unterminated node heredoc naming the token" block node "$HD_TOKEN_BODY" open
hd_case "SR-hdu2 unterminated cat heredoc, same body" approve cat "$HD_TOKEN_BODY" open
hd_case "SR-hdu3 unterminated node heredoc naming only the minter" approve node "$HD_MINTER_BODY" open

rm -r -f "$TMP" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Unit companion: the rows above only see the final verdict, so a shape-table
# regression could hide behind a different route. Asserted both directions.
# The call is arity-adaptive on purpose — the fix is expected to take the
# delivering interpreter's identity as a second argument, and these rows must
# assert the SAME property before and after that signature change.
# ---------------------------------------------------------------------------
echo ""
echo "=== LSU: interpreterBodyIsRecognizedReadOnly, per delivering language ==="
LSU_OUT="$("$RWT" 40 node -e '
const is = require(process.argv[1] + "/hooks/block-clearance-token-write/interpreter-scan.js");
const ro = is.interpreterBodyIsRecognizedReadOnly;
const call = (body, lang) => (ro.length >= 2 ? ro(body, lang) : ro(body));
const Q = String.fromCharCode(39);
const TOK = "/wf/wsid.off-clearance";
const rows = [
  [false, "ruby", "ruby open(pipe rm)",    "open(" + Q + "|rm -f " + TOK + Q + ")"],
  [false, "ruby", "ruby open(pipe echo)",  "open(" + Q + "|echo x" + Q + ")"],
  [false, "ruby", "ruby open(> literal)",  "open(" + Q + ">" + TOK + Q + ")"],
  [false, "ruby", "ruby open(bare token)", "open(" + Q + TOK + Q + ")"],
  [true,  "node", "node bare readFileSync", "require(" + Q + "fs" + Q + ").readFileSync(" + Q + TOK + Q + ")"],
  [true,  "node", "node console.log(readFileSync)", "console.log(require(" + Q + "fs" + Q + ").readFileSync(" + Q + TOK + Q + "))"],
  [true,  "python", "python bare open(t).read()", "open(" + Q + TOK + Q + ").read()"],
  [true,  "python", "python print(open(t).read())", "print(open(" + Q + TOK + Q + ").read())"],
  // deno / bun are the other two FALLBACK_INTERPRETER_NAMES, and the shape comments in
  // interpreter-scan.js scope the node alternation to "node / deno / bun" deliberately:
  // require("fs").readFileSync is a real, inert API in both runtimes, so the node shape
  // MAY vouch for them — unlike ruby, whose Kernel#open is a different grammar. Scoping
  // the shapes by language must preserve that, in both directions.
  [true,  "deno", "deno bare readFileSync (node-compat fs)", "require(" + Q + "fs" + Q + ").readFileSync(" + Q + TOK + Q + ")"],
  [false, "deno", "deno Deno.writeTextFileSync", "Deno.writeTextFileSync(" + Q + TOK + Q + "," + Q + "x" + Q + ")"],
  [true,  "bun",  "bun bare readFileSync (node-compat fs)", "require(" + Q + "fs" + Q + ").readFileSync(" + Q + TOK + Q + ")"],
  [false, "bun",  "bun writeFileSync", "require(" + Q + "fs" + Q + ").writeFileSync(" + Q + TOK + Q + "," + Q + "x" + Q + ")"],
];
for (const [want, lang, label, body] of rows) {
  let got, threw = null;
  try { got = call(body, lang); } catch (e) { threw = e && e.message; }
  if (threw !== null) process.stdout.write("NG|LSU " + label + " threw: " + threw + "\n");
  else if (got === want) process.stdout.write("OK|LSU " + label + " -> " + got + "\n");
  else process.stdout.write("NG|LSU " + label + " (as " + lang + ") want=" + want + " got=" + got + "\n");
}
process.stdout.write("DONE|" + rows.length + "\n");
' "$_AGENTS_DIR_NODE" 2>&1)"

LSU_DONE=no
while IFS= read -r line; do
    case "$line" in
        OK\|*)   pass "${line#OK|}" ;;
        NG\|*)   fail "${line#NG|}" ;;
        DONE\|*) LSU_DONE=yes ;;
        "")      ;;
        *)       echo "  (node stderr: $line)" ;;
    esac
done <<< "$LSU_OUT"

# A node crash prints nothing, and the whole unit table would vanish into a green
# "0 passed, 0 failed" without this.
if [ "$LSU_DONE" = "yes" ]; then
    pass "LSU-run the shape table ran to completion"
else
    fail "LSU-run the shape table did NOT complete (node crashed or timed out); output=$LSU_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
