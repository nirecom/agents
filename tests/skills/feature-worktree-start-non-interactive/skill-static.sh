#!/bin/bash
# tests/feature-worktree-start-non-interactive/skill-static.sh
# Tests: skills/worktree-start/SKILL.md
# Tags: worktree, start, skill, static, TL2, scope:issue-specific
# Static cases (TC1-TC9) against skills/worktree-start/SKILL.md.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

if [ ! -f "$SKILL_MD" ]; then
    fail "precondition missing — skills/worktree-start/SKILL.md"
    finish
fi

# --- TC1: --task-name removed ----------------------------------------------
if grep -q -- '--task-name' "$SKILL_MD"; then
    fail "TC1: --task-name still present in SKILL.md (flag must be removed)"
else
    pass "TC1: --task-name absent from SKILL.md"
fi

# --- TC2: --branch-type removed --------------------------------------------
if grep -q -- '--branch-type' "$SKILL_MD"; then
    fail "TC2: --branch-type still present in SKILL.md (flag must be removed)"
else
    pass "TC2: --branch-type absent from SKILL.md"
fi

# --- TC3: idempotency / reuse documented -----------------------------------
if grep -qiE 'already exists|git worktree list|idempoten|reuse' "$SKILL_MD"; then
    pass "TC3: idempotency / reuse-existing semantics documented"
else
    fail "TC3: idempotency keyword (already exists / git worktree list / idempotent / reuse) missing"
fi

# --- TC4: arg validation documented ----------------------------------------
if grep -qiE 'invalid|valid(ate|ation)|reject|exit 1|missing' "$SKILL_MD"; then
    pass "TC4: arg validation / error path documented"
else
    fail "TC4: validation/error-path keyword missing"
fi

# --- TC5: WS-2 references the derive script --------------------------------
if grep -qF 'skills/worktree-start/scripts/derive-worktree-name.sh' "$SKILL_MD"; then
    pass "TC5: SKILL.md references scripts/derive-worktree-name.sh"
else
    fail "TC5: SKILL.md does not reference scripts/derive-worktree-name.sh"
fi

# --- TC6: WS-2 block never instructs an AskUserQuestion call ----------------
# A bare "the token is absent" grep is too blunt now that WS-2 explains *when*
# AskUserQuestion is unreachable (the --headless trigger). What must hold is the
# substance: every mention inside WS-2 sits in a negated/unreachable context, so no
# line can be read as an instruction to ask.
WS2_BLOCK="$(sed -n '/^WS-2\./,/^WS-3\./p' "$SKILL_MD")"
WS2_ASK_ALL="$(printf '%s\n' "$WS2_BLOCK" | grep -cF 'AskUserQuestion')"
WS2_ASK_NEG="$(printf '%s\n' "$WS2_BLOCK" | grep -F 'AskUserQuestion' \
    | grep -ciE 'cannot|never|unreachable|no workflow session|not ')"
if [ -z "$WS2_BLOCK" ]; then
    fail "TC6: WS-2 block not found (sed extraction empty)"
elif [ "$WS2_ASK_ALL" -eq "$WS2_ASK_NEG" ]; then
    pass "TC6: no WS-2 line instructs an AskUserQuestion call ($WS2_ASK_ALL mention(s), all negated)"
else
    fail "TC6: WS-2 mentions AskUserQuestion outside a negated context ($WS2_ASK_ALL mentions, $WS2_ASK_NEG negated)"
fi

# --- TC7: --headless mentioned at least twice ------------------------------
HEADLESS_COUNT="$(grep -c -- '--headless' "$SKILL_MD")"
if [ "$HEADLESS_COUNT" -ge 2 ]; then
    pass "TC7: --headless documented in >=2 places (found $HEADLESS_COUNT)"
else
    fail "TC7: --headless documented in fewer than 2 places (found $HEADLESS_COUNT)"
fi

# --- TC8: derive script exists ---------------------------------------------
if [ -f "$SCRIPT" ]; then
    pass "TC8: skills/worktree-start/scripts/derive-worktree-name.sh exists"
else
    fail "TC8: skills/worktree-start/scripts/derive-worktree-name.sh missing"
