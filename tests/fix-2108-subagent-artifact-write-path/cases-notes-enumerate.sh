#!/usr/bin/env bash
# Tests: hooks/lib/worktree-notes-session-ids.js, hooks/workflow-state/session-id.js, hooks/lib/resolve-workflow-session-id.js, hooks/block-clearance-token-write.js, hooks/lib/active-session-ids.js, hooks/lib/protected-basenames.js
# Tags: worktree-notes, session-id, transcript-path, git-worktree, enumeration, fail-closed, block-clearance-token-write, cross-module-wiring, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Sections C11 + C14. C11 asserts enumerateWorktreeNotesSessionIds(): EVERY candidate a
# clearance reader could resolve to, deliberately WITHOUT the resolvers' `hits.size > 1`
# ambiguity fail-safe. C14 pins the resolvers' OWN behaviour as unchanged by the helper
# extraction, so that divergence cannot leak back into resolution. Fixtures come from
# cases-worktree-notes.sh, which the aggregator sources first.
run_C11_enumerate() {
    local d out nogit node_abs long sids

    _wtn_setup

    # C11-0 — shape contract. `sids` is an ARRAY (not the Set that
    # observeActiveSessionIds returns), `complete` a boolean.
    d="$WTN_BASE/enum-cwd"
    _wtn_notes "$d" ghost
    out="$(_wtn_in "$d" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"
    assert_eq "C11-0 CWD notes are enumerated, observation complete" "true|ghost-planted-sid" "$out"

    # C11-1 — NOT in a git repo and no notes anywhere. This is an ANSWER, not a fault:
    # the whole existing suite runs its hooks from a non-repo temp CWD and expects
    # artifact stems to be ALLOWED there, which only holds while complete stays true.
    d="$WTN_BASE/enum-bare"
    _wtn_notes "$d" none
    assert_eq "C11-1 no notes, no repo -> empty set, still complete" "true|" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"

    # C11-2 — a notes value the charset gate rejects contributes NOTHING and is not a
    # fault either; otherwise one malformed notes file would fail every write closed.
    d="$WTN_BASE/enum-bad"
    _wtn_notes "$d" slashed
    assert_eq "C11-2 charset-rejected notes value yields no sid and no fault" "true|" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"

    if [ "$WTN_REPO_OK" != yes ]; then
        skip "C11-3..C11-5 need git worktrees (git unavailable or worktree add failed)"
    else
        # C11-3 — THE DIVERGENCE. Two distinct sibling Session-IDs make both resolvers
        # return null (their `hits.size > 1` ambiguity fail-safe). For OBSERVATION that
        # answer is wrong: a reader in either worktree resolves to one of them, so BOTH
        # are clearance-bearing and both must be enumerated.
        _wtn_notes "$WTN_BASE/wt-one" sibone
        _wtn_notes "$WTN_BASE/wt-two" sibtwo
        _wtn_notes "$WTN_REPO" none
        assert_eq "C11-3 two distinct siblings yield BOTH sids (no ambiguity fail-safe)" \
            "true|sib-one-sid,sib-two-sid" \
            "$(_wtn_in "$WTN_REPO" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"

        # C11-4 — no first-hit stop. From inside wt-one the resolvers return at the OWN
        # worktree and never look further; the enumeration must still collect wt-two.
        assert_eq "C11-4 own-worktree hit does not stop the sibling scan" \
            "true|sib-one-sid,sib-two-sid" \
            "$(_wtn_in "$WTN_BASE/wt-one" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"

        # C11-5 — every source unioned and de-duplicated: CWD notes (a subdir of wt-one
        # carrying its own file), own-worktree notes, and both siblings.
        mkdir -p "$WTN_BASE/wt-one/sub"
        _wtn_notes "$WTN_BASE/wt-one/sub" ghost
        assert_eq "C11-5 CWD + own + sibling notes are unioned" \
            "true|ghost-planted-sid,sib-one-sid,sib-two-sid" \
            "$(_wtn_in "$WTN_BASE/wt-one/sub" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"
        rm -rf "$WTN_BASE/wt-one/sub" 2>/dev/null || true
    fi

    # C11-6 — git ABSENT from PATH. This is deliberately NOT asserted as a fault: the
    # resolvers reach git through execSync(), which throws indistinguishably for a
    # missing binary and for "not a git repository", and C11-1 already fixes the latter
    # as an answer. What is pinned here is that the enumeration keeps its contract in
    # that state — it answers in the documented shape, and the CWD notes still count.
    nogit="$WTN_BASE/empty-bin"; mkdir -p "$nogit"
    node_abs="$(command -v node 2>/dev/null)"
    d="$WTN_BASE/enum-nogit"
    _wtn_notes "$d" ghost
    if [ -n "$node_abs" ]; then
        assert_eq "C11-6 git unavailable: still answers, CWD notes still enumerated" \
            "true|ghost-planted-sid" \
            "$(cd "$d" && PATH="$nogit" "$node_abs" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE" 2>/dev/null)"
    else
        skip "C11-6 needs an absolute node path to run with PATH emptied"
    fi
    # SKIPPED: separating "the git binary is missing" from "this is not a git repo".
    # Because: execSync() throws for both with no distinguishing `code`, and treating
    # either as a fault would fail-close every non-repo CWD — including the one the rest
    # of this suite runs from. The fail-closed path is exercised through the state-store
    # faults in C1c/C7 and C12-4 instead.
    # L3 gap: a PATH poisoned in production is observed as an empty worktree list rather
    # than as complete:false, so a planted sibling sid would go unenumerated there.

    # C11-7 — STRING BOUNDARY (test-design.md, "extremely long"). Nothing bounds the
    # agent-written `Session-ID:` value, so what is pinned is BOUNDED, DETERMINISTIC
    # behaviour, inside the probe's 25s budget: a hang or unbounded scan fails the rows.
    d="$WTN_BASE/enum-long"
    mkdir -p "$d"
    long="$(run_probe -e "process.stdout.write('a'.repeat(4096))")"
    assert_eq "C11-7 fixture: the planted value really is 4096 chars" "4096" "${#long}"
    printf 'Session-ID: %s\n' "$long" > "$d/WORKTREE_NOTES.md"
    out="$(_wtn_in "$d" "$PROBE_DIR/wtn-enum-probe.js" "$WT_NOTES_NODE")"
    sids="${out#*|}"
    assert_eq "C11-7 a 4096-char notes sid still answers in shape, complete:true" "true" "${out%%|*}"
    assert_eq "C11-7 it is enumerated whole, as exactly ONE sid" "4096" "${#sids}"
    assert_not_contains "C11-7 the enumeration did not split it into several sids" "," "$sids"

    # The verdict the write guards then reach, via the shared stem probe (its writer is
    # cases-ghost-sid.sh; the aggregator sources every part before any section runs).
    _gs_write_probes
    assert_eq "C11-7 the long planted stem IS clearance-bearing (defined verdict)" "true" \
        "$(_wtn_in "$d" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "$long" clean wsid)"
    assert_eq "C11-7 control: an unrelated stem is still NOT clearance-bearing here" "false" \
        "$(_wtn_in "$d" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "issue-2108-survey" clean wsid)"

    _wtn_teardown
}

