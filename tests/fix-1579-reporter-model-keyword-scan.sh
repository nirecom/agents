#!/usr/bin/env bash
# lang-check: ignore — pre-existing Japanese "Plan Step 3-3" comment at line 152, unrelated to this session's diff
# tests/fix-1579-reporter-model-keyword-scan.sh
# Tests: bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, .github/labels.yml, hooks/lib/model-match.js, bin/model-match.js
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
# #1611: the reporter-model:* label table moved out of issue-create.sh into the
# shared matcher module. T15 follows the SSOT.
MODEL_MATCH_JS="$REPO_ROOT/hooks/lib/model-match.js"

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
    printf 'created\n' >> "${GH_CREATE_LOG:-/dev/null}"
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
CREATED="$WORK/created.txt"

# run_ic <args...> → runs issue-create.sh with mock gh; captures labels into $CAP and
# one 'created' line per `gh issue create` invocation into $CREATED.
# Sets $IC_RC to issue-create.sh's exit code (and also returns it).
run_ic() {
    : > "$CAP"; : > "$CREATED"
    GH_LABEL_CAPTURE="$CAP" \
    GH_CREATE_LOG="$CREATED" \
    PATH="$MOCKDIR:$PATH" \
    AGENTS_CONFIG_DIR="" \
    ISSUE_CREATE_SKIP_SCHEMA=1 \
        bash "$IC" "$@" >/dev/null 2>"$WORK/stderr.txt"
    IC_RC=$?
    return $IC_RC
}

has_label()  { grep -qxF "$1" "$CAP"; }

# assert_created <name> → 0 if the run actually created an issue.
#
# This is the precondition every NEGATIVE assertion in this file depends on. Without
# it, "label X was absent" is satisfied just as well by a run that never reached
# `gh issue create` at all — a broken argument parser, a failed preflight, or a typo
# in the test's own flags all produce an empty $CAP and a green test. The label-absence
# check only means something once we know the creation call happened and succeeded.
assert_created() {
    local name="$1"
    if [ "${IC_RC:-1}" -ne 0 ]; then
        fail "$name" "PRECONDITION: issue-create.sh exited $IC_RC — label-absence proves nothing (stderr: $(head -n 1 "$WORK/stderr.txt" 2>/dev/null))"
        return 1
    fi
    local n; n=$(grep -c '^created$' "$CREATED" 2>/dev/null || printf '0')
    if [ "$n" != "1" ]; then
        fail "$name" "PRECONDITION: expected exactly 1 'gh issue create' invocation, saw $n — label-absence proves nothing"
        return 1
    fi
    return 0
}

assert_label_present() {
    local name="$1"; shift; local args=(); local expect
    # last arg is expected label; preceding are run_ic args
    expect="${!#}"
    args=("${@:1:$(($#-1))}")
    run_ic "${args[@]}"
    assert_created "$name" || return
    if has_label "$expect"; then pass "$name"
    else fail "$name" "expected label '$expect' not passed to gh (got: $(tr '\n' ' ' < "$CAP"))"; fi
}

assert_label_absent() {
    local name="$1"; shift; local args=(); local forbid
    forbid="${!#}"
    args=("${@:1:$(($#-1))}")
    run_ic "${args[@]}"
    assert_created "$name" || return
    if has_label "$forbid"; then fail "$name" "label '$forbid' unexpectedly passed to gh"
    else pass "$name"; fi
}

