#!/usr/bin/env bash
# tests/fix-1780-round12-cli-lifecycle.sh
# Tests: bin/request-off-clearance
# Tags: off-clearance, mint, examination, cli-contract, session-id, exit-codes, workflow-dir, audit, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The real codex examiner. Every verdict here comes from a PATH stub, so the
#   examiner's own prompt-following, latency and JSON discipline are out of scope;
#   what is asserted is the SCRIPT's contract around whatever comes back.
# - A real 180s wall-clock timeout. The timeout branch is driven by a stub that
#   exits 124/142 (the two codes bin/run-with-timeout.sh can produce), not by
#   actually waiting three minutes.
# - Real 0600 enforcement. Git Bash on Windows reports emulated permissions, so
#   the mode assertion is deliberately absent here (it lives in
#   tests/fix-1780-round4-mint-schema.sh S10, which skips on this platform).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1658 / #1608 / #1780 round-12)
#
# bin/request-off-clearance is the ONLY thing standing between "the model wants
# the workflow switched off" and a token that lets an OFF sentinel reach the
# human approval prompt. Its sibling suites all enter through one happy path
# (SESSION_ID set, args valid, examiner present) and assert what happens AFTER
# the verdict. Everything BEFORE the verdict — argument validation, the
# required-env gate, sid resolution, the canonical workflow-dir resolution, and
# the exit code / channel each failure mode reports on — was asserted nowhere,
# even though those are precisely the paths that decide WHETHER a token can be
# minted and WHERE it lands.
#
# The three properties this file pins, each on its own (CPR-SC):
#   A  REFUSALS ARE TOTAL. Every rejected invocation exits non-zero, mints
#      nothing, and — for the argument/env/sid gates — never even reaches the
#      examiner. An exit-0 refusal or a silently-minted token is the whole bug.
#   B  THE SID DECIDES THE FILENAME. The token is session-scoped; if sid
#      resolution picks a different source than the shim's, the token is minted
#      where nothing will look for it (#1658 in its bash form).
#   C  CHANNELS AND CODES ARE PART OF THE CONTRACT. stdout carries the verdict
#      narrative; stderr carries operator alarms. A caller that cannot tell
#      ALLOW from REJECT from "examiner broken" cannot fail closed.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib/request-off-clearance-harness.sh
. "$AGENTS_DIR/tests/lib/request-off-clearance-harness.sh"

offclr_require_script

# ===========================================================================
# A - ARGUMENT VALIDATION. Table-driven per skills/_shared/test-design/parser-regex-tests.md:
# one row per malformed invocation, all asserted the same way, so a new
# validation rule is one row and a dropped rule is one visible failure.
#
# Each row asserts THREE things at once, because any one of them alone is
# satisfiable by a broken script: the exit code (callers branch on it), the
# stderr diagnostic (operators read it), and — the security-relevant one — that
# the examiner was NEVER INVOKED. A script that validates after shelling out has
# already spent a codex call and, worse, already interpolated unvalidated input
# into a prompt.
# ===========================================================================
run_A_argument_validation() {
    local tmp tn probe rows row args want_rc want_err label invoked
    # rows: <label>|<want_rc>|<stderr regex>|<args...>
    rows='no arguments at all|2|--target must be workflow or worktree|
unknown target value|2|--target must be workflow or worktree|--target sideways --category cleanup --detail x
target given, category missing|2|--category must be one of|--target workflow --detail x
unknown category value|2|--category must be one of|--target workflow --category please --detail x
unknown urgency value|2|--urgency must be normal or urgent|--target workflow --category cleanup --urgency LOUD --detail x
detail missing|2|--detail is required|--target workflow --category cleanup
unknown flag|2|unknown argument|--target workflow --category cleanup --detail x --force
bare positional argument|2|unknown argument|--target workflow --category cleanup --detail x extra'

    while IFS='|' read -r label want_rc want_err args; do
        [ -n "$label" ] || continue
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        probe="$tmp/examiner-was-invoked"
        # The stub records that it ran BEFORE emitting anything, so "the examiner
        # was reached" is observable even when its output is discarded.
        REQ_SID="a-sid"
        # shellcheck disable=SC2086
        run_req "$tn" "#!/usr/bin/env bash
touch '$probe'
exit 0
" $args
        invoked="no"; [ -f "$probe" ] && invoked="yes"
        local ok=1
        [ "$RC" = "$want_rc" ] || ok=0
        echo "$ERR" | grep -qE -- "$want_err" || ok=0
        [ "$(token_count "$tmp")" -eq 0 ] || ok=0
        [ "$invoked" = "no" ] || ok=0
        if [ "$ok" = "1" ]; then
            pass "A [$label] -> exit $want_rc, diagnosed on stderr, examiner never invoked, NO token"
        else
            fail "A [$label] -> want rc=$want_rc/err~$want_err/examiner=no/tokens=0; got rc=$RC invoked=$invoked tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR") out=$(printf '%q' "$OUT")"
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done <<< "$rows"

    # An explicitly EMPTY --detail is diagnosed like a missing one: the prompt's
    # data section would otherwise be blank and the examiner asked to rule on
    # nothing. Kept out of the table above because a table row cannot carry an
    # empty word through unquoted expansion.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    probe="$tmp/examiner-was-invoked"
    REQ_SID="a-sid"
    run_req "$tn" "#!/usr/bin/env bash
