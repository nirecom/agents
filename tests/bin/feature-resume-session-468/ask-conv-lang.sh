# shellcheck shell=bash
# tests/bin/feature-resume-session-468/ask-conv-lang.sh — T22: AskUserQuestion texts are written in CONV_LANG, not fixed English (#2731 R5). Sourced by tests/bin/feature-resume-session-468.sh; not standalone.
# Tests: skills/resume-session/SKILL.md
# Tags: session, resume, skill-procedure, conv-lang, scope:issue-specific, pwsh-not-required, TL1

if ! declare -F run_cli >/dev/null 2>&1; then
    echo "ask-conv-lang.sh: sourced fragment — run tests/bin/feature-resume-session-468.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

echo ""
echo "=== T22: ask_conv_lang (#2731 R5) ==="

# A fixed English question string is shown to the user as-is, whatever CONV_LANG says.
# The skill must instead tell the model to write the question in CONV_LANG, keeping the
# option labels (branch keys) and step / skill names verbatim.

if [ ! -f "$SKILL_MD_LOCAL" ]; then
    fail "T22. skills/resume-session/SKILL.md not found at $SKILL_MD_LOCAL"
else
    for _lit in 'Confirm: resume interrupted workflow session?' 'Workflow paused at `<step>`. Re-run `/<skill>`?'; do
        if grep -qF -- "$_lit" "$SKILL_MD_LOCAL"; then
            fail "T22a. fixed English AskUserQuestion text still present: $_lit"
        else
            pass "T22a. fixed English AskUserQuestion text removed: $_lit"
        fi
    done

    RSM1_BODY=$(sed -n '/^### RSM-1 — Hard-fail check/,/^### RSM-/p' "$SKILL_MD_LOCAL")
    RSM1_ASK=$(printf '%s\n' "$RSM1_BODY" | grep -F 'AskUserQuestion' | head -1)
    case "$RSM1_ASK" in
        *CONV_LANG*'Resume'*'Cancel'*) pass "T22b. RSM-1 asks in CONV_LANG and keeps the Resume / Cancel options" ;;
        *) fail "T22b. RSM-1 ask line does not write the question in CONV_LANG with Resume / Cancel options: $RSM1_ASK" ;;
    esac

    SKILL_ROW=$(grep -E '^\| `skill` \|' "$SKILL_MD_LOCAL" | head -1)
    T22C_PROBLEMS=""
    case "$SKILL_ROW" in *CONV_LANG*) ;; *) T22C_PROBLEMS="$T22C_PROBLEMS [no CONV_LANG]" ;; esac
    case "$SKILL_ROW" in *verbatim*) ;; *) T22C_PROBLEMS="$T22C_PROBLEMS [step and skill names not kept verbatim]" ;; esac
    case "$SKILL_ROW" in *'`Resume`'*'`Cancel`'*) ;; *) T22C_PROBLEMS="$T22C_PROBLEMS [Resume / Cancel option labels gone]" ;; esac
    case "$SKILL_ROW" in *'invoke `<skill>`'*) ;; *) T22C_PROBLEMS="$T22C_PROBLEMS [Resume no longer invokes <skill>]" ;; esac
    if [ -n "$SKILL_ROW" ] && [ -z "$T22C_PROBLEMS" ]; then
        pass "T22c. the skill row asks in CONV_LANG, keeps names verbatim and the Resume / Cancel branch"
    else
        fail "T22c. the skill row regressed;${T22C_PROBLEMS:- [row missing]} row=$SKILL_ROW"
    fi
fi
