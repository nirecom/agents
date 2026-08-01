#!/usr/bin/env bash
# tests/feat-1763-issue-request-patterns.sh
# Tests: hooks/lib/issue-request-patterns.js
# Tags: issue-create, provenance, patterns, regex, table-driven, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - The UserPromptSubmit hook actually receiving a real prompt (tests/TL3-hook-issue-provenance-mint.sh).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# S9: isIssueCreationRequest(promptText) — deterministic, no LLM.
#   Layer A: /issue-create slash form.
#   Layer B: issue-noun + request-modality function word (NOT a closed verb list — C3).
#   Preprocessing: fenced code, inline code and quoted (`>`) lines are stripped before scanning.
# The positive cases below use verbs deliberately absent from any plausible closed
# verb list — they are the regression guard against re-introducing verb enumeration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
MOD="$AGENTS_DIR/hooks/lib/issue-request-patterns.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

MOD_PRESENT=no; [ -f "$MOD" ] && MOD_PRESENT=yes

# eval_subject <prompt-text-with-\n-escapes> → "yes" | "no" | "<missing>"
eval_subject() {
    [ "$MOD_PRESENT" = "yes" ] || { printf '<missing>'; return; }
    local text; text=$(printf '%b' "$1")
    TEXT="$text" "$RWT" 12 node -e "
try {
  const m = require(process.argv[1]);
  process.stdout.write(m.isIssueCreationRequest(process.env.TEXT) ? 'yes' : 'no');
} catch (e) { process.stdout.write('err:' + e.message); }
" "$(node_path "$MOD")" 2>/dev/null
}

echo "=== isIssueCreationRequest — table-driven (positive + negative) ==="

