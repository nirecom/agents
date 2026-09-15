#!/usr/bin/env bash
# tests/feature-2256-codex-header-label.sh
# Tests: bin/review-plan-codex, bin/review-code-codex, bin/run-codex-review-loop
# Tags: codex, status-header, codex-label, issue-2256, TL2, scope:issue-specific, pwsh-not-required
#
# Both codex reviewers unify on the "Codex Review" status label. The label is
# assigned at file top, BEFORE arg parsing, so the early
# "--x requires an argument" paths still emit a named header instead of the
# "## : FAILED" empty-label regression, and the loop reads the header with a
# prefix grep rather than "first non-blank line".
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAN_BIN="$AGENTS_ROOT/bin/review-plan-codex"
CODE_BIN="$AGENTS_ROOT/bin/review-code-codex"
SUP_BIN="$AGENTS_ROOT/bin/supervisor-review-codex"
LOOP_BIN="$AGENTS_ROOT/bin/run-codex-review-loop"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name (want: [$want] got: [$got])"; fi
}
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then fail "$name (expectation is empty — the fixture did not produce a baseline)"; return; fi
    assert_eq "$name" "$want" "$got"
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name (needle is empty)"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then pass "$name"
    else fail "$name (missing: [$needle] in: [$(printf '%s' "$hay" | head -c 400)])"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name (needle is empty)"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        fail "$name (unexpectedly present: [$needle])"
    else pass "$name"; fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_ENV_FILE 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
cd "$TMPDIR_BASE" || exit 1

for _f in "$PLAN_BIN" "$CODE_BIN" "$LOOP_BIN"; do
    if [ ! -f "$_f" ]; then
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

# --- A. the label is declared at file top, before arg parsing ---------------
echo ""
echo "--- A: CODEX_LABEL declaration site ---"

