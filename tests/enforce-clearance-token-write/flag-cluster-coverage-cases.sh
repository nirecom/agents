#!/usr/bin/env bash
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/lib/protected-basenames.js
# Tags: anti-cheat, off-clearance, clearance-token, pretooluse, interpreter-scan, flag-cluster, allow-direction, negative-assertion, table-driven, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook firing on a real host. Covered by tests/TL3-hook-clearance-token-write.sh.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
# Split from read-only-allowlist-cases.sh at its 300-line WARN line
# (rules/coding/file-split.md Pattern A): the #1816 cluster path's ALLOW direction
# (CF-*), blocked-target survival (SV-*), and second interpreter-name spellings (CP-*).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# shellcheck source=tests/lib/clearance-hook-harness.sh
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

if [ "$HOOK_PRESENT" = "yes" ]; then pass "H0 hook file present"; else fail "H0 hook file MISSING at $HOOK - all cases below are vacuous"; fi

# Columns: name | want | payload (payload must not itself contain '|').
# @TOK@ = absolute token path, @DIR@ = workflow dir.
while IFS='|' read -r name want payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"; payload="$(trim "$payload")"
    payload="${payload//@TOK@/$TOKEN}"
    payload="${payload//@DIR@/$TN}"
    assert_verdict "$name" "$want" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
done <<'TABLE'
# --- CF: the #1816 ALLOW direction through a COMBINED flag. The sibling's RD-ro1/RD-ro2 ---
# --- deliver their read-only body behind a PLAIN -c / -e, so nothing there proves a ---
# --- bundled flag can still approve. Each row delivers a genuinely inert body through a ---
# --- real cluster and must APPROVE. All four block on main @HEAD (the bare ---
# --- READONLY_BODY_SHAPES members are this PR's addition), so they can genuinely fail. ---
CF-allow1 python3 -uc bare open(token).read()            | approve | python3 -uc "open('@TOK@').read()"
CF-allow2 python3 -Iuc bare open(token).read()           | approve | python3 -Iuc "open('@TOK@').read()"
CF-allow3 node -pe bare readFileSync(token)              | approve | node -pe "require('fs').readFileSync('@TOK@')"
CF-allow4 python -uc bare read (the OTHER python name)   | approve | python -uc "open('@TOK@').read()"
# --- Each allow row faces a write row differing by one token, so an allowlist that ---
# --- started vouching for writes behind a cluster reddens instead of staying green. ---
CF-adj1 python3 -uc open(token,'w').write vs CF-allow1   | block   | python3 -uc "open('@TOK@','w').write('x')"
CF-adj2 node -pe writeFileSync(token) vs CF-allow3       | block   | node -pe "require('fs').writeFileSync('@TOK@','x')"
# --- CF-fc*: the MEASURED verdict for a read-only body behind a cluster that outruns ---
# --- the extractor. Tier-1's new alternations arm on the WIDE cluster, but Tier-2's ---
# --- flagRe still carries FLAG_ALTS's {0,2} bound, so no body is extracted and ---
# --- `bodies.length === 0` fails CLOSED (interpreter-scan.js) — detail.md ---
# --- `## Risks & edge cases` accepts that asymmetry deliberately. These rows PIN the ---
# --- fail-closed block; they are not an allow row in disguise. Each faces a -ctrl row ---
# --- carrying the SAME body behind a narrow flag, so cluster WIDTH is the single ---
# --- variable: a reddening -ctrl means the body layer broke, not the fail-closed branch. ---
CF-fc1 python3 -Piuc bare read is fail-CLOSED, not allowed | block | python3 -Piuc "open('@TOK@').read()"
CF-fc1-ctrl python3 -uc same body, narrow flag           | approve | python3 -uc "open('@TOK@').read()"
CF-fc2 bun -wxyze bare read is fail-CLOSED               | block   | bun -wxyze "require('fs').readFileSync('@TOK@')"
CF-fc2-ctrl bun -e same body, narrow flag                | approve | bun -e "require('fs').readFileSync('@TOK@')"
CF-fc3 deno -wxyze read is fail-CLOSED                   | block   | deno -wxyze "Deno.readTextFileSync('@TOK@')"
CF-fc4 ruby -wnrtye File.read is fail-CLOSED             | block   | ruby -wnrtye "File.read('@TOK@');"
# --- CP: CPR-ORTH over the interpreter-name lists. A list with two spellings and only ---
# --- one exercised would stay green after the second was dropped. ---
# --- PYTHON_INTERPRETER_NAMES = ["python","python3"] and every #1816 row used python3; ---
# --- these use the bare name and can ONLY match via PYTHON_CLUSTER_FLAG (the generic ---
# --- CLUSTER_FLAG {0,2} bound cannot reach a 3+ letter prefix). Both approve on main ---
# --- @HEAD, so dropping "python" from the list reddens them. ---
CP-py-bare1 python -Piuc writing the token               | block   | python -Piuc "open('@TOK@','w').write('x')"
CP-py-bare2 python -bBiuxSPqhIOuc writing the token      | block   | python -bBiuxSPqhIOuc "open('@TOK@','w').write('x')"
CP-py-bare1-ctrl python3 -Piuc same body                 | block   | python3 -Piuc "open('@TOK@','w').write('x')"
# --- LANGUAGE_INTERPRETER_NAMES carries "node" AND "nodejs"; only "node" was exercised. ---
CP-nodejs-write nodejs -e writeFileSync(token)           | block   | nodejs -e "require('fs').writeFileSync('@TOK@','x')"
CP-nodejs-read nodejs -pe bare readFileSync(token)       | approve | nodejs -pe "require('fs').readFileSync('@TOK@')"
# --- PWSH_INTERPRETER_NAMES carries "pwsh" AND "powershell"; the sibling reaches ---
# --- powershell only through the interpolation prefilter (IP3), never the -Command path. ---
CP-pwsh-alt-block powershell -ExecutionPolicy naming the token | block | powershell -ExecutionPolicy Bypass -Command "Get-Content ./unrelated.txt; echo @TOK@"
CP-pwsh-alt-allow powershell -Command Get-Content -Raw token   | approve | powershell -Command "Get-Content -Raw '@TOK@'"
# --- SHELL_INTERPRETER_NAMES = ["bash","sh","zsh","dash","busybox"]; only bash had a row ---
# --- (CL-bash in the sibling). These four reach the same redirect classification. ---
CP-sh sh -exc redirect into the token                    | block   | sh -exc "echo forged > @TOK@ ; true"
CP-zsh zsh -exc redirect into the token                  | block   | zsh -exc "echo forged > @TOK@ ; true"
CP-dash dash -exc redirect into the token                | block   | dash -exc "echo forged > @TOK@ ; true"
CP-busybox busybox -exc redirect into the token          | block   | busybox -exc "echo forged > @TOK@ ; true"
TABLE