run_C14_resolver_pins() {
    local d SIDJS WSIDJS

    _wtn_setup
    SIDJS="$AGENTS_NODE/hooks/workflow-state/session-id.js"
    WSIDJS="$AGENTS_NODE/hooks/lib/resolve-workflow-session-id.js"

    # C14 pins the two resolvers' OWN behaviour across the helper extraction. The
    # enumeration above deliberately diverges from them (C11-3); these rows are what
    # stops that divergence from leaking back into resolution itself.
    d="$WTN_BASE/pin-cwd"
    _wtn_notes "$d" plain

    # C14-1 — priority 1 still short-circuits: a valid stdin sid wins over the notes
    # file. This is exactly the shadowing that hid the planted value from the observer.
    assert_eq "C14-1 valid stdin sid still wins over WORKTREE_NOTES (priority 1)" "stdin-sid" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" sid '{"sessionIdFromInput":"stdin-sid"}')"

    # C14-2 — priority 5 before 6: an input sid outside SESSION_ID_VALID_RE is skipped
    # and the transcript basename is used, still ahead of the notes file.
    assert_eq "C14-2 invalid stdin sid falls to the transcript basename (priority 5)" "tsid1234" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" sid '{"sessionIdFromInput":"bad.sid","transcriptPath":"/xx/tsid1234.jsonl"}')"

    # C14-3 — priority 6: with nothing in front of it, the CWD notes file resolves.
    assert_eq "C14-3 CWD WORKTREE_NOTES resolves at priority 6" "canon-sid-1" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" sid '{}')"
    assert_eq "C14-3 resolveWorkflowSessionId reads the same file at its priority 1" "canon-sid-1" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" wsid '{}')"

    # C14-4 — a charset-rejected notes value is not adopted by EITHER resolver. Both
    # fall through; outside a repo and outside the agents project there is nothing left.
    d="$WTN_BASE/pin-bad"
    _wtn_notes "$d" dotted
    assert_eq "C14-4 resolveSessionId ignores a dotted notes value" "null" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" sid '{}')"
    assert_eq "C14-4 resolveWorkflowSessionId ignores it too (CPR-ORTH)" "null" \
        "$(_wtn_in "$d" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" wsid '{}')"

    if [ "$WTN_REPO_OK" != yes ]; then
        skip "C14-5/C14-6 need git worktrees (git unavailable or worktree add failed)"
        _wtn_teardown
        return
    fi

    # C14-5 — the ambiguity fail-safe stays in RESOLUTION. Two distinct siblings, own
    # worktree carrying no notes: both resolvers must still answer null, even though
    # C11-3 proves the enumeration reports both.
    _wtn_notes "$WTN_BASE/wt-one" sibone
    _wtn_notes "$WTN_BASE/wt-two" sibtwo
    _wtn_notes "$WTN_REPO" none
    assert_eq "C14-5 resolveSessionId keeps the two-sibling ambiguity fail-safe" "null" \
        "$(_wtn_in "$WTN_REPO" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" sid '{}')"
    assert_eq "C14-5 resolveWorkflowSessionId keeps it too" "null" \
        "$(_wtn_in "$WTN_REPO" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" wsid '{}')"

    # C14-6 — own-worktree-first is preserved: from inside wt-one, its own notes win
    # over the sibling instead of being folded into an ambiguous set.
    assert_eq "C14-6 own worktree still wins over a sibling (resolveSessionId)" "sib-one-sid" \
        "$(_wtn_in "$WTN_BASE/wt-one" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" sid '{}')"
    assert_eq "C14-6 own worktree still wins over a sibling (resolveWorkflowSessionId)" "sib-one-sid" \
        "$(_wtn_in "$WTN_BASE/wt-one" "$PROBE_DIR/wtn-resolver-probe.js" "$SIDJS" "$WSIDJS" wsid '{}')"

    _wtn_teardown
}

