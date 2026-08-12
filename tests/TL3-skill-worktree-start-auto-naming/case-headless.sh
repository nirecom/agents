# shellcheck shell=bash
# tests/TL3-skill-worktree-start-auto-naming/case-headless.sh
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, headless, fork, claude-e2e, TL3, scope:common
#
# WSE-8..WSE-12 — forked invocation: no session, AskUserQuestion unreachable,
# so WS-2 must pass `--headless <label>`; name carries the D3b UTC
# disambiguator, so assertions pin slug prefix + shape, not the timestamp.
# Sourced by ../TL3-skill-worktree-start-auto-naming.sh after helpers.sh.

echo ""
echo "=== TL3: worktree-start, forked --headless invocation ==="

WSH_SID="b7b7b7b7-0000-0000-0000-000000000002"
WSH_LABEL="tidy the sample fixtures"
ws_setup "headless"

# Deliberately no intent.md for this session id: D2 prefers a readable intent
# over the --headless label, so leaving one behind would silently test the
# session path again under a headless name.
if [ ! -e "$WORKFLOW_PLANS_DIR/$WSH_SID-intent.md" ]; then
    pass "WSE-8. no intent.md exists for this session — the run can only succeed via --headless"
else
    fail "WSE-8. fixture leak: an intent.md exists for the headless session id"
fi

ws_derive "$WSH_SID" --headless "$WSH_LABEL"
if [ "$WS_DERIVE_RC" -eq 0 ] && [ -n "$WS_TASK" ]; then
    pass "WSE-9. the oracle --headless run derived TASK_NAME=$WS_TASK BRANCH_TYPE=$WS_BRANCH_TYPE REPO_NAME=$WS_REPO_NAME"
else
    fail "WSE-9. oracle --headless derive run failed (rc=$WS_DERIVE_RC) — the rest of this case cannot be judged. output: $WS_DERIVE_OUT"
fi

# Strip the 14-digit UTC disambiguator: everything before it is reproducible.
WSH_SLUG="${WS_TASK%-*}"
WSH_BT="$WS_BRANCH_TYPE"
WSH_RN="$WS_REPO_NAME"

ws_claude "$WSH_SID" "$(ws_prompt "You are running as a forked subagent: no workflow session hosts this run and AskUserQuestion is unreachable, so WS-2 must be given --headless with the label: $WSH_LABEL")"
if [ "$WS_RC" -eq 0 ]; then
    pass "WSE-10. the live claude -p --headless run following SKILL.md completed"
else
    fail "WSE-10. claude -p exited $WS_RC. output: $WS_OUT"
fi

ws_assert_no_prompt "WSE-11."

# Exactly one linked worktree, under the pinned base, named
# <slug>-<14-digit UTC>/<REPO_NAME>, on refs/heads/<BRANCH_TYPE>/<same name>.
# `git worktree list` always prints the main checkout first, so entry 2 is the
# one the model added — selecting it positionally avoids depending on how the
# host spells the temp root (MSYS /tmp vs C:/Users/.../Temp).
WSH_PORCELAIN="$(git -C "$WS_REPO" worktree list --porcelain)"
WSH_ENTRY="$(printf '%s\n' "$WSH_PORCELAIN" | sed -n 's#^worktree ##p' | sed -n '2p')"
WSH_NORM="$(norm_path "$WSH_ENTRY")"
WSH_BASE_NORM="$(norm_path "$(native_path "$WORKTREE_BASE_DIR")")"
WSH_TASK_DIR="$(basename "$(dirname "$WSH_ENTRY")")"
WSH_REPO_DIR="$(basename "$WSH_ENTRY")"
WSH_GOT_BRANCH="$(ws_branch_of "$WSH_NORM")"

if [ -n "$WSH_ENTRY" ] \
    && [ "$(ws_worktree_count)" = "2" ] \
    && case "$WSH_NORM" in "$WSH_BASE_NORM"/*) true ;; *) false ;; esac \
    && printf '%s' "$WSH_TASK_DIR" | grep -qE "^${WSH_SLUG}-[0-9]{14}$" \
    && [ "$WSH_REPO_DIR" = "$WSH_RN" ] \
    && [ "$WSH_GOT_BRANCH" = "refs/heads/$WSH_BT/$WSH_TASK_DIR" ]; then
    pass "WSE-12. the model created <base>/$WSH_TASK_DIR/$WSH_RN on $WSH_GOT_BRANCH — base dir, slug, disambiguator shape, repo component and branch all match what --headless derives"
else
    fail "WSE-12. headless path/branch mismatch — entry='${WSH_ENTRY:-<none>}' (want under '$WSH_BASE_NORM') task-dir='$WSH_TASK_DIR' (want ^${WSH_SLUG}-[0-9]{14}\$) repo-dir='$WSH_REPO_DIR' (want '$WSH_RN') branch='${WSH_GOT_BRANCH:-<none>}' (want refs/heads/$WSH_BT/$WSH_TASK_DIR). porcelain: $(printf '%s' "$WSH_PORCELAIN" | tr '\n' ' ') | claude output: $WS_OUT"
fi
