#!/bin/bash
# Tests: bin/github-issues, bin/github-issues/bootstrap-labels.sh, bin/github-issues/bootstrap-labels.sh., bin/github-issues/sync-labels.sh
# Tags: workflow, github, issues, labels, sync
# Tests for issue #283 — bin/github-issues/bootstrap-labels.sh.
#
# bootstrap-labels.sh copies the label-sync skeleton (labels.yml, sync-labels.sh,
# sync-labels.yml workflow) from AGENTS_CONFIG_DIR into a target repo, then runs
# the initial `gh label create --force` sync unless --no-sync is given.
#
# RED: this entire suite fails until bin/github-issues/bootstrap-labels.sh is
# created. Each test is structured so it will pass automatically once the
# source script lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_SCRIPT="$AGENTS_DIR/bin/github-issues/bootstrap-labels.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Ensure mock helpers are executable.
for f in gh git doc-append; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

# ----------------------------------------------------------------------------
# Fixture helpers
# ----------------------------------------------------------------------------

setup_tmp() {
    TMP="$(mktemp -d)"
    FAKE_AGENTS="$TMP/agents"
    REPO="$TMP/repo"
    mkdir -p "$FAKE_AGENTS/bin/github-issues" "$FAKE_AGENTS/.github/workflows"
    mkdir -p "$REPO"
    # Source artifacts in fake AGENTS_CONFIG_DIR.
    cat > "$FAKE_AGENTS/.github/labels.yml" <<'EOF'
- name: type:task
  color: "0e8a16"
- name: type:incident
  color: "d93f0b"
- name: status:cancelled
  color: "cccccc"
- name: status:migrated
  color: "fbca04"
- name: priority:high
  color: "b60205"
EOF
    cat > "$FAKE_AGENTS/.github/workflows/sync-labels.yml" <<'EOF'
name: Sync labels
on: { push: { branches: [main], paths: [.github/labels.yml] } }
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash bin/github-issues/sync-labels.sh
EOF
    cat > "$FAKE_AGENTS/bin/github-issues/sync-labels.sh" <<'EOF'
#!/usr/bin/env bash
# Real sync-labels.sh stub — reads .github/labels.yml and runs
# `gh label create --force` once per entry.
set -euo pipefail
LABELS_FILE="${1:-.github/labels.yml}"
grep -E '^- name:' "$LABELS_FILE" | sed -E 's/^- name:[[:space:]]*//' | while read -r name; do
    gh label create "$name" --force >/dev/null 2>&1 || true
done
EOF
    chmod +x "$FAKE_AGENTS/bin/github-issues/sync-labels.sh"

    export AGENTS_CONFIG_DIR="$FAKE_AGENTS"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_LABEL_LOG="$TMP/labels.log"
    : > "$GH_MOCK_LABEL_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    unset AGENTS_CONFIG_DIR GH_MOCK_LABEL_LOG TMP FAKE_AGENTS REPO
}

# Cross-platform sha256 helper.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ============================================================================
# B-series — bootstrap-labels.sh
# ============================================================================

# --- B1: script exists and is executable.
# TODO: source not yet written — will FAIL until bin/github-issues/bootstrap-labels.sh lands.
if [ -f "$BOOTSTRAP_SCRIPT" ] && [ -x "$BOOTSTRAP_SCRIPT" ]; then
    pass "B1: bootstrap-labels.sh exists and is executable"
else
    fail "B1: bootstrap-labels.sh missing or not executable ($BOOTSTRAP_SCRIPT)"
fi

# --- B2: no arguments → non-zero exit, usage to stderr
setup_tmp
ERRFILE="$TMP/b2.err"
run_with_timeout 15 bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>"$ERRFILE"
RC=$?
ERR=$(cat "$ERRFILE" 2>/dev/null)
if [ "$RC" -ne 0 ] && echo "$ERR" | grep -qiE '(usage|usage:)'; then
    pass "B2: no args → non-zero exit + usage on stderr"
else
    fail "B2: rc=$RC err='$ERR'"
fi
teardown_tmp

# --- B3: non-existent repo-dir → non-zero, stderr mentions "not found" / "no such"
setup_tmp
ERRFILE="$TMP/b3.err"
run_with_timeout 15 bash "$BOOTSTRAP_SCRIPT" "$TMP/does-not-exist" >/dev/null 2>"$ERRFILE"
RC=$?
ERR=$(cat "$ERRFILE" 2>/dev/null)
if [ "$RC" -ne 0 ] && echo "$ERR" | grep -qiE '(not found|no such)'; then
    pass "B3: non-existent repo-dir → non-zero exit + 'not found'/'no such' on stderr"
else
    fail "B3: rc=$RC err='$ERR'"
fi
teardown_tmp

# --- B4: normal case — 3 files copied into target repo.
setup_tmp
run_with_timeout 15 bash "$BOOTSTRAP_SCRIPT" "$REPO" >/dev/null 2>&1
RC=$?
b4_missing=()
for rel in ".github/labels.yml" ".github/workflows/sync-labels.yml" \
           "bin/github-issues/sync-labels.sh"; do
    [ -f "$REPO/$rel" ] || b4_missing+=("$rel")
done
if [ "$RC" -eq 0 ] && [ "${#b4_missing[@]}" -eq 0 ]; then
    pass "B4: 3 files copied into target repo (labels.yml, sync-labels.yml, sync-labels.sh)"
else
    fail "B4: rc=$RC missing=${b4_missing[*]:-(none)}"
fi
teardown_tmp

