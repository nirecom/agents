#!/bin/bash
# tests/feature-worktree-start-non-interactive/private-repo-gate.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/check-private-repo-name.js, bin/list-private-repo-names.js
# Tags: worktree, start, private-repo, outbound-scan, security, TL2, scope:issue-specific
# B21 — the private-repo-name half of derive-worktree-name.sh's scan gate, and the
# one-shot cache that feeds it.
#
# Why it needs its own coverage: bin/scan-outbound.sh only consults two static files,
# so a private repo's bare name reaches a public branch name unless scan_clean() also
# checks it against the user's private-repo list. That second check is the only thing
# standing between an intent title and a pushed branch — and because the list is
# resolved from the environment, "the gate ran" and "the gate had anything to compare
# against" are separate facts. Both are pinned here.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# A fictional private repo name. It has to survive slugification unchanged to be a
# meaningful probe, so it is already in slug shape.
PRIV='secret-thing'
PRIV_TITLE="Fix the $PRIV rollout"

# Fixed-name repo dir: REPO_NAME is itself scanned at D0 and becomes the fallback slug,
# so a random mktemp basename would make the expected task name unpredictable.
PR_REPO="$FIXTURE/pr-gate-repo"
mkdir -p "$PR_REPO"
git -C "$PR_REPO" init -q >/dev/null 2>&1
git -C "$PR_REPO" config core.hooksPath /dev/null

INTENT_B21="$FIXTURE/b21-intent.md"
write_intent "$INTENT_B21" "$PRIV_TITLE" '- #1910: private repo name gate'

# --- B21a: a title carrying a private repo name never reaches the task name --
# The declared cache is the list the gate compares against; everything else is the
# production path, real scanner included.
PRIVATE_REPO_NAMES_CACHE="$PRIV"
run_derive B21a --intent "$INTENT_B21" --repo-dir "$PR_REPO"
B21A_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$B21A_TN" = "1910-pr-gate-repo" ]; then
    pass "B21a: a title carrying a private repo name is replaced by the repo-name fallback ($B21A_TN)"
else
    fail "B21a: expected TASK_NAME=1910-pr-gate-repo (rc=$RC, tn='$B21A_TN', err='$ERR')"
fi
if [[ "$OUT" == *"$PRIV"* || "$ERR" == *"$PRIV"* ]]; then
    fail "B21a/leak: the private repo name reached stdout or stderr (out='$OUT', err='$ERR')"
else
    pass "B21a/leak: the private repo name appears in neither the emitted name nor the diagnostic"
fi
if [[ "$ERR" == *'outbound scan'* && "$ERR" == *'using a non-descriptive name instead'* ]]; then
    pass "B21a/stderr: the fallback is attributed to the outbound scan"
else
    fail "B21a/stderr: expected the outbound-scan fallback diagnostic (err='$ERR')"
fi

# --- B21a/neg: the same title with an empty list is NOT rejected ------------
# The classifier's other verdict (skills/_shared/test-design.md "Classifier / guard
# cases"). Without it B21a cannot tell "the private-repo check rejected the title" from
# "the title was rejected for some unrelated reason", and an over-blocking gate that
# degraded every name to a fallback would still look green.
PRIVATE_REPO_NAMES_CACHE=''
run_derive B21a/neg --intent "$INTENT_B21" --repo-dir "$PR_REPO"
B21N_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$B21N_TN" = "1910-fix-the-secret-thing-rollout" ]; then
    pass "B21a/neg: with no private repos declared the same title is kept verbatim ($B21N_TN)"
else
    fail "B21a/neg: expected TASK_NAME=1910-fix-the-secret-thing-rollout with an empty list (rc=$RC, tn='$B21N_TN', err='$ERR')"
fi

