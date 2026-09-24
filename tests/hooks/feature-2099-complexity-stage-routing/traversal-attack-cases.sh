#!/bin/bash
# tests/feature-2099-complexity-stage-routing/traversal-attack-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, hooks/workflow-state/state-io.js
# Tags: complexity, routing, cli, security, path-traversal, adversarial, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# --- TA: rejection is not containment ----------------------------------------
# A non-zero exit only says the CLI complained; it says nothing about what the
# process did on the way there. Every case below snapshots the workflow state
# dir AND an out-of-tree canary tree first, and requires both to come back
# byte-identical — so a CLI that writes and then errors is still caught.
D2099T_OUTSIDE="$TMPDIR_BASE/outside"

d2099t_setup_canary() {
    mkdir -p "$D2099T_OUTSIDE/nested"
    printf 'ORIGINAL-CANARY\n' > "$D2099T_OUTSIDE/canary.txt"
    printf 'ORIGINAL-NESTED\n' > "$D2099T_OUTSIDE/nested/deep.txt"
}

# Recursive content+shape snapshot of a tree: every path, and every file's bytes
# via cksum. Detects creation, deletion, truncation and in-place edits alike.
d2099t_snapshot() {
    local root="$1" f
    [ -d "$root" ] || { echo "__NO_DIR__"; return; }
    find "$root" | sort | while IFS= read -r f; do
        if [ -f "$f" ]; then
            printf '%s %s\n' "${f#$root}" "$(cksum < "$f")"
        else
            printf '%s DIR\n' "${f#$root}"
        fi
    done
}

# The attack corpus, one payload per line: label | payload. Three shapes —
# relative traversal, absolute paths, and shell metacharacters — because a
# validator can plausibly stop one and miss the others.
D2099T_PAYLOADS='rel-unix|../../etc/passwd
rel-win|..\..\windows\system32\config
rel-mixed|foo/../../../bar
rel-dotdot|..
rel-encoded|%2e%2e%2fevil
abs-unix|/etc/passwd
abs-win|C:/Windows/win.ini
abs-unc|//server/share/evil
home|~/evil
meta-semicolon|evil;touch D2099T_CANARY
meta-subshell|$(touch D2099T_CANARY)
meta-backtick|`touch D2099T_CANARY`
meta-pipe|evil|touch D2099T_CANARY
meta-amp|evil&&touch D2099T_CANARY
meta-redirect|evil>D2099T_CANARY
meta-quote|evil'"'"'"; touch D2099T_CANARY #
meta-nul|evil%00.json'

# One invocation of one CLI under one session id, with the interpreter that CLI's
# own shebang names (d2099_cli_runner) and the argument shape that CLI actually
# requires. `record-complexity-and-skip` is bash and needs --target; running it
# through `node` died on a syntax error before its validation ever ran, which made
# every "hostile input rejected" verdict below a measurement of Node's parser.
d2099t_invoke() {
    local bin="$1" sid="$2" runner
    runner=$(d2099_cli_runner "$bin")
    case "$bin" in
        "$BIN_READ")
            run_with_timeout "$runner" "$bin" --session "$sid" --stage detail 2>&1 ;;
        "$BIN_RECORD_SKIP")
            run_with_timeout "$runner" "$bin" --session "$sid" \
                --signals "S1-multi-file" --target outline 2>&1 ;;
        *)
            run_with_timeout "$runner" "$bin" --session "$sid" --signals "S1-multi-file" 2>&1 ;;
    esac
}

# Run one CLI with one hostile --session value. Prints "rc=<n> receipt=<yes|no>".
d2099t_attack() {
    local bin="$1" payload="$2" rc=0 out
    out=$(d2099t_invoke "$bin" "$payload") || rc=$?
    case "$out" in
        *RECORDED_COMPLEXITY*) echo "rc=$rc receipt=yes" ;;
        *) echo "rc=$rc receipt=no" ;;
    esac
}

# A CLI that rejects EVERY session id rejects hostile ones for free. This control
# uses a SAFE, ordinary session id through the exact same call path, so a green
# corpus below means validation, not a usage error or a dead interpreter. Every
# per-payload verdict is conditioned on it, and its output is asserted too: a
# non-empty run proves the wrapper itself was reached and did its work.
d2099t_control_accepts_legit() {
    local bin="$1" sid rc=0 out
    sid=$(new_session tactl)
    out=$(d2099t_invoke "$bin" "$sid") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "no rc=$rc out=[$out]"
    else
        echo yes
    fi
}