# --- B5: initial sync — gh label create called once per labels.yml entry.
setup_tmp
EXPECTED_COUNT=$(grep -cE '^- name:' "$FAKE_AGENTS/.github/labels.yml")
run_with_timeout 30 bash "$BOOTSTRAP_SCRIPT" "$REPO" >/dev/null 2>&1
RC=$?
LOG_COUNT=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null || echo 0)
has_task=$(grep -c 'type:task' "$GH_MOCK_LABEL_LOG" 2>/dev/null || echo 0)
has_incident=$(grep -c 'type:incident' "$GH_MOCK_LABEL_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$LOG_COUNT" -ge "$EXPECTED_COUNT" ] \
   && [ "$has_task" -ge 1 ] && [ "$has_incident" -ge 1 ]; then
    pass "B5: initial sync — $LOG_COUNT label create calls (>= $EXPECTED_COUNT), includes type:task + type:incident"
else
    fail "B5: rc=$RC log_count=$LOG_COUNT expected=$EXPECTED_COUNT has_task=$has_task has_incident=$has_incident"
fi
teardown_tmp

# --- B6: idempotency — pre-populated files unchanged after second run.
setup_tmp
# Pre-populate target with the 3 files (different content from source so
# we can detect any overwrite).
mkdir -p "$REPO/.github/workflows" "$REPO/bin/github-issues"
echo "# pre-existing labels.yml" > "$REPO/.github/labels.yml"
echo "# pre-existing workflow"    > "$REPO/.github/workflows/sync-labels.yml"
echo "# pre-existing sync"        > "$REPO/bin/github-issues/sync-labels.sh"
chmod +x "$REPO/bin/github-issues/sync-labels.sh"

before_a=$(sha256_of "$REPO/.github/labels.yml")
before_b=$(sha256_of "$REPO/.github/workflows/sync-labels.yml")
before_c=$(sha256_of "$REPO/bin/github-issues/sync-labels.sh")

run_with_timeout 30 bash "$BOOTSTRAP_SCRIPT" "$REPO" >/dev/null 2>&1
RC=$?

after_a=$(sha256_of "$REPO/.github/labels.yml")
after_b=$(sha256_of "$REPO/.github/workflows/sync-labels.yml")
after_c=$(sha256_of "$REPO/bin/github-issues/sync-labels.sh")

if [ "$RC" -eq 0 ] \
   && [ "$before_a" = "$after_a" ] \
   && [ "$before_b" = "$after_b" ] \
   && [ "$before_c" = "$after_c" ]; then
    pass "B6: idempotency — pre-existing files unchanged after second run (sha256 stable)"
else
    fail "B6: rc=$RC a=$before_a/$after_a b=$before_b/$after_b c=$before_c/$after_c"
fi
teardown_tmp

# --- B8: --no-sync — files copied, no gh label create calls.
setup_tmp
run_with_timeout 30 bash "$BOOTSTRAP_SCRIPT" "$REPO" --no-sync >/dev/null 2>&1
RC=$?
b8_missing=()
for rel in ".github/labels.yml" ".github/workflows/sync-labels.yml" \
           "bin/github-issues/sync-labels.sh"; do
    [ -f "$REPO/$rel" ] || b8_missing+=("$rel")
done
LOG_SIZE=$(wc -c <"$GH_MOCK_LABEL_LOG" 2>/dev/null | tr -d ' ')
LOG_SIZE=${LOG_SIZE:-0}
if [ "$RC" -eq 0 ] && [ "${#b8_missing[@]}" -eq 0 ] && [ "$LOG_SIZE" -eq 0 ]; then
    pass "B8: --no-sync — 3 files copied, label log empty (no sync calls)"
else
    fail "B8: rc=$RC missing=${b8_missing[*]:-(none)} log_size=$LOG_SIZE"
fi
teardown_tmp

# --- B9: partial-present — pre-existing sync-labels.sh NOT overwritten,
#        missing files filled in.
setup_tmp
mkdir -p "$REPO/bin/github-issues"
echo "# pre-existing sync-labels stub" > "$REPO/bin/github-issues/sync-labels.sh"
chmod +x "$REPO/bin/github-issues/sync-labels.sh"
before_sync=$(sha256_of "$REPO/bin/github-issues/sync-labels.sh")

run_with_timeout 30 bash "$BOOTSTRAP_SCRIPT" "$REPO" --no-sync >/dev/null 2>&1
RC=$?

after_sync=$(sha256_of "$REPO/bin/github-issues/sync-labels.sh")
labels_present=$([ -f "$REPO/.github/labels.yml" ] && echo 1 || echo 0)
workflow_present=$([ -f "$REPO/.github/workflows/sync-labels.yml" ] && echo 1 || echo 0)
if [ "$RC" -eq 0 ] \
   && [ "$before_sync" = "$after_sync" ] \
   && [ "$labels_present" = "1" ] \
   && [ "$workflow_present" = "1" ]; then
    pass "B9: partial-present — pre-existing sync-labels.sh preserved (cp -n); missing files filled in"
else
    fail "B9: rc=$RC before=$before_sync after=$after_sync labels=$labels_present workflow=$workflow_present"
fi
teardown_tmp

# --- B10: AGENTS_CONFIG_DIR unset → non-zero exit.
setup_tmp
unset AGENTS_CONFIG_DIR
run_with_timeout 15 bash "$BOOTSTRAP_SCRIPT" "$REPO" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "B10: AGENTS_CONFIG_DIR unset → non-zero exit"
else
    fail "B10: AGENTS_CONFIG_DIR unset should fail (rc=$RC)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
