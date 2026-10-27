#!/bin/bash
# tests/bin/feature-commit-gate-redesign/section-e.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Section E: review-code-codex staged-diff fallback.

echo ""
echo "=== Section E: review-code-codex staged fallback ==="

if [ ! -f "$CODEX_BIN" ]; then
    fail "E22 (review-code-codex not found at $CODEX_BIN)"
    fail "E23 (review-code-codex not found)"
    fail "E24 (review-code-codex not found)"
else
    # Mock codex bin — use a Unix-style path so PATH parsing on Git Bash
    # does not split on the drive-letter colon (e.g. "C:/Users/...").
    if command -v cygpath >/dev/null 2>&1; then
        MOCK_BIN_PATH="$(cygpath -u "$TMPDIR_BASE/mock-bin")"
    else
        MOCK_BIN_PATH="$TMPDIR_BASE/mock-bin"
    fi
    MOCK_BIN="$TMPDIR_BASE/mock-bin"
    mkdir -p "$MOCK_BIN"
    SENTINEL_STAGED="STAGED_SENTINEL_X9Q3Z"
    SENTINEL_COMMIT="COMMIT_SENTINEL_W4P7M"
    CAPTURE="$TMPDIR_BASE/codex-capture.txt"

    write_codex_capture_mock() {
        cat > "$MOCK_BIN/codex" <<MOCK_EOF
#!/usr/bin/env bash
cat > "$CAPTURE"
echo "ok"
exit 0
MOCK_EOF
        chmod +x "$MOCK_BIN/codex"
    }

    # 22. Fresh branch (no commits past base) + staged content → PERFORMED, staged content forwarded
    REPO_22="$(setup_main_checkout "codex-repo-22")"
    # Branch but no commits past base
    git -C "$REPO_22" checkout -q -b feature-22
    echo "$SENTINEL_STAGED line" > "$REPO_22/staged.txt"
    git -C "$REPO_22" add staged.txt
    write_codex_capture_mock
    rm -f "$CAPTURE"
    OUT_22="$(cd "$REPO_22" && PATH="$MOCK_BIN_PATH:$PATH" HOME="$TMPDIR_BASE" \
        run_with_timeout 60 bash "$CODEX_BIN" --base main --no-log 2>&1 || true)"
    if echo "$OUT_22" | grep -q "## Codex Review: PERFORMED" && \
       [ -f "$CAPTURE" ] && grep -q "$SENTINEL_STAGED" "$CAPTURE"; then
        pass "E22. fresh branch + staged → PERFORMED with staged diff forwarded"
    else
        fail "E22. expected PERFORMED+staged-sentinel; capture-exists=$([ -f "$CAPTURE" ] && echo y || echo n) out: $OUT_22"
    fi

    # 23. Fresh branch, no commits, no staged → SKIPPED mentioning empty
    REPO_23="$(setup_main_checkout "codex-repo-23")"
    git -C "$REPO_23" checkout -q -b feature-23
    write_codex_capture_mock
    OUT_23="$(cd "$REPO_23" && PATH="$MOCK_BIN_PATH:$PATH" HOME="$TMPDIR_BASE" \
        run_with_timeout 60 bash "$CODEX_BIN" --base main --no-log 2>&1 || true)"
    if echo "$OUT_23" | grep -q "## Codex Review: SKIPPED" && echo "$OUT_23" | grep -qi "empty"; then
        pass "E23. fresh branch + no staged → SKIPPED (empty)"
    else
        fail "E23. expected SKIPPED+empty; got: $OUT_23"
    fi

    # 24. Branch has commits past base + also has staged → PERFORMED over the working tree vs
    #     merge-base: committed AND staged-only sentinels both in the prompt, no EXCLUDED line
    REPO_24="$(setup_main_checkout "codex-repo-24")"
    git -C "$REPO_24" checkout -q -b feature-24
    echo "$SENTINEL_COMMIT line" > "$REPO_24/committed.txt"
    git -C "$REPO_24" add committed.txt
    git -C "$REPO_24" commit -q -m "feature commit"
    # Add staged-only content with a different sentinel
    echo "$SENTINEL_STAGED line" > "$REPO_24/staged-only.txt"
    git -C "$REPO_24" add staged-only.txt
    write_codex_capture_mock
    rm -f "$CAPTURE"
    OUT_24="$(cd "$REPO_24" && PATH="$MOCK_BIN_PATH:$PATH" HOME="$TMPDIR_BASE" CODEX_REVIEW_MAX_DIFF_LINES=5000 \
        run_with_timeout 60 bash "$CODEX_BIN" --base main --no-log 2>&1 || true)"
    if echo "$OUT_24" | grep -q "## Codex Review: PERFORMED" \
       && [ -f "$CAPTURE" ] \
       && grep -q "$SENTINEL_COMMIT" "$CAPTURE" \
       && grep -q "$SENTINEL_STAGED" "$CAPTURE" \
       && ! echo "$OUT_24" | grep -q "^## Codex Review Scope: EXCLUDED"; then
        pass "E24. branch w/ commits + staged → PERFORMED with committed and staged sentinels, no EXCLUDED line"
    else
        fail "E24. expected PERFORMED+commit-sentinel+staged-sentinel and no EXCLUDED line; capture-exists=$([ -f "$CAPTURE" ] && echo y || echo n) out: $OUT_24"
    fi
fi