touch '$probe'
exit 0
" --target workflow --category cleanup --detail ""
    if [ "$RC" -eq 2 ] && echo "$ERR" | grep -q -- "--detail is required" && [ ! -f "$probe" ] && [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "A [--detail \"\"] empty detail -> exit 2, diagnosed on stderr, examiner never invoked, NO token"
    else
        fail "A [--detail \"\"] want rc=2 + '--detail is required' + no examiner; got rc=$RC err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # A TRAILING flag with no value (`... --detail` at the end of argv) is a
    # separate shape: `shift 2` with one argument left fails, and `set -e` aborts
    # the script before the validation block can name the problem. What is
    # asserted here is therefore only what the security contract requires —
    # fail-CLOSED: non-zero, no examiner call, no token. The MISSING diagnostic on
    # this path is a known rough edge, deliberately not blessed by an assertion on
    # the (empty) stderr text.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    probe="$tmp/examiner-was-invoked"
    REQ_SID="a-sid"
    run_req "$tn" "#!/usr/bin/env bash
touch '$probe'
exit 0
" --target workflow --category cleanup --detail
    if [ "$RC" -ne 0 ] && [ ! -f "$probe" ] && [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "A [trailing --detail with no value] -> fails CLOSED: non-zero, examiner never invoked, NO token"
    else
        fail "A [trailing --detail with no value] want non-zero + no examiner + no token; got rc=$RC tokens=$(token_count "$tmp")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # --help is the one non-error early exit: usage on stderr, exit 0, no examiner.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    probe="$tmp/examiner-was-invoked"
    REQ_SID="a-sid"
    run_req "$tn" "#!/usr/bin/env bash
touch '$probe'
exit 0
" --help
    if [ "$RC" -eq 0 ] && echo "$ERR" | grep -q "usage: request-off-clearance" && [ ! -f "$probe" ]; then
        pass "A [--help] -> exit 0 with usage on stderr, examiner never invoked"
    else
        fail "A [--help] -> want rc=0 + usage on stderr + no examiner; got rc=$RC err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# B - REQUIRED ENV + SESSION-ID RESOLUTION.
#
# The token's filename IS its session scope. bin/request-off-clearance resolves
# the sid from SESSION_ID, then CLAUDE_CODE_SESSION_ID, then CLAUDE_SESSION_ID,
# then WORKTREE_NOTES.md — a four-source precedence chain that nothing asserted.
# Each source is exercised alone (so precedence cannot be faked by a script that
# reads only one of them) and the precedence order is exercised with all three
# set to DIFFERENT values.
# ===========================================================================
run_B_env_and_sid() {
    local tmp tn notes

    # B1 AGENTS_CONFIG_DIR is a hard precondition: without it the script cannot
    # even resolve the canonical workflow dir, so it must refuse before anything.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="b1sid"; REQ_NO_CONFIG_DIR=1
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    if [ "$RC" -eq 1 ] && echo "$ERR" | grep -q "AGENTS_CONFIG_DIR not set" && [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "B1 AGENTS_CONFIG_DIR unset -> exit 1 on stderr, NO token"
    else
        fail "B1 want rc=1 + 'AGENTS_CONFIG_DIR not set' + no token; got rc=$RC tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # B2-B4 each sid source ALONE mints under exactly that sid.
    local src val
    for src in SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID; do
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        val="sid-from-$(echo "$src" | tr '[:upper:]' '[:lower:]')"
        REQ_ENV=("$src=$val")
        run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
        if [ -f "$tmp/$val.off-clearance" ] && [ "$(token_count "$tmp")" -eq 1 ]; then
            pass "B2 sid source $src alone -> token minted at <$val>.off-clearance"
        else
            fail "B2 sid source $src alone did not name the token; rc=$RC files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ') out=$(printf '%q' "$OUT")"
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done

    # B5 precedence: all three set to DIFFERENT values, SESSION_ID must win, then
    # CLAUDE_CODE_SESSION_ID. Asserted as "exactly one token, and it is that one" —
    # a script that minted under two sids would also satisfy a bare -f check.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_ENV=("SESSION_ID=prec-first" "CLAUDE_CODE_SESSION_ID=prec-second" "CLAUDE_SESSION_ID=prec-third")
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    if [ -f "$tmp/prec-first.off-clearance" ] && [ "$(token_count "$tmp")" -eq 1 ]; then
        pass "B5a SESSION_ID outranks CLAUDE_CODE_SESSION_ID and CLAUDE_SESSION_ID"
    else
        fail "B5a precedence wrong; files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_ENV=("CLAUDE_CODE_SESSION_ID=prec-second" "CLAUDE_SESSION_ID=prec-third")
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    if [ -f "$tmp/prec-second.off-clearance" ] && [ "$(token_count "$tmp")" -eq 1 ]; then
        pass "B5b CLAUDE_CODE_SESSION_ID outranks CLAUDE_SESSION_ID"
    else
        fail "B5b precedence wrong; files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # B6 WORKTREE_NOTES.md fallback, from $PWD. The CR is deliberate: the notes
    # file is authored on Windows and the sid is used as a FILENAME, so a stray
    # \r would mint a token no reader can name.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    notes=$(make_tmp)
    printf 'Session-ID: notes-sid-42\r\nOther: x\n' > "$notes/WORKTREE_NOTES.md"
    REQ_CWD="$notes"
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    if [ -f "$tmp/notes-sid-42.off-clearance" ] && [ "$(token_count "$tmp")" -eq 1 ]; then
        pass "B6 no sid env vars -> WORKTREE_NOTES.md in \$PWD supplies the sid (CR stripped)"
    else
        fail "B6 notes fallback did not supply the sid; rc=$RC files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ') err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" "$notes" 2>/dev/null || true

    # B7 WORKTREE_PATH redirects the notes lookup away from $PWD.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    notes=$(make_tmp)
    printf 'Session-ID: wtpath-sid\n' > "$notes/WORKTREE_NOTES.md"
    REQ_ENV=("WORKTREE_PATH=$notes")
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    if [ -f "$tmp/wtpath-sid.off-clearance" ]; then
        pass "B7 WORKTREE_PATH points the WORKTREE_NOTES.md lookup at the worktree, not \$PWD"
    else
        fail "B7 WORKTREE_PATH notes lookup failed; rc=$RC files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -r -f "$tmp" "$notes" 2>/dev/null || true

    # B8 no sid anywhere -> refuse. Fail-closed: an unresolvable sid must not
    # degrade into a shared/global token.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    if [ "$RC" -eq 1 ] && echo "$ERR" | grep -q "session id unresolvable" && [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "B8 sid unresolvable from every source -> exit 1, NO token"
    else
        fail "B8 want rc=1 + 'session id unresolvable' + no token; got rc=$RC tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # B9 a sid that is not [A-Za-z0-9_-]+ is a path-traversal / filename hazard,
    # so it is refused rather than sanitised. Table-driven over the shapes that
    # matter: separators, traversal, spaces, and an absolute path.
    local bad
    for bad in 'has space' '../escape' 'a/b' 'sid;rm' '..' '/tmp/abs'; do
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        REQ_ENV=("SESSION_ID=$bad")
        run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
        if [ "$RC" -eq 1 ] && echo "$ERR" | grep -qE "session id unresolvable or malformed" && [ "$(token_count "$tmp")" -eq 0 ]; then
            pass "B9 [$bad] malformed sid -> exit 1, NO token (no path-shaped filename accepted)"
        else
            fail "B9 [$bad] want rc=1 + malformed diagnostic + no token; got rc=$RC tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR")"
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done
}

# ===========================================================================
# C - THE ALLOW PATH, END TO END through the canonical getWorkflowDir().
#
# #1658's whole point is that the mint location is resolved by the SAME
# getWorkflowDir() the shim reads, not by a bash-side re-implementation. So the
# assertion is not "a token exists somewhere" but "the token is at the exact
# path the script announced, inside the pinned CLAUDE_WORKFLOW_DIR, and nowhere
# else" — plus the operator-facing surface (exit code, clean stderr, the
# category-binding instruction, and the correctly UPPERCASED sentinel name for
# each target).
# ===========================================================================
run_C_allow_surface() {
    local tmp tn target upper announced
    for target in workflow worktree; do
        upper="$(echo "$target" | tr '[:lower:]' '[:upper:]')"
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        REQ_SID="c-$target"
        run_req "$tn" "$(allow_stub 'the examiner said so')" \
            --target "$target" --category trivial-change --urgency urgent --detail "one-line typo"
        local ok=1
        [ "$RC" -eq 0 ] || ok=0
        [ -z "$ERR" ] || ok=0
        [ "$(token_count "$tmp")" -eq 1 ] || ok=0
        [ -f "$tmp/c-$target.off-clearance" ] || ok=0
        echo "$OUT" | grep -q "Examiner verdict: ALLOW" || ok=0
        echo "$OUT" | grep -q "single-use, expires in 15 minutes" || ok=0
        echo "$OUT" | grep -q "\[trivial-change\]" || ok=0
        echo "$OUT" | grep -q "WORKFLOW_ENFORCE_${upper}_OFF:" || ok=0
        # the announced path must BE the file, not a plausible-looking string
        announced="$(echo "$OUT" | sed -n 's/^Clearance token minted: \(.*\) (single-use.*/\1/p')"
        [ -n "$announced" ] && [ -f "$announced" ] || ok=0
        # and the token's own fields must echo THIS request
        [ "$(offclr_json "$tmp/c-$target.off-clearance" 't.target')" = "$target" ] || ok=0
        [ "$(offclr_json "$tmp/c-$target.off-clearance" 't.urgency')" = "urgent" ] || ok=0
        if [ "$ok" = "1" ]; then
            pass "C [$target] ALLOW -> exit 0, empty stderr, token at the ANNOUNCED path under CLAUDE_WORKFLOW_DIR, ${upper}_OFF guidance"
        else
            fail "C [$target] ALLOW surface wrong; rc=$RC tokens=$(token_count "$tmp") announced=$(printf '%q' "$announced") err=$(printf '%q' "$ERR") out=$(printf '%q' "$OUT")"
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done

    # C3 the audit trail is written under the SAME sid the token is named for —
    # an examination recorded under a different sid is unauditable.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="c3sid"
    run_req "$tn" "$(allow_stub 'audited allow')" --target workflow --category workflow-bug --detail "bug"
    if [ -f "$tmp/c3sid-supervisor-state.json" ] && grep -q "off_examination" "$tmp/c3sid-supervisor-state.json" \
       && grep -q "verdict=ALLOW" "$tmp/c3sid-supervisor-state.json"; then
        pass "C3 ALLOW appends an off_examination finding under the SAME sid as the token"
    else
        fail "C3 audit entry missing/misfiled; files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# D - EVERY NON-ALLOW OUTCOME. Table-driven over the five ways the examination
# can end without a grant, asserting the trio a caller actually branches on:
# exit code, the narrative channel, and (always) zero tokens.
#
# They are separate rows and not one "it rejected" assertion because they are
# operationally different events: a REJECT is a decision, a timeout/crash is a
# broken examiner, and only the latter may point the operator at the EMERGENCY
# sentinel. Collapsing them would let a broken examiner read as a policy
# decision — or, worse, let a policy REJECT advertise the emergency bypass.
# ===========================================================================
run_D_refusal_matrix() {
    local tmp tn label ok

    # D1 authentic REJECT: a decision. No emergency hint, no stderr alarm.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="d1sid"
    run_req "$tn" "$(reject_stub 'use /sweep-worktrees instead')" --target worktree --category cleanup --detail "leftovers"
    ok=1
    [ "$RC" -ne 0 ] || ok=0
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$OUT" | grep -q "Examiner verdict: REJECT" || ok=0
    echo "$OUT" | grep -q "No clearance token minted" || ok=0
    echo "$OUT" | grep -q "use /sweep-worktrees instead" || ok=0
    ! echo "$OUT$ERR" | grep -q "EMERGENCY" || ok=0
    grep -q "verdict=REJECT" "$tmp/d1sid-supervisor-state.json" 2>/dev/null || ok=0
    if [ "$ok" = "1" ]; then
        pass "D1 authentic REJECT -> non-zero, examiner's reason on stdout, audited, NO emergency hint, NO token"
    else
        fail "D1 REJECT surface wrong; rc=$RC tokens=$(token_count "$tmp") out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # D2/D3 the two timeout exit codes bin/run-with-timeout.sh can produce
    # (124 = GNU timeout, 142 = 128+SIGALRM perl fallback). Both must land on the
    # timeout branch; a suite that only covers 124 leaves the macOS/perl path
    # falling through to the generic "examiner failed" message.
    local code
    for code in 124 142; do
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        REQ_SID="d-$code"
        run_req "$tn" "#!/usr/bin/env bash
exit $code
" --target workflow --category workflow-bug --detail "bug"
        ok=1
        [ "$RC" -ne 0 ] || ok=0
        [ "$(token_count "$tmp")" -eq 0 ] || ok=0
        echo "$OUT" | grep -q "examiner timed out after 180s" || ok=0
        echo "$OUT" | grep -q "WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY" || ok=0
        grep -q "timed out" "$tmp/d-$code-supervisor-state.json" 2>/dev/null || ok=0
        if [ "$ok" = "1" ]; then
            pass "D2 examiner exit $code -> timeout REJECT, audited, emergency escalation offered, NO token"
        else
            fail "D2 exit $code did not take the timeout branch; rc=$RC out=$(printf '%q' "$OUT")"
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done

    # D4 a crashing examiner: UNAVAILABLE, and its stderr is relayed to the
    # operator's stderr (not swallowed, and not mixed into stdout where the
    # verdict lives).
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="d4sid"
    run_req "$tn" "#!/usr/bin/env bash
echo 'codex: model overloaded' >&2
exit 7
" --target workflow --category workflow-bug --detail "bug"
    ok=1
    [ "$RC" -ne 0 ] || ok=0
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$OUT" | grep -q "Examiner failed (exit 7)" || ok=0
    echo "$ERR" | grep -q -- "--- examiner stderr ---" || ok=0
    echo "$ERR" | grep -q "model overloaded" || ok=0
    ! echo "$OUT" | grep -q "model overloaded" || ok=0
    grep -q "exited 7" "$tmp/d4sid-supervisor-state.json" 2>/dev/null || ok=0
    if [ "$ok" = "1" ]; then
        pass "D4 examiner exit 7 -> UNAVAILABLE, its stderr relayed on STDERR only, audited, NO token"
    else
        fail "D4 crash surface wrong; rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # D5 no examiner on PATH at all.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="d5sid"; REQ_NO_EXAMINER=1
    run_req "$tn" "" --target worktree --category cleanup --detail "leftovers"
    ok=1
    [ "$RC" -ne 0 ] || ok=0
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$OUT" | grep -q "codex not found on PATH" || ok=0
    echo "$OUT" | grep -q "WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY" || ok=0
    grep -q "not found on PATH" "$tmp/d5sid-supervisor-state.json" 2>/dev/null || ok=0
    if [ "$ok" = "1" ]; then
        pass "D5 codex absent from PATH -> UNAVAILABLE, audited, WORKTREE emergency escalation offered, NO token"
    else
        fail "D5 absent-examiner surface wrong; rc=$RC out=$(printf '%q' "$OUT") files=$(ls "$tmp" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # D6 the missing timeout wrapper is a REFUSAL, not a fallback to an unbounded
    # codex call. Simulated by pointing BASH_SOURCE's dirname at a copy of the
    # script with no run-with-timeout.sh beside it.
    local fakebin
    fakebin=$(make_tmp)
    cp "$OFFCLR_REQ" "$fakebin/request-off-clearance"
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="d6sid"
    local saved="$OFFCLR_REQ"
    OFFCLR_REQ="$fakebin/request-off-clearance"
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    OFFCLR_REQ="$saved"
    ok=1
    [ "$RC" -ne 0 ] || ok=0
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$ERR" | grep -q "timeout wrapper not found" || ok=0
    if [ "$ok" = "1" ]; then
        pass "D6 run-with-timeout.sh missing -> UNAVAILABLE, NO token (never an unbounded examiner call)"
    else
        fail "D6 missing-wrapper surface wrong; rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" "$fakebin" 2>/dev/null || true
}

run_A_argument_validation
run_B_env_and_sid
run_C_allow_surface
run_D_refusal_matrix

offclr_report
