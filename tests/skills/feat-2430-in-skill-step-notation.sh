#!/usr/bin/env bash
# tests/skills/feat-2430-in-skill-step-notation.sh
# Tests: skills/
# Tags: terminology, in-skill-step, skill-md, static-check, allowlist, table-driven, regression-2430, scope:issue-specific, pwsh-not-required, TL1

# Issue #2430 — a bare "step" means a workflow step (glossary). A numbered line inside a skill procedure is an in-skill step and is written by its ID alone (WI-10, CI-3), so "Step WI-10" no longer reads as if WI-10 were one of the workflow steps. The script output strings that print "SUMMARY=Step <ID>:" follow the same rule. Code identifiers, the plan schema's "## Steps" and WF-CODE-N / WF-META-N are untouched and not matched here.

# TDD (write_code has not run): expected to FAIL until the in-skill step rewrite (the last delivery of #2430) lands. N4 (bare numeric "Step 1" / "step 2" / "Step 3b" references, C4) FAILs until those lines are rewritten; N5 and N6 hold today.

set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

SKILLS="$AGENTS_DIR/skills"

hits="$(grep -rnE --include='*.md' '\bStep [A-Z]{1,5}-[0-9]+[a-z]?\b' "$SKILLS" 2>/dev/null)"
if [ -z "$hits" ]; then
    pass "N1: no skill prompt writes an in-skill step as 'Step <ID>'"
else
    fail "N1: skill prompts still write 'Step <ID>' ($(printf '%s\n' "$hits" | wc -l | tr -d ' ') lines)" "$(printf '%s\n' "$hits" | head -5)"
fi

hits="$(grep -rn --include='*.sh' 'SUMMARY=Step' "$SKILLS" 2>/dev/null)"
if [ -z "$hits" ]; then
    pass "N2: no skill script prints 'SUMMARY=Step <ID>:'"
else
    fail "N2: skill scripts still print 'SUMMARY=Step'" "$(printf '%s\n' "$hits" | head -5)"
fi

# Non-vacuity: the scan must actually see the skill prompts it claims to cover.
seen="$(grep -rlE --include='SKILL.md' '^#' "$SKILLS" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$seen" -ge 10 ]; then
    pass "N3: the scan reaches the skill prompts ($seen SKILL.md files)"
else
    fail "N3: the scan saw too few SKILL.md files" "seen=$seen"
fi

# ---- N4-N6: bare numeric in-skill step references ("Step 1", "steps 3-6", "Step 3b").
# The leading class keeps CLI flags such as `--from-step 1` out; `Step <ID>-<n>` is N1's job.
# The trailing class replaces \b, whose verdict before a multibyte char (the en dash in "4–6") varies by locale.
STEP_RE='(^|[^-A-Za-z_])[Ss]teps? [0-9]+[a-z]?([^A-Za-z0-9_]|$)'

# Occurrences that are not in-skill step references. file|occurrence substring|reason
# A row covers only the occurrences lying inside its substring, never the rest of the line.
ALLOWLIST="$(cat <<'ALLOW'
skills/migrate-repo/SKILL.md|Step 1 label setup|bin/migrate-repo tool stage numbering
skills/migrate-repo/SKILL.md|Steps 4–6|bin/migrate-repo tool stage numbering (--from-step table)
skills/migrate-repo/SKILL.md|Step 6 stages the allowlist|bin/migrate-repo tool stage numbering
skills/migrate-repo/SKILL.md|apply /migrate-repo Step 1/3 artifacts|bin/migrate-repo tool stage numbering in its quoted commit message
skills/migrate-repo/SKILL.md|Step 2 skipped (idempotency)|bin/migrate-repo tool stage numbering (sample output)
skills/migrate-repo/SKILL.md|Steps 3–6 run|bin/migrate-repo tool stage numbering (sample output)
skills/session-close/SKILL.md|legacy "Step 7"|historical quote of the retired label
ALLOW
)"

# flags <regex> <text> — flag / ok for one line of prose.
flags() { if printf '%s\n' "$2" | grep -qE -- "$1"; then printf 'flag'; else printf 'ok'; fi; }

# allowed <repo-relative file> <line content> — yes when every STEP_RE occurrence on
# the line lies inside an allowlist row's substring for that file. Per occurrence:
# each covered substring is masked out, and any occurrence left over still flags.
allowed() {
    local file sub reason masked="$2"
    while IFS='|' read -r file sub reason; do
        [[ -z "$file" || "$1" != "$file" ]] && continue
        masked="${masked//"$sub"/ ALLOWED }"
    done <<<"$ALLOWLIST"
    if [[ "$(flags "$STEP_RE" "$masked")" == "ok" ]]; then printf 'yes'; else printf 'no'; fi
}

