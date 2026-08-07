#!/usr/bin/env bash
# tests/feature-530-notes-promotion-protocol.sh
# Tests: skills/_shared/notes-promotion.md, skills/worktree-end/SKILL.md, skills/session-close/SKILL.md, skills/issue-close-finalize/SKILL.md, skills/issue-create/SKILL.md, rules/mid-workflow-findings.md
# Tags: notes-promotion, worktree-notes, skill-orchestration, static, prompt-contract, TL1, scope:issue-specific
#
# Issue #530 — WORKTREE_NOTES.md promotion becomes a single shared protocol
# (skills/_shared/notes-promotion.md) referenced by three execution points
# (worktree-end WE-11, session-close SC-8, issue-close-finalize residual pass)
# instead of one bespoke procedure inlined in worktree-end.
#
# TL1 (static): the subject is prompt text. The behavior of the CLI the protocol
# delegates to is covered by tests/feature-530-notes-promotion-triage-flow.sh and
# tests/feature-worktree-end-step55-promotion.sh.
#
# RED before write-code: skills/_shared/notes-promotion.md does not exist yet and
# the three callsites do not reference it yet. Every group below therefore fails
# with a named assertion, not a crash.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SHARED_REL="skills/_shared/notes-promotion.md"
SHARED_MD="$AGENTS_DIR/$SHARED_REL"
WE_MD="$AGENTS_DIR/skills/worktree-end/SKILL.md"
SC_MD="$AGENTS_DIR/skills/session-close/SKILL.md"
ICF_MD="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"
IC_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"
MWF_MD="$AGENTS_DIR/rules/mid-workflow-findings.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/np-protocol-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Print the markdown section containing the first line that carries `needle`:
# from its nearest preceding heading up to (not including) the next heading of
# the same-or-shallower depth. Exit 1 when the needle is absent, so a caller can
# distinguish "not documented" from "documented but wrong".
extract_section_containing() {
    awk -v needle="$2" '
        function depth_of(l,   d) { d = 0; while (substr(l, d + 1, 1) == "#") d++; return d }
        { line[NR] = $0 }
        END {
            target = 0
            for (i = 1; i <= NR; i++) if (index(line[i], needle) > 0) { target = i; break }
            if (target == 0) exit 1
            start = 0
            for (i = target; i >= 1; i--) if (line[i] ~ /^#+ /) { start = i; break }
            if (start == 0) start = 1
            d0 = depth_of(line[start])
            end = NR
            for (i = start + 1; i <= NR; i++) {
                if (line[i] ~ /^#+ / && depth_of(line[i]) <= d0) { end = i - 1; break }
            }
            for (i = start; i <= end; i++) print line[i]
        }
    ' "$1"
}

# ===========================================================================
# Group A — the shared protocol file exists and states its contract
# ===========================================================================
group_shared_protocol_exists() {
    if [ ! -f "$SHARED_MD" ]; then
        fail "A1: $SHARED_REL does not exist"
        return 1
    fi
    pass "A1: $SHARED_REL exists"
    return 0
}

group_shared_three_execution_points() {
    [ -f "$SHARED_MD" ] || { fail "A2: $SHARED_REL missing"; return; }
    local missing="" c
    for c in worktree-end session-close issue-close-finalize; do
        grep -qF -- "--caller $c" "$SHARED_MD" || missing="$missing --caller=$c"
    done
    if [ -z "$missing" ]; then
        pass "A2: $SHARED_REL names all three execution points by --caller value"
    else
        fail "A2: execution-point table incomplete" "missing:$missing"
    fi
}

group_shared_skip_conditions() {
    [ -f "$SHARED_MD" ] || { fail "A3: $SHARED_REL missing"; return; }
    local missing=""
    # 1. non-interactive session
    grep -qiE 'non-interactive' "$SHARED_MD" || missing="$missing non-interactive"
    # 2. non-GitHub remote — named via the probe that decides it
    grep -qF 'is-github-dotcom-remote' "$SHARED_MD" || missing="$missing non-github-remote"
    # 3. user explicitly defers
    grep -qiE 'defer' "$SHARED_MD" || missing="$missing user-defer"
    # 4. resolve-driven skip (ownership hand-off or unresolvable notes path)
    grep -qE 'notes-path-unresolved|owned-by-session-close' "$SHARED_MD" \
        || missing="$missing resolve-skip"
    if [ -z "$missing" ]; then
        pass "A3: $SHARED_REL documents all four skip conditions"
    else
        fail "A3: skip-condition list incomplete" "missing:$missing"
    fi
}

group_shared_delegates_to_resolve() {
    [ -f "$SHARED_MD" ] || { fail "A4: $SHARED_REL missing"; return; }
    local has_resolve has_bin
    has_resolve=0; has_bin=0
    grep -qE '(^|[^a-z-])resolve([^a-z-]|$)' "$SHARED_MD" && has_resolve=1
    grep -qF 'worktree-notes-triage' "$SHARED_MD" && has_bin=1
    if [ "$has_resolve" -eq 1 ] && [ "$has_bin" -eq 1 ]; then
        pass "A4: $SHARED_REL delegates ownership/path decisions to the triage \`resolve\` subcommand"
    else
        fail "A4: resolve delegation not documented" "resolve=$has_resolve triage-bin=$has_bin"
    fi
}

# NP-11: ManualReminders are surfaced to the user in chat, never filed as issues.
group_shared_manual_reminders_read_aloud() {
    [ -f "$SHARED_MD" ] || { fail "A5: $SHARED_REL missing"; return; }
    local hit
    hit="$(grep -n 'ManualReminders' "$SHARED_MD" \
           | grep -iE 'read|aloud|surface|chat|報告|読み上げ' | head -1)"
    if [ -n "$hit" ]; then
        pass "A5: $SHARED_REL documents reading ## ManualReminders aloud to the user (NP-11)"
    else
        fail "A5: no ManualReminders read-aloud directive found" \
             "grep 'ManualReminders' hits: $(grep -c 'ManualReminders' "$SHARED_MD" 2>/dev/null || echo 0)"
    fi
}

# ===========================================================================
# Group B — the three callsites reference the shared protocol
# ===========================================================================
group_callsites_reference_shared() {
    local rel path label
    for entry in "skills/worktree-end/SKILL.md|WE-11" \
                 "skills/session-close/SKILL.md|SC-8" \
                 "skills/issue-close-finalize/SKILL.md|ICF-residual"; do
        rel="${entry%%|*}"; label="${entry##*|}"
        path="$AGENTS_DIR/$rel"
        if [ ! -f "$path" ]; then
            fail "B/$label: $rel missing"
            continue
        fi
        if grep -qF "$SHARED_REL" "$path"; then
            pass "B/$label: $rel references $SHARED_REL"
        else
            fail "B/$label: $rel does not reference $SHARED_REL"
        fi
    done
}

# ===========================================================================
# Group C — WE-11 no longer asks the user (promotion is unconditional there)
# ===========================================================================
group_we11_no_askuserquestion() {
    [ -f "$WE_MD" ] || { fail "C1: worktree-end/SKILL.md missing"; return; }
    local block
    if ! block="$(extract_section_containing "$WE_MD" 'Step WE-11')"; then
        fail "C1: no 'Step WE-11' heading found in worktree-end/SKILL.md"
        return
    fi
    if printf '%s\n' "$block" | grep -qF 'AskUserQuestion'; then
        fail "C1: WE-11 block still contains AskUserQuestion" \
             "$(printf '%s\n' "$block" | grep -nF 'AskUserQuestion' | head -2)"
    else
        pass "C1: WE-11 block contains no AskUserQuestion"
    fi
}

# ===========================================================================
# Group D — defer-type wording removed from the filing instructions
# ===========================================================================
# The regression: text that tells the reader to FILE the finding in a later
# session. Filing happens now; only the implementation is deferred — so
# "implementation will require a separate session" is correct prose that the
# oracle must accept, while "file the issue in a separate session" must be
# rejected. A co-occurrence test over a whole line or block cannot tell those
# apart, because both mention filing and both mention a separate session.
#
# The oracle therefore works sentence by sentence, and a deferring sentence has
# to survive two checks:
#
#   (1) explicit deferral of the filing — the sentence speaks about filing,
#       defers, and is not talking about the implementation. Rejected.
#   (2) AMBIGUOUS deferral — the sentence defers but names nothing at all:
#       no filing, no implementation, no work verb. "It will require a separate
#       session." is the shape that matters: the reader cannot tell whether the
#       thing postponed is the filing or the fix, and a reader who guesses
#       "the filing" loses the finding. A deferring sentence must say what is
#       being deferred, so an unanchored one is rejected too.
#
# Known limit: a single sentence that does both jobs — "file the issue in a
# separate session, not the implementation" — is accepted, because the impl
# exemption is sentence-scoped. Splitting finer than sentences would misread
# ordinary punctuation.
FILING_RE='/issue-create|file the issue|file it|filing|起票'
DEFER_RE='separate session|next session|another session|later|別セッション|後で|次のセッション'
IMPL_RE='implementation|implement|実装'
# Verbs that name the deferred WORK (as opposed to the filing). A deferring
# sentence anchored on one of these is unambiguous prose, not a violation.
WORK_RE='address|work on|worked on|working on|works on|fix|resolve|handle|tackle|対応|着手|作業'

# defer_verdict <text> -> "ok" | "violation: <sentence>"
defer_verdict() {
    printf '%s\n' "$1" \
        | sed 's/。/。\n/g; s/\([.;]\) /\1\n/g' \
        | awk -v filing="$FILING_RE" -v defer="$DEFER_RE" -v impl="$IMPL_RE" -v work="$WORK_RE" '
            {
                s = tolower($0)
                if (s !~ defer) next
                gsub(/^[ \t]+|[ \t]+$/, "", $0)
                if (s ~ filing && s !~ impl) {
                    print "violation: " $0
                    found = 1
                    exit
                }
                if (s !~ filing && s !~ impl && s !~ work) {
                    print "violation (ambiguous — defers without naming what): " $0
                    found = 1
                    exit
                }
            }
            END { if (!found) print "ok" }
        '
}

# D1/D2 oracle self-test: paired cases pinning both directions. The reject rows
# double as the mutation probe — if the oracle were loosened to accept
# everything, every "reject" row would fail here.
group_defer_oracle_paired_cases() {
    local failures=0 name want text got
    while IFS='|' read -r name want text; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        got="$(defer_verdict "$text")"
        case "$got" in violation*) got="reject" ;; ok) got="accept" ;; esac
        if [ "$got" = "$want" ]; then
            pass "D3/$name: oracle returns $want"
        else
            fail "D3/$name: oracle returned $got, want $want" "text=$text"
            failures=$((failures + 1))
        fi
    done <<'TABLE'
accept-impl-defers-en|accept|Invoke `/issue-create` immediately. Implementation will require a separate session.
accept-impl-defers-ja|accept|起票は今すぐ `/issue-create` で行う。別セッションになるのは実装だけである。
accept-file-now-then-work-later|accept|File the issue now. Address it in a separate session via /workflow-init.
accept-no-filing-verb|accept|Mid-workflow findings are worked on in a separate session.
accept-filing-without-defer|accept|Invoke `/issue-create` immediately from the linked worktree.
reject-file-in-separate-session|reject|Invoke `/issue-create` for it in a separate session once this one lands.
reject-file-the-issue-later|reject|File the issue in the next session.
reject-filing-later|reject|Filing can happen later.
reject-ja-kian-betsu|reject|起票は別セッションで行う。
reject-ambiguous-bare-defer|reject|It will require a separate session.
reject-ambiguous-this-later|reject|This has to wait until later.
accept-impl-named-in-same-sentence|accept|Implementing the fix requires a separate session, so only the issue is opened now.
accept-work-verb-named|accept|Resolve the finding in a separate session via /workflow-init.
TABLE
    return $failures
}

