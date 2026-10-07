#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/static-cases.sh — P10, P11.
# SKILL.md carries RNT-6a between RNT-6 and RNT-7 in the planned order; the allow list
# auto-approves the read-only probe and the one-effect mark, never answer.

# line_of <fixed-string> — first line number in SKILL.md holding it, or 0.
line_of() { local n; n="$(grep -nF -- "$1" "$SKILL_MD" 2>/dev/null | head -n 1 | cut -d: -f1)"; printf '%s' "${n:-0}"; }

case_begin "skill-md-calibration-offer" "skills/run-tests/SKILL.md"

# ── P10 SKILL.md RNT-6a wording, order, frontmatter and size ────────────────
ck "P10 frontmatter line 4 adds AskUserQuestion" "tools: Bash, Write, AskUserQuestion" "$(sed -n 4p "$SKILL_MD")"
_l6="$(grep -n '^RNT-6\. ' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
_l6a="$(grep -n '^RNT-6a\. \*\*Calibration offer\.\*\*' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
_l7="$(grep -n '^RNT-7\. ' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
if [ -n "$_l6" ] && [ -n "$_l6a" ] && [ -n "$_l7" ] && [ "$_l6" -lt "$_l6a" ] && [ "$_l6a" -lt "$_l7" ]; then
    pass "P10 RNT-6a sits between RNT-6 and RNT-7"
else
    fail "P10 RNT-6a missing or out of place" "RNT-6=${_l6:-none} RNT-6a=${_l6a:-none} RNT-7=${_l7:-none}"
fi
# Each instruction appears once, in this order, inside RNT-6a (between RNT-6a and RNT-7).
_prev="${_l6a:-0}"; _order_bad=""
for _frag in \
    'skills/run-tests/scripts/probe-calibration.sh" --cwd <cwd> --session <sid>` and read `decision=`' \
    '`none` -> go to RNT-7.' \
    'when AskUserQuestion is unavailable (non-interactive: `claude -p`, `/loop`, subagents) -> show `notice=` verbatim, write no record, go to RNT-7.' \
    'skills/run-tests/scripts/mark-calibration-asked.sh" --session <sid>`; if it fails or prints `first=no`, treat as `notice`.' \
    'calibrate now (long-running) / not now / never ask again on this host.' \
    'skills/run-tests/scripts/answer-calibration.sh" defer --cwd <cwd> --session <sid>`, then go to RNT-7.' \
    'skills/run-tests/scripts/answer-calibration.sh" never-ask --cwd <cwd> --session <sid>`; if it fails, show its stderr and say the choice was not saved; then go to RNT-7.' \
    'echo "<<WORKFLOW_NEXT_STEP_PAUSE: [for=run_tests] run-tests calibration>>"' \
    'skills/run-tests/scripts/answer-calibration.sh" calibrate --cwd <cwd> --session <sid>` with Bash `run_in_background`' \
    'echo "<<WORKFLOW_NEXT_STEP_RESUME: run-tests calibration done>>"' \
    're-run the probe and read `source=`, `max_jobs=`, `os_match=`; the exit code alone never proves the new value applies.' \
    '`source=measured` with `os_match=yes` -> say the run uses the measured `max_jobs=`, then go to RNT-7 with the payload unchanged.' \
    'never retry, and go to RNT-7 with the payload unchanged.'; do
    _n="$(line_of "$_frag")"
    if [ "$_n" -le "$_prev" ] || [ -z "$_l7" ] || [ "$_n" -ge "$_l7" ]; then _order_bad="${_order_bad} [$_frag]"; fi
    _prev="$_n"
done
ck "P10 RNT-6a instructions present and in order" "" "$_order_bad"
ck "P10 mark runs before the question (mark line < ask line)" "yes" \
    "$( [ "$(line_of 'mark-calibration-asked.sh')" -gt 0 ] && [ "$(line_of 'mark-calibration-asked.sh')" -le "$(line_of 'never ask again on this host')" ] && echo yes || echo no)"
grep -qxF -- '- Launch calibration only from RNT-6a after an explicit "calibrate now" answer; tests/run-all.sh never starts it.' "$SKILL_MD" \
    && pass "P10 Rules line names the only launch path" || fail "P10 Rules line missing"
_rules="$(grep -n '^## Rules' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
_launch="$(line_of 'Launch calibration only from RNT-6a')"
[ -n "$_rules" ] && [ "$_launch" -gt "$_rules" ] && pass "P10 the launch rule is under ## Rules" || fail "P10 the launch rule is not under ## Rules"
ck "P10 no code fences in SKILL.md" "0" "$(grep -c '^[[:space:]]*```' "$SKILL_MD" || true)"
_lines="$(wc -l < "$SKILL_MD" | tr -d ' ')"
[ "$_lines" -le 100 ] && pass "P10 SKILL.md is at most 100 lines ($_lines)" || fail "P10 SKILL.md exceeds 100 lines" "lines=$_lines"
case_ran P10

case_end

case_begin "allow-list-probe-and-mark-only" "install/settings-allow-commands.txt"

# ── P11 probe and mark are auto-approved; answer is not ─────────────────────
grep -qxF 'skills/run-tests/scripts/probe-calibration.sh' "$ALLOW_TXT" \
    && pass "P11 probe-calibration.sh is on the allow list" || fail "P11 probe-calibration.sh missing from the allow list"
grep -qxF 'skills/run-tests/scripts/mark-calibration-asked.sh' "$ALLOW_TXT" \
    && pass "P11 mark-calibration-asked.sh is on the allow list" || fail "P11 mark-calibration-asked.sh missing from the allow list"
ck "P11 answer-calibration.sh is not on the allow list" "0" "$(grep -c 'answer-calibration' "$ALLOW_TXT" || true)"
ck "P11 bin/test-lanes-status.sh entry is unchanged" "1" "$(grep -cxF 'bin/test-lanes-status.sh' "$ALLOW_TXT" || true)"
case_ran P11

case_end

grp_done static-cases.sh
