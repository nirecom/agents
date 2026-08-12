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
#
# B21d-B21i cover D0a, the one name that must NOT be on that list: the current repo's
# own. Left in, it makes the gate self-match at D0 and /worktree-start unusable in any
# private repo — so the exclusion is as load-bearing as the gate itself, and equally
# dangerous if it over-reaches.
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
mkdir -p "$PR_CFG/bin" "$PR_CFG/hooks/lib"
cp "$AGENTS_DIR/bin/scan-outbound.sh" "$PR_CFG/bin/scan-outbound.sh"
cp "$AGENTS_DIR/bin/check-private-repo-name.js" "$PR_CFG/bin/check-private-repo-name.js"
# check-private-repo-name.js resolves its matcher as <script-dir>/../hooks/lib/
# is-private-repo.js and fail-opens (exit 0) when that require throws — so without
# this copy the gate would be dead for every invocation from PR_CFG, and B21c would
# pass vacuously. The real module is copied, not stubbed: the cache is always armed
# by the time it runs here, so its `gh`-calling listPrivateRepoNames() is never
# reached and only the pure findPrivateName() matcher is exercised.
# The whole lib/ goes in, not just is-private-repo.js: the module has lib-local
# requires of its own (parse-git-args.js), and a missing transitive dep would
# reproduce the very fail-open this copy exists to close — silently.
cp -r "$AGENTS_DIR/hooks/lib/." "$PR_CFG/hooks/lib/"
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

# --- B21d-B21i: D0a, the current repo's own name is excluded from the gate ---
#
# Why this needs its own group: the list the gate compares against is "every repo
# the user owns that is private", which necessarily includes the repo /worktree-start
# is being run in whenever that repo is itself private. REPO_NAME is then matched
# against a list containing REPO_NAME, so D0's scan_clean("$REPO_NAME") fails closed
# on the very first gate — unconditionally, for every invocation, in every private
# repo. That is not a leak the gate is preventing: the repo's own name is already
# known to everyone who can see this repo's remote, and it is the one name that
# cannot leak *into* this repo from somewhere else.
#
# D0a therefore filters exactly one entry — the current repo's own bare name, compared
# case-insensitively — out of the cache, once, before the first scan_clean() call. The
# cases below pin both halves of that: it must remove the self-entry (B21d/B21e), and
# it must remove nothing else (B21f/B21g/B21i). Every case drives the same declared
# cache contract the rest of this suite uses; none reaches `gh`.
SELF_REPO="$FIXTURE/selfname-repo"
mkdir -p "$SELF_REPO"
git -C "$SELF_REPO" init -q >/dev/null 2>&1
git -C "$SELF_REPO" config core.hooksPath /dev/null
# D0a keys off the resolved `origin` remote identity, not the checkout directory's
# basename (F1/F2 security fix) — an origin is required here for D0a to actually
# fire in B21d/B21e/B21f/B21h/B21j/B21k below. The owner segment is arbitrary; only
# the repo segment ("selfname-repo") is compared, case-insensitively, against the
# bare form of each declared cache entry.
git -C "$SELF_REPO" remote add origin https://github.com/acme-org/selfname-repo.git

D0A_MSG='the repository directory name failed the outbound scan'

# B21d: the repro. The repo's own name is in the list, spelled identically.
PRIVATE_REPO_NAMES_CACHE='selfname-repo'
run_derive B21d --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$SELF_REPO"
B21D_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [[ "$ERR" != *"$D0A_MSG"* ]]; then
    pass "B21d/no-self-block: a repo whose own name is in the private list still derives a name (no D0 self-block)"
else
    fail "B21d/no-self-block: expected rc=0 with no D0 scan-failure diagnostic (rc=$RC, err='$ERR')"
fi
if [ "$(repo_name)" = 'selfname-repo' ] && printf '%s' "$B21D_TN" | grep -qE "^work-on-thing-$TS_RE\$"; then
    pass "B21d/emitted: the run completes normally — REPO_NAME=selfname-repo and the label survives ($B21D_TN)"
else
    fail "B21d/emitted: expected REPO_NAME=selfname-repo and TASK_NAME=work-on-thing-<ts> (rn='$(repo_name)', tn='$B21D_TN', err='$ERR')"
fi

# B21e: the comparison is case-insensitive. `gh` reports a repo's name in its
# canonical casing, which need not match the checkout directory's casing — and the
# checker itself matches case-insensitively, so a case-variant entry would re-block
# exactly as the exact-case one did if D0a compared case-sensitively.
PRIVATE_REPO_NAMES_CACHE='SelfName-REPO'
run_derive B21e --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$SELF_REPO"
B21E_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [[ "$ERR" != *"$D0A_MSG"* ]] \
    && printf '%s' "$B21E_TN" | grep -qE "^work-on-thing-$TS_RE\$"; then
    pass "B21e/case-insensitive: a case-variant spelling of the repo's own name is excluded too ($B21E_TN)"
