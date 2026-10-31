#!/bin/bash
# tests/bin/feature-2731-codex-callsite-surface.sh
# Tests: bin/lib/review-plan-codex/prompts.sh, bin/review-code-codex, bin/review-plan-codex, bin/supervisor-findings-codex
# Tags: codex, conv-lang, plan-lang, preamble, call-site, table-driven, TL1, scope:issue-specific, pwsh-not-required
# #2731 R3: each codex_core_adversarial_preamble call site passes the language surface its output
# belongs to (plan reviews -> plan, supervisor findings -> conv). Static extraction is the right
# layer: the contract is the literal surface argument at each call site, and running the callers
# needs a real codex CLI. The scan guard fails on any unlisted call or a surface outside {conv,plan}.
# #2814 6-1: the four plan-review formats call codex_core_plan_review_preamble <kind> <reviewed>
# [surface] instead; the scan recognises both functions and pins which one each file calls.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

# Expected call sites: <relpath> | <function> | <call count> | <surface, `-` = no surface argument>.
# <function> is `adversarial` (codex_core_adversarial_preamble) or `plan_review`
# (codex_core_plan_review_preamble). The `-` row is the no-surface allowlist: the case-marker band
# check is an internal tool prompt whose output is parsed by machine (CASE_BOUNDARY lines), so it
# must stay language-neutral.
CALLSITE_TABLE="$(cat <<'TABLE'
bin/review-plan-codex                        | plan_review | 3 | plan
bin/review-code-codex                        | adversarial | 1 | plan
bin/lib/review-plan-codex/prompts.sh         | plan_review | 1 | plan
bin/supervisor-findings-codex                | adversarial | 1 | conv
bin/lib/test-embed-cases/codex-band-check.sh | adversarial | 1 | -
TABLE
)"

# adversarial: "<kind>" [surface]; plan_review: "<kind>" <reviewed, quoted or bare> [surface].
CALL_RE_ADV='codex_core_adversarial_preamble[[:space:]]+"[^"]*"([[:space:]]+([^)[:space:]]+))?[[:space:]]*\)'
CALL_RE_PR='codex_core_plan_review_preamble[[:space:]]+"[^"]*"[[:space:]]+("[^"]*"|[^")[:space:]]+)([[:space:]]+([^)[:space:]]+))?[[:space:]]*\)'
DEF_RE='codex_core_(adversarial|plan_review)_preamble[[:space:]]*\(\)'
NAME_RE='codex_core_(adversarial|plan_review)_preamble'