label_line()  { grep -n '^CODEX_LABEL=' "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
parse_line()  { grep -n '^while \[\[ \$# -gt 0 \]\]' "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
init_call()   { grep -c 'codex_core_init "\$CODEX_LABEL"' "$1" 2>/dev/null || true; }

for _pair in "review-plan-codex:$PLAN_BIN" "review-code-codex:$CODE_BIN"; do
    _name="${_pair%%:*}"; _file="${_pair#*:}"
    LL="$(label_line "$_file")"
    PL="$(parse_line "$_file")"
    assert_eq "A: $_name declares CODEX_LABEL=\"Codex Review\" at top level" \
        "1" "$(grep -c '^CODEX_LABEL="Codex Review"$' "$_file" 2>/dev/null || true)"
    ORDER=unknown
    if [ -n "$LL" ] && [ -n "$PL" ]; then
        if [ "$LL" -lt "$PL" ]; then ORDER=before; else ORDER=after; fi
    fi
    assert_eq "A: $_name assigns the label before the arg-parse loop" "before" "$ORDER"
    assert_eq "A: $_name passes the variable to codex_core_init" "1" "$(init_call "$_file")"
    assert_eq "A: $_name no longer hardcodes a literal init label" \
        "0" "$(grep -c 'codex_core_init "Codex' "$_file" 2>/dev/null || true)"
    assert_eq "A: $_name emits no hardcoded '## Codex Review: ' verdict literal" \
        "0" "$(grep -c 'echo "## Codex Review: ' "$_file" 2>/dev/null || true)"
    assert_eq "A: $_name carries no 'Codex Plan Review' string" \
        "0" "$(grep -c 'Codex Plan Review' "$_file" 2>/dev/null || true)"
done

# --- B. the arg-parse error paths carry the label ---------------------------
echo ""
echo "--- B: arg-parse error headers ---"

run_bin() {
    LAST_OUT="$(bash "$@" 2>/dev/null)"
    LAST_RC=$?
}

run_bin "$PLAN_BIN" --input
assert_eq_nz "B: review-plan-codex missing --input value names the label" \
    "## Codex Review: FAILED — --input requires an argument" "$LAST_OUT"
assert_eq "B: review-plan-codex missing --input value still exits 0" "0" "$LAST_RC"
assert_not_contains "B: review-plan-codex missing --input has no empty label" \
    "## : FAILED" "$LAST_OUT"

run_bin "$PLAN_BIN" --ledger
assert_eq_nz "B: review-plan-codex missing --ledger value names the label" \
    "## Codex Review: FAILED — --ledger requires an argument" "$LAST_OUT"

run_bin "$PLAN_BIN" --context
assert_eq_nz "B: review-plan-codex missing --context value names the label" \
    "## Codex Review: FAILED — --context requires an argument" "$LAST_OUT"

run_bin "$CODE_BIN" --base
assert_eq_nz "B: review-code-codex missing --base value names the label" \
    "## Codex Review: FAILED — --base requires an argument" "$LAST_OUT"
assert_eq "B: review-code-codex missing --base value still exits 0" "0" "$LAST_RC"
assert_not_contains "B: review-code-codex missing --base has no empty label" \
    "## : FAILED" "$LAST_OUT"

run_bin "$CODE_BIN" --concerns-file
assert_eq_nz "B: review-code-codex missing --concerns-file value names the label" \
    "## Codex Review: FAILED — --concerns-file requires an argument" "$LAST_OUT"

run_bin "$CODE_BIN" --base 'evil;rm -rf /'
assert_contains "B: review-code-codex rejected base ref names the label" \
    "## Codex Review: FAILED — invalid --base ref" "$LAST_OUT"

# --- C. sibling and repo-wide invariants ------------------------------------
echo ""
echo "--- C: sibling label and repo-wide sweep ---"

if [ -f "$SUP_BIN" ]; then
    assert_eq "C: supervisor-review-codex keeps its own label (out of scope)" \
        "1" "$(grep -c 'codex_core_init "Supervisor Alert Mode Codex Review"' "$SUP_BIN" 2>/dev/null || true)"
else
    fail "C: bin/supervisor-review-codex is missing — its label cannot be pinned"
fi

# This suite is excluded from the sweep on purpose: case D drives the retired
# header through the loop to prove it is rejected, so the literal must live here.
REPO_HITS="$(grep -rl 'Codex Plan Review' "$AGENTS_ROOT/bin" "$AGENTS_ROOT/skills" "$AGENTS_ROOT/agents" "$AGENTS_ROOT/rules" "$AGENTS_ROOT/hooks" 2>/dev/null | sed "s|^$AGENTS_ROOT/||" | sort | paste -sd ',' - || true)"
assert_eq "C: no 'Codex Plan Review' string remains in bin/skills/agents/rules/hooks" "" "$REPO_HITS"

# --- D. the loop reads the header with a prefix grep ------------------------
echo ""
echo "--- D: run-codex-review-loop status-header acquisition ---"

FAKE_ROOT="$TMPDIR_BASE/fake-agents"
mkdir -p "$FAKE_ROOT/rules"
cp -R "$AGENTS_ROOT/bin" "$FAKE_ROOT/bin"
cp "$AGENTS_ROOT/rules/core-principles.md" "$FAKE_ROOT/rules/core-principles.md"

STUB="$FAKE_ROOT/bin/review-plan-codex"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "${STUB_BODY_PRE:-}"' \
    'printf "%s\n" "${STUB_HEADER:-## Codex Review: PERFORMED}"' \
    'printf "%s\n" "<!-- begin-codex-output -->"' \
    'printf "%s\n" "${STUB_VERDICT:-APPROVED}"' \
    'printf "%s\n" "<!-- end-codex-output -->"' \
    'exit 0' > "$STUB"

LOOPN=0
run_loop() {
    LOOPN=$((LOOPN + 1))
    local lp="$TMPDIR_BASE/lp$LOOPN"
    mkdir -p "$lp"
    printf 'draft\n' > "$lp/draft.md"
    printf 'none\n' > "$lp/tradeoffs.md"
    : > "$lp/loopsid-codex-context.detail-plan.built"
    LOOP_OUT="$(AGENTS_CONFIG_DIR="$FAKE_ROOT" STUB_BODY_PRE="$1" STUB_HEADER="$2" STUB_VERDICT="${3:-APPROVED}" \
        bash "$FAKE_ROOT/bin/run-codex-review-loop" \
        --format detail-plan --session-id loopsid --plans-dir "$lp" \
        --draft-file "$lp/draft.md" --cap 2 --max-extensions 1 \
        --accepted-tradeoffs "$lp/tradeoffs.md" 2>&1)"
    LOOP_RC=$?
}

run_loop "codex spent 12s reasoning about the plan" "## Codex Review: PERFORMED"
assert_eq "D: a leading non-status line does not hide the PERFORMED header" "0" "$LOOP_RC"
assert_not_contains "D: the leading line is not mistaken for the status header" \
    "unrecognized status header" "$LOOP_OUT"

run_loop "noise" "## Codex Review: FAILED — round cap reached (3/2 rounds)"
assert_eq "D: the round-cap header behind a leading line escalates (exit 2)" "2" "$LOOP_RC"
assert_contains "D: the round-cap escalation is announced" "round cap reached" "$LOOP_OUT"

run_loop "noise" "## Codex Review: SKIPPED — codex CLI not installed"
assert_eq "D: a SKIPPED header behind a leading line falls back (exit 3)" "3" "$LOOP_RC"

run_loop "noise" "## Codex Review: FAILED — codex exec exit code 7"
assert_eq "D: a FAILED header behind a leading line falls back (exit 3)" "3" "$LOOP_RC"

run_loop "noise" "no status header at all"
assert_eq "D: output with no status line at all halts (exit 4)" "4" "$LOOP_RC"
assert_contains "D: the halt names the unrecognized header" \
    "unrecognized status header" "$LOOP_OUT"

run_loop "" "## Codex Plan Review: PERFORMED"
assert_eq "D: the retired 'Codex Plan Review' header is no longer accepted" "4" "$LOOP_RC"

assert_eq "D: the loop matches the header by prefix, not by first-line position" \
    "1" "$(grep -c "grep -m1 '\^## Codex Review: '" "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "D: the first-non-blank-line acquisition is gone" \
    "0" "$(grep -c "awk 'NF{print; exit}'" "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "D: the loop's status case arms carry no retired label" \
    "0" "$(grep -c 'Codex Plan Review' "$LOOP_BIN" 2>/dev/null || true)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
