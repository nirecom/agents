#!/bin/bash
# tests/unit-quote-spans-differential.sh
# Tests: hooks/lib/quote-spans.js, hooks/lib/strip-quoted-args.js, hooks/lib/command-ir.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: hook, quote-spans, differential, parser, security, regression, scope:common
#
# STATUS: RED until C1 and C2 land.
#   - Phase A (frozen-vs-golden, 73 assertions + 1 alignment row) is GREEN today
#     and must stay green: it pins the OLD-implementation baseline byte for byte.
#   - Phase B (hasUnclosedQuote old-vs-new) is RED — hooks/lib/quote-spans.js
#     does not exist yet.
#   - Phase C (stripQuotedArgs / stripDqPreservingCmdSubst) is GREEN today
#     (old side == new side, since C2 has not rewritten them as wrappers yet)
#     and is the regression gate that fires the moment C2 changes behaviour.
#   - Phase D (foldDqNewlines vs foldNewlinesInSpans(str,["dq"])) is RED.
#
# Old-vs-new differential over a >=45-case corpus harvested from:
#   tests/fix-strip-quoted-args-lib.sh, tests/unit-command-ir.sh,
#   tests/fix-1424-1425-1448-write-detector.sh,
#   tests/feature-parallel-sessions-worktree-bash-patterns/dq-and-strip.sh,
#   the 7 historical false positives (#1568 #1533 #1457 #1449 #1385 #1191, PR #1612),
#   and the mandatory 14-case span table in tests/unit-quote-spans/structure.sh.
#
# ORACLE INTEGRITY (phase A). The frozen copies under tests/fixtures/
# quote-spans-frozen/ are the "old" side of every comparison below. Checking
# only that they return the right TYPES would let a corrupted, truncated or
# quietly-refactored frozen copy redefine the baseline while the differential
# stayed green. Phase A therefore compares frozen output against
# tests/fixtures/quote-spans-golden.jsonl — a byte-level record of the
# PRE-migration outputs — for all four functions on every corpus row, aligned by
# input rather than by index.
#
# Diff policy:
#   hasUnclosedQuote            -> byte equality, ZERO diffs allowed.
#   stripQuotedArgs             -> diffs allowed only via DIFF_ALLOWLIST below.
#   stripDqPreservingCmdSubst   -> same.
#   foldDqNewlines              -> same.
#
# TL3 gap (what this TL2 test does NOT catch):
# - the refactored functions running inside the live enforce-worktree.js /
#   scan-outbound hook processes on real Claude Code Bash payloads
# - divergence on inputs outside the frozen corpus (the corpus is a sample, not
#   the full input domain)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

