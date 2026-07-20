#!/usr/bin/env bash
# tests/fix-1579-reporter-model-keyword-scan.sh
# Tests: bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, .github/labels.yml
# Tags: scope:issue-specific
# TL2 — no real GitHub API calls; tests script logic only.
# TL3 gap (what this test does NOT catch):
# - Actual GitHub API label creation (needs real token + network)
# - Claude runtime model detection behavior (LLM prompt-level, not testable in shell)
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
IC="$REPO_ROOT/bin/github-issues/issue-create.sh"
LABELS_YML="$REPO_ROOT/.github/labels.yml"

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# --- Test harness: mock `gh`, run issue-create.sh, capture the labels it would pass ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"
mkdir -p "$MOCKDIR"

cat > "$MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh: capture --label args from `issue create`; everything else exits 1
# (non-fatal in issue-create.sh: auth-status warn / resolver skip).
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
    while [ $# -gt 0 ]; do
        if [ "$1" = "--label" ]; then printf '%s\n' "$2" >> "$GH_LABEL_CAPTURE"; fi
        shift
    done
    echo "https://github.com/test/repo/issues/999"
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCKDIR/gh"

CAP="$WORK/labels.txt"

# run_ic <args...> → runs issue-create.sh with mock gh; captures labels into $CAP.
# Returns issue-create.sh exit code. Labels land in $CAP one per line.
run_ic() {
    : > "$CAP"
    GH_LABEL_CAPTURE="$CAP" \
    PATH="$MOCKDIR:$PATH" \
    AGENTS_CONFIG_DIR="" \
    ISSUE_CREATE_SKIP_SCHEMA=1 \
        bash "$IC" "$@" >/dev/null 2>"$WORK/stderr.txt"
    return $?
}

has_label()  { grep -qxF "$1" "$CAP"; }

assert_label_present() {
    local name="$1"; shift; local args=(); local expect
    # last arg is expected label; preceding are run_ic args
    expect="${!#}"
    args=("${@:1:$(($#-1))}")
    run_ic "${args[@]}"
    if has_label "$expect"; then pass "$name"
    else fail "$name" "expected label '$expect' not passed to gh (got: $(tr '\n' ' ' < "$CAP"))"; fi
}

assert_label_absent() {
    local name="$1"; shift; local args=(); local forbid
    forbid="${!#}"
    args=("${@:1:$(($#-1))}")
    run_ic "${args[@]}"
    if has_label "$forbid"; then fail "$name" "label '$forbid' unexpectedly passed to gh"
    else pass "$name"; fi
}

# No reporter-model:* label at all (used for unknown-model case).
assert_no_reporter_model() {
    local name="$1"; shift
    run_ic "$@"
    if grep -q '^reporter-model:' "$CAP"; then
        fail "$name" "unexpected reporter-model:* label (got: $(tr '\n' ' ' < "$CAP"))"
    else pass "$name"; fi
}

echo "=== reporter-model keyword mapping (--reporter-model) ==="

# T1-T6: model name keyword → reporter-model:<canonical>
assert_label_present "T1-fable"          --title t --body "b" --reporter-model "claude-fable-5"  "reporter-model:fable"
assert_label_present "T2-opus"           --title t --body "b" --reporter-model "claude-opus-4-8" "reporter-model:opus"
assert_label_present "T3-opus-modelid"   --title t --body "b" --reporter-model "claude-opus-4-8" "reporter-model:opus"
assert_label_present "T4-devstral"       --title t --body "b" --reporter-model "devstral-v0.2"   "reporter-model:devstral"
assert_label_present "T5-qwen-coder"     --title t --body "b" --reporter-model "qwen-coder-32b"  "reporter-model:qwen-coder"
assert_label_present "T6-qwen-alias"     --title t --body "b" --reporter-model "qwen"            "reporter-model:qwen-coder"

# T7: unknown model → no reporter-model:* label
assert_no_reporter_model "T7-unknown-no-label" --title t --body "b" --reporter-model "unknown-model-xyz"

echo ""
echo "=== severity keyword scan (abort|hang|security|leak, word-boundary) ==="

# T8-T11: keyword in title or body forces severity:high
assert_label_present "T8-title-abort"    --title "abort loop"      --body "b"            "severity:high"
assert_label_present "T9-title-hang"     --title "it will hang"    --body "b"            "severity:high"
assert_label_present "T10-body-security" --title "t"               --body "security bug" "severity:high"
assert_label_present "T11-body-leak"     --title "t"               --body "a leak here"  "severity:high"

# T12: explicit severity:low + keyword → high overrides low (low removed, high present)
run_ic --title "t" --body "abort now" --label "severity:low"
if has_label "severity:high" && ! has_label "severity:low"; then
    pass "T12-high-overrides-low"
else
    fail "T12-high-overrides-low" "want severity:high present + severity:low absent (got: $(tr '\n' ' ' < "$CAP"))"
fi

# T13-T14: word-boundary — substring / inflection must NOT trigger
assert_label_absent "T13-abstract-no-match" --title "abstract concept" --body "b" "severity:high"
assert_label_absent "T14-hanging-no-match"  --title "hanging around"   --body "b" "severity:high"

echo ""
echo "=== T15 drift check: script reporter-model:* RHS ⊆ labels.yml ==="

# Extract reporter-model:* label strings appearing in issue-create.sh, compare to labels.yml.
SCRIPT_LABELS=$(grep -oE 'reporter-model:[a-z0-9-]+' "$IC" 2>/dev/null | sort -u)
if [ -z "$SCRIPT_LABELS" ]; then
    fail "T15-drift" "no reporter-model:* labels found in issue-create.sh (fix not yet applied)"
else
    MISSING=""
    while IFS= read -r lbl; do
        [ -z "$lbl" ] && continue
        if ! grep -qF "\"$lbl\"" "$LABELS_YML"; then
            MISSING="${MISSING:+$MISSING }$lbl"
        fi
    done <<< "$SCRIPT_LABELS"
    if [ -z "$MISSING" ]; then
        pass "T15-drift (script labels: $(echo $SCRIPT_LABELS | tr '\n' ' '))"
    else
        fail "T15-drift" "script reporter-model labels missing from labels.yml: $MISSING"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
