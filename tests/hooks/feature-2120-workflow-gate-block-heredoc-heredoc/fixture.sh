# Tests: hooks/enforce-worktree.js, hooks/workflow-gate.js
# Tags: workflow-gate, enforce-worktree, fixture, scope:issue-specific
# M0/M0b source-presence and false-green guards, plus the throwaway git fixture
# (main + linked worktree, plans dir, workflow dir) every case file runs against.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh after helpers.sh;
# it deliberately `exit`s the whole suite when git/node are unavailable.

# M0 — a deleted source must turn this file RED, never green: a failed require()
# yields an empty reason that trivially "lacks Bash".
for f in "$EARLY_MSG" "$ENTRY_GATE" "$EW_HOOK" "$HANDLE_EW" "$SCU"; do
    if [ -f "$f" ]; then pass "M0: source present — ${f#$AN/}"
    else fail "M0: source MISSING — ${f#$AN/}"; fi
done

for _bin in git node; do
    command -v "$_bin" >/dev/null 2>&1 || { skip "whole file ($_bin unavailable)"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0; }
done

TMP="$(mktemp -d)"
trap 'git -C "$TMP/main" worktree remove --force "$TMP/linked" >/dev/null 2>&1; rm -rf "$TMP"' EXIT
MAIN="$TMP/main"; LINKED="$TMP/linked"; WF="$TMP/wf"; PLANS="$TMP/plans"
mkdir -p "$WF" "$PLANS"
git init -q -b main "$MAIN" 2>/dev/null || git init -q "$MAIN"
# The machine-wide core.hooksPath points at agents/hooks, whose pre-commit hook
# would reject this throwaway fixture repo.
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name T
git -C "$MAIN" commit -q --allow-empty --no-verify -m init
WT_ERR="$(git -C "$MAIN" worktree add -q -b feature/t2120-fixture "$LINKED" 2>&1)"
MAIN_N="$(np "$MAIN")"; LINKED_N="$(np "$LINKED")"; PLANS_N="$(np "$PLANS")"; TMP_N="$(np "$TMP")"

# C7 (test-review round 2) — FALSE-GREEN GUARD on the fixture itself. M3/M5/M5b/M6b
# all guard on `[ -e "$LINKED/.git" ]` and skip when it is absent, so a fixture that
# never got built used to leave the suite green with four protected-branch cases
# silently unrun. There is no environment in which this SHOULD fail: `git` is already
# proven present by the command -v gate above, the repo is a freshly `git init`-ed
# fixture with one commit, and the branch name cannot pre-exist. So a failure here is
# a real defect (in git, the temp dir, or this fixture) and must turn the suite RED.
# The per-case skips are kept below so the output still says WHICH cases did not run.
if [ -e "$LINKED/.git" ]; then
    pass "M0b: linked-worktree fixture created (M3/M5/M5b/M6b can run)"
else
    fail "M0b: \`git worktree add\` FAILED — M3, M5, M5b and M6b CANNOT RUN (protected-branch
      coverage is absent, not passing). git said: ${WT_ERR:-<no output>}"
fi

# Dual-pin per rules/test/fixture-isolation.md; inherited session ids unset so the
# hooks cannot resolve (and mutate) the live session's state file.
export CLAUDE_WORKFLOW_DIR="$(np "$WF")"
export WORKFLOW_PLANS_DIR="$(np "$PLANS")"
export ENFORCE_WORKTREE=on
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# SCRATCHPAD is inherited from the live session and would tighten the scratchpad
# allow root to THAT session's dir (claude-scratchpad-base.js H2). Unset it so the
# root falls back to <os-tmpdir>/claude, which M10 can address deterministically.
unset SCRATCHPAD 2>/dev/null || true
SCRATCH_N="$(node -e 'const p=require("path"),os=require("os");process.stdout.write(p.join(os.tmpdir(),"claude","t2120-scratch").replace(/\\/g,"/"))' 2>/dev/null)"
# M12 (C2) needs the SSOT base EXACTLY as buildAltTargetRemedy() interpolates it
# (case-folded on win32) for reason matching, plus a forward-slash form for use
# inside shell command payloads.
CLAUDE_BASE_RAW="$(node -e 'process.stdout.write(require(process.argv[1]).getClaudeBaseNorm())' "$AN/hooks/lib/claude-scratchpad-base.js" 2>/dev/null)"
CLAUDE_BASE_FWD="$(node -e 'process.stdout.write(require(process.argv[1]).getClaudeBaseNorm().replace(/\\/g,"/"))' "$AN/hooks/lib/claude-scratchpad-base.js" 2>/dev/null)"
ALT_REMEDY="$AN/hooks/lib/alt-target-remedy.js"
SID="feat2120t1"