fi

# --- TC9 [C5a]: WS-7 pins CONFIRM_WORKTREE OFF in headless mode -------------
# TC7 only counts --headless occurrences; this asserts the headless-pinning RULE
# itself lives in the WS-7 block (the orchestration half of the guarantee that
# B15 covers at the unit level).
WS7_BLOCK="$(sed -n '/^WS-7\./,/^WS-8\./p' "$SKILL_MD")"
if [ -z "$WS7_BLOCK" ]; then
    fail "TC9: WS-7 block not found (sed extraction empty)"
elif printf '%s' "$WS7_BLOCK" | grep -qF 'CONFIRM_WORKTREE' \
    && printf '%s' "$WS7_BLOCK" | grep -qF -- '--headless' \
    && printf '%s' "$WS7_BLOCK" | grep -qiE '(headless|non-interactive).*CONFIRM_WORKTREE.*off'; then
    pass "TC9: WS-7 pins CONFIRM_WORKTREE OFF for headless mode"
else
    fail "TC9: WS-7 block does not state that headless mode treats CONFIRM_WORKTREE as OFF"
fi

# --- TC10 [N4]: WS-2 tells the caller to read REPO_NAME= from stdout --------
# D0 emits REPO_NAME so the model never has to infer the last path component
# (CPR-SSOT). The script half is covered behaviorally (B15); this is the orchestration
# half — a SKILL.md that stopped naming the stdout key would leave the model guessing.
if printf '%s\n' "$WS2_BLOCK" | grep -qF 'REPO_NAME=' \
    && printf '%s\n' "$WS2_BLOCK" | grep -qiE 'stdout' \
    && printf '%s\n' "$WS2_BLOCK" | grep -qiE 'never infer it|do not infer'; then
    pass "TC10: WS-2 instructs reading REPO_NAME= from the script's stdout and never inferring it"
else
    fail "TC10: WS-2 does not instruct consuming REPO_NAME= from stdout (block='$WS2_BLOCK')"
fi

# --- TC11 [N6]: the path template spells the emitted key, not a prose slug ---
# `<REPO_NAME>` in the path template must match the stdout key verbatim; the old
# lowercase `<repo-name>` read as a third, undefined placeholder. Asserted as a
# presence + absence pair so the absence half cannot pass on a file that simply
# dropped the template.
if grep -qF '<REPO_NAME>' "$SKILL_MD"; then
    pass "TC11/present: SKILL.md uses the <REPO_NAME> path-template token"
else
    fail "TC11/present: SKILL.md no longer carries a <REPO_NAME> path-template token"
fi
if grep -qF '<repo-name>' "$SKILL_MD"; then
    fail "TC11/absent: SKILL.md still carries the stale lowercase <repo-name> template token"
else
    pass "TC11/absent: the stale lowercase <repo-name> template token is gone"
fi

# --- TC12 [MEDIUM-1]: --headless covers the unreachable-prompt context ------
# The trigger is not only "no workflow session": a subagent or forked context cannot
# present a prompt at all. Substance is pinned, not the wording.
if printf '%s\n' "$WS2_BLOCK" | grep -qiE 'subagent|forked' \
    && printf '%s\n' "$WS2_BLOCK" | grep -qiE 'no workflow session'; then
    pass "TC12: WS-2 names both --headless triggers (unreachable prompt context + no workflow session)"
else
    fail "TC12: WS-2's --headless guidance does not cover the subagent/forked context (block='$WS2_BLOCK')"
fi

# --- TC13 [MEDIUM-2]: reuse-safety path comparison normalizes case ----------
# Backslash folding alone is not enough on a case-insensitive filesystem: two spellings
# of the same path would read as a collision instead of a reusable worktree.
if printf '%s\n' "$WS2_BLOCK" | grep -qiE 'lowercase|case-insensitive' \
    && printf '%s\n' "$WS2_BLOCK" | grep -qiE 'backslash'; then
    pass "TC13: WS-2's reuse-safety comparison normalizes separators and case before comparing"
else
    fail "TC13: WS-2's reuse-safety comparison does not mention case normalization (block='$WS2_BLOCK')"
fi

finish