# No reporter-model:* label at all (used for unknown-model case).
assert_no_reporter_model() {
    local name="$1"; shift
    run_ic "$@"
    assert_created "$name" || return
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
echo "=== T16 reporter-model via raw self-report sentence (--reporter-model-text) ==="

# The dispatch script must accept the untouched self-report sentence and delegate
# ID extraction + label lookup to the shared matcher (#1611).
assert_label_present "T16-self-report-text-opus" \
    --title t --body "b" \
    --reporter-model-text "You are powered by the model named Opus 4.8. The exact model ID is claude-opus-4-8." \
    "reporter-model:opus"

assert_label_present "T17-self-report-text-ds4" \
    --title t --body "b" \
    --reporter-model-text "You are powered by the model named DS4 Flash. The exact model ID is deepseek-v4-flash." \
    "reporter-model:ds4"

echo ""
echo "=== T18 flag precedence: explicit --reporter-model beats --reporter-model-text ==="

# Plan Step 3-3: "両方指定時は --reporter-model を優先" — the already-extracted
# id is authoritative; the raw sentence is only a convenience extractor.
assert_label_present "T18-explicit-flag-wins" \
    --title t --body "b" \
    --reporter-model "claude-opus-4-8" \
    --reporter-model-text "You are powered by the model named DS4 Flash. The exact model ID is deepseek-v4-flash." \
    "reporter-model:opus"

assert_label_absent "T18b-text-derived-label-suppressed" \
    --title t --body "b" \
    --reporter-model "claude-opus-4-8" \
    --reporter-model-text "You are powered by the model named DS4 Flash. The exact model ID is deepseek-v4-flash." \
    "reporter-model:ds4"

echo ""
echo "=== T18c named-less short form via --reporter-model-text (#1988) ==="

# A backend may emit the short self-report "You are powered by the model <name>."
# with no "named" clause and no ID sentence. The shared matcher must still derive
# the label from the name.
assert_label_present "T18c-self-report-short-form-opus" \
    --title t --body "b" \
    --reporter-model-text "You are powered by the model Opus 4.8." \
    "reporter-model:opus"

assert_label_present "T18d-self-report-short-form-ds4" \
    --title t --body "b" \
    --reporter-model-text "You are powered by the model DS4 Flash." \
    "reporter-model:ds4"

echo ""
echo "=== T19 matcher subprocess failure degrades to no label (never aborts) ==="

# The label table now lives in a JS module reached through `node`. On a host
# without a working node, issue creation must still succeed — it just loses the
# reporter-model:* label, exactly like an unknown model does today.
BROKEN_NODE_DIR="$WORK/broken-node"
mkdir -p "$BROKEN_NODE_DIR"
printf '#!/usr/bin/env bash\nexit 127\n' > "$BROKEN_NODE_DIR/node"
chmod +x "$BROKEN_NODE_DIR/node"

: > "$CAP"; : > "$CREATED"
GH_LABEL_CAPTURE="$CAP" \
GH_CREATE_LOG="$CREATED" \
PATH="$BROKEN_NODE_DIR:$MOCKDIR:$PATH" \
AGENTS_CONFIG_DIR="" \
ISSUE_CREATE_SKIP_SCHEMA=1 \
    bash "$IC" --title t --body "b" \
        --reporter-model-text "You are powered by the model named DS4 Flash. The exact model ID is deepseek-v4-flash." \
        >/dev/null 2>>"$WORK/stderr.txt"
IC_RC=$?

# Order matters here: T19b is the precondition for T19, so it is asserted FIRST.
# "no reporter-model label" is the expected outcome of a degraded matcher AND the
# expected outcome of a wholly aborted run — only the creation check tells them apart.
if [ "$IC_RC" -eq 0 ] && [ "$(grep -c '^created$' "$CREATED" 2>/dev/null || printf '0')" = "1" ]; then
    pass "T19b-issue-still-created"
    T19_OK=yes
else
    fail "T19b-issue-still-created" "issue creation aborted when the matcher process failed (rc=$IC_RC, creates=$(grep -c '^created$' "$CREATED" 2>/dev/null || printf '0'), labels: $(tr '\n' ' ' < "$CAP"))"
    T19_OK=no
fi

if [ "$T19_OK" != "yes" ]; then
    fail "T19-no-label-when-matcher-fails" "PRECONDITION: the issue was never created — label-absence proves nothing"
elif grep -q '^reporter-model:' "$CAP"; then
    fail "T19-no-label-when-matcher-fails" "a reporter-model:* label appeared although the matcher process could not run (got: $(tr '\n' ' ' < "$CAP"))"
else
    pass "T19-no-label-when-matcher-fails"
fi

echo ""
echo "=== T15 drift check: matcher-module reporter-model:* RHS ⊆ labels.yml ==="

# Extract reporter-model:* label strings from the SSOT module, compare to labels.yml.
SCRIPT_LABELS=$(grep -oE 'reporter-model:[a-z0-9-]+' "$MODEL_MATCH_JS" 2>/dev/null | sort -u)
if [ -z "$SCRIPT_LABELS" ]; then
    fail "T15-drift" "no reporter-model:* labels found in hooks/lib/model-match.js (module not yet implemented)"
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
echo "=== T20 host-level skill wiring: SKILL.md documents both self-report forms ==="

# C2 cross-module coverage (#1988): the dispatch tests call issue-create.sh
# directly, so deleting the named-less short-form passthrough instruction from
# skills/issue-create/SKILL.md stays green. Assert the caller contract documents
# BOTH the named form and the named-less short form as --reporter-model-text.
SKILL="$REPO_ROOT/skills/issue-create/SKILL.md"
if ! grep -qF 'You are powered by the model named <name>. The exact model ID is <id>.' "$SKILL"; then
    fail "T20-named-form-doc" "SKILL.md does not document the named self-report form"
else
    pass "T20-named-form-doc"
fi
if ! grep -qF 'You are powered by the model <name>.' "$SKILL"; then
    fail "T20-short-form-doc" "SKILL.md does not document the named-less short self-report form (#1988)"
else
    pass "T20-short-form-doc"
fi
if ! grep -qF -- '--reporter-model-text "<sentence>"' "$SKILL"; then
    fail "T20-passthrough-flag" "SKILL.md does not document the --reporter-model-text passthrough flag"
else
    pass "T20-passthrough-flag"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