else
    fail "B21e/case-insensitive: expected the same clean derivation from cache 'SelfName-REPO' (rc=$RC, tn='$B21E_TN', err='$ERR')"
fi

# B21f: scope. The self-exclusion must not degrade into a blanket cache bypass —
# with the repo's own name AND a genuinely different private name declared, the
# other name must still be caught. One run proves both directions at once: D0
# passes (self-entry gone) while the --headless label carrying the other private
# name is still rejected (that entry survived).
PRIVATE_REPO_NAMES_CACHE="$(printf 'selfname-repo\n%s' "$PRIV")"
run_derive B21f --intent "$ABSENT_INTENT" --headless "keep-the-$PRIV-label" --repo-dir "$SELF_REPO"
B21F_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$(repo_name)" = 'selfname-repo' ] && [[ "$ERR" != *"$D0A_MSG"* ]]; then
    pass "B21f/self-excluded: with both names declared the self-entry is still excluded (D0 passes, REPO_NAME emitted)"
else
    fail "B21f/self-excluded: expected rc=0 and REPO_NAME=selfname-repo (rc=$RC, rn='$(repo_name)', err='$ERR')"
fi
if printf '%s' "$B21F_TN" | grep -qE "^worktree-$TS_RE\$" \
    && [[ "$ERR" == *'--headless label failed the outbound scan'* ]]; then
    pass "B21f/other-still-caught: the other private name is still rejected — only the self-entry was filtered ($B21F_TN)"
else
    fail "B21f/other-still-caught: expected the label to be rejected and TASK_NAME=worktree-<ts> (tn='$B21F_TN', err='$ERR')"
fi
if [[ "$OUT" == *"$PRIV"* ]]; then
    fail "B21f/leak: the other private name survived into the emitted name (out='$OUT')"
else
    pass "B21f/leak: the other private name never reaches the emitted name"
fi

# B21g: the exclusion is whole-entry equality, not "any entry contained in the repo
# name". A checkout named after a private repo *plus a suffix* is a different name,
# and the private one it embeds is still someone else's to protect — D0 must keep
# failing closed there, or the filter would have opened a hole wider than the bug.
EMBED_REPO="$FIXTURE/$PRIV-checkout"
mkdir -p "$EMBED_REPO"
git -C "$EMBED_REPO" init -q >/dev/null 2>&1
git -C "$EMBED_REPO" config core.hooksPath /dev/null
PRIVATE_REPO_NAMES_CACHE="$PRIV"
run_derive B21g --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$EMBED_REPO"
if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] \
    && [[ "$ERR" == *"$D0A_MSG"* ]]; then
    pass "B21g/exact-match-only: a checkout name that merely embeds a private name still fails closed at D0"
else
    fail "B21g/exact-match-only: expected rc=1 with the D0 scan-failure diagnostic (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$OUT" == *"$PRIV"* || "$ERR" == *"$PRIV"* ]]; then
    fail "B21g/leak: the offending repo name reached stdout or stderr (out='$OUT', err='$ERR')"
else
    pass "B21g/leak: the refusal never echoes the offending repo name"
fi

# B21h: the exclusion is a one-shot env-prefix on only the two REPO_NAME
# scan_clean() call sites (D0, and D2's repo-name fallback) — not a blanket
# export every later scan_clean() inherits. The D2 repo-name fallback is the
# discriminating path for that pair: a title that yields no ASCII slug falls
# back to slugify(REPO_NAME), which is built from the self-excluded list too.
# But the composed TASK_NAME ("1910-selfname-repo") is scanned a third time at
# D6 against the *unfiltered* cache (TITLE/TASK_NAME deliberately keep seeing
# the full list — see D0a's Scope note), and that rescan still finds the
# repo's own name embedded in it and rejects it, falling through to D6's
# non-descriptive timestamp fallback.
INTENT_B21H="$FIXTURE/b21h-intent.md"
write_intent "$INTENT_B21H" '!!! @@@' '- #1910: self-name exclusion'
PRIVATE_REPO_NAMES_CACHE='selfname-repo'
run_derive B21h --intent "$INTENT_B21H" --repo-dir "$SELF_REPO"
B21H_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B21H_TN" | grep -qE "^1910-worktree-$TS_RE\$"; then
    pass "B21h/downstream: the exclusion reaches the D2 repo-name fallback, then D6's unfiltered rescan still catches the embedded self-name ($B21H_TN)"
else
    fail "B21h/downstream: expected TASK_NAME=1910-worktree-<ts> from D6's non-descriptive fallback (rc=$RC, tn='$B21H_TN', err='$ERR')"
fi

