# b-posttooluse.sh — B1-B11: the real hooks/postuse-step-in-flight-mark.js
# PostToolUse hook, spawned as a child process with a Claude Code-shaped payload
# on stdin (#2013). Sourced by tests/feature-2013-step-in-flight-automark.sh.
# Tests: hooks/postuse-step-in-flight-mark.js, hooks/workflow-state/effective-state.js
# Tags: step-in-flight, posttooluse, automark, wi-10-lookahead, regression-2013, scope:issue-specific, pwsh-not-required, TL2

# settle_through <tn> <sid> <step>... — mark every named step complete, so the
# NEXT unlisted step in VALID_STEPS order becomes the session's current step.
settle_through() {
    local tn="$1" sid="$2"; shift 2
    local s
    for s in "$@"; do seed_step "$tn" "$sid" "$s" complete; done
}

# _expect_marked <case-id> <desc> <sid> <tool> <expected-step> <setup-fn>
# Drives the hook once and asserts BOTH that the expected step went in_progress
# and that the hook exited 0 — a hook that crashed after writing is still broken.
_expect_marked() {
    local id="$1" desc="$2" sid="$3" tool="$4" want="$5" setup="$6" tmp tn got
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    "$setup" "$tmp" "$tn" "$sid"
    run_automark "$tn" "$sid" "$tool"
    got="$(step_status "$tmp" "$sid" "$want")"
    if [ "$got" = "in_progress" ] && [ "$AM_RC" -eq 0 ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — $want is '$got' (want in_progress), hook rc=$AM_RC out='$AM_OUT'"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# B1: the #2013 report itself. During WI-10 the very first Agent dispatch can
#     happen before any state file exists; the guard then sees "no state", C4
#     fires, and the session is nudged mid-dispatch. The lookahead must resolve
#     an absent state to `research` and mark it.
# ---------------------------------------------------------------------------
_setup_b1() { : ; }   # deliberately no state file at all
run_B1() { _expect_marked B1 "Agent dispatch with NO state file marks research in_progress (WI-10 lookahead)" b1 Agent research _setup_b1; }

# ---------------------------------------------------------------------------
# B2: the second half of the lookahead — a state file exists but workflow_init
#     is still the resolved step while research is pending. That is the same
#     WI-10 window, just after /workflow-init created the file.
# ---------------------------------------------------------------------------
_setup_b2() { seed_step "$2" "$3" workflow_init pending; }
run_B2() { _expect_marked B2 "Agent dispatch at workflow_init-pending marks research (lookahead past WI-10)" b2 Agent research _setup_b2; }

# ---------------------------------------------------------------------------
# B3: the normal path — no lookahead once the session is past WI-10. The
#     resolved current step is `detail`, and that is what gets marked. Paired
#     with B2 this proves the lookahead is a bounded special case (CPR-UNV),
#     not a permanent "always research" rule.
# ---------------------------------------------------------------------------
_setup_b3() { settle_through "$2" "$3" workflow_init clarify_intent research outline; }
run_B3() { _expect_marked B3 "Agent dispatch past WI-10 marks the resolved current step (detail), not research" b3 Agent detail _setup_b3; }

# ---------------------------------------------------------------------------
# B4/B5: the other two dispatch tools. The C4 trigger is the dispatch itself,
#        so Skill and Task must behave identically to Agent (CPR-ORTH) — one
#        registered tool that slipped out of the matcher or out of the hook's
#        own tool set reproduces #2013 for that tool alone.
# ---------------------------------------------------------------------------
_setup_b4() { settle_through "$2" "$3" workflow_init clarify_intent research outline detail branching_complete write_tests; }
run_B4() { _expect_marked B4 "Skill dispatch marks the current step (review_tests)" b4 Skill review_tests _setup_b4; }

# B5 is the write_tests row, and it dispatches via `Agent` because that is what
# the real WT-6 procedure uses. Testing this step through `Task` alone would
# leave the actual production path — the one #2013 was reported against —
# unexercised for the step where a stalled dispatch is most expensive (#1979).
_setup_b5() { settle_through "$2" "$3" workflow_init clarify_intent research outline detail branching_complete; }
run_B5() { _expect_marked B5 "Agent dispatch during write_tests marks write_tests (the real WT-6 dispatch path)" b5 Agent write_tests _setup_b5; }

# B5b: the same step through `Task`, kept as the supplementary row. Task is still
# a registered dispatch tool, so it must behave identically — but it is the
# variant, not the case that stands in for the production path.
run_B5b() { _expect_marked B5b "Task dispatch during write_tests marks write_tests too (supplementary tool variant)" b5b Task write_tests _setup_b5; }

# _expect_unchanged <case-id> <desc> <sid> <tool> <agent-id> <setup-fn>
# The negative half of the classifier. Compares the WHOLE step map before and
# after, so a hook that marked some other step is caught too, and anchors that
# the digest was readable in the first place.
_expect_unchanged() {
    local id="$1" desc="$2" sid="$3" tool="$4" agent="$5" setup="$6" tmp tn before after
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    "$setup" "$tmp" "$tn" "$sid"
    before="$(state_digest "$tmp" "$sid")"
    if [ "$before" = "<no-state>" ] || [ -z "$before" ]; then
        fail "$id: $desc — fixture produced no readable state to compare against"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    run_automark "$tn" "$sid" "$tool" "$agent"
    after="$(state_digest "$tmp" "$sid")"
    if [ "$before" = "$after" ] && [ "$AM_RC" -eq 0 ]; then
        pass "$id: $desc"
    elif [ "$before" != "$after" ]; then
        fail "$id: $desc — state changed
    before: $before
    after:  $after"
    else
        fail "$id: $desc — state was left alone, but the hook exited $AM_RC (want 0)"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# B6: a non-dispatch tool. Bash is by far the most frequent PostToolUse event,
#     so a hook that marked on every tool would put the session permanently
#     in_progress and silence C4 for good.
# ---------------------------------------------------------------------------
_setup_started() { settle_through "$2" "$3" workflow_init clarify_intent; }
run_B6() { _expect_unchanged B6 "Bash dispatch leaves the state untouched (not a dispatch tool)" b6 Bash "" _setup_started; }

# ---------------------------------------------------------------------------
# B7: a dispatch made BY a subagent (agent_id present). The C4 guard runs on the
#     main conversation; marking from inside a subagent would let a child turn
#     silence the parent's guard.
# ---------------------------------------------------------------------------
run_B7() { _expect_unchanged B7 "Agent dispatch from inside a subagent (agent_id set) leaves the state untouched" b7 Agent "sub-abc" _setup_started; }

# ---------------------------------------------------------------------------
# B8/B9: current step outside the allowlist. These are the write-side mirror of
#        A5/A6 — the hook must not record in_progress for a step whose
#        predicate would never honour it anyway, which would leave a permanent
#        unsettled record behind (the #1979 stall shape).
# ---------------------------------------------------------------------------
_setup_b8() { settle_through "$2" "$3" workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security; }
run_B8() { _expect_unchanged B8 "Agent dispatch at current step 'docs' (not allowlisted) leaves the state untouched" b8 Agent "" _setup_b8; }

_setup_b9() { seed_step "$2" "$3" workflow_init complete; }
run_B9() { _expect_unchanged B9 "Agent dispatch at current step 'clarify_intent' (not allowlisted) leaves the state untouched" b9 Agent "" _setup_b9; }

# ---------------------------------------------------------------------------
# B10: idempotency. A research turn dispatches many agents; each dispatch must
#      NOT append another event. The observable is the event-stream length, not
#      the status — the status would look identical either way while the stream
#      grew without bound.
# ---------------------------------------------------------------------------
run_B10() {
    local tmp tn n1 n2 n3 problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" b10
    run_automark "$tn" b10 Agent
    [ "$AM_RC" -eq 0 ] || problems="$problems [1st dispatch exited $AM_RC, want 0]"
    [ "$(step_status "$tmp" b10 research)" = "in_progress" ] ||
        problems="$problems [first dispatch did not mark research in_progress]"
    n1="$(event_count "$tmp" b10)"
    [ "${n1:-0}" -gt 0 ] || problems="$problems [event stream is empty — nothing to compare]"

    # Runs 2 and 3 are the repeat. Each is asserted on BOTH axes: the exit code
    # (a PostToolUse hook that throws on the already-marked path would break the
    # user's tool call on every dispatch after the first) and the event count
    # (silence achieved by an unbounded, ever-growing event stream is not
    # idempotence — it is the same bug with a slower leak).
    run_automark "$tn" b10 Agent
    [ "$AM_RC" -eq 0 ] || problems="$problems [2nd dispatch exited $AM_RC, want 0; out='$AM_OUT']"
    n2="$(event_count "$tmp" b10)"
    [ "$n1" = "$n2" ] || problems="$problems [event count grew $n1 -> $n2 on the 2nd dispatch]"

    run_automark "$tn" b10 Skill
    [ "$AM_RC" -eq 0 ] || problems="$problems [3rd dispatch exited $AM_RC, want 0; out='$AM_OUT']"
    n3="$(event_count "$tmp" b10)"
    [ "$n2" = "$n3" ] || problems="$problems [event count grew $n2 -> $n3 on the 3rd dispatch]"

    [ "$(step_status "$tmp" b10 research)" = "in_progress" ] ||
        problems="$problems [research left in_progress no longer holds after the repeats]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "B10: 2nd and 3rd dispatches against an already-marked step both exit 0 and append no further events (idempotent)"
    else
        fail "B10: not idempotent;$problems"
    fi
}

# ---------------------------------------------------------------------------
# B11: fail-safe. A PostToolUse hook that throws or writes garbage to stdout
#      breaks the user's tool call — the failure mode must be "do nothing
#      quietly". Corrupt state is the realistic trigger (a half-written file
#      from a killed process).
# ---------------------------------------------------------------------------
run_B11() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    printf '{ this is not json' > "$tmp/b11.json"
    run_automark "$tn" b11 Agent
    [ "$AM_RC" -eq 0 ] || problems="$problems [exit code $AM_RC, expected 0]"
    case "$(printf '%s' "$AM_OUT" | tr -d ' \n\r')" in
        ""|"{}") : ;;
        *) problems="$problems [stdout was '$AM_OUT', expected empty or {}]" ;;
    esac
    # The corrupt file must be left alone: a hook that "repaired" it by
    # overwriting would destroy evidence the mechanism-failure reporter needs.
    grep -q 'this is not json' "$tmp/b11.json" 2>/dev/null ||
        problems="$problems [the corrupt state file was overwritten]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "B11: corrupt state file — hook exits 0 with no decision output and leaves the file untouched"
    else
        fail "B11: fail-safe contract broken;$problems"
    fi
}