# FC-char - one case per CHARACTER of the #1816 cluster alphabets. The CF/CP
# rows above sample whole clusters, so a letter silently dropped from
# PYTHON_CLUSTER_CHARSET / PERL_CLUSTER_CHARSET leaves them all green.

# Each flag repeats its one character 5x before the terminator: the generic
# CLUSTER_FLAG admits at most 2 letters on either side of [ce], so a 5x run is
# out of its reach and ONLY the language alphabet can explain a block -
# including for `c`, the single letter the two alphabets share. The alphabets
# are spelled out HERE rather than read from the source, so removing a
# character reddens its row; pin_charset catches the reverse drift.
PY_CHARSET_PIN='BbdEhiIOPqsSuvVx'
PERL_CHARSET_PIN='aCcDdFfgIilMmnpSsTtUuVvWwXx'
SCAN_SRC="$AGENTS_DIR/hooks/block-clearance-token-write/interpreter-scan.js"
FC_REP=5

pin_charset() {  # <const-name> <expected>
    local name="$1" want="$2" got
    got="$(sed -n "s/^const $name = \"\([^\"]*\)\";.*/\1/p" "$SCAN_SRC" | head -1)"
    if [ "$want" = "$got" ]; then
        pass "FC-pin $name is the alphabet the FC-char rows enumerate"
    else
        fail "FC-pin $name drifted - want='$want' got='$got'; add or drop the matching FC-char row"
    fi
}
pin_charset PYTHON_CLUSTER_CHARSET "$PY_CHARSET_PIN"
pin_charset PERL_CLUSTER_CHARSET "$PERL_CHARSET_PIN"

repeat_char() {  # <char> <count>
    local ch="$1" n="$2" out="" i=0
    while [ "$i" -lt "$n" ]; do out="$out$ch"; i=$((i + 1)); done
    printf '%s' "$out"
}

# Perl has no READONLY_BODY_SHAPES, so any body naming the token blocks once the
# cluster arms Tier-1; the python body is a plain write for the same reason.
FC_PY_BODY="open('$TOKEN','w').write('x')"
FC_PERL_BODY="open(F,'$TOKEN');print F 'x';"

fc_char_case() {  # <label> <interpreter> <char> <terminator> <body> <want>
    local label="$1" interp="$2" ch="$3" term="$4" body="$5" want="$6" flag
    flag="-$(repeat_char "$ch" "$FC_REP")$term"
    assert_verdict "FC-$label [$ch] $interp $flag naming the token" "$want" \
        "$(run_hook "$TN" "$(mk_bash_input "$interp $flag \"$body\"")")"
}

