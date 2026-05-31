#!/bin/bash
# Tests: bin/doc-append.py
# Tags: 277, doc-append-merge-union
# E2E tests for issue #277 — verify `merge=union` resolves rebase/merge
# conflicts on docs/history.md and CHANGELOG.md, and that doc-append's
# INCIDENT auto-numbering still works after the sort refactor.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC_APPEND="$REPO_ROOT/bin/doc-append.py"
ERRORS=0

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Resolve a runnable Python. On Windows, bare `python`/`python3` may be the
# Microsoft Store stub (exit 49 with no output). Prefer `uv run python` when
# available; otherwise fall back to python3/python.
if command -v uv >/dev/null 2>&1; then
    PY_RUNNER=(uv run python)
elif command -v python3 >/dev/null 2>&1 && python3 -c "import sys" >/dev/null 2>&1; then
    PY_RUNNER=(python3)
else
    PY_RUNNER=(python)
fi

setup_repo() {
    local dir="$1"
    local target_file="$2"  # e.g. docs/history.md or CHANGELOG.md
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
    # Disable any inherited hooks (e.g. enforce-worktree pre-commit)
    git -C "$dir" config core.hooksPath /dev/null
    # Force main branch name regardless of init.defaultBranch
    git -C "$dir" symbolic-ref HEAD refs/heads/main
    mkdir -p "$dir/docs"
    # Inline .gitattributes (the worktree's .gitattributes may not have
    # the merge=union line yet — the fix introduces it).
    echo "$target_file merge=union" > "$dir/.gitattributes"
    # Seed file with one entry
    mkdir -p "$dir/$(dirname "$target_file")"
    cat > "$dir/$target_file" <<'EOF'
### FEATURE: Seed (2026-01-01, seed111)
Background: initial
Changes: initial
EOF
    git -C "$dir" add .
    git -C "$dir" commit -q -m "seed"
}

append_entry() {
    # $1=repo, $2=target_file, $3=subject, $4=date, $5=commit
    local dir="$1" target="$2" subj="$3" d="$4" c="$5"
    cat >> "$dir/$target" <<EOF

### FEATURE: $subj ($d, $c)
Background: bg
Changes: ch
EOF
    git -C "$dir" add "$target"
    git -C "$dir" commit -q -m "add $subj"
}

check_no_conflict_markers() {
    local file="$1" label="$2"
    if grep -q '^<<<<<<<' "$file" 2>/dev/null; then
        fail "$label: conflict markers present in $file"
    else
        pass "$label: no conflict markers in $file"
    fi
}

# -------- R1a: git rebase on docs/history.md --------
echo "=== R1a: git rebase on docs/history.md ==="
TMP1="$(mktemp -d)"
TMP2=""; TMP3=""; TMP4=""
trap 'rm -rf "$TMP1" "${TMP2:-}" "${TMP3:-}" "${TMP4:-}"' EXIT
setup_repo "$TMP1" "docs/history.md"
git -C "$TMP1" checkout -q -b branch-a
append_entry "$TMP1" "docs/history.md" "FromA" "2026-05-01" "aaa1111"
git -C "$TMP1" checkout -q main
git -C "$TMP1" checkout -q -b branch-b
append_entry "$TMP1" "docs/history.md" "FromB" "2026-05-02" "bbb2222"
# Rebase branch-b onto branch-a
if run_with_timeout git -C "$TMP1" rebase branch-a >/dev/null 2>&1; then
    pass "R1a: rebase exit code 0"
    check_no_conflict_markers "$TMP1/docs/history.md" "R1a"
else
    fail "R1a: rebase failed (exit non-zero)"
    git -C "$TMP1" rebase --abort 2>/dev/null || true
fi

# -------- R1b: git merge on docs/history.md --------
echo "=== R1b: git merge --no-ff on docs/history.md ==="
TMP2="$(mktemp -d)"
setup_repo "$TMP2" "docs/history.md"
git -C "$TMP2" checkout -q -b branch-a
append_entry "$TMP2" "docs/history.md" "FromA" "2026-05-01" "aaa1111"
git -C "$TMP2" checkout -q main
git -C "$TMP2" checkout -q -b branch-b
append_entry "$TMP2" "docs/history.md" "FromB" "2026-05-02" "bbb2222"
if run_with_timeout git -C "$TMP2" merge --no-ff -m "merge a" branch-a >/dev/null 2>&1; then
    pass "R1b: merge exit code 0"
    check_no_conflict_markers "$TMP2/docs/history.md" "R1b"
else
    fail "R1b: merge failed (exit non-zero)"
    git -C "$TMP2" merge --abort 2>/dev/null || true
fi

# -------- R1c: git rebase on CHANGELOG.md --------
echo "=== R1c: git rebase on CHANGELOG.md ==="
TMP3="$(mktemp -d)"
setup_repo "$TMP3" "CHANGELOG.md"
git -C "$TMP3" checkout -q -b branch-a
append_entry "$TMP3" "CHANGELOG.md" "FromA" "2026-05-01" "aaa1111"
git -C "$TMP3" checkout -q main
git -C "$TMP3" checkout -q -b branch-b
append_entry "$TMP3" "CHANGELOG.md" "FromB" "2026-05-02" "bbb2222"
if run_with_timeout git -C "$TMP3" rebase branch-a >/dev/null 2>&1; then
    pass "R1c: rebase exit code 0"
    check_no_conflict_markers "$TMP3/CHANGELOG.md" "R1c"
else
    fail "R1c: rebase failed (exit non-zero)"
    git -C "$TMP3" rebase --abort 2>/dev/null || true
fi

# -------- R4: INCIDENT auto-numbering still works --------
echo "=== R4: INCIDENT auto-numbering compatibility ==="
TMP4="$(mktemp -d)"
mkdir -p "$TMP4/docs"
cat > "$TMP4/docs/history.md" <<'EOF'
### FEATURE: Seed (2026-01-01, seed111)
Background: initial
Changes: initial
EOF

run_with_timeout "${PY_RUNNER[@]}" "$DOC_APPEND" "$TMP4/docs/history.md" \
    --category INCIDENT --subject "First incident" --date 2026-02-01 \
    --commits "i1111111" --cause "cause1" --fix "fix1" --no-auto-rotate \
    >/dev/null 2>&1 || fail "R4: first INCIDENT append failed"

if grep -q '### INCIDENT: #1:' "$TMP4/docs/history.md"; then
    pass "R4: first INCIDENT numbered #1"
else
    fail "R4: '### INCIDENT: #1:' not found"
    echo "----- file content -----"
    cat "$TMP4/docs/history.md"
    echo "------------------------"
fi

run_with_timeout "${PY_RUNNER[@]}" "$DOC_APPEND" "$TMP4/docs/history.md" \
    --category INCIDENT --subject "Second incident" --date 2026-03-01 \
    --commits "i2222222" --cause "cause2" --fix "fix2" --no-auto-rotate \
    >/dev/null 2>&1 || fail "R4: second INCIDENT append failed"

if grep -q '### INCIDENT: #2:' "$TMP4/docs/history.md"; then
    pass "R4: second INCIDENT numbered #2"
else
    fail "R4: '### INCIDENT: #2:' not found"
    echo "----- file content -----"
    cat "$TMP4/docs/history.md"
    echo "------------------------"
fi

echo
if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: $ERRORS error(s)"
    exit 1
fi
echo "ALL PASS"