# Section C18 — TRANSCRIPT-DERIVED SESSION ID, END TO END (review C3).
# C14-2 pins priority 5 at UNIT level: resolveSessionId() returns the transcript
# basename. That is one function; the write decision is another, and #2108 makes the
# two meet — the guard blocks only when the stem IS an effective session id, so which
# sid the chain observed is the whole verdict. Claude Code omits `session_id` from some
# PreToolUse payloads while always carrying `transcript_path`, so this is the shape a
# real hook must survive, not a synthetic edge. Every row below drives the REAL hook
# subprocess with `session_id` absent, and reads the resolved sid off the decision
# itself: a stem equal to the transcript basename must block, one that is not must not.

C18_WFDIR=""
C18_CONFIG=""
C18_TRANSCRIPTS=""
C18_TP="/xx/transcript-c18sid.jsonl"

# _c18_input <Write|Bash> <target-or-command> <transcript-path, or "-" to omit>
# `session_id` is never emitted — that omission is the point of the section.
_c18_input() {
    run_probe -e 'const t=process.argv[1];const o={tool_name:t,tool_input:t==="Bash"?{command:process.argv[2]}:{file_path:process.argv[2],content:"x"}};if(process.argv[3]!=="-")o.transcript_path=process.argv[3];process.stdout.write(JSON.stringify(o))' \
        "$1" "$2" "$3"
}

