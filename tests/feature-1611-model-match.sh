#!/usr/bin/env bash
# tests/feature-1611-model-match.sh
# Tests: hooks/lib/model-match.js, bin/model-match.js
# Tags: model-detection, parser, cli, issue-create, scope:issue-specific, TL2
#
# Issue #1611 — single source of truth for model identification:
#   * the self-report sentence parser,
#   * the keyword matcher,
#   * the reporter-model:* label table (order is behaviour),
# all consolidated into hooks/lib/model-match.js, exposed to shell/LLM callers
# through bin/model-match.js.
#
# Table-driven per skills/_shared/test-design/parser-regex-tests.md (the subject
# is a parser + allowlist table).
#
# TL3 gap (what this test does NOT catch):
# - What the live Claude Code system prompt's self-report sentence actually says
#   for a given backend (upstream wording is not observable from a shell test).
# - Whether /issue-create passes the sentence through in a real session.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$REPO_DIR/hooks/lib/model-match.js"
CLI="$REPO_DIR/bin/model-match.js"

if command -v cygpath >/dev/null 2>&1; then
    MM_MOD="$(cygpath -m "$MODULE")"
else
    MM_MOD="$MODULE"
fi
export MM_MOD

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# js_eval <expression> — evaluates the expression with the module bound to `M`.
# null/undefined → "null"; arrays → JSON; throws → "THREW"; module missing → "NOMODULE".
js_eval() {
    local expr="$1"
    local out
    out="$(run_with_timeout 30 node -e "
const M = require(process.env.MM_MOD);
function fmt(v) {
  if (v === null || v === undefined) return 'null';
  if (Array.isArray(v)) return JSON.stringify(v);
  return String(v);
}
let out;
try { out = ($expr); } catch (e) { out = 'THREW'; }
process.stdout.write(fmt(out));
" </dev/null 2>/dev/null)" || out="NOMODULE"
    [ -z "$out" ] && out="NOMODULE"
    printf '%s' "$out"
}

SELF_FULL="You are powered by the model named Sonnet 4.6. The exact model ID is claude-sonnet-4-6."
SELF_NAME_ONLY="You are powered by the model named Fable."

echo "=== extractModelIdFromSelfReport ==="

run_table() {
    local name expr want
    while IFS='|' read -r name expr want; do
        name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$name" ] && continue
        case "$name" in '#'*) continue ;; esac
        want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        assert_eq "$name" "$want" "$(js_eval "$expr")"
    done
}

run_table <<'TABLE'
E01-full-sentence      | M.extractModelIdFromSelfReport('You are powered by the model named Sonnet 4.6. The exact model ID is claude-sonnet-4-6.') | claude-sonnet-4-6
E02-full-sentence-opus | M.extractModelIdFromSelfReport('You are powered by the model named Opus 4.8. The exact model ID is claude-opus-4-8.')     | claude-opus-4-8
E03-name-only-fallback | M.extractModelIdFromSelfReport('You are powered by the model named Fable.')                                              | Fable
E04-unrelated-text     | M.extractModelIdFromSelfReport('hello there, no model here')                                                             | null
E05-empty-string       | M.extractModelIdFromSelfReport('')                                                                                       | null
E06-non-string-num     | M.extractModelIdFromSelfReport(42)                                                                                       | null
E07-non-string-null    | M.extractModelIdFromSelfReport(null)                                                                                     | null
E08-object-input       | M.extractModelIdFromSelfReport({id: 'x'})                                                                                | null
E09-surrounding-space  | M.extractModelIdFromSelfReport('You are powered by the model named X. The exact model ID is  spaced-id .')               | spaced-id
E10-embedded-in-prose  | M.extractModelIdFromSelfReport('Intro line.\nYou are powered by the model named DS4 Flash. The exact model ID is deepseek-v4-flash.\nMore text.') | deepseek-v4-flash
E11-period-inside-id   | M.extractModelIdFromSelfReport('You are powered by the model named Devstral. The exact model ID is devstral-v0.2.') | devstral-v0.2
E12-period-id-two-dots | M.extractModelIdFromSelfReport('You are powered by the model named Qwen. The exact model ID is qwen3.5-coder.1.') | qwen3.5-coder.1
E13-period-id-to-label | M.resolveReporterModelLabel(M.extractModelIdFromSelfReport('You are powered by the model named Devstral. The exact model ID is devstral-v0.2.')) | reporter-model:devstral
TABLE

echo ""
echo "=== normalizeModelId ==="

