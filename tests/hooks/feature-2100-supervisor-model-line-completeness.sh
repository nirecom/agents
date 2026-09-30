#!/usr/bin/env bash
# tests/hooks/feature-2100-supervisor-model-line-completeness.sh
# Tests: hooks/lib/supervisor-report-format.js, hooks/lib/supervisor-findings-render.js, hooks/workflow-gate/user-verified-audit.js, hooks/supervisor-guard/audit-arm.js, hooks/supervisor-guard.js, hooks/stop-l2-findings-display.js, bin/session-close-render-sc7.js
# Tags: hook, bin, supervisor, model-routing, static, lint, tripwire, scope:issue-specific, audit, unit
# SF-M4 (#2100 Step 8e, TL1): every supervisor spawn instruction in hooks/ + bin/ is
# followed by a formatAgentModelLine( call. Deliberate tripwire: a new file naming
# agents/supervisor(-audit).md fails until it is classified in the Step 6 table.
# M4-2 / AM-1..3 are RED until Step 6 lands; M4-1 / M4-3 / AM-4 are GREEN today.

set -u
# Anchor to THIS checkout: an inherited AGENTS_DIR would otherwise win in harness.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

WORK="$(make_tmp)"
trap 'rm -rf "$WORK"' EXIT

SPAWN_ERE='agents/supervisor(-audit)?[.]md'
TRIPWIRE_HINT="classify it in the #2100 detail-plan Step 6 table (H1-H10) and add formatAgentModelLine(<role>) after each spawn line, or mark it path-assembly-only here"

# Classified hit set (Background of the #2100 detail plan): spawn instruction + path assembly only.
EXPECTED_HITS="bin/session-close-render-sc7.js
hooks/lib/supervisor-findings-render.js
hooks/lib/supervisor-report-format.js
hooks/stop-l2-findings-display.js
hooks/supervisor-guard.js
hooks/workflow-gate/user-verified-audit.js"

# unfollowed_spawn_lines <file> <ERE> — line numbers of each <ERE> line whose NEXT
# line lacks a formatAgentModelLine( call. Empty output = compliant.
unfollowed_spawn_lines() {
    awk -v re="$2" '
        pend { if (index($0, "formatAgentModelLine(") == 0) print pend; pend = 0 }
        $0 ~ re { pend = NR }
        END { if (pend) print pend }
    ' "$1"
}

# check_spawn_file <label> <rel> <ERE> — pass when <rel> has >=1 spawn line and all are followed.
check_spawn_file() {
    local label="$1" rel="$2" re="$3" f="$AGENTS_DIR/$2" bad n
    if [ ! -f "$f" ]; then
        fail "$label" "$rel missing"
        return
    fi
    n="$(grep -cE "$re" "$f")"
    bad="$(unfollowed_spawn_lines "$f" "$re" | tr '\n' ' ')"
    if [ "$n" -eq 0 ]; then
        fail "$label" "$rel has no spawn line matching /$re/ — reclassify it"
    elif [ -n "$bad" ]; then
        fail "$label" "$rel spawn line(s) ${bad}not followed by formatAgentModelLine( — $TRIPWIRE_HINT"
    else
        pass "$label ($n spawn line(s) followed)"
    fi
}

# --- M4-1: the set of files naming a supervisor agent is exactly the classified one
case_begin "M4-1 supervisor path hit set" "hooks/supervisor-guard.js"
got_hits="$(cd "$AGENTS_DIR" || exit 1; grep -rlE --exclude-dir=node_modules "$SPAWN_ERE" hooks bin | tr '\\' '/' | LC_ALL=C sort)"
want_hits="$(printf '%s\n' "$EXPECTED_HITS" | LC_ALL=C sort)"
if [ -z "$got_hits" ]; then
    fail "M4-1 hit set" "grep found no file at all — vacuous scan"
elif [ "$got_hits" = "$want_hits" ]; then
    pass "M4-1 hit set equals the 6 classified files"