RUNNER="${_AGENTS_DIR_NODE}/tests/fixtures/quote-spans-differential.js"
CORPUS="${_AGENTS_DIR_NODE}/tests/fixtures/quote-spans-corpus.txt"
GOLDEN="${AGENTS_DIR}/tests/fixtures/quote-spans-golden.jsonl"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DIFF ALLOWLIST (in-file, authoritative).
#
# Row format (tab-separated, six fields):
#   <fn>	<JSON-encoded input>	direction: stricter	class: <cls>	expose: <literal>	<why>
#
# `<fn>` is one of: stripQuotedArgs | stripDqPreservingCmdSubst | foldDqNewlines
# (hasUnclosedQuote is NOT allowlistable — it must be byte-identical.)
#
# Listing an input is NOT enough. Each row declares WHICH relation it claims,
# and tests/fixtures/quote-spans-differential/relation.js proves it from the two
# outputs — an allowlisted row that quietly deleted a path, an argument, an
# occurrence or any other unlisted text now fails:
#
#   class: unchanged    the scan is ok:false, so the new output must be the INPUT
#                       byte-for-byte. An exact pin; `expose: -` is allowed only
#                       for this class, because the class already pins the whole
#                       output.
#   class: expose-more  the new output must carry EVERY word atom of the old
#                       output with at least the same multiplicity, and may not
#                       hide any metacharacter the old output exposed. This is
#                       the security direction — losing `rm -rf x` fails even
#                       though the row is allowlisted.
#   class: blank-more   the old regex leaked text out of a quote span. The new
#                       output may INVENT no word atom the old one lacked, and
#                       every atom it drops must occur in the input ONLY inside
#                       a dq/sq/ansic span. A new implementation that swallowed
#                       unquoted command text fails that second obligation.
#
# `expose:` names a literal that must be present in the NEW output, so no row
# can pass by collapsing to an empty string.
#
# The #1569 refactor is behaviour-preserving EXCEPT for two grammar defects it
# is explicitly chartered to fix:
#
#   (i)  ANSI-C rescan. Old stripQuotedArgs matches `$'...'` with the regex
#        /\$'(?:[^'\\]|\\.)*'/g and then rescans the REMAINDER, so `$'it'\''s
#        fine'` comes back duplicated and `echo $'branch -d'` collapses to
#        `echo '`. The span-based replacement emits `$''` per ANSI-C span.
#        These are the `blank-more` rows: the text the old output leaked is
#        provably inside a quote span of the input.
#   (ii) `$()` termination by paren counting. Old stripDqPreservingCmdSubst
#        counts `(`/`)` without looking inside the body's quotes, so
#        `"$(printf ')'; rm -rf x)"` truncates at the SQ's `)` and returns
#        `""  printf '  ` — `rm -rf x` disappears from write detection
#        entirely. These are the `expose-more` rows.
#
# Anything NOT in one of those two classes is still an unlisted diff and FAILS.
# The runner additionally fails any allowlist entry whose input is not in the
# corpus (a dead key silently widens the allowlist).
# ─────────────────────────────────────────────────────────────────────────────
DIFF_ALLOWLIST=$(cat <<'ALLOWLIST'
# fn	input-json	direction	class	expose	reason
# (i) ANSI-C span replacement — old regex rescans the remainder after $'...'
stripQuotedArgs	"$'it'\\''s fine'"	direction: stricter	class: blank-more	expose: $''	old duplicates the tail (`\''s fine''\''s fine'`); new emits one `$''` per ANSI-C span
stripQuotedArgs	"echo $'branch -d'"	direction: stricter	class: blank-more	expose: echo	old collapses to `echo '` and loses the closing quote; new emits `$''`
stripQuotedArgs	"gh issue create --body $'it'\\''s fine'"	direction: stricter	class: blank-more	expose: --body	#1457 payload — same rescan defect as above
stripQuotedArgs	"$'a|b'"	direction: stricter	class: blank-more	expose: $''	old returns a bare `'`; new emits `$''`
stripQuotedArgs	"$'unclosed string"	direction: stricter	class: unchanged	expose: -	unterminated ANSI-C is now ok:false, so the transform returns the input untouched
stripQuotedArgs	"\"unclosed"	direction: stricter	class: unchanged	expose: -	unclosed DQ is one of the five error-contract cases (plan: 未閉じ DQ x 変換 API -> ok:false + out===str); old blanked the whole input to `""`
# (ii) $() termination — old paren counter ignores quotes inside the body
stripQuotedArgs	"$(echo a\\')b')"	direction: stricter	class: unchanged	expose: -	trailing unclosed SQ makes the scan ok:false; new returns the input untouched instead of blanking a guessed span
stripQuotedArgs	"$(echo $'a\\')b')"	direction: stricter	class: blank-more	expose: echo	mandatory case 3 — old treats the ANSI-C `\'` as a terminator and drops `a\'`
stripQuotedArgs	"\"$(echo $'a\\')b')\""	direction: stricter	class: expose-more	expose: echo	same, wrapped in DQ — old returns `""  echo   ')""` and loses body text
stripQuotedArgs	"$(printf ')'"	direction: stricter	class: unchanged	expose: -	unterminated cmdsubst is now ok:false; new returns the input untouched
stripQuotedArgs	"$( (echo x)"	direction: stricter	class: unchanged	expose: -	unterminated subshell inside cmdsubst is now ok:false
stripQuotedArgs	"\"$(printf ')'; rm -rf x)\""	direction: stricter	class: expose-more	expose: rm -rf x	old truncates at the SQ's `)` and HIDES `rm -rf x`; new keeps it visible to the write detector
stripQuotedArgs	"\"$(printf '\"')\""	direction: stricter	class: expose-more	expose: printf	DQ inside a cmdsubst body inside DQ — old and new disagree on where the body ends
stripDqPreservingCmdSubst	"$(printf ')'; rm -rf x)"	direction: stricter	class: unchanged	expose: -	paren counter stops at the SQ's `)`; the span scan keeps the whole body
stripDqPreservingCmdSubst	"\"$(printf ')'; rm -rf x)\""	direction: stricter	class: expose-more	expose: rm -rf x	the plan's named defect — old output `""  printf '  ` hides `rm -rf x`
stripDqPreservingCmdSubst	"$(echo a\\')b')"	direction: stricter	class: unchanged	expose: -	unclosed SQ → ok:false → input returned untouched
stripDqPreservingCmdSubst	"$(echo $'a\\')b')"	direction: stricter	class: unchanged	expose: -	mandatory case 3 — ANSI-C `\'` is not a terminator, so the body survives whole
stripDqPreservingCmdSubst	"\"$(echo $'a\\')b')\""	direction: stricter	class: expose-more	expose: echo	old returns `""  echo $'a\'  ` and hides `b')`
stripDqPreservingCmdSubst	"$(printf ')'"	direction: stricter	class: unchanged	expose: -	unterminated cmdsubst is now ok:false
stripDqPreservingCmdSubst	"\"unclosed"	direction: stricter	class: unchanged	expose: -	unclosed DQ is one of the five error-contract cases (plan: 未閉じ DQ x 変換 API -> ok:false + out===str); old blanked the whole input to `""`
stripDqPreservingCmdSubst	"$( (echo x)"	direction: stricter	class: unchanged	expose: -	unterminated subshell inside cmdsubst is now ok:false
stripDqPreservingCmdSubst	"\"$(printf '\"')\""	direction: stricter	class: expose-more	expose: printf	DQ inside a cmdsubst body inside DQ
# foldDqNewlines: no entry. Every corpus case that carries a newline has its DQ
# spans closed, so the span-based fold must be byte-identical to the old one.
# If a diff appears here it is a real regression, not an intended tightening.
ALLOWLIST
)

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t qsdiff)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT
ALLOW_FILE="$TMPDIR_BASE/allowlist.tsv"
printf '%s\n' "$DIFF_ALLOWLIST" > "$ALLOW_FILE"
if command -v cygpath >/dev/null 2>&1; then
    ALLOW_FILE_NODE="$(cygpath -m "$ALLOW_FILE")"
