#!/bin/bash
# Tests: skills/write-code/SKILL.md
# Tags: skill, static, scope:common
# Fragment of tests/skills/feature-write-code-skill-static.sh, sourced after _lib.sh (not
# standalone): WCD-7 stages the edited files before the completion sentinel.

# w. WCD-7 stages WCD-5's edited files before the completion sentinel (#2327): a
# missing or mis-ordered step leaves the write_code snapshot blind to the edits.
echo "=== w. WCD-7 stages implementation files before completion ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd7_section=$(awk '/^WCD-7\./{f=1} f && /^## /{exit} f' "$WRITE_CODE_SKILL")
    completion_section=$(awk '/^## Completion/{f=1; next} f && /^## /{exit} f' "$WRITE_CODE_SKILL")
    line_wcd6=$(grep -n '^WCD-6\.' "$WRITE_CODE_SKILL" | head -1 | cut -d: -f1)
    line_wcd7=$(grep -n '^WCD-7\.' "$WRITE_CODE_SKILL" | head -1 | cut -d: -f1)
    if [ -n "$line_wcd6" ] && [ -n "$line_wcd7" ] && [ "$line_wcd7" -gt "$line_wcd6" ]; then
        pass "w. WCD-7 exists after WCD-6 (L$line_wcd6 < L$line_wcd7)"
    else
        fail "w. WCD-7 missing or not after WCD-6 (WCD-6=L${line_wcd6:-none}, WCD-7=L${line_wcd7:-none})"
    fi
    printf '%s\n' "$wcd7_section" | grep -qF 'bin/stage-review-scope-files.js' \
        && pass "w. WCD-7 calls bin/stage-review-scope-files.js" \
        || fail "w. WCD-7 does not call bin/stage-review-scope-files.js"
    printf '%s\n' "$wcd7_section" | grep -qF 'WCD-5' && ! printf '%s\n' "$wcd7_section" | grep -qF 'WCD-6' \
        && pass "w. WCD-7 stages WCD-5's edited-file list, not WCD-6's presentation list" \
        || fail "w. WCD-7 must reference WCD-5 (and not WCD-6) as its file-list source"
    if printf '%s\n' "$wcd7_section" | grep -qF 'non-zero' \
        && printf '%s\n' "$wcd7_section" | grep -qF 'do not emit the completion sentinel' \
        && printf '%s\n' "$wcd7_section" | grep -qF '/supervisor-report'; then
        pass "w. WCD-7 halts on non-zero exit without the sentinel and reports via /supervisor-report"
    else
        fail "w. WCD-7 lacks the non-zero halt / no-sentinel / /supervisor-report contract"
    fi
    if printf '%s\n' "$completion_section" | grep -qF 'WCD-7' \
        && ! printf '%s\n' "$completion_section" | grep -qF 'once WCD-6 passes'; then
        pass "w. Completion gates the sentinel on WCD-7, not on 'once WCD-6 passes'"
    else
        fail "w. Completion does not gate on WCD-7 (or still says 'once WCD-6 passes')"
    fi
    printf '%s\n' "$completion_section" | grep -qF 'bin/workflow/next-step' \
        && pass "w. Completion runs bin/workflow/next-step after the sentinel" \
        || fail "w. Completion lacks the bin/workflow/next-step line"
    skill_lines=$(grep -c '' "$WRITE_CODE_SKILL")
    [ "$skill_lines" -le 100 ] && pass "w. SKILL.md stays within 100 lines ($skill_lines)" \
        || fail "w. SKILL.md exceeds 100 lines ($skill_lines)"
fi
