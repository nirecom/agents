#!/bin/bash
# tests/feature-worktree-start-non-interactive/derive-gh.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, gh, classifier, label, TL2, scope:issue-specific
# gh-classifier cases (B8, B9, B13a, B13b) for derive-worktree-name.sh D4.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture
# This is the only sub-file that shims PATH, so it owns the $STUBDIR allocation.
ensure_stubdir

# B8/B9 stub `gh` executables are created at their case sites (they capture into
# case-specific files). The production script resolves `gh` from PATH — there is no
# env-var executable seam — so the stubs follow the repo's PATH-shim convention
# (see tests/feature-issue-635-pr-approval-hook.sh U14): a temp bin dir prepended
# onto PATH for the duration of the call under test only.

# --- gh-path fixture repo (B8/B9) ------------------------------------------
# The label lookup only runs when bin/is-github-dotcom-remote "$REPO_DIR" exits 0,
# so the fixture repo needs a github.com origin. A placeholder org/repo is used —
# the stub answers, nothing ever reaches the network.
GH_REPO="$FIXTURE/gh-repo"
mkdir -p "$GH_REPO"
git -C "$GH_REPO" init -q >/dev/null 2>&1
git -C "$GH_REPO" config core.hooksPath /dev/null
git -C "$GH_REPO" remote add origin https://github.com/example-org/example-repo.git
GH_REPO_REAL="$(cd "$GH_REPO" && pwd -P)"

# --- B8: type:incident label beats the title keyword -----------------------
# Also pins the repo-scoping contract: the lookup must run with CWD == $REPO_DIR,
# otherwise it silently queries whatever repo the caller happened to be sitting in.
B8_CAPTURE="$FIXTURE/b8-gh-capture.txt"
: > "$B8_CAPTURE"
cat > "$STUBDIR/gh" <<STUB
#!/bin/sh
{ printf 'ARGV=%s\n' "\$*"; printf 'CWD=%s\n' "\$(pwd -P)"; } >> "$B8_CAPTURE"
printf 'type:incident\n'
STUB
chmod +x "$STUBDIR/gh"

B8_SAVED_PATH="$PATH"
PATH="$STUBDIR:$PATH"
run_derive B8 --intent "$INTENT_B1" --repo-dir "$GH_REPO"
PATH="$B8_SAVED_PATH"

B8_ARGV="$(sed -n 's/^ARGV=//p' "$B8_CAPTURE" | head -1)"
B8_CWD="$(sed -n 's/^CWD=//p' "$B8_CAPTURE" | head -1)"
if [ "$RC" -eq 0 ] && has_line 'BRANCH_TYPE=fix'; then
    pass "B8: type:incident label overrides the title keyword (BRANCH_TYPE=fix)"
else
    fail "B8: expected BRANCH_TYPE=fix from the PATH-shimmed gh stub (rc=$RC, out='$OUT')"
fi
if printf '%s' "$B8_ARGV" | grep -qF 'issue view 1910'; then
    pass "B8/argv: gh invoked as 'issue view 1910' (argv='$B8_ARGV')"
else
    fail "B8/argv: expected 'issue view 1910' in the gh argv (argv='$B8_ARGV')"
fi
# Negative control for the B9/B9b fallthrough diagnostic: a lookup that actually
# returned labels must stay silent, otherwise the diagnostic is noise rather than signal.
if [ -z "$ERR" ]; then
    pass "B8/quiet: a successful label lookup emits no fallthrough diagnostic"
else
    fail "B8/quiet: expected empty stderr on a successful gh label lookup (err='$ERR')"
fi
if [ -n "$B8_CWD" ] && [ "$B8_CWD" = "$GH_REPO_REAL" ]; then
    pass "B8/cwd: gh ran scoped to \$REPO_DIR ($B8_CWD)"
else
    fail "B8/cwd: expected gh CWD='$GH_REPO_REAL' (got '$B8_CWD')"
fi

# --- B9: an unusable gh degrades gracefully --------------------------------
# The stub is genuinely reachable on PATH but always fails, so the label fetch
# really is exercised and really does come back empty — the fallback to the
# title-keyword inference is what keeps rc=0.
B9_STUBDIR="$FIXTURE/b9-stub"
mkdir -p "$B9_STUBDIR"
B9_CAPTURE="$FIXTURE/b9-gh-capture.txt"
: > "$B9_CAPTURE"
cat > "$B9_STUBDIR/gh" <<STUB
#!/bin/sh
printf 'invoked\n' >> "$B9_CAPTURE"
printf 'gh: stub is unusable\n' >&2
exit 1
STUB
chmod +x "$B9_STUBDIR/gh"

B9_SAVED_PATH="$PATH"
PATH="$B9_STUBDIR:$PATH"
run_derive B9 --intent "$INTENT_B1" --repo-dir "$GH_REPO"
PATH="$B9_SAVED_PATH"

if [ "$RC" -eq 0 ] && has_line 'BRANCH_TYPE=feature' && [ -s "$B9_CAPTURE" ]; then
    pass "B9: a failing gh yields no labels and falls back to the title keyword (BRANCH_TYPE=feature)"
else
    fail "B9: expected rc=0 + BRANCH_TYPE=feature after an invoked-but-failing gh stub (rc=$RC, out='$OUT', invoked='$(cat "$B9_CAPTURE")')"
