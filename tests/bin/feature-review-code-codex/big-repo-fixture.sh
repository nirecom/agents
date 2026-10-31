# Part of the feature-review-code-codex entrypoints (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, fixture, scope:issue-specific, pwsh-not-required, TL2
# Builds BIG_REPO: a repository whose committed diff is comfortably past the cap, so truncation is real rather than simulated by an injected constant.

BIG_REPO="$TMPDIR_BASE/big-repo"
mkdir -p "$BIG_REPO"
git -C "$BIG_REPO" init -q
git -C "$BIG_REPO" config core.hooksPath "$BIG_REPO/.git/no-such-hooks"
git -C "$BIG_REPO" config user.email "test@example.com"
git -C "$BIG_REPO" config user.name "Test"
git -C "$BIG_REPO" config commit.gpgsign false
echo "init" > "$BIG_REPO/README.md"
git -C "$BIG_REPO" add README.md
git -C "$BIG_REPO" commit -q -m "initial"
git -C "$BIG_REPO" checkout -q -b feature-big
awk 'BEGIN { for (i = 0; i < 6000; i++) print "generated line " i }' > "$BIG_REPO/big.txt"
git -C "$BIG_REPO" add big.txt
git -C "$BIG_REPO" commit -q -m "big commit"
