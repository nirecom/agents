# e-robustness.sh — E1-E3: malformed markers, hostile expires_at values, and the
# [for=...] reason parser as a table (#1624).
# Sourced by tests/feature-1624-next-step-pause-scope.sh.
# Tests: hooks/lib/next-step-pause-marker.js, hooks/lib/session-markers.js
# Tags: next-step-pause, for-step, ttl, fail-closed, parser, regression-1624, scope:issue-specific, pwsh-not-required, TL1

# read_marker <tn> <sid> — String(readPauseMarker(...)) reduced to a stable token:
# `null`, `object`, or `THREW:<msg>`. A throw must never be read as `null` —
# the two have opposite consequences for a consumer wrapped in a try/catch.
read_marker() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" "$RWT" 20 node -e "
const m = require('$PAUSE_NODE');
let r;
try { r = m.readPauseMarker(process.env.SID); } catch (e) { process.stdout.write('THREW:' + e.message); process.exit(0); }
process.stdout.write(r === null || r === undefined ? 'null' : typeof r);" 2>/dev/null
}

# ---------------------------------------------------------------------------
# E1: a marker file that is not JSON at all. The realistic trigger is a
#     half-written file from a killed process, and the direction of the doubt is
#     the whole point: a marker that cannot be read cannot prove it is live, so
#     it must be inactive (fail-CLOSED) rather than silencing the guards forever.
# ---------------------------------------------------------------------------
run_E1() {
    local tmp tn got problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    printf '{ this is not json' > "$(marker_path "$tmp" e1)"
    got="$(read_marker "$tn" e1)"
    [ "$got" = "null" ] || problems="$problems [readPauseMarker returned '$got', expected null]"
    got="$(pause_active "$tn" e1 research)"
    [ "$got" = "false/false" ] || problems="$problems [isPauseActive/facade = '$got', expected false/false]"
    # Evidence preservation: a "repair" that overwrote the file would destroy the
    # only trace of what went wrong.
    grep -q 'this is not json' "$(marker_path "$tmp" e1)" 2>/dev/null ||
        problems="$problems [the corrupt marker was overwritten by the reader]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "E1: a malformed marker file yields readPauseMarker=null and isPauseActive=false, and is left on disk untouched"
    else
        fail "E1: malformed-marker handling wrong;$problems"
    fi
}

# ---------------------------------------------------------------------------
# E2: the expires_at input domain, one row per way the field can fail to prove
#     freshness. Every one of them must be inactive; the `valid` row is the
#     positive anchor that keeps a blanket `return false` from passing the table.
#     `exactly-expired` is the boundary: expires_at one millisecond in the past
#     is past, so the comparison must be strict rather than >=.
# ---------------------------------------------------------------------------
run_E2() {
    local label value want got problems=""
    while IFS='|' read -r label value want; do
        label="$(trim "$label")"; value="$(trim "$value")"; want="$(trim "$want")"
        case "$label" in ''|'#'*) continue ;; esac
        local tmp tn
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        write_pause "$tn" "e2" "[for=any] baseline"
        if [ ! -f "$(marker_path "$tmp" e2)" ]; then
            problems="$problems [$label: baseline marker was never written]"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi
        [ "$value" = "KEEP" ] || patch_marker "$tmp" e2 expires_at "$value"
        got="$(pause_active "$tn" e2 research)"
        [ "$got" = "$want/$want" ] ||
            problems="$problems [$label (expires_at=$value): got '$got', expected '$want/$want']"
        rm -rf "$tmp" 2>/dev/null || true
    done <<'EOF'
# label            | expires_at value written into the marker      | want isPauseActive
valid              | KEEP                                          | true
null               | null                                          | false
undefined          | undefined                                     | false
number             | 9999999999999                                 | false
boolean            | true                                          | false
empty-string       | ''                                            | false
unparseable        | 'not a date at all'                           | false
object             | ({})                                          | false
array              | ([])                                          | false
exactly-expired    | new Date(Date.now() - 1).toISOString()         | false
EOF
    if [ -z "$problems" ]; then
        pass "E2: every expires_at value that cannot prove freshness (null, undefined, number, boolean, empty, unparseable, object, array, 1ms past) is inactive, while a valid one stays active"
    else
        fail "E2: expires_at handling is not fail-CLOSED;$problems"
    fi
}

# ---------------------------------------------------------------------------
# E3: the [for=...] parser, as a table over the reason string. The tag is written
#     by a human typing a sentinel, so the input domain is prose — and the
#     default matters more than any single row: anything the parser cannot read
#     as a step name must widen to `any`, never narrow to a step that was never
#     named. Narrowing on a typo would silently un-pause the session the author
#     meant to pause.
# ---------------------------------------------------------------------------
run_E3() {
    local label reason want_for probe want_active tmp tn got problems=""
    while IFS='|' read -r label reason want_for probe want_active; do
        label="$(trim "$label")"; want_for="$(trim "$want_for")"
        probe="$(trim "$probe")"; want_active="$(trim "$want_active")"
        reason="$(trim "$reason")"
        case "$label" in ''|'#'*) continue ;; esac
        [ "$reason" = "EMPTY" ] && reason=""
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        write_pause "$tn" e3 "$reason"
        if [ ! -f "$(marker_path "$tmp" e3)" ]; then
            problems="$problems [$label: no marker written for reason '$reason']"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi
        got=$(P="$(node_path "$(marker_path "$tmp" e3)")" "$RWT" 15 node -e "
const fs = require('fs');
try { process.stdout.write(String(JSON.parse(fs.readFileSync(process.env.P, 'utf8')).for_step)); }
catch (e) { process.stdout.write('<unreadable>'); }" 2>/dev/null)
        [ "$got" = "$want_for" ] || problems="$problems [$label: for_step='$got', expected '$want_for']"
        got="$(pause_active "$tn" e3 "$probe")"
        [ "$got" = "$want_active/$want_active" ] ||
            problems="$problems [$label: active at $probe = '$got', expected '$want_active/$want_active']"
        rm -rf "$tmp" 2>/dev/null || true
    done <<'EOF'
# label          | reason string                              | want for_step | probe step   | want active
tag-match        | [for=write_tests] waiting on the subagent   | write_tests   | write_tests  | true
tag-mismatch     | [for=write_tests] waiting on the subagent   | write_tests   | review_tests | false
tag-any          | [for=any] whole-session maintenance         | any           | review_tests | true
no-tag           | waiting on a monitored dispatch             | any           | review_tests | true
empty-reason     | EMPTY                                      | any           | research     | true
malformed-empty  | [for=] waiting on something                 | any           | research     | true
unknown-step     | [for=not_a_real_step] waiting               | any           | research     | true
EOF
    if [ -z "$problems" ]; then
        pass "E3: the [for=...] parser resolves a valid tag to that step and widens every unreadable form (absent, empty, unknown step, wrong case) to 'any'"
    else
        fail "E3: [for=...] parsing wrong;$problems"
    fi
}
