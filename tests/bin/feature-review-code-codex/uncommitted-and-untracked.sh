# Part of tests/bin/feature-review-code-codex.sh (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, uncommitted, untracked, staged, fallback, scope:issue-specific, pwsh-not-required, TL2
# Cases 15-17, moved verbatim out of the parent at the 500-line hard split limit. Reuses TMPDIR_BASE, MOCK_BIN, SCRIPT, _timeout, fail, pass from the parent.
# TL3 gap: codex is a shell mock, so these rows observe which diff the script assembled, never what the installed binary did with it; staged/unstaged/untracked states are built by explicit git commands, so index states a real editor or merge conflict produces (partial staging, unmerged entries) are unexercised. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# ---------------------------------------------------------------------------
# 15. Uncommitted-fallback: staged-only changes on a fresh branch are reviewed
#     (the prior `git diff --cached` path must still work via `git diff HEAD`).
# ---------------------------------------------------------------------------
STAGED_REPO="$TMPDIR_BASE/staged-repo"
mkdir -p "$STAGED_REPO"
git -C "$STAGED_REPO" init -q
git -C "$STAGED_REPO" config core.hooksPath "$STAGED_REPO/.git/no-such-hooks"
git -C "$STAGED_REPO" config user.email "test@example.com"
git -C "$STAGED_REPO" config user.name "Test"
echo "init" > "$STAGED_REPO/README.md"
git -C "$STAGED_REPO" add README.md
git -C "$STAGED_REPO" commit -q -m "initial"
git -C "$STAGED_REPO" checkout -q -b staged-branch
echo "staged edit" >> "$STAGED_REPO/README.md"
git -C "$STAGED_REPO" add README.md