fi
# The fallthrough is silent otherwise: "gh could not be reached" and "the issue simply
# carries no incident label" produce the same BRANCH_TYPE, so only a diagnostic tells
# the operator which one happened. It is a fixed literal — gh's own output may carry
# private info and must never be relayed.
GH_DIAG='the gh issue label lookup failed or returned nothing'
if [[ "$ERR" == *"$GH_DIAG"* && "$ERR" != *'stub is unusable'* ]]; then
    pass "B9/stderr: a failed gh lookup emits its own diagnostic without relaying gh's output"
else
    fail "B9/stderr: expected the gh-lookup diagnostic and no relayed gh output (err='$ERR')"
fi

# --- B9b: gh succeeds but returns no labels — same fallthrough, same diagnostic
# The symmetric counterpart of B9: exit 0 with empty stdout must not be mistaken for a
# usable label list, and must not abort the run either.
B9B_STUBDIR="$FIXTURE/b9b-stub"
mkdir -p "$B9B_STUBDIR"
B9B_CAPTURE="$FIXTURE/b9b-gh-capture.txt"
: > "$B9B_CAPTURE"
cat > "$B9B_STUBDIR/gh" <<STUB
#!/bin/sh
printf 'invoked\n' >> "$B9B_CAPTURE"
exit 0
STUB
chmod +x "$B9B_STUBDIR/gh"

B9B_SAVED_PATH="$PATH"
PATH="$B9B_STUBDIR:$PATH"
run_derive B9b --intent "$INTENT_B1" --repo-dir "$GH_REPO"
PATH="$B9B_SAVED_PATH"

if [ "$RC" -eq 0 ] && has_line 'BRANCH_TYPE=feature' && [ -s "$B9B_CAPTURE" ]; then
    pass "B9b: an empty-but-successful gh label list still falls through to the title keyword (feature)"
else
    fail "B9b: expected rc=0 + BRANCH_TYPE=feature from an empty-output gh stub (rc=$RC, out='$OUT', invoked='$(cat "$B9B_CAPTURE")')"
fi
if [[ "$ERR" == *"$GH_DIAG"* ]]; then
    pass "B9b/stderr: the empty-label case reports the same fallthrough diagnostic"
else
    fail "B9b/stderr: expected the gh-lookup diagnostic on an empty label list (err='$ERR')"
fi

# --- B13a [C3a]: a sanctioned non-incident label does NOT force fix ---------
# Symmetric to B8: only `type:incident` may override the title keyword.
B13A_CAPTURE="$FIXTURE/b13a-gh-capture.txt"
: > "$B13A_CAPTURE"
B13A_STUBDIR="$FIXTURE/b13a-stub"
mkdir -p "$B13A_STUBDIR"
cat > "$B13A_STUBDIR/gh" <<STUB
#!/bin/sh
printf 'ARGV=%s\n' "\$*" >> "$B13A_CAPTURE"
printf 'type:task\nseverity:low\n'
STUB
chmod +x "$B13A_STUBDIR/gh"

B13A_SAVED_PATH="$PATH"
PATH="$B13A_STUBDIR:$PATH"
run_derive B13a --intent "$INTENT_B1" --repo-dir "$GH_REPO"
PATH="$B13A_SAVED_PATH"

if [ "$RC" -eq 0 ] && has_line 'BRANCH_TYPE=feature' && [ -s "$B13A_CAPTURE" ]; then
    pass "B13a: a non-incident label list leaves BRANCH_TYPE to the title keyword (feature)"
else
    fail "B13a: expected rc=0 + BRANCH_TYPE=feature with the gh stub invoked (rc=$RC, out='$OUT', capture='$(cat "$B13A_CAPTURE")')"
fi

# --- B13b [C3b]: a cross-repo issue skips the gh lookup entirely ------------
# D4 guards the label lookup on `-z "$ISSUE_REPO"`. The stub records every
# invocation, so the absence of the marker file is what proves non-invocation.
B13B_MARKER="$FIXTURE/b13b-gh-invoked.txt"
rm -f "$B13B_MARKER"
B13B_STUBDIR="$FIXTURE/b13b-stub"
mkdir -p "$B13B_STUBDIR"
cat > "$B13B_STUBDIR/gh" <<STUB
#!/bin/sh
printf 'ARGV=%s\n' "\$*" >> "$B13B_MARKER"
printf 'type:incident\n'
STUB
chmod +x "$B13B_STUBDIR/gh"

INTENT_B13B="$FIXTURE/b13b-intent.md"
write_intent "$INTENT_B13B" 'Refactor cross repo issue handling' '- other-repo#1910: cross-repo reference'

B13B_SAVED_PATH="$PATH"
PATH="$B13B_STUBDIR:$PATH"
run_derive B13b --intent "$INTENT_B13B" --repo-dir "$GH_REPO"
PATH="$B13B_SAVED_PATH"

B13B_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ ! -e "$B13B_MARKER" ] && has_line 'BRANCH_TYPE=refactor'; then
    pass "B13b: a cross-repo issue skips the gh label lookup and falls back to the title keyword (refactor)"
else
    fail "B13b: expected rc=0, no gh invocation, BRANCH_TYPE=refactor (rc=$RC, out='$OUT', marker='$( [ -e "$B13B_MARKER" ] && cat "$B13B_MARKER" )')"
fi
if [ "$B13B_TN" = "1910-refactor-cross-repo-issue-handling" ]; then
    pass "B13b/name: the cross-repo issue number still prefixes the task name ($B13B_TN)"
else
    fail "B13b/name: expected TASK_NAME=1910-refactor-cross-repo-issue-handling (got '$B13B_TN')"
fi

report_shape gh
finish
