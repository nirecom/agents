#!/usr/bin/env bash
# tests/feature-issue-1492-label-taxonomy.sh
# Tests: .github/labels.yml, bin/github-issues/migrate-model-labels.sh
# Tags: scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Actual GitHub API label rename/create via migrate-model-labels.sh (needs real token + network)
# - Idempotency of migrate-model-labels.sh against a live GitHub repo
# - --dry-run output format verified against real GitHub API responses
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LABELS_YML="$REPO_ROOT/.github/labels.yml"
MIGRATE_SCRIPT="$REPO_ROOT/bin/github-issues/migrate-model-labels.sh"

PASS=0; FAIL=0

assert_contains_label() {
    local name="$1" label_name="$2"
    if grep -qF "\"$label_name\"" "$LABELS_YML" 2>/dev/null; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — label '$label_name' not found in labels.yml"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains_label() {
    local name="$1" label_name="$2"
    if grep -qF "\"$label_name\"" "$LABELS_YML" 2>/dev/null; then
        echo "FAIL: $name — label '$label_name' should NOT exist in labels.yml"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $name"
        PASS=$((PASS + 1))
    fi
}

assert_labels_yml_contains() {
    local name="$1" pattern="$2"
    if grep -qF "$pattern" "$LABELS_YML" 2>/dev/null; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — pattern not found in labels.yml: $pattern"
        FAIL=$((FAIL + 1))
    fi
}

assert_labels_yml_not_contains() {
    local name="$1" pattern="$2"
    if grep -qF "$pattern" "$LABELS_YML" 2>/dev/null; then
        echo "FAIL: $name — pattern should NOT exist in labels.yml: $pattern"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $name"
        PASS=$((PASS + 1))
    fi
}

