# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, robustness, idempotency, edge-case, scope:issue-specific
# H4/H5/H6 — idempotency, non-string input, multi-heredoc greediness, and the
# CRLF / 200KB fixture cases that must be bounded-time and non-throwing.
# H12 — degenerate delimiter/body edges: an EMPTY body and a 220-char delimiter.
# Sourced by feature-2121-heredoc-strip-widening.sh.

# ── H4 — idempotency + robustness. Re-stripping an already-stripped string must
# not change it again, and non-string input must never throw out of the hook.
run_H4() {
    local got
    got="$(run_with_timeout 30 node -e '
try {
  const {stripHeredocBody}=require(process.argv[1]);
  const once=stripHeredocBody(process.argv[2]);
  process.stdout.write(String(stripHeredocBody(once)===once));
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" "$(printf '%b' "cat <<'EOF' > x\\na; b\\nEOF\\n")" 2>/dev/null)"
    assert_eq "H4 idempotent: stripping twice equals stripping once" "true" "$got"

    got="$(run_with_timeout 30 node -e '
try {
  const {stripHeredocBody}=require(process.argv[1]);
  const vals=[null,undefined,42,{},[],""];
  process.stdout.write(vals.map(v=>{try{stripHeredocBody(v);return "ok";}catch(e){return "throw";}}).join(","));
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" 2>/dev/null)"
    assert_eq "H4 non-string input never throws (a throw fails the hook OPEN)" "ok,ok,ok,ok,ok,ok" "$got"
}

run_H5() {
    # H5 — two heredocs in one command. Pins two properties a single-heredoc case
    # cannot see: the body match must be non-greedy (a greedy one runs from the first
    # opener to the LAST terminator, swallowing the second opener and its redirect
    # target), and the replace must be global (a non-global one leaves the second
    # body in place, where its operators are re-read as sequencing).
    local two="cat <<'EOF' > a.txt\\nAAABODY\\nEOF\\ncat <<'EOF' > b.txt\\nBBBBODY\\nEOF\\n"
    assert_eq "H5 first body stripped" "true" "$(body_gone "$two" "AAABODY")"
    assert_eq "H5 second body stripped too (replace is global)" "true" "$(body_gone "$two" "BBBBODY")"
    assert_eq "H5 second opener's redirect target survives (match is non-greedy)" "false" \
        "$(body_gone "$two" "b.txt")"
    assert_eq "H5 first opener's redirect target survives" "false" "$(body_gone "$two" "a.txt")"
}

run_H6() {
    # H6 (C7 round 1; FALSE-GREEN FIX C4, round 3) — CRLF and long bodies must be
    # bounded-time, non-throwing AND correct. Round 3: the old `got != "ERROR"` check
    # was false-green — `stripped` swallows every failure into empty stdout, so a
    # timeout kill / launch failure / Windows argv-length overflow all scored PASS.
    # Now: the node process must EXIT 0 and emit the exact expected verdict, and the
    # 200KB body arrives via a FIXTURE FILE (argv caps near 32KB on Windows — the very
    # failure the weak assertion was hiding).
    local out st fsize
    local crlf="$H_TMP_N/h6-crlf.txt" long="$H_TMP_N/h6-long.txt"

    # CRLF fixture built inside node, so no shell/MSYS layer can rewrite the \r.
    node -e 'require("fs").writeFileSync(process.argv[1], "cat <<\x27EOF\x27 > x\r\nSECRETBODY\r\nEOF\r\n")' "$crlf" 2>/dev/null
    if [ -s "$crlf" ]; then pass "H6 CRLF: fixture written (case is not vacuous)"
    else fail "H6 CRLF: fixture file was NOT written — the case below cannot run"; fi

    out="$(strip_fixture "$SQA" "$crlf" "SECRETBODY")"; st=$?
    if [ "$st" -eq 0 ]; then pass "H6 CRLF: node exited 0 (no throw, no timeout kill)"
    else fail "H6 CRLF: node exited $st — throw/timeout/launch failure, NOT a success"; fi
    assert_eq "H6 CRLF: body is stripped and its text is gone" "changed:gone" "$out"

    node -e 'require("fs").writeFileSync(process.argv[1], "cat <<\x27EOF\x27 > out.txt\n" + "y".repeat(200000) + "\nSECRETBODY\nEOF\n")' "$long" 2>/dev/null
    fsize="$(node -e 'try{process.stdout.write(String(require("fs").statSync(process.argv[1]).size));}catch(e){process.stdout.write("0");}' "$long" 2>/dev/null)"
    if [ "${fsize:-0}" -ge 200000 ]; then pass "H6 long body: fixture is >=200KB (fsize=$fsize — case is not vacuous)"
    else fail "H6 long body: fixture is only ${fsize:-0} bytes — the 200KB case did NOT run"; fi

    out="$(strip_fixture "$SQA" "$long" "SECRETBODY")"; st=$?
    if [ "$st" -eq 0 ]; then pass "H6 long body: node exited 0 (bounded time, no throw, no timeout kill)"
    else fail "H6 long body: node exited $st — backtracking/timeout/throw, NOT a success"; fi
    assert_eq "H6 long body: 200KB body is stripped and its text is gone" "changed:gone" "$out"

    # Idempotency on a WIDENED non-cat opener, with the same status guard.
    out="$(run_with_timeout 30 node -e '
const {stripHeredocBody}=require(process.argv[1]);
const once=stripHeredocBody(process.argv[2]);
process.stdout.write(String(stripHeredocBody(once)===once));
' "$SQA" "$(printf '%b' "tee out.txt <<'EOF'\\na; b\\nEOF\\n")" 2>/dev/null)"; st=$?
    if [ "$st" -eq 0 ]; then pass "H6 idempotency probe: node exited 0"
    else fail "H6 idempotency probe: node exited $st — not a result, a failure"; fi
    assert_eq "H6 idempotent on a widened non-cat opener (tee)" "true" "$out"
}

# ── H12 — the two DEGENERATE edges of the opener/terminator pair that H6's size
# and encoding cases do not reach: a body of length zero, and a delimiter word far
# longer than any realistic tag. rules/test.md edge-case classes "empty" and
# "extremely long" applied to the delimiter/body axis rather than the input axis.
run_H12() {
    # (a) EMPTY BODY. The body branch is `\n([\s\S]*?)\n\s*\4`, so it needs TWO
    # newlines between the opener line and the terminator. `cat <<'EOF'\nEOF` has
    # only one, and therefore never matches. PINNED AS OBSERVED, not asserted as
    # desired — and the direction is fail-safe: nothing is removed, so nothing is
    # hidden from the write scanners. The smallest body the regex DOES match is a
    # single blank line, which is the boundary partner of the rows above it.
    assert_eq "H12 empty body: cat <<'EOF' with no body line at all is NOT stripped (pinned, fail-safe)" "false" \
        "$(stripped "cat <<'EOF'\\nEOF\\n")"
    assert_eq "H12 empty body with a redirect: still not stripped" "false" \
        "$(stripped "cat <<'EOF' > out.txt\\nEOF\\n")"
    assert_eq "H12 empty body: text AFTER the terminator stays visible (over-visible = fail-safe)" "false" \
        "$(body_gone "cat <<'EOF'\\nEOF\\nRMPAYLOAD\\n" "RMPAYLOAD")"
    assert_eq "H12 boundary partner: ONE blank line is the smallest body that IS stripped" "true" \
        "$(stripped "cat <<'EOF' > out.txt\\n\\nEOF\\n")"

    # (b) EXTREMELY LONG DELIMITER. The tag charset is unbounded
    # (`[A-Za-z_][A-Za-z0-9_.-]*`), and the terminator branch backreferences it, so
    # a 220-character tag must still pair up — in bounded time, without throwing.
    # Built as a FIXTURE FILE for the same reason H6's 200KB body is (argv caps near
    # 32KB on Windows) and so the node exit status is assertable.
    local out st
    local ltfile="$H_TMP_N/h12-longtag.txt" mmfile="$H_TMP_N/h12-longtag-mismatch.txt"

    node -e 'const t="E".repeat(220);require("fs").writeFileSync(process.argv[1],"cat <<\x27"+t+"\x27 > out.txt\nSECRETBODY\n"+t+"\n")' "$ltfile" 2>/dev/null
    if [ -s "$ltfile" ]; then pass "H12 long-delimiter fixture written (case is not vacuous)"
    else fail "H12 long-delimiter fixture was NOT written — the case below cannot run"; fi
    out="$(strip_fixture "$SQA" "$ltfile" "SECRETBODY")"; st=$?
    if [ "$st" -eq 0 ]; then pass "H12 long delimiter: node exited 0 (bounded time, no throw, no timeout kill)"
    else fail "H12 long delimiter: node exited $st — backtracking/timeout/throw, NOT a success"; fi
    assert_eq "H12 220-char delimiter: opener and terminator pair up, body is stripped" "changed:gone" "$out"

    # Negative partner: one extra character on the terminator must break the pair,
    # so the "changed:gone" above is the backreference matching, not a wildcard.
    node -e 'const t="E".repeat(220);require("fs").writeFileSync(process.argv[1],"cat <<\x27"+t+"\x27 > out.txt\nSECRETBODY\n"+t+"X\n")' "$mmfile" 2>/dev/null
    if [ -s "$mmfile" ]; then pass "H12 mismatched-delimiter fixture written (case is not vacuous)"
    else fail "H12 mismatched-delimiter fixture was NOT written — the case below cannot run"; fi
    out="$(strip_fixture "$SQA" "$mmfile" "SECRETBODY")"; st=$?
    if [ "$st" -eq 0 ]; then pass "H12 mismatched long delimiter: node exited 0"
    else fail "H12 mismatched long delimiter: node exited $st — not a result, a failure"; fi
    assert_eq "H12 220-char terminator off by ONE char: nothing stripped, body stays visible" "unchanged:present" "$out"
}