# B21i: the no-op branches. D0a must change nothing when the repo's own name is not
# in the list at all — both with a populated list (the filter runs and removes
# nothing) and with an empty one (the `-n` guard skips the block entirely). Without
# this pair, an over-eager filter that dropped the wrong entry, or a block that threw
# away the cache wholesale, would still look green above.
PLAIN_REPO="$FIXTURE/plain-repo"
mkdir -p "$PLAIN_REPO"
git -C "$PLAIN_REPO" init -q >/dev/null 2>&1
git -C "$PLAIN_REPO" config core.hooksPath /dev/null

PRIVATE_REPO_NAMES_CACHE="$PRIV"
run_derive B21i/populated --intent "$ABSENT_INTENT" --headless plain-label --repo-dir "$PLAIN_REPO"
B21I_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$(repo_name)" = 'plain-repo' ] \
    && printf '%s' "$B21I_TN" | grep -qE "^plain-label-$TS_RE\$"; then
    pass "B21i/populated: a repo absent from the private list derives exactly as before ($B21I_TN)"
else
    fail "B21i/populated: expected REPO_NAME=plain-repo and TASK_NAME=plain-label-<ts> (rc=$RC, rn='$(repo_name)', tn='$B21I_TN', err='$ERR')"
fi
# ...and the other private name in that same list is still live, so "unchanged"
# means unchanged, not "the filter quietly emptied the cache".
run_derive B21i/still-armed --intent "$ABSENT_INTENT" --headless "keep-the-$PRIV-label" --repo-dir "$PLAIN_REPO"
if [ "$RC" -eq 0 ] && printf '%s' "$(task_name)" | grep -qE "^worktree-$TS_RE\$"; then
    pass "B21i/still-armed: the untouched list still rejects a label carrying the private name"
else
    fail "B21i/still-armed: expected the label to be rejected under an untouched list (rc=$RC, tn='$(task_name)', err='$ERR')"
fi

PRIVATE_REPO_NAMES_CACHE=''
run_derive B21i/empty --intent "$ABSENT_INTENT" --headless plain-label --repo-dir "$PLAIN_REPO"
B21IE_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$(repo_name)" = 'plain-repo' ] \
    && printf '%s' "$B21IE_TN" | grep -qE "^plain-label-$TS_RE\$"; then
    pass "B21i/empty: an empty declared list skips D0a entirely and derives unchanged ($B21IE_TN)"
else
    fail "B21i/empty: expected the same derivation with an empty declared list (rc=$RC, rn='$(repo_name)', tn='$B21IE_TN', err='$ERR')"
fi

# B21j: idempotency. D0a rewrites the cache variable it was handed, so a second run
# under the same declared list must reach the same verdict — the filtering is derived
# fresh from REPO_NAME each run, never accumulated. Only the timestamp suffix may
# differ, so the comparison is on REPO_NAME plus the slug half of the task name.
PRIVATE_REPO_NAMES_CACHE='selfname-repo'
run_derive B21j/first --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$SELF_REPO"
B21J_RN1="$(repo_name)"; B21J_TN1="$(task_name)"; B21J_RC1="$RC"
run_derive B21j/second --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$SELF_REPO"
B21J_RN2="$(repo_name)"; B21J_TN2="$(task_name)"; B21J_RC2="$RC"
if [ "$B21J_RC1" -eq 0 ] && [ "$B21J_RC2" -eq 0 ] \
    && [ -n "$B21J_RN1" ] && [ "$B21J_RN1" = "$B21J_RN2" ] \
    && [ "${B21J_TN1%-*}" = "${B21J_TN2%-*}" ]; then
    pass "B21j/idempotent: repeating the run under the same declared list yields the same REPO_NAME and slug (${B21J_TN1%-*})"
else
    fail "B21j/idempotent: the two runs diverged (rc=$B21J_RC1/$B21J_RC2, rn='$B21J_RN1'/'$B21J_RN2', tn='$B21J_TN1'/'$B21J_TN2')"
fi

# B21k: the owner-qualified spelling. Cache lines arrive in both bare (`repo`) and
# `owner/repo` form, and the consumer (bin/check-private-repo-name.js findPrivateName())
# matches on the last `/`-delimited segment — so a verbatim comparison against the bare
# REPO_NAME leaves an `owner/<self>` entry in the list and the repo self-blocks at D0
# anyway. D0a must normalize the same way the consumer does.
PRIVATE_REPO_NAMES_CACHE='acme-org/selfname-repo'
run_derive B21k --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$SELF_REPO"
B21K_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [[ "$ERR" != *"$D0A_MSG"* ]] \
    && [ "$(repo_name)" = 'selfname-repo' ] \
    && printf '%s' "$B21K_TN" | grep -qE "^work-on-thing-$TS_RE\$"; then
    pass "B21k/owner-qualified: an owner/repo-form self-entry is excluded too — no D0 self-block ($B21K_TN)"
else
    fail "B21k/owner-qualified: expected the same clean derivation from cache 'acme-org/selfname-repo' (rc=$RC, rn='$(repo_name)', tn='$B21K_TN', err='$ERR')"
fi

report_shape private-repo
finish
