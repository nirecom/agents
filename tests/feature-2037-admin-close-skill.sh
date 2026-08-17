#!/usr/bin/env bash
# tests/feature-2037-admin-close-skill.sh
# Tests: skills/issue-close-verified/SKILL.md, skills/supervisor-report/SKILL.md, hooks/workflow-mark/enforce-override-handlers.js, bin/supervisor-report
# Tags: rules-injection, progressive-disclosure, admin-close, issue-close-verified, sentinel, executable-doc, supervisor-report, TL2, scope:issue-specific
#
# WHY (CPR-WPH): #2037 turns two rules that documented a PROCEDURE into skills that perform it. rules/issue-close-verified.md described a session-scoped bypass window for `gh issue close`; rules/supervisor-reporting.md described a CLI call. Once a procedure lives in a skill, "the text was copied across" is no longer the property that matters — a skill is executed, and the failure that actually hurts is a skill that opens the bypass window and never closes it, leaving `gh issue close` unguarded for the rest of the session.
# A string-comparison test cannot see that. So S2 treats the SKILL.md as an EXECUTABLE DOCUMENT: it extracts the two sentinel commands the skill tells you to run and feeds them, in order, to the real handler that production uses, then asserts the marker appears and then disappears. A misspelled sentinel, a changed quoting style, or a missing END step all fail there — none of which a grep for the token would catch.
# S3/S4 cover what execution cannot: that the skill instructs the restore step UNCONDITIONALLY (the first line of defence against a leaked window is the sentence, not the syntax), and that it still routes ordinary closes back to the standard path. S9 (feature-2037-admin-close-skill/guard-sequence.sh) closes the loop by driving the skill's own commands against the real enforce-issue-close.js: blocked, then allowed inside the window, then blocked again. The supervisor-report skill gets the same "check the destination against its real consumer" treatment in feature-2037-admin-close-skill/supervisor-report-cli.sh (S5/S8/S10).
# Layer: TL2 (real handler module, real marker files in an isolated temp workflow dir; no live Claude session).
# TL3 gap: whether the model, in a live session, actually reaches ICV-4 and emits the END sentinel after a failed or interrupted close. Nothing here can observe that — S2 only proves the documented commands work when executed. Mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

ICV_SKILL="$AGENTS_DIR/skills/issue-close-verified/SKILL.md"
SR_SKILL="$AGENTS_DIR/skills/supervisor-report/SKILL.md"
HANDLERS_JS="${_AGENTS_DIR_NODE}/hooks/workflow-mark/enforce-override-handlers.js"
SR_CLI="$AGENTS_DIR/bin/supervisor-report"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): the workflow dir is pinned per case
# and WORKFLOW_PLANS_DIR is pinned alongside it — pinning one alone lets supervisor-emit
# fall back to the developer's real ~/.workflow-plans/. Inherited session ids are dropped
# so nothing here can resolve the live session.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID || true

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

echo "=== S1: the skill's bypass window has a beginning and an end, in that order ==="

if [ ! -f "$ICV_SKILL" ]; then
    fail "S1: skills/issue-close-verified/SKILL.md does not exist — the admin close procedure has no home"
    ICV_ON_LINE=""; ICV_END_LINE=""; ICV_ON_CMD=""; ICV_END_CMD=""