group_mid_workflow_no_defer_wording() {
    [ -f "$MWF_MD" ] || { fail "D1: rules/mid-workflow-findings.md missing"; return; }
    local verdict
    verdict="$(defer_verdict "$(cat "$MWF_MD")")"
    if [ "$verdict" = "ok" ]; then
        pass "D1: rules/mid-workflow-findings.md defers implementation only, never the filing itself"
    else
        fail "D1: a sentence defers the filing itself" "$verdict"
    fi
}

group_ic3_no_defer_wording() {
    [ -f "$IC_MD" ] || { fail "D2: issue-create/SKILL.md missing"; return; }
    local block verdict
    if ! block="$(extract_section_containing "$IC_MD" 'IC-3.')"; then
        fail "D2: no IC-3 step found in issue-create/SKILL.md"
        return
    fi
    verdict="$(defer_verdict "$block")"
    if [ "$verdict" = "ok" ]; then
        pass "D2: the IC-3 notice defers implementation only, never the filing itself"
    else
        fail "D2: IC-3 notice defers the filing itself" "$verdict"
    fi
}

group_shared_no_defer_wording() {
    [ -f "$SHARED_MD" ] || { fail "D4: $SHARED_REL missing"; return; }
    local verdict
    verdict="$(defer_verdict "$(cat "$SHARED_MD")")"
    if [ "$verdict" = "ok" ]; then
        pass "D4: $SHARED_REL (NP-8) defers implementation only, never the filing itself"
    else
        fail "D4: shared protocol defers the filing itself" "$verdict"
    fi
}

