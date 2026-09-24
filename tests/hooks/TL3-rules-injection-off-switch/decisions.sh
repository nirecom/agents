# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, off-switch, instructions-loaded, gate-decisions, TL3, scope:common
#
# Pure-function gate decision logic for TL3-rules-injection-off-switch (no filesystem,
# no subprocess). Split out of helpers.sh to stay under the 300-line WARN threshold
# (rules/coding/file-split.md); helpers.sh sources this file, so every consumer keeps
# these functions. Exercised at TL2 by tests/cc-tl3-rules-injection-gate.sh, whose TL3
# body is RUN_TL3-gated and skips on ordinary runs — without this seam it never runs.

# ril_rc_label <rc> — human-readable cause for a non-zero subprocess exit.
ril_rc_label() {
    case "$1" in
        0)        echo "ok" ;;
        124|137)  echo "timed out" ;;
        77)       echo "skipped" ;;
        90)       echo "could not enter the fixture repo" ;;
        *)        echo "non-zero exit" ;;
    esac
}

# ril_gate_base_status <base_rc> <dir_exists:0|1> <n_entries> <target_seen:0|1>
# Echoes "OK" or "INCONCLUSIVE <reason text>".
# C4: the subprocess result is gated FIRST. A crashed or timed-out RUN-BASE can still
# have left a partial receipt set, and EXPECTED_SET / S / W derived from it would make
# every later absence claim rest on an unknown baseline.
ril_gate_base_status() {
    local rc="$1"
    local dir_exists="$2"
    local n="$3"
    local target_seen="$4"
    if [ "$rc" != "0" ]; then
        echo "INCONCLUSIVE RUN-BASE subprocess exited $rc ($(ril_rc_label "$rc")) — EXPECTED_SET/S/W would be derived from a partial run"
    elif [ "$dir_exists" != "1" ]; then
        echo "INCONCLUSIVE receipt dir absent — the InstructionsLoaded hook never fired (event name or registration wrong)"
    elif [ "${n:-0}" -lt 1 ] 2>/dev/null; then
        echo "INCONCLUSIVE receipt dir exists but holds no entries"
    elif [ "$target_seen" != "1" ]; then
        echo "INCONCLUSIVE probe-target.md has no receipt in RUN-BASE — the negative claim in G3 would be unanchored"
    else
        echo "OK"
    fi
}

# ril_gate_judge_verdict <judge_rc> <target_seen:0|1> <quiescence_status> <target_seen_after:0|1>
# Echoes "G-FAIL <reason>" | "G-INCONCLUSIVE <reason>" | "G-PASS-PENDING <reason>".
# Asymmetry is preserved: a positive observation is decisive on its own and is
# evaluated BEFORE the rc gate; absence requires a completed subprocess AND quiescence.
ril_gate_judge_verdict() {
    local rc="$1"
    local seen="$2"
    local qstatus="$3"
    local seen_after="$4"
    if [ "$seen" = "1" ]; then
        echo "G-FAIL probe-target.md was injected despite the reserved glob — the off-switch is fail-open"
    elif [ "$rc" != "0" ]; then
        echo "G-INCONCLUSIVE RUN-JUDGE subprocess exited $rc ($(ril_rc_label "$rc")) — absence cannot be distinguished from a run that never completed"
    elif [ "$qstatus" != "OK" ]; then
        echo "G-INCONCLUSIVE quiescence not reached (STATUS=$qstatus) — firing completion is unproven, so absence proves nothing"
    elif [ "$seen_after" = "1" ]; then
        echo "G-FAIL probe-target.md arrived during the stability window — the off-switch is fail-open"
    else
        echo "G-PASS-PENDING Q1+Q2 satisfied and probe-target.md has no receipt"
    fi
}