else
    ICV_ON_LINE="$(grep -n '<<WORKFLOW_ISSUE_CLOSE_VERIFIED:' "$ICV_SKILL" | head -1 | cut -d: -f1)"
    ICV_END_LINE="$(grep -n '<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END:' "$ICV_SKILL" | head -1 | cut -d: -f1)"

    if [ -n "$ICV_ON_LINE" ]; then
        pass "S1a: the skill names the opening sentinel (line $ICV_ON_LINE)"
    else
        fail "S1a: no line carries '<<WORKFLOW_ISSUE_CLOSE_VERIFIED:' — the skill never opens the bypass window it exists to manage"
    fi
    if [ -n "$ICV_END_LINE" ]; then
        pass "S1b: the skill names the closing sentinel (line $ICV_END_LINE)"
    else
        fail "S1b: no line carries '<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END:' — the skill opens a session-wide bypass and never closes it"
    fi
    if [ -n "$ICV_ON_LINE" ] && [ -n "$ICV_END_LINE" ]; then
        if [ "$ICV_ON_LINE" -lt "$ICV_END_LINE" ]; then
            pass "S1c: the opening sentinel is documented before the closing one (L$ICV_ON_LINE < L$ICV_END_LINE)"
        else
            fail "S1c: the closing sentinel (L$ICV_END_LINE) is documented before the opening one (L$ICV_ON_LINE) — following the steps in order would close a window that is not open yet"
        fi
        # A close instruction after the END step would run outside the window and be
        # blocked by the guard, which is the silent-failure shape this case rules out.
        if tail -n "+$((ICV_END_LINE + 1))" "$ICV_SKILL" | grep -q 'gh issue close'; then
            fail "S1d: a 'gh issue close' instruction appears AFTER the closing sentinel — that close runs with the guard restored and will be blocked"
        else
            pass "S1d: no 'gh issue close' instruction appears after the closing sentinel"
        fi
    fi

    # Extract the echo commands verbatim: the point of S2 is that what the skill tells a
    # reader to type is exactly what gets executed, so nothing is reconstructed here.
    ICV_ON_CMD="$(grep -o 'echo "<<WORKFLOW_ISSUE_CLOSE_VERIFIED:[^"]*>>"' "$ICV_SKILL" | head -1)"
    ICV_END_CMD="$(grep -o 'echo "<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END:[^"]*>>"' "$ICV_SKILL" | head -1)"
fi

echo ""
echo "=== S2: executable document — running the skill's own commands opens then closes the window ==="

if [ -z "$ICV_ON_CMD" ] || [ -z "$ICV_END_CMD" ]; then
    fail "S2: could not extract both sentinel echo commands from the skill (on='${ICV_ON_CMD:-<none>}' end='${ICV_END_CMD:-<none>}') — they must appear as a quoted 'echo \"<<...: reason>>\"' command a reader can run verbatim"
elif [ ! -f "$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers.js" ]; then
    fail "S2: IMPLEMENTATION MISSING: hooks/workflow-mark/enforce-override-handlers.js"
else
    S2_WF="$(fresh_workflow_dir)"
    S2_SID="s2sid-2037"
    cat > "$TMPDIR_BASE/drive.js" <<'DRIVE_EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const handlers = require(process.argv[2]);
const sid = process.argv[3];
const wfdir = process.argv[4];
const marker = path.join(wfdir, sid + ".issue-close-verified");
const messages = [];
const run = (cmd) => {
    handlers.handle({
        cmd,
        sessionId: sid,
        pushMessage: (m) => messages.push(String(m)),
        signalFatal: (m) => messages.push("FATAL:" + String(m)),
    });
};
run(process.argv[5]);
console.log("AFTER_ON=" + (fs.existsSync(marker) ? "present" : "absent"));
run(process.argv[6]);
console.log("AFTER_END=" + (fs.existsSync(marker) ? "present" : "absent"));
console.log("FATAL=" + (messages.some((m) => m.startsWith("FATAL:")) ? "yes" : "no"));
DRIVE_EOF

    S2_OUT="$(run_with_timeout 60 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$S2_WF" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node "$TMPDIR_BASE/drive.js" "$HANDLERS_JS" "$S2_SID" "$S2_WF" "$ICV_ON_CMD" "$ICV_END_CMD" 2>&1)"
    S2_ON="$(printf '%s\n' "$S2_OUT" | grep '^AFTER_ON=' | head -1 | cut -d= -f2-)"
    S2_END="$(printf '%s\n' "$S2_OUT" | grep '^AFTER_END=' | head -1 | cut -d= -f2-)"

    if [ "$S2_ON" = "present" ]; then
        pass "S2a: running the skill's opening command creates $S2_SID.issue-close-verified"
    else
        fail "S2a: the skill's opening command did not create the marker (AFTER_ON=${S2_ON:-<none>}) — the documented sentinel does not match what the handler recognizes; output: $(printf '%s' "$S2_OUT" | tr '\n' ' ' | cut -c1-400)"
    fi
    if [ "$S2_ON" = "present" ] && [ "$S2_END" = "absent" ]; then
        pass "S2b: running the skill's closing command removes the marker — following the skill leaves no open bypass window"
    else
        fail "S2b: the window was not closed (AFTER_ON=${S2_ON:-<none>} AFTER_END=${S2_END:-<none>}) — a session following this skill would keep gh issue close unguarded; output: $(printf '%s' "$S2_OUT" | tr '\n' ' ' | cut -c1-400)"
    fi
fi

echo ""
echo "=== S3/S4: the instructions execution cannot verify ==="

if [ -f "$ICV_SKILL" ]; then
    # S3: the restore step must be stated as unconditional. S2 proves the syntax works;
    # only this sentence tells the model to run it after a failure or an abort, which is
    # exactly when a forgotten restore does the damage.
    if grep -qiE '(always|must|unconditional|even if|regardless|whether or not|fail|abort|interrupt)' "$ICV_SKILL" \
       && grep -qiE '^[^#]*\b(always|must|even if|regardless|unconditional)\b.*(END|restore|close the window|窓)' "$ICV_SKILL"; then
        pass "S3: the skill states the restore step is run unconditionally (even when the closes fail or are interrupted)"
    else
        fail "S3: no unconditional-restore instruction found — nothing tells the model to emit the END sentinel after a failed or aborted close, and cleanupZombies' 7-day sweep is a backstop, not a recovery path"
    fi

    S4_OK=0
    grep -q 'issue-close-stage' "$ICV_SKILL" && grep -q 'issue-close-finalize' "$ICV_SKILL" && S4_OK=1
    if [ "$S4_OK" -eq 1 ]; then
        pass "S4: the skill points ordinary closes back at the standard path (/issue-close-stage + /issue-close-finalize)"
    else
        fail "S4: the skill never names the standard close path (/issue-close-stage + /issue-close-finalize) — an admin bypass with no stated alternative becomes the default route"
    fi
fi


echo ""
echo "=== S6: the procedure the skill inherited from rules/issue-close-verified.md ==="

# S1-S4 check the WINDOW: that it opens, closes, and is closed unconditionally. What they
# cannot see is whether anything useful happens INSIDE it. The rule this skill replaces
# carried three facts beyond the two sentinels — which situations justify an admin close,
# that the close itself runs while the window is open, and that the bypass is reported. A
# skill that kept the sentinels and dropped those is a working bypass with no stated
# justification, no work, and no audit trail, and every case above stays green on it.
if [ ! -f "$ICV_SKILL" ]; then
    fail "S6: skills/issue-close-verified/SKILL.md does not exist"
else
    # S6a — the close must be documented BETWEEN the two sentinels. S1d already rules out
    # a close after the END step; this is the positive half, and the two together pin the
    # close to the only interval where the guard is actually down.
    S6_CLOSE_LINE="$(grep -n 'gh issue close' "$ICV_SKILL" | head -1 | cut -d: -f1)"
    if [ -z "$S6_CLOSE_LINE" ]; then
        fail "S6a: the skill never names 'gh issue close' — it opens and closes a bypass window around nothing, so following it performs no close at all"
    elif [ -n "$ICV_ON_LINE" ] && [ -n "$ICV_END_LINE" ] \
         && [ "$S6_CLOSE_LINE" -gt "$ICV_ON_LINE" ] && [ "$S6_CLOSE_LINE" -lt "$ICV_END_LINE" ]; then
        pass "S6a: the close step sits inside the window (L$ICV_ON_LINE < L$S6_CLOSE_LINE < L$ICV_END_LINE)"
    else
        fail "S6a: the close step (L$S6_CLOSE_LINE) is not between the opening (L${ICV_ON_LINE:-<none>}) and closing (L${ICV_END_LINE:-<none>}) sentinels — it would run with enforce-issue-close.js still armed and be blocked"
    fi

    # S6b — the admissible situations, enumerated. Without them the skill answers "how"
    # and never "when", and an unqualified bypass becomes the path of least resistance.
    S6_REASONS=0
    grep -qiE 'obsolete|triage|batch' "$ICV_SKILL" && S6_REASONS=$((S6_REASONS + 1))
    grep -qiE 'incidentally|not covered|別セッション|outside .*session' "$ICV_SKILL" && S6_REASONS=$((S6_REASONS + 1))
    if [ "$S6_REASONS" -ge 2 ]; then
        pass "S6b: the skill enumerates the admissible admin-close situations ($S6_REASONS of 2 recognized)"
    else
        fail "S6b: fewer than two admissible situations are described ($S6_REASONS of 2) — the rule listed obsolete-issue batch triage and incidentally-fixed issues; a skill that only says how to open the window invites it to be opened for anything"
    fi

    # S6c — the bypass has to leave a trace. rules/supervisor-reporting.md's own trigger
    # list names "sentinel used" as reportable, so a skill whose entire job is to emit a
    # bypass sentinel and never mention reporting contradicts the standing instruction.
    if grep -qiE 'supervisor-report|supervisor report|報告' "$ICV_SKILL"; then
        pass "S6c: the skill routes the bypass to the supervisor report trail"
    else
        fail "S6c: nothing in the skill mentions reporting — a session-scoped guard bypass would be exercised with no record, and the cross-session pattern detection the report trail exists for cannot see it"
    fi

    # S6d — the invocation decision, stated. This skill is the one a human genuinely does
    # invoke by name, so an absent key is not a harmless default here: it is the one place
    # where inheriting a future default silently could remove the documented entry point.
    # The value is pinned, not merely required to be stated: batch triage is started by a
    # person, so `false` here would leave the documented entry point unreachable by the only
    # party expected to use it.
    S6_FM="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 {print}' "$ICV_SKILL")"
    S6_UI="$(printf '%s\n' "$S6_FM" | grep -E '^user-invocable:' | head -1 | sed -E 's/^user-invocable:[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "$S6_UI" ]; then
        fail "S6d: issue-close-verified's frontmatter carries no explicit 'user-invocable:' key — the invocation decision for the one skill a human is expected to call by name is left to whatever the default happens to be"
    elif [ "$S6_UI" = "true" ]; then
        pass "S6d: issue-close-verified declares user-invocable: true"
    else
        fail "S6d: issue-close-verified declares user-invocable: '$S6_UI', want 'true' — a human-started batch triage cannot reach the skill it is documented to start from"
    fi
fi

echo ""
echo "=== S7: running the documented sequence twice leaves the same state as once ==="

# The realistic misuse is not a clean open-work-close. It is a session that opens the
# window, gets interrupted, re-runs the skill from the top, and eventually emits ONE end
# sentinel. If the handler treated the second open as a nested window — a depth counter, a
# second marker file, an error — that single close would not restore the guard, and S2's
# clean pairing would never reveal it. Closing twice is checked for the mirror reason: a
# retry after a failed close must not fail or resurrect the marker.
if [ -z "${ICV_ON_CMD:-}" ] || [ -z "${ICV_END_CMD:-}" ]; then
    fail "S7: the sentinel commands could not be extracted (see S2) — idempotency was not exercised"
elif [ ! -f "$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers.js" ]; then
    fail "S7: IMPLEMENTATION MISSING: hooks/workflow-mark/enforce-override-handlers.js"
else
    S7_WF="$(fresh_workflow_dir)"
    S7_SID="s7sid-2037"
    cat > "$TMPDIR_BASE/drive-idem.js" <<'IDEM_EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const handlers = require(process.argv[2]);
const sid = process.argv[3];
const wfdir = process.argv[4];
const marker = path.join(wfdir, sid + ".issue-close-verified");
const messages = [];
const run = (cmd) => handlers.handle({
    cmd,
    sessionId: sid,
    pushMessage: (m) => messages.push(String(m)),
    signalFatal: (m) => messages.push("FATAL:" + String(m)),
});
const markers = () => {
    try {
        return fs.readdirSync(wfdir).filter((n) => n.endsWith(".issue-close-verified")).length;
    } catch (_) { return -1; }
};
run(process.argv[5]);
run(process.argv[5]);
console.log("AFTER_TWO_OPENS=" + (fs.existsSync(marker) ? "present" : "absent"));
console.log("MARKER_COUNT=" + markers());
run(process.argv[6]);
console.log("AFTER_ONE_CLOSE=" + (fs.existsSync(marker) ? "present" : "absent"));
run(process.argv[6]);
console.log("AFTER_TWO_CLOSES=" + (fs.existsSync(marker) ? "present" : "absent"));
console.log("FATAL=" + (messages.some((m) => m.startsWith("FATAL:")) ? "yes" : "no"));
IDEM_EOF

    S7_OUT="$(run_with_timeout 60 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$S7_WF" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node "$TMPDIR_BASE/drive-idem.js" "$HANDLERS_JS" "$S7_SID" "$S7_WF" "$ICV_ON_CMD" "$ICV_END_CMD" 2>&1)"
    s7f() { printf '%s\n' "$S7_OUT" | grep "^$1=" | head -1 | cut -d= -f2-; }

    if [ "$(s7f AFTER_TWO_OPENS)" = "present" ] && [ "$(s7f MARKER_COUNT)" = "1" ]; then
        pass "S7a: two opens leave exactly one marker — the window does not nest"
    else
        fail "S7a: two opens produced AFTER_TWO_OPENS=$(s7f AFTER_TWO_OPENS) MARKER_COUNT=$(s7f MARKER_COUNT) (want present/1); output: $(printf '%s' "$S7_OUT" | tr '\n' ' ' | cut -c1-400)"
    fi
    if [ "$(s7f AFTER_ONE_CLOSE)" = "absent" ]; then
        pass "S7b: a single close after two opens restores the guard"
    else
        fail "S7b: the guard is still bypassed after the documented close (AFTER_ONE_CLOSE=$(s7f AFTER_ONE_CLOSE)) — a re-run of the skill would leave gh issue close unguarded for the rest of the session"
    fi
    if [ "$(s7f AFTER_TWO_CLOSES)" = "absent" ] && [ "$(s7f FATAL)" = "no" ]; then
        pass "S7c: closing an already-closed window is a silent no-op, not an error"
    else
        fail "S7c: the second close did not no-op (AFTER_TWO_CLOSES=$(s7f AFTER_TWO_CLOSES) FATAL=$(s7f FATAL)) — a retry after an interrupted close would fail or reopen the window; output: $(printf '%s' "$S7_OUT" | tr '\n' ' ' | cut -c1-400)"
    fi