_c18_run() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        # CONFIG-DEPENDENT BRANCH ISOLATION (review C4). resolveSessionId() does not stop
        # at the transcript_path basename: if nothing earlier answers, it scans a
        # transcript BASE DIRECTORY, defaulting to ~/.claude/projects and keyed on
        # CLAUDE_PROJECT_DIR / cwd. Left unpinned, that priority-7 branch can hand the
        # chain a sid from the developer's real machine, and this section's whole claim —
        # "transcript_path is the only place the sid could have come from" — evaporates,
        # in the direction that silently turns a block row green for the wrong reason.
        # So: the base points at a fresh EMPTY fixture, and the project-dir override is
        # cleared rather than inherited.
        unset CLAUDE_PROJECT_DIR
        export CLAUDE_TRANSCRIPT_BASE_DIR="$C18_TRANSCRIPTS"
        export AGENTS_CONFIG_DIR="$C18_CONFIG"
        export CLAUDE_WORKFLOW_DIR="$C18_WFDIR"
        export WORKFLOW_PLANS_DIR="$C18_WFDIR"
        run_hook_capture "$1" "$RWT" 20 node "$BCTW_HOOK"
    )
}

# _c18_decide <Write|Bash> <target> <transcript-or-dash> <label>
# Sets C18_VERDICT. It cannot RETURN the verdict on stdout: the crash guard reports
# through pass/fail, which also writes stdout, and a command substitution would splice
# that line into the value being compared.
C18_VERDICT=""
_c18_decide() {
    local payload out
    if [ "$1" = Bash ]; then
        payload="$(_c18_input Bash "echo x > $2" "$3")"
    else
        payload="$(_c18_input Write "$2" "$3")"
    fi
    out="$(_c18_run "$payload")"
    assert_not_contains "$4 hook exits 0 (no crash / no timeout)" "<<HOOK_EXIT_" "$out"
    C18_VERDICT="$(gate_decision "$out")"
}

# --- C18-6 execute-on-approve harness ----------------------------------------
# _c18_exec_gated <route> <target-sh> <target-fwd> <transcript-or-dash>
# Asks the hook, then performs the corresponding action IFF it approved. `Write` is the
# editor route, whose action is simply creating the file with the payload the stdin
# carried; `Bash` is the shell-redirect route, whose action is the command itself. Sets
# C18_EXEC_VERDICT rather than printing it: the crash guard inside _c18_decide writes
# pass/fail to stdout, which a command substitution would splice into the value.
C18_EXEC_VERDICT=""
_c18_exec_gated() {
    local route="$1" tgt_sh="$2" tgt_fwd="$3" tp="$4"
    _c18_decide "$route" "$tgt_fwd" "$tp" "C18-6 gated [$route $(basename "$tgt_sh")]"
    C18_EXEC_VERDICT="$C18_VERDICT"
    [ "$C18_EXEC_VERDICT" = approve ] || return 0
    if [ "$route" = Bash ]; then
        ( cd "$NEUTRAL_CWD" && MSYS_NO_PATHCONV=1 bash -c "echo x > $tgt_fwd" >/dev/null 2>&1 ) || true
    else
        printf 'x' > "$tgt_sh" 2>/dev/null || true
    fi
    return 0
}