fc_alphabet_sweep() {  # <label> <interpreter> <alphabet> <terminator> <body>
    local label="$1" interp="$2" alphabet="$3" term="$4" body="$5" i=0
    while [ "$i" -lt "${#alphabet}" ]; do
        fc_char_case "$label" "$interp" "${alphabet:$i:1}" "$term" "$body" block
        i=$((i + 1))
    done
}

fc_alphabet_sweep py python3 "$PY_CHARSET_PIN" c "$FC_PY_BODY"
fc_alphabet_sweep perl perl "$PERL_CHARSET_PIN" e "$FC_PERL_BODY"

# The symmetric direction: letters OUTSIDE each alphabet must leave Tier-1
# disarmed, so the identical body approves. Without these the sweeps above stay
# green even if the charset had been replaced by a bare [A-Za-z].
for _ch in Z k w y; do fc_char_case py-out python3 "$_ch" c "$FC_PY_BODY" approve; done
for _ch in k y z Q; do fc_char_case perl-out perl "$_ch" e "$FC_PERL_BODY" approve; done

# PERL_CLUSTER_FLAG terminates on [eE]; only the lowercase half was exercised
# above, and PYTHON_CLUSTER_FLAG's terminator is lowercase-c ONLY (POSIX short
# flags are case-sensitive) - both halves of each pair are written out.
fc_char_case perl-upper-E perl a E "$FC_PERL_BODY" block
fc_char_case perl-upper-E-out perl k E "$FC_PERL_BODY" approve
fc_char_case py-upper-C-out python3 B C "$FC_PY_BODY" approve

# SV - protection-fix-tests.md Pattern 1 (negative assertion). Every #1816 block row here
# and in the sibling asserts against a token path that does NOT exist, so "block" cannot
# be told apart from "nothing was written because the target was absent". These rows SEED
# a real token file with known content, then assert the block AND byte-identical survival.
# The hook never executes the command, so the survival half can only fail one way - that
# is the point: it makes the PRECONDITION real (the resource existed and was reachable)
# and turns the block into a claim about a live target. Kept out of the table because
# each row needs seed/verify steps around the assert.
SEED_CONTENT='SEEDED-TOKEN-BODY-do-not-clobber'
seeded_block_case() {  # <label> <payload>
    local label="$1" payload="$2" got
    printf '%s' "$SEED_CONTENT" > "$TMP/wsid.off-clearance"
    if [ ! -f "$TMP/wsid.off-clearance" ]; then
        fail "$label seeding failed - the case would assert nothing about a live target"
        return
    fi
    assert_block "$label (target seeded and live)" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
    if [ ! -f "$TMP/wsid.off-clearance" ]; then
        fail "$label-survives the seeded token is GONE after the blocked call"
        return
    fi
    got="$(cat "$TMP/wsid.off-clearance" 2>/dev/null)"
    if [ "$got" = "$SEED_CONTENT" ]; then
        pass "$label-survives the seeded token is byte-identical after the blocked call"
    else
        fail "$label-survives the seeded token CHANGED: want='$SEED_CONTENT' got='$got'"
    fi
}

# One row per interpreter family the #1816 widening touches, plus the redirect route.
seeded_block_case "SV-py python3 -Piuc clobbering a seeded token" \
    "python3 -Piuc \"open('$TOKEN','w').write('CLOBBERED')\""
seeded_block_case "SV-perl perl -wnle clobbering a seeded token" \
    "perl -wnle \"open(F,'>','$TOKEN');print F 'CLOBBERED';\""
seeded_block_case "SV-ruby ruby -wnrtye clobbering a seeded token" \
    "ruby -wnrtye \"File.write('$TOKEN','CLOBBERED');\""
seeded_block_case "SV-redirect sh -exc redirect over a seeded token" \
    "sh -exc \"echo CLOBBERED > $TOKEN ; true\""

# The paired negative for the seeding itself: without it every SV-*-survives PASS would
# also score green on a read-only fixture dir, or if the writes landed elsewhere.
printf '%s' "$SEED_CONTENT" > "$TMP/wsid.off-clearance"
printf 'CLOBBERED' > "$TMP/wsid.off-clearance"
if [ "$(cat "$TMP/wsid.off-clearance" 2>/dev/null)" = "CLOBBERED" ]; then
    pass "SV-fixture an UNGUARDED write to the same path does change it (SV survival halves can fail)"
else
    fail "SV-fixture the fixture token is not writable at all - every SV-*-survives PASS above is vacuous"
fi

rm -r -f "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