fi

# --- Sibling case files. The entry file crossed the 300-line WARN
# (rules/coding/file-split.md Pattern A), so it splits on the axis the cases already have:
# the guard sequence for issue-close-verified, and everything about supervisor-report.
# Both are sourced rather than run standalone so the extracted sentinel commands and the
# fixture helpers above stay in scope. ---
SR_CASES="$AGENTS_DIR/tests/feature-2037-admin-close-skill/supervisor-report-cli.sh"
if [ -f "$SR_CASES" ]; then
    # shellcheck source=./feature-2037-admin-close-skill/supervisor-report-cli.sh
    . "$SR_CASES"
else
    fail "IMPLEMENTATION MISSING: $SR_CASES (supervisor-report CLI cases)"
fi

# S11/S12/S13 are their own files rather than additions to supervisor-report-cli.sh, which
# is already past the 300-line WARN. Each carries one axis: --detail payload safety, the
# doc-vs-schema enum set equality, and the C3 alert's verify-pointer.
DI_CASES="$AGENTS_DIR/tests/feature-2037-admin-close-skill/detail-injection.sh"
if [ -f "$DI_CASES" ]; then
    # shellcheck source=./feature-2037-admin-close-skill/detail-injection.sh
    . "$DI_CASES"
else
    fail "IMPLEMENTATION MISSING: $DI_CASES (--detail shell-injection cases)"
fi

EC_CASES="$AGENTS_DIR/tests/feature-2037-admin-close-skill/enum-completeness.sh"
if [ -f "$EC_CASES" ]; then
    # shellcheck source=./feature-2037-admin-close-skill/enum-completeness.sh
    . "$EC_CASES"
else
    fail "IMPLEMENTATION MISSING: $EC_CASES (enum completeness oracle)"
fi

FP_CASES="$AGENTS_DIR/tests/feature-2037-admin-close-skill/formatter-pointer.sh"
if [ -f "$FP_CASES" ]; then
    # shellcheck source=./feature-2037-admin-close-skill/formatter-pointer.sh
    . "$FP_CASES"
else
    fail "IMPLEMENTATION MISSING: $FP_CASES (C3 alert verify-pointer cases)"
fi

GUARD_CASES="$AGENTS_DIR/tests/feature-2037-admin-close-skill/guard-sequence.sh"
if [ -f "$GUARD_CASES" ]; then
    # shellcheck source=./feature-2037-admin-close-skill/guard-sequence.sh
    . "$GUARD_CASES"
else
    fail "IMPLEMENTATION MISSING: $GUARD_CASES (end-to-end guard-sequence cases)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
