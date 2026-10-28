#!/bin/bash
# tests/bin/feature-2731-codex-callsite-surface.sh
# Tests: bin/lib/review-plan-codex/prompts.sh, bin/review-code-codex, bin/review-plan-codex, bin/supervisor-findings-codex
# Tags: codex, conv-lang, plan-lang, preamble, call-site, table-driven, TL1, scope:issue-specific, pwsh-not-required
# #2731 R3: each codex_core_adversarial_preamble call site passes the language surface its output
# belongs to (plan reviews -> plan, supervisor findings -> conv). Static extraction is the right
# layer: the contract is the literal 2nd argument at each call site, and running the callers
# needs a real codex CLI. The scan guard fails on any unlisted call or a surface outside {conv,plan}.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

# Expected call sites: <relpath> | <call count> | <surface, `-` = no surface argument>.
# The `-` row is the no-surface allowlist: the case-marker band check is an internal tool prompt
# whose output is parsed by machine (CASE_BOUNDARY lines), so it must stay language-neutral.
CALLSITE_TABLE="$(cat <<'TABLE'
bin/review-plan-codex                        | 3 | plan
bin/review-code-codex                        | 1 | plan
bin/lib/review-plan-codex/prompts.sh         | 1 | plan
bin/supervisor-findings-codex                | 1 | conv
bin/lib/test-embed-cases/codex-band-check.sh | 1 | -
TABLE
)"

CALL_RE='codex_core_adversarial_preamble[[:space:]]+"[^"]*"([[:space:]]+([^)[:space:]]+))?[[:space:]]*\)'
DEF_RE='codex_core_adversarial_preamble[[:space:]]*\(\)'

# list_calls <root> — one `<relpath>|<surface>` line per call under bin/ hooks/ skills/ (non-.md).
# Every non-comment, non-definition line naming the function counts as a call, whatever its shape;
# a trailing `\` joins the next line first. `-` = no surface, `?` = surface not parseable.
list_calls() {
    local root="$1" rel line i surface
    local -a lines
    while IFS= read -r rel; do
        case "$rel" in *.md) continue ;; esac
        mapfile -t lines < <(tr -d '\r' <"$root/$rel")
        for ((i = 0; i < ${#lines[@]}; i++)); do
            line="${lines[i]}"
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" == *codex_core_adversarial_preamble* ]] || continue
            [[ "$line" =~ $DEF_RE ]] && continue
            while [[ "$line" == *\\ && $((i + 1)) -lt ${#lines[@]} ]]; do
                i=$((i + 1)); line="${line%\\} ${lines[i]}"
            done
            surface="?"
            [[ "$line" =~ $CALL_RE ]] && surface="${BASH_REMATCH[2]:--}"
            printf '%s|%s\n' "$rel" "$surface"
        done
    done < <(cd "$root" && grep -rl 'codex_core_adversarial_preamble' bin hooks skills 2>/dev/null | tr -d '\r' | sort)
}

# check_calls <root> <table> — prints one line per drift between the calls found and the table
# (unlisted file, count mismatch, wrong surface, surface outside {conv,plan,-}); empty = in sync.
check_calls() {
    local root="$1" table="$2" calls rel count want got n
    calls="$(list_calls "$root")"
    while IFS='|' read -r rel got; do
        [[ -z "$rel" ]] && continue
        case "$got" in conv|plan|-) ;; *) echo "bad-surface: $rel: $got" ;; esac
        printf '%s\n' "$table" | grep -q "^$rel[[:space:]]*|" || echo "unlisted: $rel"
    done <<<"$calls"
    while IFS='|' read -r rel count want; do
        rel="${rel//[[:space:]]/}"; count="${count//[[:space:]]/}"; want="${want//[[:space:]]/}"
        [[ -z "$rel" ]] && continue
        n="$(printf '%s\n' "$calls" | grep -c "^$rel|")"
        [[ "$n" == "$count" ]] || echo "count: $rel: want=$count got=$n"
        while IFS='|' read -r _ got; do
            [[ "$got" == "$want" ]] || echo "surface: $rel: want=$want got=$got"
        done < <(printf '%s\n' "$calls" | grep "^$rel|")
    done <<<"$table"
}

# expect_row <relpath> — the table row for <relpath> holds against the real tree.
expect_row() {
    local row rel count want calls
    row="$(printf '%s\n' "$CALLSITE_TABLE" | grep "^$1[[:space:]]*|")"
    if [[ -z "$row" ]]; then fail "row $1" "not in CALLSITE_TABLE"; return; fi
    IFS='|' read -r rel count want <<<"$row"
    count="${count//[[:space:]]/}"; want="${want//[[:space:]]/}"
    calls="$(list_calls "$SCRIPT_CHECKOUT_ROOT" | grep "^$1|")"
    assert_eq "$(printf '%s\n' "$calls" | grep -c .)" "$count"
    assert_eq "$(printf '%s\n' "$calls" | cut -d'|' -f2 | sort -u)" "$want"
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
while IFS='|' read -r _ count _; do total=$((total + ${count//[[:space:]]/})); done <<<"$CALLSITE_TABLE"
assert_eq "$(list_calls "$SCRIPT_CHECKOUT_ROOT" | grep -c .)" "$total"
case_end

case_begin "callsite-guard-detects-drift" "bin/review-plan-codex"
# Negative control: the guard must flag an unlisted no-surface call, a bogus surface, a count
# change, and a surface flip; comment lines and the function definition are not calls.
FX="$_ISOLATION_TMP_ROOT/fx"
mkdir -p "$FX/bin/lib" "$FX/hooks" "$FX/skills"
cat >"$FX/bin/lib/core.sh" <<'EOF'
# codex_core_adversarial_preamble "doc example" plan)
codex_core_adversarial_preamble() { :; }
EOF
cat >"$FX/bin/new-tool" <<'EOF'
P=$(codex_core_adversarial_preamble "new tool")
Q=$(codex_core_adversarial_preamble "other" japanese)
EOF
cat >"$FX/bin/review-plan-codex" <<'EOF'
P=$(codex_core_adversarial_preamble "implementation plan" plan)
P=$(codex_core_adversarial_preamble "test coverage review" conv)
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
want_calls="bin/multi-tool|-"$'\n'"bin/new-tool|-"$'\n'"bin/new-tool|japanese"$'\n'"bin/review-code-codex|plan"
want_calls+=$'\n'"bin/review-plan-codex|plan"$'\n'"bin/review-plan-codex|conv"$'\n'"bin/unquoted-tool|?"
assert_eq "$(list_calls "$FX")" "$want_calls"
fx_table="bin/review-plan-codex | 3 | plan"$'\n'"bin/review-code-codex | 1 | plan"
drift="$(check_calls "$FX" "$fx_table")"
for want in "unlisted: bin/new-tool" "bad-surface: bin/new-tool: japanese" "count: bin/review-plan-codex: want=3 got=2" "surface: bin/review-plan-codex: want=plan got=conv" "unlisted: bin/multi-tool" "unlisted: bin/unquoted-tool" "bad-surface: bin/unquoted-tool: ?"; do
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