# --- B21b/B21c: the one-shot cache seam -------------------------------------
# derive-worktree-name.sh calls scan_clean() several times per run (D0, D2, D6), and
# each call re-invokes the checker. Resolving the name list once per run rather than
# once per check is what turns N `gh repo list` round-trips into one — and it is the
# same seam this suite relies on to stay off the network entirely.
#
# A stand-in AGENTS_CONFIG_DIR makes the lister observable: the stub records every
# invocation and answers with a fictional private name, so both halves of the contract
# are testable — how often it runs, and whether its answer is actually used.
PR_CFG="$FIXTURE/pr-cfg"
mkdir -p "$PR_CFG/bin"
cp "$AGENTS_DIR/bin/scan-outbound.sh" "$PR_CFG/bin/scan-outbound.sh"
cp "$AGENTS_DIR/bin/check-private-repo-name.js" "$PR_CFG/bin/check-private-repo-name.js"
# bin/is-github-dotcom-remote is deliberately absent, as in d6-fallback-cascade.sh: no
# D4 label lookup, no network. --headless keeps parse-closes-issues out of the picture.
PR_MARKER="$FIXTURE/pr-lister-invocations.txt"
: > "$PR_MARKER"
# The marker path is a string literal inside the JS source, so no MSYS argv translation
# applies to it — it must already be in the platform-native spelling Node can open, or
# the stub would throw, emit nothing, and read as "the lister was never invoked".
PR_MARKER_NATIVE="$(native_path "$PR_MARKER")"
cat > "$PR_CFG/bin/list-private-repo-names.js" <<STUB
// Stand-in lister: record the invocation, then answer with one fictional private name.
require('fs').appendFileSync('$PR_MARKER_NATIVE', 'invoked\n');
process.stdout.write('$PRIV\n');
STUB
# Self-check: a stub that cannot write its marker would make every invocation count
# below read as zero, i.e. a false green for exactly the property B21b asserts.
node "$PR_CFG/bin/list-private-repo-names.js" >/dev/null 2>&1
if [ "$(grep -c 'invoked' "$PR_MARKER")" -eq 1 ]; then
    pass "B21/stub: the stand-in lister records its invocations (0 counts below are real)"
else
    fail "B21/stub: the stand-in lister cannot record invocations — B21b/B21c cannot be trusted (marker='$PR_MARKER_NATIVE')"
fi

PR_SAVED_CFG="$AGENTS_CONFIG_DIR"

# B21b: a caller that already declared the list keeps it — the lister must not run.
: > "$PR_MARKER"
PRIVATE_REPO_NAMES_CACHE_SET=1
PRIVATE_REPO_NAMES_CACHE=''
export AGENTS_CONFIG_DIR="$PR_CFG"
run_derive B21b --intent "$ABSENT_INTENT" --headless "keep-the-$PRIV-label"
export AGENTS_CONFIG_DIR="$PR_SAVED_CFG"

B21B_CALLS="$(grep -c 'invoked' "$PR_MARKER")"
B21B_TN="$(task_name)"
if [ "$B21B_CALLS" -eq 0 ]; then
    pass "B21b/no-lookup: a pre-declared list suppresses the lister entirely (0 invocations)"
else
    fail "B21b/no-lookup: expected 0 lister invocations when PRIVATE_REPO_NAMES_CACHE_SET=1 (got $B21B_CALLS)"
fi
if [ "$RC" -eq 0 ] && printf '%s' "$B21B_TN" | grep -qE "^keep-the-$PRIV-label-$TS_RE\$"; then
    pass "B21b/declared-wins: the declared empty list is what the gate compares against ($B21B_TN)"
else
    fail "B21b/declared-wins: expected TASK_NAME=keep-the-$PRIV-label-<ts> from the declared empty list (rc=$RC, tn='$B21B_TN', err='$ERR')"
fi

# B21c: with nothing declared, the lister runs — exactly once, not once per scan_clean.
: > "$PR_MARKER"
unset PRIVATE_REPO_NAMES_CACHE_SET
unset PRIVATE_REPO_NAMES_CACHE
export AGENTS_CONFIG_DIR="$PR_CFG"
run_derive B21c --intent "$ABSENT_INTENT" --headless "keep-the-$PRIV-label"
export AGENTS_CONFIG_DIR="$PR_SAVED_CFG"
# Restore the suite-wide insulation immediately: every later run_derive depends on it.
export PRIVATE_REPO_NAMES_CACHE_SET=1
export PRIVATE_REPO_NAMES_CACHE=''

B21C_CALLS="$(grep -c 'invoked' "$PR_MARKER")"
B21C_TN="$(task_name)"
if [ "$B21C_CALLS" -eq 1 ]; then
    pass "B21c/one-shot: an undeclared list is resolved exactly once per run, not once per scan"
else
    fail "B21c/one-shot: expected exactly 1 lister invocation across the run's three scan_clean calls (got $B21C_CALLS)"
fi
if [ "$RC" -eq 0 ] && printf '%s' "$B21C_TN" | grep -qE "^worktree-$TS_RE\$"; then
    pass "B21c/answer-used: the lister's answer reaches the gate — the label is rejected ($B21C_TN)"
else
    fail "B21c/answer-used: expected the non-descriptive worktree-<ts> fallback from the lister's answer (rc=$RC, tn='$B21C_TN', err='$ERR')"
fi
if [[ "$OUT" == *"$PRIV"* ]]; then
    fail "B21c/leak: the private repo name survived into the emitted name (out='$OUT')"
else
    pass "B21c/leak: the private repo name never reaches the emitted name"
fi

report_shape private-repo
finish