else
    extra="$(comm -23 <(printf '%s\n' "$got_hits") <(printf '%s\n' "$want_hits") | tr '\n' ' ')"
    gone="$(comm -13 <(printf '%s\n' "$got_hits") <(printf '%s\n' "$want_hits") | tr '\n' ' ')"
    fail "M4-1 hit set" "unclassified: [${extra}] vanished: [${gone}] — $TRIPWIRE_HINT"
fi
case_end

# --- M4-2: spawn-instruction files follow every spawn line with the model line --
case_begin "M4-2 supervisor-report-format spawn lines" "hooks/lib/supervisor-report-format.js"
check_spawn_file "M4-2 supervisor-report-format.js" "hooks/lib/supervisor-report-format.js" "$SPAWN_ERE"
case_end
case_begin "M4-2 supervisor-findings-render spawn lines" "hooks/lib/supervisor-findings-render.js"
check_spawn_file "M4-2 supervisor-findings-render.js" "hooks/lib/supervisor-findings-render.js" "$SPAWN_ERE"
case_end
case_begin "M4-2 user-verified-audit spawn lines" "hooks/workflow-gate/user-verified-audit.js"
check_spawn_file "M4-2 user-verified-audit.js" "hooks/workflow-gate/user-verified-audit.js" "$SPAWN_ERE"
case_end
case_begin "M4-2 audit-arm Agent file line" "hooks/supervisor-guard/audit-arm.js"
check_spawn_file "M4-2 audit-arm.js (Agent file:)" "hooks/supervisor-guard/audit-arm.js" "Agent file:"
case_end

# --- M4-3: checker controls — a bare spawn line is caught, a followed one is not -
case_begin "M4-3 checker negative and positive control" "tests/hooks/feature-2100-supervisor-model-line-completeness.sh"
printf '%s\n' 'const a = 1;' '  lines.push("Action: invoke agents/supervisor.md as a subagent.");' '  lines.push("next");' > "$WORK/bare.js"
printf '%s\n' '  lines.push("Run agents/supervisor-audit.md now.");' '  lines.push(formatAgentModelLine("reviewer"));' > "$WORK/followed.js"
printf '%s\n' '  lines.push("Action: invoke agents/supervisor.md as a subagent.");' > "$WORK/last.js"
assert_eq "$(unfollowed_spawn_lines "$WORK/bare.js" "$SPAWN_ERE")|$(unfollowed_spawn_lines "$WORK/followed.js" "$SPAWN_ERE")|$(unfollowed_spawn_lines "$WORK/last.js" "$SPAWN_ERE")" "2||1"
# check_spawn_file itself must FAIL on the bare fixture; the subshell keeps that
# expected FAIL out of this file's counters.
sub="$( (AGENTS_DIR="$WORK"; PASS=0; FAIL=0; check_spawn_file "probe" "bare.js" "$SPAWN_ERE"; echo "F=$FAIL") | tail -1)"
assert_eq "$sub" "F=1"
case_end

# --- AM-1..4 (Step 6 H9, SF-M1/SF-M2, TL2): formatAuditArmReason renders the
# reviewer model line right after "  Agent file:". RED until Step 6 (AM-4 GREEN).
harness_isolate "$WORK/iso"
NEUTRAL="$WORK/neutral"; mkdir -p "$NEUTRAL"
AUDIT_ARM_NODE="$(np "$AGENTS_DIR")/hooks/supervisor-guard/audit-arm.js"
AM_JS="const a = require('$AUDIT_ARM_NODE');
process.stdout.write(a.formatAuditArmReason(
  { run_id: 'run-am', cause: 'pre-merge', sub_checks: ['S1', 'S2'] },
  { sessionId: 'sid-am', effectiveSid: 'sid-am', stateFilePath: '/tmp/am-state.json', auditAgentPath: '/tmp/am-audit.md' }));"