# ril_f1_verdict <rc> <model-output>
# Echoes "F1-PASS <reason>" | "F1-FAIL <reason>" | "F1-INCONCLUSIVE <reason>".
# Fallback: asks the model whether two nonces are in context, reached only when the
# receipt route yields no payload. Self-report, so parsed STRICTLY: subprocess must
# exit 0 AND output must hold exactly two `present`/`absent` tokens in order (control
# first, probe second) — extra/missing tokens or a crashed/timed-out probe is
# INCONCLUSIVE, never a pass (unlike a loose `present.*absent` match, which would grade
# a refusal or echo as clean). Vocabulary is disjoint from the gate's: no F1 outcome
# yields G-PASS — it's diagnostic about WHY nothing came back, not a filesystem fact.
ril_f1_verdict() {
    local rc="$1"
    local out="$2"
    local toks n
    if [ "$rc" != "0" ]; then
        echo "F1-INCONCLUSIVE model probe exited $rc ($(ril_rc_label "$rc")) — its answer describes an interrupted run"
        return
    fi
    toks="$(printf '%s' "$out" | tr 'A-Z' 'a-z' | tr -c 'a-z' '\n' | grep -xE 'present|absent' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    set -- $toks
    n=$#
    if [ "$n" -ne 2 ]; then
        echo "F1-INCONCLUSIVE want exactly two present/absent tokens, found $n ($toks) — the answer is not parseable"
        return
    fi
    # The two tokens must be ADJACENT in the answer's word stream. "present absent" and
    # {"result":"present absent"} are answers; "both are present; neither is absent" is
    # prose that happens to contain the same two words in the same order, and grading it
    # as a pass is exactly the loose-match defect this parser replaced.
    local words first second
    words="$(printf '%s' "$out" | tr 'A-Z' 'a-z' | tr -c 'a-z' '\n' | grep -v '^$' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    first="$(printf '%s\n' $words | grep -nxE 'present|absent' | head -1 | cut -d: -f1)"
    # shellcheck disable=SC2086
    second="$(printf '%s\n' $words | grep -nxE 'present|absent' | sed -n 2p | cut -d: -f1)"
    if [ -z "$first" ] || [ -z "$second" ] || [ "$((second - first))" -ne 1 ]; then
        echo "F1-INCONCLUSIVE the two tokens are separated by other words — the answer is prose, not a verdict"
        return
    fi
    if [ "$1" != "present" ]; then
        echo "F1-INCONCLUSIVE the control nonce reported '$1' — with no control in context the probe is unanchored"
    elif [ "$2" = "absent" ]; then
        echo "F1-PASS control present and the reserved-glob probe absent"
    else
        echo "F1-FAIL the reserved-glob probe body is still in context"
    fi
}

# --- post-quiescence orchestration (C5) -------------------------------------------
# G4/G5 used to run as independent `if` blocks in main.sh, each printing pass/fail while RIL_VERDICT stayed
# G-PASS-PENDING — a failing G4 left G5 free to print the pass token on an already-failed run. Fixed as one
# sticky state machine here (not main.sh) so the TL2 sibling can force each branch to fail. Contract: verdict
# is monotone (never re-enters G-PASS-PENDING); bare `G-PASS` appears ONLY when every check held; failure
# REASON never contains that token (says "the pending pass is retracted" instead), so a grep for it can be
# trusted.
# ril_post_quiescence <pending> <ctrl_verdict> <target_verdict> <q3_seen:0|1> <q3_elapsed_sec> <q3_required_sec>
# Emits `PASS <text>` / `FAIL <text>` / `NOTE <text>` lines, then `VERDICT=<token>`.
ril_post_quiescence() {
    local pending="$1" ctrl="$2" target="$3" q3_seen="$4" q3_elapsed="$5" q3_required="$6"
    local final="$pending"

    if [ -z "$final" ] || [ "$final" = "G-INCONCLUSIVE" ]; then
        echo "NOTE G4/G5 not reached — the judge run never produced a usable observation"
        echo "VERDICT=${final:-G-INCONCLUSIVE}"
        return
    fi

    # G4a: the deliberately frontmatter-less control probe must classify S-MISSING.
    if [ "$ctrl" = "S-MISSING" ]; then
        echo "PASS G4. probe-control-1.md (no frontmatter, unlisted) recorded verdict S-MISSING"
    else
        echo "FAIL G4. want verdict S-MISSING for probe-control-1.md, got '$ctrl' — the classifier is wrong, so every verdict read from this run is suspect"
        final="G-FAIL"
    fi

    # G4b: only meaningful when the target actually leaked.
    if [ "$pending" = "G-FAIL" ]; then
        if [ "$target" = "S-LEAK" ]; then
            echo "PASS G4. the leaked target was classified S-LEAK"
        else
            echo "FAIL G4. leaked target must be S-LEAK, got '$target'"
        fi
        final="G-FAIL"
    fi

    # G5 (Q3): the terminal re-read. Reached only while the verdict is still pending —
    # a failed G4 above has already settled it, and re-deciding here is exactly the
    # defect this function replaces.
    if [ "$final" != "G-PASS-PENDING" ]; then
        echo "NOTE G5. terminal re-read skipped — a post-quiescence assertion already failed, so the pending pass is retracted"
        echo "VERDICT=$final"
        return
    fi
    if [ "$q3_seen" = "1" ]; then
        echo "FAIL G5. probe-target.md appeared on the terminal re-read — the pending pass is retracted"
        final="G-FAIL"
    elif [ "${q3_elapsed:-0}" -lt "${q3_required:-30}" ] 2>/dev/null; then
        echo "FAIL G5. the terminal re-read observed only ${q3_elapsed}s of the required ${q3_required}s — a short window cannot tell 'absent' from 'not yet arrived'"
        final="G-INCONCLUSIVE"
    else
        echo "PASS G5. terminal re-read confirms probe-target.md is still absent after ${q3_elapsed}s of continuous observation"
        final="G-PASS"
    fi
    echo "VERDICT=$final"
}