run_table <<'TABLE'
N01-trim-lowercase | M.normalizeModelId('  Claude-Opus-4-8  ') | claude-opus-4-8
N02-already-normal | M.normalizeModelId('deepseek-v4')         | deepseek-v4
N03-non-string     | M.normalizeModelId(42)                    | null
N04-null           | M.normalizeModelId(null)                  | null
N05-control-char   | M.normalizeModelId(String.fromCharCode(98,97,100,1,105,100)) | null
TABLE

echo ""
echo "=== parseKeywordList ==="

run_table <<'TABLE'
K01-semicolon-trim | M.parseKeywordList('deepseek; qwen ;')  | ["deepseek","qwen"]
K02-lowercases     | M.parseKeywordList('DeepSeek;QWEN')     | ["deepseek","qwen"]
K03-single         | M.parseKeywordList('ds4')               | ["ds4"]
K04-empty-string   | M.parseKeywordList('')                  | []
K05-only-separator | M.parseKeywordList(';;;')               | []
K06-non-string     | M.parseKeywordList(42)                  | []
K07-undefined      | M.parseKeywordList(undefined)           | []
TABLE

echo ""
echo "=== matchKeyword ==="

run_table <<'TABLE'
M01-case-insensitive | M.matchKeyword('DeepSeek-V4-Flash', ['deepseek'])       | deepseek
M02-substring        | M.matchKeyword('qwen-coder-32b', ['qwen'])              | qwen
M03-order-first-wins | M.matchKeyword('deepseek-qwen-mix', ['qwen','deepseek'])| qwen
M04-order-reversed   | M.matchKeyword('deepseek-qwen-mix', ['deepseek','qwen'])| deepseek
M05-no-match         | M.matchKeyword('claude-opus-4-8', ['deepseek','qwen'])  | null
M06-empty-keywords   | M.matchKeyword('anything', [])                          | null
M07-null-model       | M.matchKeyword(null, ['deepseek'])                      | null
M08-non-array-kw     | M.matchKeyword('deepseek-v4', 'deepseek')               | null
TABLE

echo ""
echo "=== resolveReporterModelLabel (order-preserving label table) ==="

run_table <<'TABLE'
L01-fable      | M.resolveReporterModelLabel('claude-fable-5')  | reporter-model:fable
L02-opus       | M.resolveReporterModelLabel('claude-opus-4-8') | reporter-model:opus
L03-sonnet     | M.resolveReporterModelLabel('claude-sonnet-4-6')| reporter-model:sonnet
L04-ds4        | M.resolveReporterModelLabel('ds4-flash')       | reporter-model:ds4
L05-deepseek   | M.resolveReporterModelLabel('deepseek-v4')     | reporter-model:ds4
L06-devstral   | M.resolveReporterModelLabel('devstral-v0.2')   | reporter-model:devstral
L07-qwen-coder | M.resolveReporterModelLabel('qwen-coder-32b')  | reporter-model:qwen-coder
L08-qwen-alias | M.resolveReporterModelLabel('qwen')            | reporter-model:qwen-coder
L09-unknown    | M.resolveReporterModelLabel('unknown-model-xyz')| null
L10-null       | M.resolveReporterModelLabel(null)              | null
L11-ds4-before-deepseek | M.resolveReporterModelLabel('ds4-deepseek-build') | reporter-model:ds4
L12-uppercase-input     | M.resolveReporterModelLabel('Claude-OPUS-4-8')    | reporter-model:opus
TABLE

echo ""
echo "=== REPORTER_MODEL_LABELS shape ==="

assert_eq "L13-table-is-ordered-pairs" "true" \
    "$(js_eval "Array.isArray(M.REPORTER_MODEL_LABELS) && M.REPORTER_MODEL_LABELS.every(p => Array.isArray(p) && p.length === 2)")"
assert_eq "L14-ds4-precedes-deepseek" "true" \
    "$(js_eval "M.REPORTER_MODEL_LABELS.findIndex(p => p[0] === 'ds4') < M.REPORTER_MODEL_LABELS.findIndex(p => p[0] === 'deepseek')")"

echo ""
echo "=== bin/model-match.js CLI ==="

# cli_out <args...> — prints "<exit>:<stdout-trimmed>"
cli_out() {
    local out code
    out="$(run_with_timeout 30 node "$CLI" "$@" 2>/dev/null)"
    code=$?
    printf '%s:%s' "$code" "$(printf '%s' "$out" | tr -d '\r\n')"
}

if [ ! -f "$CLI" ]; then
    fail "C00-cli-exists" "bin/model-match.js not found (not implemented yet)"
else
    pass "C00-cli-exists"
fi