raw="$(grep -rnE --include='*.md' -- "$STEP_RE" "$SKILLS" 2>/dev/null)"
flagged=""
while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    rel="${hit#"$AGENTS_DIR/"}"
    file="${rel%%:*}"
    content="${rel#*:}"; content="${content#*:}"
    [[ "$(allowed "$file" "$content")" == "yes" ]] && continue
    flagged+="${rel}"$'\n'
done <<<"$raw"
if [[ -z "$raw" ]]; then
    fail "N4: the numeric step scan matched nothing at all — the allowlisted lines alone should match (vacuous scan)"
elif [[ -z "$flagged" ]]; then
    pass "N4: no skill prompt refers to an in-skill step by bare number outside the allowlist"
else
    fail "N4: skill prompts still refer to in-skill steps by bare number ($(printf '%s' "$flagged" | grep -c .) lines)" \
        "$(printf '%s' "$flagged" | head -8)"
fi

stale=""
while IFS='|' read -r file sub reason; do
    [[ -z "$file" ]] && continue
    # Stale = the substring is gone from the file, or it holds no occurrence to cover.
    if ! grep -qF -- "$sub" "$AGENTS_DIR/$file" 2>/dev/null || [[ "$(flags "$STEP_RE" "$sub")" != "flag" ]]; then
        stale+=" [$file|$sub]"
    fi
done <<<"$ALLOWLIST"
if [[ -z "$stale" ]]; then
    pass "N5: every allowlist row still covers a numeric step occurrence in its file"
else
    fail "N5: stale allowlist rows (match nothing — remove them)" "$stale"
fi

# N6 — the same regex / allowlist over fixture strings, plus mutation probes that
# prove each part of the regex is load-bearing.
while IFS='|' read -r name re_kind input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    case "$re_kind" in
        real)      re="$STEP_RE" ;;
        no-lead)   re='[Ss]teps? [0-9]+[a-z]?([^A-Za-z0-9_]|$)' ;;
        no-plural) re='(^|[^-A-Za-z_])[Ss]tep [0-9]+[a-z]?([^A-Za-z0-9_]|$)' ;;
        no-suffix) re='(^|[^-A-Za-z_])[Ss]teps? [0-9]+([^A-Za-z0-9_]|$)' ;;        *)         fail "N6 $name: unknown regex kind '$re_kind'"; continue ;;
    esac
    got="$(flags "$re" "$input")"
    if [[ "$got" == "$want" ]]; then pass "N6 $name"; else fail "N6 $name" "input='$input' want=$want got=$got"; fi
done <<'TABLE'
heading-dash|real|Step 1 — Dispatch complexity-judge|flag
letter-suffix|real|see Step 3b for the batch path|flag
lowercase|real|an unstaged tests/ makes step 2 reject|flag
plural-plus|real|protocol (Steps 1+2+3) using CONFIRM_OUTLINE|flag
markdown-heading|real|## Step 4: optional persistence|flag
cli-flag|real|--from-step 3 --stage|ok
workflow-label|real|WF-CODE-5 (/write-code)|ok
id-form-is-n1|real|Step WI-10 dispatches|ok
stepwise|real|stepwise 2 refinement|ok
footstep|real|footstep 1 echoes|ok
en-dash-range|real|MR-10 row: Steps 4–6 done|flag
end-of-line|real|resumes at Step 5|flag
ordinal-word|real|Step 1st of many|ok
# mutants: the verdict must flip, or that regex part is dead
mutant-no-lead-flags-cli-flag|no-lead|--from-step 3 --stage|flag
mutant-no-plural-misses-steps|no-plural|protocol (Steps 1+2+3) using CONFIRM_OUTLINE|ok
mutant-no-suffix-misses-3b|no-suffix|see Step 3b for the batch path|ok
mutant-no-lead-flags-footstep|no-lead|footstep 1 echoes|flag
TABLE

while IFS='|' read -r name file content want; do
    [[ -z "$name" ]] && continue
    got="$(allowed "$file" "$content")"
    if [[ "$got" == "$want" ]]; then pass "N6 allow-$name"; else fail "N6 allow-$name" "want=$want got=$got"; fi
done <<'TABLE'
listed-file-and-text|skills/session-close/SKILL.md|Replaces the legacy "Step 7" emit|yes
same-text-other-file|skills/resume-session/SKILL.md|Replaces the legacy "Step 7" emit|no
listed-file-other-text|skills/migrate-repo/SKILL.md|see Step 3 below|no
allowlisted-plus-forbidden-same-line|skills/migrate-repo/SKILL.md|MR-10 note: Step 6 stages the allowlist, then see Step 3 below|no
forbidden-before-allowlisted-same-line|skills/session-close/SKILL.md|After Step 2, replaces the legacy "Step 7" emit|no
two-allowlisted-occurrences-same-line|skills/migrate-repo/SKILL.md|→ Step 2 skipped (idempotency). Steps 3–6 run.|yes
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