# list_calls <root> — one `<relpath>|<function>|<surface>` line per call under bin/ hooks/ skills/
# (non-.md). Every non-comment, non-definition line naming either function counts as a call,
# whatever its shape; a trailing `\` joins the next line first. `-` = no surface, `?` = surface
# not parseable.
list_calls() {
    local root="$1" rel line i surface fn
    local -a lines
    while IFS= read -r rel; do
        case "$rel" in *.md) continue ;; esac
        mapfile -t lines < <(tr -d '\r' <"$root/$rel")
        for ((i = 0; i < ${#lines[@]}; i++)); do
            line="${lines[i]}"
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ $NAME_RE ]] || continue
            fn="${BASH_REMATCH[1]}"
            [[ "$line" =~ $DEF_RE ]] && continue
            while [[ "$line" == *\\ && $((i + 1)) -lt ${#lines[@]} ]]; do
                i=$((i + 1)); line="${line%\\} ${lines[i]}"
            done
            surface="?"
            if [[ "$fn" == adversarial ]]; then
                [[ "$line" =~ $CALL_RE_ADV ]] && surface="${BASH_REMATCH[2]:--}"
            else
                [[ "$line" =~ $CALL_RE_PR ]] && surface="${BASH_REMATCH[3]:--}"
            fi
            printf '%s|%s|%s\n' "$rel" "$fn" "$surface"
        done
    done < <(cd "$root" && grep -rlE "$NAME_RE" bin hooks skills 2>/dev/null | tr -d '\r' | sort)
}

# check_calls <root> <table> — prints one line per drift between the calls found and the table
# (unlisted file/function pair, count mismatch, wrong surface, surface outside {conv,plan,-});
# empty = in sync.
check_calls() {
    local root="$1" table="$2" calls rel fn count want got n
    calls="$(list_calls "$root")"
    while IFS='|' read -r rel fn got; do
        [[ -z "$rel" ]] && continue
        case "$got" in conv|plan|-) ;; *) echo "bad-surface: $rel: $got" ;; esac
        printf '%s\n' "$table" | grep -q "^$rel[[:space:]]*|[[:space:]]*$fn[[:space:]]*|" || echo "unlisted: $rel $fn"
    done <<<"$calls"
    while IFS='|' read -r rel fn count want; do
        rel="${rel//[[:space:]]/}"; fn="${fn//[[:space:]]/}"; count="${count//[[:space:]]/}"; want="${want//[[:space:]]/}"
        [[ -z "$rel" ]] && continue
        n="$(printf '%s\n' "$calls" | grep -c "^$rel|$fn|")"
        [[ "$n" == "$count" ]] || echo "count: $rel $fn: want=$count got=$n"
        while IFS='|' read -r _ _ got; do
            [[ "$got" == "$want" ]] || echo "surface: $rel $fn: want=$want got=$got"
        done < <(printf '%s\n' "$calls" | grep "^$rel|$fn|")
    done <<<"$table"
}

# expect_row <relpath> — the table row for <relpath> holds against the real tree, and the file
# calls no other preamble function.
expect_row() {
    local row rel fn count want calls
    row="$(printf '%s\n' "$CALLSITE_TABLE" | grep "^$1[[:space:]]*|")"
    if [[ -z "$row" ]]; then fail "row $1" "not in CALLSITE_TABLE"; return; fi
    IFS='|' read -r rel fn count want <<<"$row"
    fn="${fn//[[:space:]]/}"; count="${count//[[:space:]]/}"; want="${want//[[:space:]]/}"
    calls="$(list_calls "$SCRIPT_CHECKOUT_ROOT" | grep "^$1|")"
    assert_eq "$(printf '%s\n' "$calls" | grep -c "^$1|$fn|")" "$count"
    assert_eq "$(printf '%s\n' "$calls" | grep -vc "^$1|$fn|")" "0"
    assert_eq "$(printf '%s\n' "$calls" | cut -d'|' -f3 | sort -u)" "$want"
}

case_begin "callsite-review-plan-codex-plan" "bin/review-plan-codex"
expect_row bin/review-plan-codex
case_end

case_begin "callsite-review-code-codex-plan" "bin/review-code-codex"
expect_row bin/review-code-codex
case_end

case_begin "callsite-review-plan-prompts-plan" "bin/lib/review-plan-codex/prompts.sh"
expect_row bin/lib/review-plan-codex/prompts.sh
case_end

case_begin "callsite-supervisor-findings-conv" "bin/supervisor-findings-codex"
expect_row bin/supervisor-findings-codex
case_end

case_begin "callsite-scan-matches-table" "bin/supervisor-findings-codex"
# Whole-tree guard: every call under bin/ hooks/ skills/ is in the table with its surface, and
# the total count equals the table sum (a new call site without a surface fails here).
drift="$(check_calls "$SCRIPT_CHECKOUT_ROOT" "$CALLSITE_TABLE")"
assert_eq "$drift" ""
total=0
while IFS='|' read -r _ _ count _; do total=$((total + ${count//[[:space:]]/})); done <<<"$CALLSITE_TABLE"
assert_eq "$(list_calls "$SCRIPT_CHECKOUT_ROOT" | grep -c .)" "$total"
case_end

case_begin "callsite-guard-detects-drift" "bin/review-plan-codex"
# Negative control: the guard must flag an unlisted no-surface call, a bogus surface, a count
# change, a surface flip, and a call to the wrong preamble function; comment lines and the
# function definitions are not calls.
FX="$_ISOLATION_TMP_ROOT/fx"
mkdir -p "$FX/bin/lib" "$FX/hooks" "$FX/skills"
cat >"$FX/bin/lib/core.sh" <<'EOF'
# codex_core_adversarial_preamble "doc example" plan)
codex_core_adversarial_preamble() { :; }
codex_core_plan_review_preamble() { :; }
EOF
cat >"$FX/bin/new-tool" <<'EOF'
P=$(codex_core_adversarial_preamble "new tool")
Q=$(codex_core_adversarial_preamble "other" japanese)
EOF
cat >"$FX/bin/review-plan-codex" <<'EOF'
P=$(codex_core_plan_review_preamble "implementation plan" "detail" plan)
P=$(codex_core_plan_review_preamble "test coverage review" "test files" conv)
P=$(codex_core_adversarial_preamble "implementation plan" plan)
EOF
# Shapes the quoted single-line regex alone would miss: a `\`-continued call and an unquoted 1st arg.
cat >"$FX/bin/multi-tool" <<'EOF'
P=$(codex_core_adversarial_preamble \
    "multi-line no surface")
EOF
cat >"$FX/bin/unquoted-tool" <<'EOF'
P=$(codex_core_adversarial_preamble $KIND conv)
EOF
cat >"$FX/bin/review-code-codex" <<'EOF'
P=$(codex_core_adversarial_preamble \
    "code diff" \
    plan)
EOF
cat >"$FX/bin/pr-tool" <<'EOF'
P=$(codex_core_plan_review_preamble "outline plan proposal" outline plan)
Q=$(codex_core_plan_review_preamble "outline plan proposal" "$REVIEWED")
EOF
want_calls="bin/multi-tool|adversarial|-"$'\n'"bin/new-tool|adversarial|-"$'\n'"bin/new-tool|adversarial|japanese"
want_calls+=$'\n'"bin/pr-tool|plan_review|plan"$'\n'"bin/pr-tool|plan_review|-"
want_calls+=$'\n'"bin/review-code-codex|adversarial|plan"
want_calls+=$'\n'"bin/review-plan-codex|plan_review|plan"$'\n'"bin/review-plan-codex|plan_review|conv"$'\n'"bin/review-plan-codex|adversarial|plan"
want_calls+=$'\n'"bin/unquoted-tool|adversarial|?"
assert_eq "$(list_calls "$FX")" "$want_calls"
fx_table="bin/review-plan-codex | plan_review | 3 | plan"$'\n'"bin/review-code-codex | adversarial | 1 | plan"
drift="$(check_calls "$FX" "$fx_table")"
for want in "unlisted: bin/new-tool adversarial" "bad-surface: bin/new-tool: japanese" "count: bin/review-plan-codex plan_review: want=3 got=2" "surface: bin/review-plan-codex plan_review: want=plan got=conv" "unlisted: bin/review-plan-codex adversarial" "unlisted: bin/multi-tool adversarial" "unlisted: bin/unquoted-tool adversarial" "bad-surface: bin/unquoted-tool: ?" "unlisted: bin/pr-tool plan_review"; do
    if printf '%s\n' "$drift" | grep -qxF "$want"; then pass "drift reported: $want"; else fail "drift not reported: $want" "drift=$(printf '%q' "$drift")"; fi
done
assert_eq "$(printf '%s\n' "$drift" | grep -c 'core.sh')" "0"
# The tabled multi-line call parses to its surface, so it raises no drift.
assert_eq "$(printf '%s\n' "$drift" | grep -c 'review-code-codex')" "0"
case_end

echo ""
echo "=== Results (feature-2731-codex-callsite-surface) ==="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