d2099t_run_corpus() {
    local bin="$1" label payload got ctl before_wf after_wf before_out after_out
    ctl=$(d2099t_control_accepts_legit "$bin")
    assert_eq "TA-CTL [$(basename "$bin")] control: a legitimate session id is accepted" "yes" "$ctl"
    d2099t_setup_canary
    before_wf=$(d2099t_snapshot "$WORKFLOW_DIR")
    before_out=$(d2099t_snapshot "$D2099T_OUTSIDE")

    while IFS='|' read -r label payload; do
        [ -n "$label" ] || continue
        payload=$(printf '%s' "$payload" | sed "s#D2099T_CANARY#$D2099T_OUTSIDE/pwned-$label#")
        got=$(d2099t_attack "$bin" "$payload")
        case "$got" in
            rc=0*) fail "TA-$label [$(basename "$bin")] accepted a hostile session id (exit 0): [$payload]" ;;
            *receipt=yes) fail "TA-$label [$(basename "$bin")] printed a success receipt while failing: [$payload]" ;;
            *)
                if [ "$ctl" = "yes" ]; then
                    pass "TA-$label [$(basename "$bin")] rejects [$payload] ($got)"
                else
                    fail "TA-$label [$(basename "$bin")] unattributable: it rejects a legitimate session id too, so [$payload] proves no validation"
                fi
                ;;
        esac
    done <<EOF
$D2099T_PAYLOADS
EOF

    after_wf=$(d2099t_snapshot "$WORKFLOW_DIR")
    after_out=$(d2099t_snapshot "$D2099T_OUTSIDE")
    assert_eq "TA-WF [$(basename "$bin")] the whole workflow state dir is byte-identical after the attack corpus" \
        "$before_wf" "$after_wf"
    assert_eq "TA-OUT [$(basename "$bin")] the out-of-tree canary tree is byte-identical after the attack corpus" \
        "$before_out" "$after_out"
}

# Every CLI that takes a session id gets the same corpus (CPR-ORTH): a validator
# living in only one of them is the bug this catches.
d2099t_session_traversal() {
    d2099t_run_corpus "$BIN_RECORD"
    d2099t_run_corpus "$BIN_READ"
    d2099t_run_corpus "$BIN_RECORD_SKIP"
}

# One --stage invocation, routed to whichever CLI takes that flag: the reader
# resolves a stored record for a session, the deriver computes a level from an
# explicit signal csv. Same hostile string, two entry points (CPR-ORTH).
d2099t_stage_invoke() {
    local bin="$1" sid="$2" stage="$3"
    case "$bin" in
        "$BIN_DERIVE")
            run_with_timeout node "$bin" --stage "$stage" --signals "S1-multi-file" 2>&1 ;;
        *)
            run_with_timeout node "$bin" --session "$sid" --stage "$stage" 2>&1 ;;
    esac
}

# TA-STAGE: --stage is the other #2099 path-shaped input. It names a routing row,
# never a file, so the same payloads must be refused without touching anything.
# derive-complexity-level is in the loop because it is the NEW CLI taking this
# very argument: a validator that lives only in the reader is the bug caught here.
d2099t_stage_corpus() {
    local bin="$1" tag="$2" label payload rc out ctl before_wf after_wf before_out after_out sid
    ctl=$(d2099t_stage_control "$bin")
    assert_eq "TA-STAGE-CTL [$tag] control: the legitimate stage 'detail' is accepted and answers with a level" \
        "yes" "$ctl"
    d2099t_setup_canary
    sid=$(new_session tastage)
    before_wf=$(d2099t_snapshot "$WORKFLOW_DIR")
    before_out=$(d2099t_snapshot "$D2099T_OUTSIDE")

    while IFS='|' read -r label payload; do
        [ -n "$label" ] || continue
        payload=$(printf '%s' "$payload" | sed "s#D2099T_CANARY#$D2099T_OUTSIDE/stage-$label#")
        rc=0
        out=$(d2099t_stage_invoke "$bin" "$sid" "$payload") || rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$ctl" != "yes" ]; then
                fail "TA-STAGE-$label [$tag] unattributable: --stage detail is rejected too, so [$payload] proves no validation"
            else
                pass "TA-STAGE-$label [$tag] rejects --stage [$payload] (exit $rc)"
            fi
        elif [ "$bin" = "$BIN_DERIVE" ] && [ "${out#*DERIVATION_UNAVAILABLE}" != "$out" ] \
             && [ "${out#*level=high}" != "$out" ]; then
            # D4's documented fail-open is a sanctioned exit 0 — but only in the
            # loud shape: the marker on stderr AND the safe level. Not a quiet ok.
            pass "TA-STAGE-$label [$tag] refuses to route [$payload], failing open loudly to level=high"
        else
            fail "TA-STAGE-$label [$tag] ACCEPTED --stage [$payload] — not a routing stage. Output: [$out]"
        fi
    done <<EOF
$D2099T_PAYLOADS
EOF

    after_wf=$(d2099t_snapshot "$WORKFLOW_DIR")
    after_out=$(d2099t_snapshot "$D2099T_OUTSIDE")
    assert_eq "TA-STAGE-WF [$tag] the workflow state dir is byte-identical after the --stage corpus" \
        "$before_wf" "$after_wf"
    assert_eq "TA-STAGE-OUT [$tag] the out-of-tree canary tree is byte-identical after the --stage corpus" \
        "$before_out" "$after_out"
}

