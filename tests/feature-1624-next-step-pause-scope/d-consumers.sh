# d-consumers.sh — D1: the two REAL consumers driven as child processes, one row
# per scope variant (#1624). C1-C10 call isPauseActive directly; a predicate that
# is correct in isolation still fixes nothing if the guard that decides whether to
# nudge the user never consults it with the session's current step.
# Sourced by tests/feature-1624-next-step-pause-scope.sh.
# Tests: hooks/stop-premature-stop-guard.js, bin/workflow/lib/next-step/verdict.js, hooks/lib/session-markers.js
# Tags: next-step-pause, for-step, stop-hook, next-step, regression-1624, scope:issue-specific, pwsh-not-required, TL2

# Every row runs against the SAME session shape: workflow_init + clarify_intent
# complete, so the current step is `research`. That fixes the one variable the
# scope decision turns on and lets the marker's for_step be the only difference
# between a silent guard and a nudging one.

# _drive_row <sid> <reason|-> <mutate:none|expire> — seed, optionally write and
# mutate the marker, then run both real consumers. Sets ROW_C4_RC / ROW_NS.
_drive_row() {
    local sid="$1" reason="$2" mutate="$3"
    ROW_TMP="$(make_tmp)"; ROW_TN="$(node_path "$ROW_TMP")"
    seed_started "$ROW_TN" "$sid"
    if [ "$reason" != "-" ]; then
        write_pause "$ROW_TN" "$sid" "$reason"
        ROW_MARKER_OK=$([ -f "$(marker_path "$ROW_TMP" "$sid")" ] && echo yes || echo no)
        [ "$mutate" = "expire" ] && expire_marker "$ROW_TMP" "$sid" 60000
    else
        ROW_MARKER_OK="n/a"
    fi
    run_c4 "$ROW_TN" "$sid"
    ROW_C4_RC="$C4_RC"
    run_next_step "$ROW_TN" "$sid"
    ROW_NS="$(ns_action "$NS_OUT")"
    ROW_NS_RAW="$NS_OUT"
}

# ---------------------------------------------------------------------------
# D1: the scope decision, read off the real C4 Stop guard and the real
#     bin/workflow/next-step binary. rc=0 from C4 means "silent, exempt"; rc=2
#     means "blocked, the user gets nudged". The control row (no marker at all)
#     must block and recommend, so every silence below is attributable to the
#     marker and not to a session that was quiet to begin with.
# ---------------------------------------------------------------------------
run_D1() {
    local label reason mutate want_rc want_ns problems=""
    while IFS='|' read -r label reason mutate want_rc want_ns; do
        label="$(trim "$label")"; reason="$(trim "$reason")"; mutate="$(trim "$mutate")"
        want_rc="$(trim "$want_rc")"; want_ns="$(trim "$want_ns")"
        case "$label" in ''|'#'*) continue ;; esac
        _drive_row "d1-$label" "$reason" "$mutate"
        if [ "$reason" != "-" ] && [ "$ROW_MARKER_OK" != "yes" ]; then
            problems="$problems [$label: no marker on disk — the row proves nothing]"
        fi
        [ "$ROW_C4_RC" = "$want_rc" ] ||
            problems="$problems [$label: C4 rc=$ROW_C4_RC, expected $want_rc]"
        # A silent C4 must be silent on stdout too: a printed nudge with rc=0
        # would still reach the user.
        if [ "$want_rc" = "0" ] && [ "$ROW_C4_RC" = "0" ] && [ -n "$C4_OUT" ]; then
            problems="$problems [$label: C4 exited 0 but still printed '$C4_OUT']"
        fi
        [ "$ROW_NS" = "$want_ns" ] ||
            problems="$problems [$label: next-step ACTION=$ROW_NS, expected $want_ns ($(echo "$ROW_NS_RAW" | tr '\n' ' '))]"
        rm -rf "$ROW_TMP" 2>/dev/null || true
    done <<'EOF'
# label            | reason                                  | mutate | c4-rc | next-step ACTION
control-no-marker  | -                                       | none   | 2     | invoke
match              | [for=research] waiting on a survey agent | none   | 0     | paused
mismatch           | [for=write_tests] waiting on tests       | none   | 2     | invoke
session-wide       | [for=any] out-of-workflow maintenance    | none   | 0     | paused
untagged           | waiting on a monitored dispatch          | none   | 0     | paused
expired-match      | [for=research] waiting on a survey agent | expire | 2     | invoke
expired-any        | [for=any] out-of-workflow maintenance    | expire | 2     | invoke
EOF
    if [ -z "$problems" ]; then
        pass "D1: the real C4 guard and the real next-step binary both honour for_step and expires_at (7 rows: control, match, mismatch, any, untagged, expired x2)"
    else
        fail "D1: real consumers disagree with the pause scope;$problems"
    fi
}

# ---------------------------------------------------------------------------
# D2: the mismatch row, stated as an end-to-end sentence rather than a column.
#     A pause taken for write_tests must leave the research turn fully guarded:
#     C4 blocks AND names a step to run. Without the second half, an
#     implementation that blocked with an empty recommendation would pass D1's
#     rc column while giving the user nothing to act on.
# ---------------------------------------------------------------------------
run_D2() {
    local problems=""
    _drive_row d2 "[for=write_tests] waiting on the test subagent" none
    # Anchor first: a session with NO marker also blocks and recommends, so
    # without proving the marker landed, everything below holds vacuously.
    [ "$ROW_MARKER_OK" = "yes" ] ||
        problems="$problems [no marker on disk — the assertions below prove nothing]"
    [ "$ROW_C4_RC" = "2" ] ||
        problems="$problems [C4 rc=$ROW_C4_RC, expected 2 — a write_tests pause silenced the research turn]"
    printf '%s' "$C4_OUT" | grep -q '"decision":"block"' ||
        problems="$problems [C4 blocked without a block decision payload: '$C4_OUT']"
    echo "$ROW_NS_RAW" | grep -qE '^NEXT_SKILL=.+$' ||
        problems="$problems [next-step recommended nothing: $(echo "$ROW_NS_RAW" | tr '\n' ' ')]"
    rm -rf "$ROW_TMP" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "D2: a write_tests-scoped pause leaves the research turn fully guarded — C4 blocks with a decision payload and next-step still names a skill"
    else
        fail "D2: cross-step leak at the real consumers;$problems"
    fi
}