# ---------------------------------------------------------------------------
# B12: malformed STDIN, as a table. B11 covers corrupt state on disk; this is the
#      other input the hook does not own. The payload comes from Claude Code, so
#      its shape is an assumption, and assumptions drift across host versions.
#      A hook that destructures a field that isn't there throws, and a
#      PostToolUse throw surfaces as a broken tool call for the user.
# ---------------------------------------------------------------------------

# Three assertions per row, all necessary: exit 0 (the tool call survives),
# empty-or-{} stdout (no decision payload invented from a payload it could not
# read), and state unchanged (never guess a step out of an unreadable event).
_expect_raw_noop() {
    local id="$1" desc="$2" raw="$3" tmp tn before after problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" braw
    before="$(state_digest "$tmp" braw)"
    if [ "$before" = "<no-state>" ] || [ -z "$before" ]; then
        fail "$id: $desc — fixture produced no readable state to compare against"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    run_automark_raw "$tn" "$raw"
    after="$(state_digest "$tmp" braw)"
    [ "$AM_RC" -eq 0 ] || problems="$problems [exit $AM_RC, want 0]"
    case "$(printf '%s' "$AM_OUT" | tr -d ' \n\r')" in
        ""|"{}") : ;;
        *) problems="$problems [stdout '$AM_OUT', want empty or {}]" ;;
    esac
    [ "$before" = "$after" ] || problems="$problems [state changed: '$before' -> '$after']"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc —$problems"
    fi
}

run_B12() {
    local label raw
    while IFS='|' read -r label raw; do
        label="$(trim "$label")"; raw="$(trim "$raw")"
        case "$label" in ''|'#'*) continue ;; esac
        [ "$raw" = "EMPTY" ] && raw=""
        _expect_raw_noop "B12-$label" "malformed stdin ($label) is a silent no-op" "$raw"
    done <<'EOF'
# label            | raw stdin
empty              | EMPTY
whitespace         |
not-json           | not json at all
truncated-json     | {"tool_name":"Agent"
json-array         | ["Agent","braw"]
json-string        | "Agent"
json-null          | null
no-tool-name       | {"session_id":"braw","transcript_path":""}
no-session-id      | {"tool_name":"Agent","transcript_path":""}
empty-session-id   | {"tool_name":"Agent","session_id":"","transcript_path":""}
tool-name-number   | {"tool_name":42,"session_id":"braw"}
tool-name-object   | {"tool_name":{"name":"Agent"},"session_id":"braw"}
session-id-number  | {"tool_name":"Agent","session_id":99}
agent-id-number    | {"tool_name":"Agent","session_id":"braw","agent_id":7}
EOF
}
