# tests/feature-2134-bash-guard/cases-message.sh
# Tests: hooks/bash-guard/message.js, hooks/bash-guard/reasons.js, hooks/bash-guard/judge.js
# Tags: hook, bash-guard, message, reason-codes, remediation, scope:issue-specific, pwsh-not-required, TL2
# M1-M5: what the deny actually says, and the code namespace. Sourced by the dispatcher.

# WHY THE MESSAGE IS TESTED AT ALL. A presentation guard that only says "denied" trades one
# compound command for a round of guessing -- #2120 is the precedent. The deny has to carry the
# way out: which literal tripped, that a scratchpad script is the sanctioned form, the single
# `bash <path>` invocation to use, and the rule that owns the policy. Each fragment below is
# one thing the model would otherwise have to re-derive.

m1_message_fragments() {
    local name want got
    got="$(probe judge-message 'git status && ls')"
    # A `<MISSING:...>` sentinel is not a message: blank it, or a fragment like `bash` would
    # match the module path inside the sentinel and report green against nothing.
    case "$got" in "<"*) got="" ;; esac
    while IFS='~' read -r name want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want#"${want%%[![:space:]]*}"}"
        want="${want%"${want##*[![:space:]]}"}"
        ROWS=$((ROWS + 1))

        assert_contains "M1/$name: the deny message carries it" "$want" "$got"
    done <<'TABLE'
allowed-line ~ ALLOWED:
scratchpad   ~ scratchpad
single-call  ~ bash
rule-owner   ~ Command-Line Issuance Discipline
TABLE
}

m1_message_fragments

# M2: the message names the literal that tripped, not just "a forbidden literal". Two different
# denies must not produce the same text, or the ALLOWED: line is decoration.
BG_HEREDOC_MSG="$(probe judge-message "$(mkcmd 'cat <<EOF\nx\nEOF')")"
case "$BG_HEREDOC_MSG" in "<"*) BG_HEREDOC_MSG="" ;; esac
assert_contains "M2: a heredoc deny names the heredoc literal" "heredoc" "$BG_HEREDOC_MSG"
assert_not_contains "M2: a heredoc deny does not name an unrelated literal" \
    "chain-and" "$BG_HEREDOC_MSG"

# M3: an allow carries no message. A guard that narrates its silence is noise on every command.
assert_eq "M3: an allow produces no message" "" "$(probe judge-message 'git status')"

# M4: every reason code lives in the BG- namespace. The workflow-gate tiers own T-A..T-E, and a
# collision would make one code mean two things in the transcript.
BG_CODES="$(probe reason-codes '')"
# Positive pin FIRST: without this, an empty BG_CODES (e.g. reason-codes mode missing or
# returning "") would make both grep -c checks below report 0 and read as green for the wrong
# reason -- a registry that lost every code would pass the same as a clean one.
BG_CODES_COUNT="$(printf '%s' "$BG_CODES" | tr ',' '\n' | grep -c . || true)"
ROWS=$((ROWS + 1))
assert_eq "M4: the reason-code registry carries a non-empty, specific set of codes" "10" "$BG_CODES_COUNT"

# M4/identity: the count pin above catches a registry that lost codes, but a registry that
# swapped some codes for different ones at the same count would still pass a count-only check
# -- pin the actual code strings too, one per forbidden-literals.js id (BG-<UPPER-KEBAB> of the
# literal id), so identity drift (not just count drift) is caught.
while IFS= read -r bg_expected_code; do
    [ -z "$bg_expected_code" ] && continue
    ROWS=$((ROWS + 1))
    assert_contains "M4/identity: the registry declares $bg_expected_code" "$bg_expected_code" "$BG_CODES"
done <<'BG_EXPECTED_CODES'
BG-CHAIN-AND
BG-CHAIN-SEMICOLON
BG-PIPE
BG-BACKTICK
BG-CMD-SUBST
BG-BRACE-GROUP
BG-HEREDOC
BG-REDIRECT-OUT
BG-REDIRECT-APPEND
BG-ENV-PREFIX
BG_EXPECTED_CODES

bg_tier_codes="$(printf '%s' "$BG_CODES" | tr ',' '\n' | grep -c '^T-[A-E]' || true)"
assert_eq "M4: no bash-guard code collides with the workflow-gate T-A..T-E namespace" \
    "0" "$bg_tier_codes"