_c18_exec_gated_rows() {
    local xdir xfwd route

    xdir="$TMPBASE_SH/c18-exec"
    rm -rf "$xdir" 2>/dev/null || true
    mkdir -p "$xdir"
    xfwd="$(node_path "$xdir")"
    xfwd="${xfwd//\\//}"

    for route in Write Bash; do
        # C18-6a — THE ATTACK. transcript_path is the only sid source (see _c18_run), so
        # `transcript-c18sid.workflow-off` is the live session's clearance state. Blocked,
        # and — because the action is gated on that block — never created.
        _c18_exec_gated "$route" "$xdir/transcript-c18sid.workflow-off" \
            "$xfwd/transcript-c18sid.workflow-off" "$C18_TP"
        assert_eq "C18-6a [$route] gated write of the transcript-sid clearance name is refused" \
            "block" "$C18_EXEC_VERDICT"
        if [ -e "$xdir/transcript-c18sid.workflow-off" ]; then
            fail "C18-6a [$route] the protected target REACHED DISK at $xdir/transcript-c18sid.workflow-off"
        else
            pass "C18-6a [$route] the protected target never reached disk (Pattern 1)"
        fi

        # C18-6b — THE APPROVED CONTROL, and the only thing that makes C18-6a mean
        # anything: an ordinary artifact stem carrying the SAME protected suffix, on the
        # same route, with the same transcript. It is approved, so it must LAND.
        _c18_exec_gated "$route" "$xdir/issue-2108-survey.workflow-off" \
            "$xfwd/issue-2108-survey.workflow-off" "$C18_TP"
        assert_eq "C18-6b [$route] gated write of an artifact stem is allowed" \
            "approve" "$C18_EXEC_VERDICT"
        if [ -s "$xdir/issue-2108-survey.workflow-off" ]; then
            pass "C18-6b [$route] the approved write REALLY executed (file is on disk)"
        else
            fail "C18-6b [$route] the approved write never reached disk - the gated-action harness does not execute, so C18-6a proves nothing"
        fi
        rm -f "$xdir/issue-2108-survey.workflow-off" 2>/dev/null || true
    done

    # C18-6c — the MUTATION CONTROL, now with the action attached (C18-4 with teeth).
    # Same protected basename, same route, transcript_path removed: no sid is observable,
    # the stem belongs to nobody, the hook approves — and the file lands. That flip is
    # what pins C18-6a's absence to transcript_path rather than to the suffix.
    _c18_exec_gated Write "$xdir/transcript-c18sid.workflow-off" \
        "$xfwd/transcript-c18sid.workflow-off" -
    assert_eq "C18-6c dropping transcript_path flips the SAME name to approve" \
        "approve" "$C18_EXEC_VERDICT"
    if [ -s "$xdir/transcript-c18sid.workflow-off" ]; then
        pass "C18-6c and the now-approved write of that same name lands on disk"
    else
        fail "C18-6c the approved write of the same name did not land - the absence in C18-6a is the harness, not the guard"
    fi

    # SKIPPED: driving these rows through a real Claude Code PreToolUse dispatch instead
    # of this test's own approve-then-act wiring.
    # Because: nothing at TL2 can make the CLI issue the tool call; the gate-to-action
    # link is reconstructed here by construction.
    # L3 gap: whether the CLI really omits `session_id` while carrying `transcript_path`
    # on the payloads it sends - only a live session shows that, and
    # tests/TL3-hook-early-gate-allowlist-write.sh is where such payloads are observed.
}

run_C18_transcript_sid_e2e() {
    local dir dir_fwd route label targetkey want target

    dir="$TMPBASE_SH/c18-transcript"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir" "$TMPBASE_SH/c18-config" "$TMPBASE_SH/c18-workflow"
    dir_fwd="$(node_path "$dir")"
    dir_fwd="${dir_fwd//\\//}"
    C18_CONFIG="$(node_path "$TMPBASE_SH/c18-config")"
    C18_WFDIR="$(node_path "$TMPBASE_SH/c18-workflow")"
    # The priority-7 transcript scan's root: freshly emptied on every run, so no leftover
    # project slug from an earlier run can supply a sid either.
    rm -rf "$TMPBASE_SH/c18-transcripts" 2>/dev/null || true
    mkdir -p "$TMPBASE_SH/c18-transcripts"
    C18_TRANSCRIPTS="$(node_path "$TMPBASE_SH/c18-transcripts")"

    # C18-0 — harness guard. A missing entrypoint prints nothing, and nothing is the
    # PreToolUse protocol's ALLOW, so every row below would false-green.
    if [ ! -f "$BCTW_HOOK" ]; then
        fail "C18-0 hook entrypoint MISSING ($BCTW_HOOK) - Section C18 would be vacuous"
        return
    fi
    pass "C18-0 block-clearance-token-write entrypoint present"

    # The trio is what makes the resolved sid observable: with `transcript-c18sid` as the
    # ONLY sid the chain can have learned, `transcript-c18sid.workflow-off` blocking while
    # an ordinary artifact stem carrying the SAME protected suffix is allowed pins the
    # decision to that sid — not to the suffix, and not to a blanket deny.
    while IFS='|' read -r route label targetkey want; do
        [[ -z "$route" || "$route" =~ ^[[:space:]]*# ]] && continue
        route="${route//[[:space:]]/}"; label="${label//[[:space:]]/}"
        targetkey="${targetkey//[[:space:]]/}"; want="${want//[[:space:]]/}"
        case "$targetkey" in
            tsid)  target="$dir_fwd/transcript-c18sid.workflow-off" ;;
            other) target="$dir_fwd/issue-2108-survey.workflow-off" ;;
            plain) target="$dir_fwd/plain-note.txt" ;;
            *)     target="$dir_fwd/unknown-target-key" ;;
        esac
        _c18_decide "$route" "$target" "$C18_TP" "C18 $label [$route $targetkey]"
        assert_eq "C18 $label [$route $targetkey] no stdin session_id, sid comes from transcript_path" \
            "$want" "$C18_VERDICT"
    done <<'TABLE'