# The sanctioned half for --stage: a real stage name must not merely be "not
# rejected" — it must answer in the exact documented protocol (D4), so a CLI that
# refuses everything cannot make the corpus above green for free.
d2099t_stage_control() {
    local bin="$1" sid rc=0 out first
    sid=$(new_session tastagectl)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S3-security" >/dev/null 2>&1
    out=$(d2099t_stage_invoke "$bin" "$sid" detail) || rc=$?
    first=$(printf '%s\n' "$out" | head -1)
    if [ "$rc" -ne 0 ]; then
        echo "no rc=$rc out=[$out]"
    elif [ "$first" = "level=high" ] || [ "$first" = "level=low" ] || [ "$first" = "NONE" ]; then
        echo yes
    else
        echo "no first-line=[$first]"
    fi
}

d2099t_stage_traversal() {
    d2099t_stage_corpus "$BIN_READ" "read-complexity-evaluation"
    d2099t_stage_corpus "$BIN_DERIVE" "derive-complexity-level"
}

# TA-STAGE-OK: the sanctioned half. Each D1 routing stage must answer in the
# documented level= protocol — otherwise "rejects everything" would make the
# corpus above green for free. S5-breaking is the probe because D2 escalates it
# at all three stages, so one expected value stays honest across the row.
d2099t_stage_sanctioned() {
    local st rc out
    for st in detail write_tests write_code; do
        rc=0
        out=$(run_with_timeout node "$BIN_DERIVE" --stage "$st" --signals "S5-breaking" 2>&1) || rc=$?
        assert_eq "TA-STAGE-OK-$st derive-complexity-level accepts the real stage [$st] (exit 0)" "0" "$rc"
        assert_eq "TA-STAGE-OK-$st ... answering in the documented level= protocol for S5-breaking" \
            "level=high" "$(printf '%s\n' "$out" | head -1)"
    done
}

# --- TA-OK: the sanctioned half (test-design.md Pattern 4) -------------------
# `-` and `_` are allowed session-id characters, and the corpus above only ever
# shows what gets REFUSED. A validator written as a blunt "reject anything with
# punctuation" would pass every case above while breaking real sessions, so the
# legitimate edge placements — leading, trailing, doubled — are asserted to
# round-trip. These are NOT the traversal payloads in another costume: they name
# no parent, no root, no shell metacharacter.
D2099T_SANCTIONED='lead-dash|-d2099edge
trail-dash|d2099edge-
lead-underscore|_d2099edge
trail-underscore|d2099edge_
double-dash|d2099--edge--x
double-underscore|d2099__edge__x
both-edges|_d2099-edge-_
long-run|d2099___---edge'

d2099t_mk_session() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const sid = process.env.SID;
// writeState, not createInitialState alone: the latter materializes no file
// (state-io/core.js). Mirrors new_session (round-9 C3).
b.writeState(sid, b.createInitialState(sid));
' >/dev/null 2>&1 || true
}

d2099t_sanctioned_session_ids() {
    local label sid rc out lvl
    while IFS='|' read -r label sid; do
        [ -n "$label" ] || continue
        d2099t_mk_session "$sid"

        rc=0
        # S2-architecture, not S3-security: this case reads back through
        # `--stage detail`, and detail's escalation sets contain S2 but not S3
        # (detail.md D2), so only S2 makes the round-trip level high. S3 would
        # read back low and the assertion below would fail for a reason that has
        # nothing to do with session-id handling.
        out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S2-architecture" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "TA-OK-$label a sanctioned session id [$sid] was REJECTED by record (exit $rc) — '-' and '_' at edges are legal, not an attack. Output: [$out]"
            continue
        fi
        assert_contains "TA-OK-$label record accepts the sanctioned session id [$sid]" \
            "RECORDED_COMPLEXITY" "$out"

        # Round-trip: the record has to be findable under the same id, and carry
        # the level the signal implies — proving it was stored where it belongs
        # rather than under some sanitized-away variant of the id.
        lvl=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null | head -1)
        assert_eq "TA-OK-$label ... and reads back under the very same id" "level=high" "$lvl"
        assert_eq "TA-OK-$label ... having appended exactly one evaluation" \
            "ce=1 skip=0" "$(d2099_side_effects "$sid")"
    done <<EOF
$D2099T_SANCTIONED
EOF
}

d2099t_session_traversal
d2099t_stage_traversal
d2099t_stage_sanctioned
d2099t_sanctioned_session_ids