# am_render <env-file-content> — sets AM_OUT / AM_ERR / AM_RC; ambient MODEL_* stripped.
AM_OUT=""; AM_ERR=""; AM_RC=0
am_render() {
    local cfg; cfg="$(mktemp -d "$WORK/cfg.XXXX")"
    printf '%b' "$1" > "$cfg/.env"
    (cd "$NEUTRAL" || exit 1
     env -u REVIEWER_MODEL -u ALERT_MODEL -u PRODUCER_HIGH_MODEL -u PRODUCER_LOW_MODEL \
        -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SUBAGENT_MODEL AGENTS_CONFIG_DIR="$(np "$cfg")" \
        bash "$RWT" 10 node -e "$AM_JS" >"$WORK/out" 2>"$WORK/err")
    AM_RC=$?
    AM_OUT="$(cat "$WORK/out")"; AM_ERR="$(cat "$WORK/err")"
}

# am_after — line after "  Agent file: …", leading indentation trimmed.
am_after() {
    printf '%s\n' "$AM_OUT" | awk 'hit { sub(/^[ \t]+/, ""); print; exit } /^  Agent file: / { hit = 1 }'
}

am_expect() {
    local label="$1" alias="$2" n got want
    n="$(printf '%s\n' "$AM_OUT" | grep -c 'Subagent model:')"
    if [ "$AM_RC" -ne 0 ]; then
        fail "$label" "render rc=$AM_RC stderr=$AM_ERR"
        return
    fi
    got="$(am_after)|$n"
    want="Subagent model: pass model: \"$alias\" to the Agent tool.|1"
    if [ "$got" = "$want" ]; then
        pass "$label"
    else
        fail "$label" "line after Agent file|model-line count: got '$got' want '$want'"
    fi
}

case_begin "AM-1 REVIEWER_MODEL reaches the audit-arm model line" "hooks/supervisor-guard/audit-arm.js"
am_render 'REVIEWER_MODEL=haiku\nALERT_MODEL=opus\n'
am_expect "AM-1 REVIEWER_MODEL=haiku" haiku
case_end

case_begin "AM-2 role-swap keeps the reviewer default" "hooks/supervisor-guard/audit-arm.js"
am_render ''
base="$AM_OUT"
am_render 'ALERT_MODEL=haiku\n'
am_expect "AM-2 ALERT_MODEL only -> opus" opus
if [ -n "$base" ] && [ "$AM_OUT" = "$base" ]; then
    pass "AM-2 output byte-identical to the no-.env baseline"
else
    fail "AM-2 swap" "ALERT_MODEL changed the audit-arm reason (or empty baseline)"
fi
case_end

case_begin "AM-3 invalid REVIEWER_MODEL falls back, value withheld" "hooks/supervisor-guard/audit-arm.js"
am_render 'REVIEWER_MODEL=gpt-amleak\n'
am_expect "AM-3 invalid REVIEWER_MODEL -> opus" opus
if printf '%s%s' "$AM_OUT" "$AM_ERR" | grep -q 'amleak'; then
    fail "AM-3 withheld" "invalid value echoed into reason/stderr"
elif [ -z "$AM_OUT" ]; then
    fail "AM-3 withheld" "empty render"
else
    pass "AM-3 invalid value withheld"
fi
case_end

case_begin "AM-4 surrounding audit-arm lines unchanged" "hooks/supervisor-guard/audit-arm.js"
am_render 'REVIEWER_MODEL=haiku\n'
stripped="$(printf '%s\n' "$AM_OUT" | grep -v 'Subagent model:')"
want_block="$(printf 'Run the audit mode strategic review agent with this run-id (run-am):\n  Agent file: /tmp/am-audit.md\n\nsupervisor-audit を該当 run-id (run-am) 付きで起動する。')"
case "$stripped" in
    *"$want_block"*) pass "AM-4 surrounding audit-arm lines unchanged" ;;
    *) fail "AM-4 surrounding lines" "block not found in: $stripped" ;;
esac
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