# ===========================================================================
# Group F (#688) — the cheap prefilter (NP-4) and the one-line notice (NP-5)
# ===========================================================================
# #688: a session whose notes are all `- (none)` must cost nothing — no CLI
# call, no /issue-create, no user-visible ceremony. A session with real notes
# must say, in one line, what it is about to file and why, BEFORE it starts
# filing; otherwise the first thing the user sees is issues appearing.
#
# The runtime half of this ("zero entries → zero /issue-create calls") is
# asserted in tests/feature-530-notes-promotion-triage-flow/promotion-loop.sh
# case L3. Here the prompt contract is asserted.

# Line number of the first line matching an ERE, or empty.
line_of() { grep -nE "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

group_prefilter_documented() {
    [ -f "$SHARED_MD" ] || { fail "F1: $SHARED_REL missing"; return; }
    local block missing="" s
    if ! block="$(extract_section_containing "$SHARED_MD" '(none)')"; then
        fail "F1: $SHARED_REL never mentions the '- (none)' placeholder, so no prefilter is specified"
        return
    fi
    for s in BugsFound RelatedTasks NextTasks; do
        printf '%s\n' "$block" | grep -qF "$s" || missing="$missing $s"
    done
    # The point of the prefilter is that nothing downstream runs.
    printf '%s\n' "$block" | grep -qiE 'skip|stop|do not|なにも|何も|終了' \
        || missing="$missing skip-directive"
    printf '%s\n' "$block" | grep -qiE '/issue-create|worktree-notes-triage|CLI|コマンド' \
        || missing="$missing names-what-is-avoided"
    if [ -z "$missing" ]; then
        pass "F1: NP-4 documents the all-'- (none)' fast path across the three triage sections, skipping the downstream call"
    else
        fail "F1: prefilter under-specified" "missing:$missing"
    fi
}

group_notice_precedes_filing() {
    [ -f "$SHARED_MD" ] || { fail "F2: $SHARED_REL missing"; return; }
    local notice_ln file_ln missing=""
    notice_ln="$(line_of "$SHARED_MD" '(one[- ]line|1行|一行)')"
    file_ln="$(line_of "$SHARED_MD" '/issue-create')"
    [ -n "$notice_ln" ] || missing="$missing no-one-line-notice"
    [ -n "$file_ln" ] || missing="$missing no-issue-create-step"
    if [ -n "$notice_ln" ] && [ -n "$file_ln" ] && [ "$notice_ln" -gt "$file_ln" ]; then
        missing="$missing notice-after-filing(notice=$notice_ln,file=$file_ln)"
    fi
    if [ -z "$missing" ]; then
        pass "F2: NP-5 requires a one-line notice, stated before the /issue-create step (line $notice_ln < $file_ln)"
    else
        fail "F2: notice ordering/existence wrong" "missing:$missing"
    fi
}

group_notice_states_count_and_reason() {
    [ -f "$SHARED_MD" ] || { fail "F3: $SHARED_REL missing"; return; }
    local block missing=""
    if ! block="$(extract_section_containing "$SHARED_MD" 'one-line')"; then
        if ! block="$(extract_section_containing "$SHARED_MD" '1行')"; then
            fail "F3: no one-line notice step found in $SHARED_REL"
            return
        fi
    fi
    # "3 findings will be filed as issues now" — a count and a reason, not a
    # bare announcement.
    printf '%s\n' "$block" | grep -qiE 'count|number|件|entries|N ' || missing="$missing count"
    printf '%s\n' "$block" | grep -qiE 'why|reason|because|explain|理由|説明' || missing="$missing reason"
    if [ -z "$missing" ]; then
        pass "F3: the NP-5 notice must carry the entry count and the reason for filing"
    else
        fail "F3: notice content under-specified" "missing:$missing"
    fi
}

# The callsites must not carry their own copy of the loop: a second copy is a
# second place for the prefilter to be forgotten (CPR-2).
group_callsites_delegate_the_loop() {
    local entry rel label path block
    for entry in "skills/worktree-end/SKILL.md|WE-11|Step WE-11" \
                 "skills/session-close/SKILL.md|SC-8|SC-8" \
                 "skills/issue-close-finalize/SKILL.md|ICF|notes-promotion"; do
        rel="$(printf '%s' "$entry" | cut -d'|' -f1)"
        label="$(printf '%s' "$entry" | cut -d'|' -f2)"
        path="$AGENTS_DIR/$rel"
        if [ ! -f "$path" ]; then
            fail "F4/$label: $rel missing"
            continue
        fi
        if ! block="$(extract_section_containing "$path" "$(printf '%s' "$entry" | cut -d'|' -f3)")"; then
            fail "F4/$label: no anchor block found in $rel"
            continue
        fi
        if printf '%s\n' "$block" | grep -qF '/issue-create' \
           && ! printf '%s\n' "$block" | grep -qF '(none)'; then
            fail "F4/$label: the block drives /issue-create itself without the '- (none)' prefilter" \
                 "$(printf '%s\n' "$block" | grep -nF '/issue-create' | head -2)"
        else
            pass "F4/$label: the callsite delegates the filing loop instead of re-implementing it unfiltered"
        fi
    done
}

# ===========================================================================
# Group E — issue-create points at the real SSOT, and names its worktree
#           exceptions
# ===========================================================================
group_ic_no_phantom_claude_md_heading() {
    [ -f "$IC_MD" ] || { fail "E1: issue-create/SKILL.md missing"; return; }
    local hits
    # NOTE: `-i` combined with `-F` aborts on GNU grep 3.0 under MSYS2; the
    # heading's capitalization is fixed, so a case-sensitive match is enough.
    hits="$(grep -n 'Mid-workflow finding capture' "$IC_MD" || true)"
    if [ -z "$hits" ]; then
        pass "E1: issue-create/SKILL.md no longer cites the non-existent CLAUDE.md heading"
    else
        fail "E1: phantom '## Mid-workflow finding capture' reference remains" "$hits"
    fi
}

group_ic_points_at_rules_file() {
    [ -f "$IC_MD" ] || { fail "E2: issue-create/SKILL.md missing"; return; }
    if grep -qF 'rules/mid-workflow-findings.md' "$IC_MD"; then
        pass "E2: issue-create/SKILL.md points at rules/mid-workflow-findings.md"
    else
        fail "E2: issue-create/SKILL.md does not reference rules/mid-workflow-findings.md"
    fi
}

group_ic_worktree_requirement_exceptions() {
    [ -f "$IC_MD" ] || { fail "E3: issue-create/SKILL.md missing"; return; }
    local line missing=""
    line="$(grep -n 'Must be invoked from a linked worktree' "$IC_MD" | head -1)"
    if [ -z "$line" ]; then
        fail "E3: no 'Must be invoked from a linked worktree' line in issue-create/SKILL.md"
        return
    fi
    # The exception clause may wrap onto the following lines; scan the sentence
    # plus a small window after it.
    local start window
    start="${line%%:*}"
    window="$(awk -v s="$start" 'NR >= s && NR <= s + 4' "$IC_MD")"
    printf '%s\n' "$window" | grep -qE 'session-close|SC-8' || missing="$missing session-close/SC-8"
    printf '%s\n' "$window" | grep -qF 'issue-close-finalize' || missing="$missing issue-close-finalize"
    if [ -z "$missing" ]; then
        pass "E3: worktree-requirement line names session-close/SC-8 and issue-close-finalize as exceptions"
    else
        fail "E3: worktree-requirement exceptions incomplete" "missing:$missing window='$window'"
    fi
}

group_shared_protocol_exists
group_shared_three_execution_points
group_shared_skip_conditions
group_shared_delegates_to_resolve
group_shared_manual_reminders_read_aloud
group_callsites_reference_shared
group_we11_no_askuserquestion
group_defer_oracle_paired_cases
group_mid_workflow_no_defer_wording
group_ic3_no_defer_wording
group_shared_no_defer_wording
group_prefilter_documented
group_notice_precedes_filing
group_notice_states_count_and_reason
group_callsites_delegate_the_loop
group_ic_no_phantom_claude_md_heading
group_ic_points_at_rules_file
group_ic_worktree_requirement_exceptions

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