assert_script_contains() {
    local name="$1" pattern="$2"
    if grep -qF -- "$pattern" "$MIGRATE_SCRIPT" 2>/dev/null; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — pattern not found in migrate script: $pattern"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== labels.yml: reporter-model:* labels exist ==="

assert_contains_label "T-reporter-model-fable-exists"       "reporter-model:fable"
assert_contains_label "T-reporter-model-opus-exists"        "reporter-model:opus"
assert_contains_label "T-reporter-model-sonnet-exists"      "reporter-model:sonnet"
assert_contains_label "T-reporter-model-ds4-exists"         "reporter-model:ds4"
assert_contains_label "T-reporter-model-devstral-exists"    "reporter-model:devstral"
assert_contains_label "T-reporter-model-qwen-coder-exists"  "reporter-model:qwen-coder"

echo ""
echo "=== labels.yml: model-scope:* labels exist ==="

assert_contains_label "T-model-scope-ds4-exists"        "model-scope:ds4"
assert_contains_label "T-model-scope-devstral-exists"   "model-scope:devstral"
assert_contains_label "T-model-scope-qwen-coder-exists" "model-scope:qwen-coder"
assert_contains_label "T-model-scope-claude-exists"     "model-scope:claude"

echo ""
echo "=== labels.yml: old model:* labels do NOT exist ==="

assert_not_contains_label "T-old-model-fable-removed"  "model:fable"
assert_not_contains_label "T-old-model-opus-removed"   "model:opus"
assert_not_contains_label "T-old-model-sonnet-removed" "model:sonnet"
assert_not_contains_label "T-old-model-ds4-removed"    "model:ds4"
assert_not_contains_label "T-old-model-others-removed" "model:others"

echo ""
echo "=== labels.yml: section headers exist ==="

assert_labels_yml_contains "T-section-header-reporter-model" "# --- Reporter Model ---"
assert_labels_yml_contains "T-section-header-model-scope"    "# --- Model Scope ---"

echo ""
echo "=== labels.yml: description content checks ==="

assert_labels_yml_contains "T-reporter-model-desc-reliability" "reliability signal"
assert_labels_yml_not_contains "T-no-specific-to-phrase" "specific to or observed with"

echo ""
echo "=== migrate-model-labels.sh: file existence and attributes ==="

if [ -f "$MIGRATE_SCRIPT" ]; then
    echo "PASS: T-migrate-script-exists"
    PASS=$((PASS + 1))
else
    echo "FAIL: T-migrate-script-exists — $MIGRATE_SCRIPT not found"
    FAIL=$((FAIL + 1))
fi

if [ -x "$MIGRATE_SCRIPT" ]; then
    echo "PASS: T-migrate-script-executable"
    PASS=$((PASS + 1))
else
    echo "FAIL: T-migrate-script-executable — $MIGRATE_SCRIPT is not executable"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== migrate-model-labels.sh: script content checks ==="

assert_script_contains "T-migrate-shebang"         "#!/usr/bin/env bash"
assert_script_contains "T-migrate-set-euo"         "set -euo pipefail"
assert_script_contains "T-migrate-dry-run-flag"    "--dry-run"
assert_script_contains "T-migrate-phase-rename"    "RENAME"
assert_script_contains "T-migrate-phase-create"    "sync-labels.sh"
assert_script_contains "T-migrate-phase-others"    "model:others"
assert_script_contains "T-migrate-phase-1488"      "1488"

echo ""
echo "=== migrate-model-labels.sh: subprocess execution (--dry-run) ==="

# T-migrate-dry-run-exits-zero: script exits 0 with --dry-run (L2 subprocess boundary)
# Requires script to exist; skips gracefully if not yet created (pre-implementation).
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "FAIL: T-migrate-dry-run-exits-zero — script not found (pre-implementation)"
    FAIL=$((FAIL + 1))
elif [ ! -x "$MIGRATE_SCRIPT" ]; then
    echo "FAIL: T-migrate-dry-run-exits-zero — script not executable"
    FAIL=$((FAIL + 1))
else
    if bash "$MIGRATE_SCRIPT" --dry-run 2>&1 >/dev/null; then
        echo "PASS: T-migrate-dry-run-exits-zero"
        PASS=$((PASS + 1))
    else
        echo "FAIL: T-migrate-dry-run-exits-zero — exited non-zero with --dry-run"
        FAIL=$((FAIL + 1))
    fi
fi

# T-migrate-dry-run-output-contains-rename: dry-run prints expected RENAME plan
if [ ! -f "$MIGRATE_SCRIPT" ] || [ ! -x "$MIGRATE_SCRIPT" ]; then
    echo "FAIL: T-migrate-dry-run-output-contains-rename — script unavailable (pre-implementation)"
    FAIL=$((FAIL + 1))
else
    DRY_OUTPUT=$(bash "$MIGRATE_SCRIPT" --dry-run 2>&1 || true)
    if echo "$DRY_OUTPUT" | grep -qi "rename\|reporter-model"; then
        echo "PASS: T-migrate-dry-run-output-contains-rename"
        PASS=$((PASS + 1))
    else
        echo "FAIL: T-migrate-dry-run-output-contains-rename — expected RENAME/reporter-model in dry-run output"
        FAIL=$((FAIL + 1))
    fi
fi

# T-migrate-unknown-flag-exits-nonzero: passing unknown flag exits non-zero (error-path)
if [ ! -f "$MIGRATE_SCRIPT" ] || [ ! -x "$MIGRATE_SCRIPT" ]; then
    echo "FAIL: T-migrate-unknown-flag-exits-nonzero — script unavailable (pre-implementation)"
    FAIL=$((FAIL + 1))
else
    if bash "$MIGRATE_SCRIPT" --unknown-flag-xyz 2>/dev/null; then
        echo "FAIL: T-migrate-unknown-flag-exits-nonzero — should have exited non-zero for unknown flag"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: T-migrate-unknown-flag-exits-nonzero"
        PASS=$((PASS + 1))
    fi
fi

# T-migrate-dry-run-idempotent: running --dry-run twice produces identical output (L2 idempotency)
if [ ! -f "$MIGRATE_SCRIPT" ] || [ ! -x "$MIGRATE_SCRIPT" ]; then
    echo "FAIL: T-migrate-dry-run-idempotent — script unavailable (pre-implementation)"
    FAIL=$((FAIL + 1))
else
    OUT1=$(bash "$MIGRATE_SCRIPT" --dry-run 2>&1 || true)
    OUT2=$(bash "$MIGRATE_SCRIPT" --dry-run 2>&1 || true)
    if [ "$OUT1" = "$OUT2" ]; then
        echo "PASS: T-migrate-dry-run-idempotent"
        PASS=$((PASS + 1))
    else
        echo "FAIL: T-migrate-dry-run-idempotent — dry-run output differs between runs"
        FAIL=$((FAIL + 1))
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