ROWS=$((ROWS + 1))
bg_nonprefixed="$(printf '%s' "$BG_CODES" | tr ',' '\n' | grep -cv '^BG-' || true)"
assert_eq "M4: every reason code is BG-prefixed" "0" "$bg_nonprefixed"

# M5: the code a deny reports is one reasons.js declares -- judge.js must not invent a string
# at the call site, which is how a code ends up in a transcript that no document explains.
# `judge` mode's column 2 is "-" both when a real code legitimately has no code-bearing verdict
# AND when judgeBashCommand wrongly ALLOWS a command it should deny (judge-probe.js sets code to
# "-" whenever `code` is null). Every real BG- code also contains a literal "-", so
# `assert_contains ... "-"` passes identically either way -- false-green. Assert the exact
# expected code and a strict shape that excludes the bare placeholder instead.
bg_deny_code="$(probe judge 'git status && ls' | awk -F'\t' '{print $2}')"
[ -n "$bg_deny_code" ] || bg_deny_code="<NO-CODE>"
ROWS=$((ROWS + 1))
assert_eq "M5: the deny's code is the specific expected code, not the bare placeholder" \
    "BG-CHAIN-AND" "$bg_deny_code"
# Belt-and-suspenders against the exact false-green this row exists to close: the placeholder
# "-" itself would also satisfy a naive assert_contains "-" check, since every real code
# contains a literal "-" too. Rule the bare placeholder out by exact-value comparison.
ROWS=$((ROWS + 1))
if [ "$bg_deny_code" = "-" ]; then
    fail "M5: the deny's code must not be the bare '-' placeholder (that means judgeBashCommand wrongly allowed)" "$bg_deny_code"
else
    pass "M5: the deny's code is not the bare '-' placeholder"
fi
assert_contains "M5: the deny's code is declared in reasons.js" "$bg_deny_code" "$BG_CODES"

# M6: the escape-hatch line is really sourced from buildScriptEscapeHatch() ->
# describeAllowedTargets(), not from message.js's catch-block fallback. A substring like
# "scratchpad" appears in BOTH, so it proves nothing; pin a scratchpad root carrying a marker
# segment that no fallback string could ever contain, and demand it verbatim.
BG_MARKER_SEG="bg-msg-marker-7f3a91"
SCRATCHPAD="$(run_with_timeout 30 node -e 'const os=require("os"),p=require("path");process.stdout.write(p.join(os.tmpdir(),"claude",process.argv[1]))' "$BG_MARKER_SEG")"
export SCRATCHPAD
BG_WANT_SCRATCHPAD="$(run_with_timeout 30 node -e 'process.stdout.write(String(require(process.argv[1]).describeAllowedTargets().scratchpad))' "$(node_path "$AGENTS_DIR/hooks/workflow-gate/early-gate-allowlist.js")" 2>/dev/null)"
BG_MARKED_MSG="$(probe judge-message 'git status && ls')"
unset SCRATCHPAD
case "$BG_MARKED_MSG" in "<"*) BG_MARKED_MSG="" ;; esac

# Fixture self-check first: if the marker never reached describeAllowedTargets(), the
# assertion below would compare the message against a generic path and pass for free.
ROWS=$((ROWS + 1))
assert_contains "M6: the fixture's marker root is what describeAllowedTargets() resolves" \
    "$BG_MARKER_SEG" "$BG_WANT_SCRATCHPAD"
ROWS=$((ROWS + 1))
assert_contains "M6: the deny message carries the exact resolved scratchpad path" \
    "$BG_WANT_SCRATCHPAD" "$BG_MARKED_MSG"
ROWS=$((ROWS + 1))
assert_contains "M6: the deny message carries the marker segment itself (not a fallback)" \
    "$BG_MARKER_SEG" "$BG_MARKED_MSG"

# SKIPPED: asserting the message's exact wording or line order.
# Because: wording is edited far more often than behaviour, and pinning it turns every copy
#          edit into a red suite -- the fragments above are what the model actually consumes.
# L3 gap: whether the message actually changes the model's next action; only a live session
#          shows a compound command being reissued as a scratchpad script.