else
    ALLOW_FILE_NODE="$ALLOW_FILE"
fi

for f in "$RUNNER" "$CORPUS" "$GOLDEN"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: precondition missing — $f"
        echo ""
        echo "Total: PASS=0 FAIL=1"
        exit 1
    fi
done

# Corpus size gate (the plan requires >= 45 cases).
CORPUS_N="$(grep -cvE '^[[:space:]]*(#|$)' "$CORPUS")"
if [ "$CORPUS_N" -ge 45 ]; then
    echo "PASS: corpus size gate (>=45 cases, got $CORPUS_N)"
    GATE_FAIL=0
else
    echo "FAIL: corpus size gate — want >=45 cases, got $CORPUS_N"
    GATE_FAIL=1
fi

OUT="$(run_with_timeout 120 node "$RUNNER" "$CORPUS" "$ALLOW_FILE_NODE" 2>&1)"
RC=$?
echo "$OUT"

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "Total: PASS=0 FAIL=1 (runner exited rc=$RC)"
    exit 1
fi

N_PASS="$(printf '%s\n' "$OUT" | grep -c '^PASS: ' || true)"
N_FAIL="$(printf '%s\n' "$OUT" | grep -c '^FAIL: ' || true)"
N_PASS=$((N_PASS + 1 - GATE_FAIL))
N_FAIL=$((N_FAIL + GATE_FAIL))

echo ""
echo "Total: PASS=$N_PASS FAIL=$N_FAIL"
[ "$N_FAIL" -eq 0 ]