while IFS='|' read -r name input want; do
    name="$(trim "$name")"
    [[ -z "$name" || "$name" =~ ^# ]] && continue
    input="$(trim "$input")"
    want="$(trim "$want")"
    got=$(eval_subject "$input")
    if [ "$got" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: hooks/lib/issue-request-patterns.js not yet created (want=$want)"
    else
        assert_eq "$name" "$want" "$got"
    fi
done <<'TABLE'
# ---- Layer A: slash command form ----
P1-slash-plain            | /issue-create foo                          | yes
P2-slash-only             | /issue-create                              | yes
P3-slash-leading-space    |   /issue-create bar                        | yes
# ---- Layer B (ja): noun + request modality, verbs deliberately unlisted ----
P4-ja-create              | issue を作成して                            | yes
P5-ja-ticket-kihyou       | この件チケット起票して                        | yes
P6-ja-kadai-register      | 課題として登録しておいて                       | yes
P7-ja-issue-kiru          | issue 切っといて                            | yes
P8-ja-issue-tateru        | イシュー立てといて                           | yes
P9-ja-bugticket-tsumu     | バグ票積んでおいて                           | yes
P10-ja-fuguai-onegai      | 不具合票 お願いします                         | yes
P11-ja-hayashite          | 課題を生やしてほしい                          | yes
# ---- Layer B (en): noun + request modality ----
P12-en-please-open        | please open an issue for this               | yes
P13-en-can-you-file       | can you file a ticket                       | yes
P14-en-lets-raise         | let's raise an issue                        | yes
P15-en-imperative-create  | create an issue for the flaky hook          | yes
# ---- Negatives: descriptive context, no request ----
N1-ja-descriptive         | issue を作成する機能を直して                    | no
N2-noun-only-ja           | このイシューについて                          | no
N3-noun-only-en           | the issue with the parser                   | no
N4-modality-only-ja       | これお願いします                             | no
N5-modality-only-en       | can you take a look at this                 | no
N6-unrelated              | run the tests and report the result         | no
N7-slash-lookalike        | the /issue-create skill is documented here  | no
# ---- Negatives: an issue noun + a request modality that is NOT about creating one.
# This is the shape the classifier is most likely to get wrong, because every surface
# signal Layer B looks for is present — noun, modality, imperative. What is absent is
# the CREATION modality: each of these refers to an issue that already exists, marked
# by a number or a definite determiner. Minting `user-explicit` here would hand the
# confirm gate a false alibi on any turn where the user merely discussed an issue.
N12-en-close-numbered     | close issue 123                             | no
N13-en-review-this        | please review this issue                    | no
N14-en-investigate-the    | investigate the issue                       | no
N15-en-comment-on-ticket  | can you comment on ticket #4                | no
N16-en-triage-existing    | let's triage the existing issues            | no
# The JA side is the same class and gets the same treatment (CPR-5): a determiner or a
# number is what marks the referent as existing, in either language.
N17-ja-close-numbered     | 課題 123 を閉じておいて                        | no
N18-ja-review-this        | この課題をレビューしてください                    | no
N19-ja-investigate-the    | 該当のイシューを調査してほしい                    | no
N20-ja-comment-numbered   | issue #12 にコメントしておいて                  | no
TABLE

echo ""
echo "=== preprocessing: fenced / inline code / quoted lines are stripped ==="

# These carry newlines, so they live outside the table (heredoc rows are line-based).
while IFS='|' read -r name input want; do
    name="$(trim "$name")"
    [[ -z "$name" || "$name" =~ ^# ]] && continue
    input="$(trim "$input")"
    want="$(trim "$want")"
    got=$(eval_subject "$input")
    if [ "$got" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: hooks/lib/issue-request-patterns.js not yet created (want=$want)"
    else
        assert_eq "$name" "$want" "$got"
    fi
done <<'TABLE'
N8-fenced-only    | look at this:\n```\nplease create an issue\n```\n                | no
N9-quoted-only    | as you said before:\n> please create an issue for this\n         | no
N10-inline-code   | the string `please create an issue` appears in the fixture      | no
N11-fenced-slash  | ```\n/issue-create foo\n```                                     | no
P16-fenced-plus-real-request | ```\nsome log output\n```\nplease open an issue for that | yes
P17-quote-plus-real-request  | > earlier context here\nチケット起票しておいて            | yes
TABLE

echo ""
echo "=== input cap: the scan is bounded, and the bound cuts rather than fails open ==="
# The classifier runs inside a UserPromptSubmit hook on text of unbounded length — a
# pasted log is an ordinary prompt. MAX_SCAN_CHARS caps what is scanned. Two things
# must both hold, and only the pair pins them: the cap must actually be reached (C2),
# and reaching it must not change the answer for text that fits (C1). A cap that
# silently returned `true` on oversized input would make every long paste a mint.
CAP=20000
eval_file() {  # <file> → "yes" | "no" | "<missing>"
    [ "$MOD_PRESENT" = "yes" ] || { printf '<missing>'; return; }
    "$RWT" 12 node -e "
try {
  const fs = require('fs');
  const m = require(process.argv[1]);
  const t = fs.readFileSync(process.argv[2], 'utf8');
  process.stdout.write(m.isIssueCreationRequest(t) ? 'yes' : 'no');
} catch (e) { process.stdout.write('err:' + e.message); }
" "$(node_path "$MOD")" "$(node_path "$2")" 2>/dev/null
}

CAPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t patcap)
trap 'rm -rf "$CAPDIR"' EXIT
# Padding is inert filler split into lines, so the cap's cut-at-last-newline keeps the
# end-of-line anchors in the JA modality patterns meaning what they say.
build_padded() {  # <file> <padding-chars> — request goes on the LAST line
    PAD="$2" node -e "
const fs = require('fs');
const n = Number(process.env.PAD);
let s = '';
while (s.length < n) s += 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n';
fs.writeFileSync(process.argv[1], s.slice(0, n) + '\nplease open an issue for this\n');
" "$(node_path "$1")"
}

build_padded "$CAPDIR/under.txt" $((CAP - 1000))
build_padded "$CAPDIR/over.txt"  $((CAP + 1000))
GOT=$(eval_file "" "$CAPDIR/under.txt")
if [ "$GOT" = "<missing>" ]; then
    fail "C1-request-within-cap-still-matches" "RED-EXPECTED: hooks/lib/issue-request-patterns.js not yet created (want=yes)"
else
    assert_eq "C1-request-within-cap-still-matches" "yes" "$GOT"
fi
GOT=$(eval_file "" "$CAPDIR/over.txt")
if [ "$GOT" = "<missing>" ]; then
    fail "C2-request-beyond-cap-is-not-scanned" "RED-EXPECTED: hooks/lib/issue-request-patterns.js not yet created (want=no)"
else
    assert_eq "C2-request-beyond-cap-is-not-scanned" "no" "$GOT"
fi

echo ""
echo "=== module export surface ==="
if [ "$MOD_PRESENT" != "yes" ]; then
    fail "X1-export-isIssueCreationRequest" "RED-EXPECTED: hooks/lib/issue-request-patterns.js not yet created"
else
    T=$("$RWT" 10 node -e "
try { const m = require(process.argv[1]);
  process.stdout.write(typeof m.isIssueCreationRequest === 'function' ? 'fn' : 'missing');
} catch (e) { process.stdout.write('err'); }
" "$(node_path "$MOD")" 2>/dev/null)
    [ "$T" = "fn" ] && pass "X1-export-isIssueCreationRequest" \
        || fail "X1-export-isIssueCreationRequest" "module does not export isIssueCreationRequest (got: $T)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