OUTPUT=$(cd "$STAGED_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --no-log 2>&1) || true

if echo "$OUTPUT" | grep -q "## Codex Review: PERFORMED"; then
    pass "Uncommitted-fallback: staged-only changes reviewed (PERFORMED)"
else
    fail "Uncommitted-fallback: staged-only changes not reviewed. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 16. Untracked-only: brand-new file on a fresh branch is included in review
#     (Gap 1 fix — git diff HEAD misses untracked files; git ls-files
#     + git diff --no-index synthesises a pseudo-diff for each one).
# ---------------------------------------------------------------------------
UNTRACKED_REPO="$TMPDIR_BASE/untracked-repo"
mkdir -p "$UNTRACKED_REPO"
git -C "$UNTRACKED_REPO" init -q
git -C "$UNTRACKED_REPO" config core.hooksPath "$UNTRACKED_REPO/.git/no-such-hooks"
git -C "$UNTRACKED_REPO" config user.email "test@example.com"
git -C "$UNTRACKED_REPO" config user.name "Test"
echo "init" > "$UNTRACKED_REPO/README.md"
git -C "$UNTRACKED_REPO" add README.md
git -C "$UNTRACKED_REPO" commit -q -m "initial"
git -C "$UNTRACKED_REPO" checkout -q -b untracked-branch
# BASE...HEAD is empty (no commits past main); no tracked changes — only one untracked file
echo "brand-new-content-xyz" > "$UNTRACKED_REPO/new-module.txt"

CAPTURE_FILE16="$TMPDIR_BASE/captured-t16.txt"
cat > "$MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
cat > "$CAPTURE_FILE16"
echo "HIGH: noted"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

# --base-state RESOLVED: an omitted state (UNKNOWN) withholds untracked content fail-closed (H1).
OUTPUT=$(cd "$UNTRACKED_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --base main --base-state RESOLVED --no-log 2>&1) || true

if echo "$OUTPUT" | grep -q "## Codex Review: PERFORMED"; then
    pass "Untracked-only: review PERFORMED"
else
    fail "Untracked-only: review not PERFORMED. Output: $OUTPUT"
fi

if [[ -f "$CAPTURE_FILE16" ]] && grep -q "brand-new-content-xyz" "$CAPTURE_FILE16"; then
    pass "Untracked-only: untracked file content present in codex prompt"
else
    fail "Untracked-only: untracked file content missing from prompt. File exists: $([ -f "$CAPTURE_FILE16" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# 17. Committed+uncommitted: when a committed diff exists (BASE...HEAD non-empty),
#     the review target is the WORKING TREE against merge-base(BASE, HEAD) (E24
#     redefinition, origin #1702 coverage gap): the unstaged edit on top of the
#     committed path and the untracked file both reach the prompt, and no
#     '## Codex Review Scope: EXCLUDED' line is printed (see also P10 in
#     path-priority/exclusion-and-cross-reference.sh for the staged-on-top case).
# ---------------------------------------------------------------------------
COMMITTED_REPO="$TMPDIR_BASE/committed-repo"
mkdir -p "$COMMITTED_REPO"
git -C "$COMMITTED_REPO" init -q
git -C "$COMMITTED_REPO" config core.hooksPath "$COMMITTED_REPO/.git/no-such-hooks"
git -C "$COMMITTED_REPO" config user.email "test@example.com"
git -C "$COMMITTED_REPO" config user.name "Test"
echo "init" > "$COMMITTED_REPO/README.md"
git -C "$COMMITTED_REPO" add README.md
git -C "$COMMITTED_REPO" commit -q -m "initial"
git -C "$COMMITTED_REPO" checkout -q -b committed-branch
echo "base content" > "$COMMITTED_REPO/tracked-file.txt"
git -C "$COMMITTED_REPO" add tracked-file.txt
git -C "$COMMITTED_REPO" commit -q -m "add tracked file"  # makes BASE...HEAD non-empty
echo "uncommitted edit" >> "$COMMITTED_REPO/tracked-file.txt"  # unstaged change (tracked)
echo "untracked-content-xyz" > "$COMMITTED_REPO/new-untracked.txt"  # untracked file

CAPTURE_FILE17="$TMPDIR_BASE/captured-t17.txt"
cat > "$MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
cat > "$CAPTURE_FILE17"
echo "HIGH: noted"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

OUTPUT=$(cd "$COMMITTED_REPO" && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" CODEX_REVIEW_MAX_DIFF_LINES=5000 _timeout bash "$SCRIPT" --base main --base-state RESOLVED --no-log 2>&1) || true

if echo "$OUTPUT" | grep -q "## Codex Review: PERFORMED"; then
    pass "Committed+uncommitted: review PERFORMED"
else
    fail "Committed+uncommitted: review not PERFORMED. Output: $OUTPUT"
fi

if [[ -f "$CAPTURE_FILE17" ]] && grep -q "base content" "$CAPTURE_FILE17"; then
    pass "Committed+uncommitted: committed diff content present in prompt"
else
    fail "Committed+uncommitted: committed diff content missing. File exists: $([ -f "$CAPTURE_FILE17" ] && echo yes || echo no)"
fi

if [[ -f "$CAPTURE_FILE17" ]] && grep -q "^+uncommitted edit" "$CAPTURE_FILE17"; then
    pass "Committed+uncommitted: the unstaged edit on top of the committed file is in the prompt"
else
    fail "Committed+uncommitted: the unstaged edit to tracked-file.txt is missing from the prompt. Output: $OUTPUT"
fi

if [[ -f "$CAPTURE_FILE17" ]] && grep -q "untracked-content-xyz" "$CAPTURE_FILE17"; then
    pass "Committed+uncommitted: untracked file content is in the prompt"
else
    fail "Committed+uncommitted: untracked file content missing from the prompt. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "^## Codex Review Scope: EXCLUDED"; then
    fail "Committed+uncommitted: an EXCLUDED line was printed although nothing is excluded any more. Output: $OUTPUT"
else
    pass "Committed+uncommitted: no EXCLUDED line is printed"
fi

if echo "$OUTPUT" | grep -q "^Note: BASE...HEAD empty"; then
    fail "Committed+uncommitted: the empty-committed fallback note was printed although a committed diff exists. Output: $OUTPUT"
else
    pass "Committed+uncommitted: no empty-committed fallback note when a committed diff exists"
fi

if [[ ! -s "$CAPTURE_FILE17" ]]; then
    fail "Committed+uncommitted: no prompt was captured, so the absence of an exclusion caveat proves nothing"
elif grep -qF -e "were excluded from this review" -e "EXCLUDED SCOPE" "$CAPTURE_FILE17"; then
    fail "Committed+uncommitted: the prompt still carries an exclusion SCOPE CAVEAT although nothing is excluded"
else
    pass "Committed+uncommitted: the prompt carries no exclusion SCOPE CAVEAT"
fi