assert_eq "C01-extract-full"      "0:claude-sonnet-4-6"     "$(cli_out --extract-self-report "$SELF_FULL")"
assert_eq "C02-extract-name-only" "0:Fable"                 "$(cli_out --extract-self-report "$SELF_NAME_ONLY")"
assert_eq "C03-extract-no-match"  "0:"                      "$(cli_out --extract-self-report "nothing to see")"
assert_eq "C04-label-known"       "0:reporter-model:opus"   "$(cli_out --reporter-label "claude-opus-4-8")"
assert_eq "C05-label-ds4-alias"   "0:reporter-model:ds4"    "$(cli_out --reporter-label "deepseek-v4-flash")"
assert_eq "C06-label-unknown"     "0:"                      "$(cli_out --reporter-label "unknown-model-xyz")"
assert_eq "C07-match-hit"         "0:deepseek"              "$(cli_out --match "deepseek-v4-flash" --keywords "deepseek;qwen")"
assert_eq "C08-match-miss"        "0:"                      "$(cli_out --match "claude-opus-4-8" --keywords "deepseek;qwen")"
assert_eq "C09-match-empty-kw"    "0:"                      "$(cli_out --match "deepseek-v4" --keywords "")"

# Argument errors are the only non-zero exit path.
BAD="$(cli_out --no-such-subcommand)"
case "$BAD" in
    2:*) pass "C10-bad-args-exit-2" ;;
    *)   fail "C10-bad-args-exit-2" "want exit 2, got '$BAD'" ;;
esac

assert_eq "C11-extract-period-id" "0:devstral-v0.2" \
    "$(cli_out --extract-self-report "You are powered by the model named Devstral. The exact model ID is devstral-v0.2.")"
assert_eq "C12-label-period-id"   "0:reporter-model:devstral" \
    "$(cli_out --reporter-label "devstral-v0.2")"

echo ""
echo "=== mutation evidence: neutralizing the extraction regex must break the parser ==="
#
# bin/mutation-probe.sh cannot be invoked here — its --test-cmd would re-enter
# this very file and recurse. This section applies the probe's own mutation
# operator (single-line `const NAME = /regex/;` → `/(?!)/`, i.e. a regex that can
# never match) to a throwaway copy of the module, then re-runs the extraction
# regressions against the mutant. If the mutant still produces the right answers,
# the parser cases are not actually exercising the regex.

MUT_DIR="$(mktemp -d)"
trap 'rm -rf "$MUT_DIR"' EXIT

if [ ! -f "$MODULE" ]; then
    fail "MU01-mutation-applies" "hooks/lib/model-match.js not found (not implemented yet)"
    fail "MU02-mutant-breaks-extraction" "no module to mutate"
    fail "MU03-mutant-breaks-fallback" "no module to mutate"
else
    MUTANT="$MUT_DIR/model-match.mutant.js"
    sed -E 's#^([[:space:]]*const [A-Za-z_][A-Za-z0-9_]* = )/.*/[a-z]*;[[:space:]]*$#\1/(?!)/;#' \
        "$MODULE" > "$MUTANT"
    MUTATED_LINES="$(diff "$MODULE" "$MUTANT" 2>/dev/null | grep -c '^<' || true)"

    if [ "${MUTATED_LINES:-0}" -ge 1 ]; then
        pass "MU01-mutation-applies ($MUTATED_LINES regex constant(s) neutralized)"
    else
        fail "MU01-mutation-applies" "no single-line 'const NAME = /regex/;' declaration found — the extraction rule is not in a mutable regex constant, so this probe cannot certify it"
    fi

    if command -v cygpath >/dev/null 2>&1; then MUTANT_N="$(cygpath -m "$MUTANT")"; else MUTANT_N="$MUTANT"; fi
    ORIG_MM_MOD="$MM_MOD"
    export MM_MOD="$MUTANT_N"

    MU02="$(js_eval "M.extractModelIdFromSelfReport('You are powered by the model named Sonnet 4.6. The exact model ID is claude-sonnet-4-6.')")"
    if [ "$MU02" = "claude-sonnet-4-6" ]; then
        fail "MU02-mutant-breaks-extraction" "the mutant still extracted claude-sonnet-4-6 — E01/E02 do not depend on the regex"
    else
        pass "MU02-mutant-breaks-extraction (mutant returned '$MU02')"
    fi

    MU03="$(js_eval "M.extractModelIdFromSelfReport('You are powered by the model named Fable.')")"
    if [ "$MU03" = "Fable" ]; then
        fail "MU03-mutant-breaks-fallback" "the mutant still extracted the name fallback — E03 does not depend on the regex"
    else
        pass "MU03-mutant-breaks-fallback (mutant returned '$MU03')"
    fi

    export MM_MOD="$ORIG_MM_MOD"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