# route | label                  | target | want
# --- the transcript basename IS the live sid: writing its clearance state is forgery.
Write   | C18-1-transcript-stem  | tsid   | block
Bash    | C18-1-transcript-stem  | tsid   | block
# --- #2108's whole point: a protected SUFFIX on an ordinary stem is an artifact name.
#     Without these rows a hook that blocked everything would satisfy C18-1.
Write   | C18-2-artifact-stem    | other  | approve
Bash    | C18-2-artifact-stem    | other  | approve
# --- and an unprotected name must reach the plain allow on both routes.
Write   | C18-3-plain-name       | plain  | approve
Bash    | C18-3-plain-name       | plain  | approve
TABLE

    # C18-4 — MUTATION CONTROL. Remove transcript_path and nothing else: the very target
    # that blocked above now flips to approve, because no sid was observable and the stem
    # is no longer anyone's. That flip is the proof the assertion is non-vacuous — the
    # block in C18-1 is carried by transcript_path alone, not by the basename's suffix.
    _c18_decide Write "$dir_fwd/transcript-c18sid.workflow-off" - "C18-4 Write"
    assert_eq "C18-4 Write: dropping transcript_path flips the SAME target to approve" \
        "approve" "$C18_VERDICT"
    _c18_decide Bash "$dir_fwd/transcript-c18sid.workflow-off" - "C18-4 Bash"
    assert_eq "C18-4 Bash: dropping transcript_path flips the SAME target to approve" \
        "approve" "$C18_VERDICT"

    # C18-5 — Pattern 1 negative assertion: a "block" verdict beside a file on disk is
    # not a block. No row above may have created its protected target.
    if [ -e "$dir/transcript-c18sid.workflow-off" ]; then
        fail "C18-5 blocked target was created at $dir/transcript-c18sid.workflow-off"
    else
        pass "C18-5 blocked target remains absent on disk"
    fi

    # C18-6 — EXECUTE-ON-APPROVE. C18-5 inspects a filesystem that nothing ever tried to
    # touch: every row above asks the hook for a verdict and stops there, so "the target is
    # absent" would hold just as well with the guard removed. This block wires the verdict
    # to the action the way PreToolUse does — the simulated Write / the Bash command runs
    # if and ONLY if the hook approved it — so an absent target becomes evidence and an
    # approved write that lands proves the wiring is real.
    _c18_exec_gated_rows

    # SKIPPED: an empty-string `session_id` present alongside transcript_path.
    # Because: C9 already owns malformed stdin session_id shapes against this same hook,
    # and the falsy-then-fall-through step it exercises is the same one C18 enters.
    # L3 gap: whether Claude Code really omits session_id on the payloads it sends is a
    # property of the CLI, not of this repo — tests/TL3-hook-early-gate-allowlist-write.sh
    # is where a live session's real payload shape is observed.
}
