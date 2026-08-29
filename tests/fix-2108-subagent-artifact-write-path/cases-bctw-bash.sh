#!/usr/bin/env bash
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/block-clearance-token-write/bash-scan/scan.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/lib/protected-basenames.js, hooks/lib/active-session-ids.js
# Tags: block-clearance-token-write, bash-scan, interpreter-body, protected-basename, session-context, malformed-input, fail-closed, subprocess, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section C5 — the BASH branch of block-clearance-token-write, driven through the real
# hook subprocess. dispatch.js:99 routes command tools to bashHitsProtected(), a
# different code path from the Edit/Write branch at :88 that Section C4 route4 covers.
# Without a TP/FP pair on THIS entrypoint the bash branch could keep its old
# suffix-only behaviour and every other section would still report green (review C3).

# _c5_run <stdin-json> -> raw hook stdout
_c5_run() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        export AGENTS_CONFIG_DIR="$C5_CONFIG"
        export CLAUDE_WORKFLOW_DIR="$C5_WFDIR"
        export WORKFLOW_PLANS_DIR="$C5_WFDIR"
        # Exit status is carried out as a <<HOOK_EXIT_n>> token (review C1): without it a
        # crashed hook prints nothing and every "approve" assertion below false-greens.
        run_hook_capture "$1" "$RWT" 20 node "$BCTW_HOOK"
    )
}

# Targets live in a plain temp dir, deliberately NOT under CLAUDE_WORKFLOW_DIR: a write
# into the workflow dir can block on directory containment (workflow-glob /
# workflow-dynamic), which would answer a question this section is not asking.
# AGENTS_CONFIG_DIR points at an EMPTY dir so the developer's real .env cannot reach
# the verdict (hooks/lib/load-env.js overrides any var whose value is falsy).

# _c5_cmd <command-text> -> PreToolUse-shaped stdin for the Bash tool, sid "wsid"
_c5_cmd() {
    printf '{"session_id":"wsid","tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_esc "$1")"
}

run_C5_bctw_bash_route() {
    local dir dir_fwd tp_out fp_out

    dir="$TMPBASE_SH/c5-bash"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir"
    dir_fwd="$(node_path "$dir")"
    dir_fwd="${dir_fwd//\\//}"

    mkdir -p "$TMPBASE_SH/c5-config" "$TMPBASE_SH/c5-workflow"
    C5_CONFIG="$(node_path "$TMPBASE_SH/c5-config")"
    C5_WFDIR="$(node_path "$TMPBASE_SH/c5-workflow")"

    # C5-0 — harness guard. An absent entrypoint would make the pair below vacuous in
    # exactly the direction that matters: a missing hook approves everything.
    if [ -f "$BCTW_HOOK" ]; then
        pass "C5-0 block-clearance-token-write.js present"
    else
        fail "C5-0 block-clearance-token-write.js MISSING at $BCTW_HOOK - Section C5 would be vacuous"
        return
    fi

    # C5-1 — TRUE POSITIVE. The stdin session_id IS the stem, so this is a forged
    # clearance file for the live session and must stay blocked on the bash route.
    tp_out="$(_c5_run "$(_c5_cmd "echo x > $dir_fwd/wsid.gh-env")")"
    assert_eq "C5-1 TP bash redirect onto <sid>.gh-env is blocked" "block" "$(gate_decision "$tp_out")"

    # C5-2 — the block must be legible, not a bare verdict: the remediation text is the
    # only thing keeping a blocked agent from hunting for a bypass (CPR-UO). `gh-env` is
    # a state KIND, so dispatch.js selects MARKER_BLOCK_MSG (sentinel route), not the
    # token message — the assertion names that branch rather than either literal.
    assert_contains "C5-2 TP block explains itself" "blocked" "$(gate_reason "$tp_out")"
    assert_contains "C5-2 TP block points at the sanctioned route" "sentinel" "$(gate_reason "$tp_out")"

    # C5-3 — FALSE POSITIVE, the #2108 shape. A subagent's survey notes happen to end in
    # a protected kind; the stem is not a session id on ANY spelling, so the bash tail
    # match must not claim it either.
    fp_out="$(_c5_run "$(_c5_cmd "echo x > $dir_fwd/issue-2108-survey.gh-env")")"
    assert_eq "C5-3 FP bash redirect onto <artifact>.gh-env is allowed" "approve" "$(gate_decision "$fp_out")"

    # C5-4 — Pattern 1 negative assertion. A verdict of "block" beside a file on disk is
    # not a block; the hook must not have created the target while resolving it.
    if [ -e "$dir/wsid.gh-env" ]; then
        fail "C5-4 blocked bash target was created at $dir/wsid.gh-env"
    else
        pass "C5-4 blocked bash target remains absent (Pattern 1)"
    fi

    # C5-5 — the DELETE direction of the same route (CPR-ORTH). A narrowing that leaked
    # only on `rm` would let a subagent delete the live session's clearance state.
    assert_eq "C5-5 TP bash rm of <sid>.gh-env is blocked" "block" \
        "$(gate_decision "$(_c5_run "$(_c5_cmd "rm -f $dir_fwd/wsid.gh-env")")")"
    assert_eq "C5-5 FP bash rm of <artifact>.gh-env is allowed" "approve" \
        "$(gate_decision "$(_c5_run "$(_c5_cmd "rm -f $dir_fwd/issue-2108-survey.gh-env")")")"

    # SKIPPED: the PowerShell spelling of the same two commands.
    # Because: the pwsh scanner has its own suite (tests/enforce-protected-marker-write.sh)
    # and this file's tag set declares pwsh-not-required.
    # L3 gap: whether settings.json actually routes Bash calls to this hook at all.
}

# Section C17 — THE INTERPRETER-BODY WRITE VECTOR (`node -e` / `python -c`).
# C5 covers the shell-redirect spelling only. A write issued from INSIDE an interpreter
# body is a different delivery route: the target never appears as a shell word, so the
# extraction pipeline marker-gate.js relies on (bash-write-targets/exotic-exec.js,
# INTERP_NAMES) does not see it — that list covers shell `-c` only. What holds the
# boundary is block-clearance-token-write's interpreter-scan.js, judging the BODY by
# mention + recognized-read-only shape; marker-gate.js is defence in depth by its own
# header comment. The security property is therefore "the CHAIN blocks", which is what
# every row below asserts, through the real hook subprocess.

C17_WFDIR=""
C17_CONFIG=""

# _c17_run <stdin-json> <hook> -> raw hook stdout (+ <<HOOK_EXIT_n>> on a non-zero exit)
_c17_run() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        unset ENFORCE_WORKTREE_EXCLUDE ENFORCE_WORKTREE_EXCLUDE_REPOS
        export ENFORCE_WORKTREE=on
        export AGENTS_CONFIG_DIR="$C17_CONFIG"
        export CLAUDE_WORKFLOW_DIR="$C17_WFDIR"
        export WORKFLOW_PLANS_DIR="$C17_WFDIR"
        run_hook_capture "$1" "$RWT" 20 node "$2"
    )
}

# _c17_body <interpreter> <verb> <target> -> the interpreter one-liner text.
# Both languages express the SAME three verbs, so a row's verdict is attributable to the
# target name rather than to which language happens to be spelled (CPR-ORTH).
_c17_body() {
    case "$1:$2" in
        node:write)    printf "node -e \"require('fs').writeFileSync('%s','x')\"" "$3" ;;
        node:delete)   printf "node -e \"require('fs').unlinkSync('%s')\"" "$3" ;;
        node:read)     printf "node -e \"console.log(require('fs').readFileSync('%s','utf8'))\"" "$3" ;;
        python:write)  printf "python -c \"open('%s','w').write('x')\"" "$3" ;;
        python:delete) printf "python -c \"import os;os.remove('%s')\"" "$3" ;;
        python:read)   printf "python -c \"print(open('%s').read())\"" "$3" ;;
        *)             printf 'echo unknown-interpreter-key' ;;
    esac
}

# --- C17-8 execute-on-approve harness ---------------------------------------
# _c17_sha <file> -> a content digest, or the empty string when the file is absent.
# Existence alone is too weak for the seeded victims: a read-modify-write leaves the
# path in place while replacing the bytes, which is the forgery this guard exists to stop.
_c17_sha() {
    [ -f "$1" ] || return 0
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else cksum "$1" | cut -d' ' -f1; fi
}

# _c17_exec_gated <command-text> -> the hook's decision, having RUN the command iff it
# approved. This is the PreToolUse contract in miniature: the tool call proceeds only on
# approve. Nothing here may write to stdout except the decision — the caller reads it
# through a command substitution, so pass/fail lines would splice into the value.
_c17_exec_gated() {
    local cmd="$1" dec
    dec="$(gate_decision "$(_c17_run "$(_c5_cmd "$cmd")" "$BCTW_HOOK")")"
    if [ "$dec" = approve ]; then
        ( cd "$NEUTRAL_CWD" && MSYS_NO_PATHCONV=1 bash -c "$cmd" >/dev/null 2>&1 ) || true
    fi
    printf '%s' "$dec"
}

# _c17_interp_ok <node|python> -> 0 when the interpreter can actually run a one-liner.
# `command -v python` is not enough on Windows, where a stub launcher exists and exits
# non-zero; the probe is an actual execution.
_c17_interp_ok() {
    case "$1" in
        node)   node -e "process.exit(0)" >/dev/null 2>&1 ;;
        python) python -c "pass" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

_c17_exec_gated_rows() {
    local xdir xfwd interp label verb targetkey want target cmd dec
    local seeded_sha now_sha

    xdir="$TMPBASE_SH/c17-exec"
    rm -rf "$xdir" 2>/dev/null || true
    mkdir -p "$xdir"
    xfwd="$(node_path "$xdir")"
    xfwd="${xfwd//\\//}"

    # PRECONDITIONS (Pattern 2). The protected targets EXIST and carry distinctive bytes
    # before any command is issued: an overwrite and a delete are both then observable,
    # and neither can hide behind "the file was never there to begin with".
    printf 'SEEDED-MARKER-C17\n'   > "$xdir/wsid.gh-env"
    printf 'SEEDED-TOKEN-C17\n'    > "$xdir/wsid.off-clearance"
    printf 'SEEDED-ARTIFACT-C17\n' > "$xdir/issue-2108-survey.gh-env"
    # The delete-side approve control needs a victim too, or "it is gone" is unfalsifiable.
    printf 'SEEDED-PLAIN-C17\n'    > "$xdir/plain-doomed.txt"

    if ! _c17_interp_ok node; then
        skip "C17-8 needs a working \`node -e\` to execute an approved interpreter body"
        return
    fi

    # C17-8a — THE ATTACK ROWS. Each is: seeded victim -> hook-gated interpreter command
    # -> assert blocked AND the victim's bytes are exactly what they were.
    while IFS='|' read -r label interp verb targetkey; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; interp="${interp//[[:space:]]/}"
        verb="${verb//[[:space:]]/}"; targetkey="${targetkey//[[:space:]]/}"
        if ! _c17_interp_ok "$interp"; then
            skip "C17-8a $label [$interp $verb $targetkey] - $interp one-liners not runnable here"
            continue
        fi
        case "$targetkey" in
            sidmarker) target="wsid.gh-env" ;;
            sidtoken)  target="wsid.off-clearance" ;;
            artifact)  target="issue-2108-survey.gh-env" ;;
            *)         target="unknown-target-key" ;;
        esac
        seeded_sha="$(_c17_sha "$xdir/$target")"
        cmd="$(_c17_body "$interp" "$verb" "$xfwd/$target")"
        dec="$(_c17_exec_gated "$cmd")"
        assert_eq "C17-8a $label [$interp $verb $targetkey] gated action is refused" "block" "$dec"
        # Pattern 1, in its strong form: still present, and byte-for-byte the seeded bytes.
        if [ ! -f "$xdir/$target" ]; then
            fail "C17-8a $label [$interp $verb $targetkey] the seeded victim was DELETED at $xdir/$target"
        else
            now_sha="$(_c17_sha "$xdir/$target")"
            assert_eq "C17-8a $label [$interp $verb $targetkey] victim bytes unchanged" \
                "$seeded_sha" "$now_sha"
        fi
    done <<'TABLE'
# label                     | interpreter | verb   | target
C17-8-exec-write            | node        | write  | sidmarker
C17-8-exec-write            | python      | write  | sidmarker
C17-8-exec-write            | node        | write  | sidtoken
C17-8-exec-delete           | node        | delete | sidmarker
C17-8-exec-delete           | python      | delete | sidmarker
C17-8-exec-delete           | node        | delete | sidtoken
C17-8-exec-artifact         | node        | write  | artifact
C17-8-exec-artifact         | python      | write  | artifact
TABLE

    # C17-8b — THE APPROVED CONTROL, and the only thing that makes C17-8a mean anything.
    # An unprotected target on the very same route: the hook approves, the harness runs
    # the body, and the file appears. Without this row every "unchanged" above is equally
    # explained by a harness that never executes anything at all.
    cmd="$(_c17_body node write "$xfwd/plain-landed.txt")"
    dec="$(_c17_exec_gated "$cmd")"
    assert_eq "C17-8b approved plain interpreter write is allowed" "approve" "$dec"
    if [ -s "$xdir/plain-landed.txt" ]; then
        pass "C17-8b the approved write REALLY executed (file is on disk)"
    else
        fail "C17-8b the approved write never reached disk - the gated-action harness does not execute, so every C17-8a 'unchanged' is vacuous"
    fi

    # C17-8c — the DELETE direction of the same control (CPR-ORTH). A harness that could
    # create but not delete would leave C17-8a's delete rows unproven.
    cmd="$(_c17_body node delete "$xfwd/plain-doomed.txt")"
    dec="$(_c17_exec_gated "$cmd")"
    assert_eq "C17-8c approved plain interpreter delete is allowed" "approve" "$dec"
    if [ -e "$xdir/plain-doomed.txt" ]; then
        fail "C17-8c the approved delete never executed - C17-8a's delete rows are vacuous"
    else
        pass "C17-8c the approved delete REALLY executed (file is gone)"
    fi

    # SKIPPED: executing the same rows as a real Claude Code PreToolUse tool call rather
    # than as a bash subprocess this test gates itself.
    # Because: nothing at TL2 can make the CLI issue the call; the gate/action wiring is
    # simulated here by construction.
    # L3 gap: whether settings.json actually routes a Bash tool call through this hook
    # before the command runs - tests/TL3-hook-early-gate-allowlist-write.sh observes that.
}

run_C17_interpreter_body() {
    local dir dir_fwd label interp verb targetkey want target cmd out ew_out

    dir="$TMPBASE_SH/c17-interp"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir"
    dir_fwd="$(node_path "$dir")"
    dir_fwd="${dir_fwd//\\//}"

    mkdir -p "$TMPBASE_SH/c17-config" "$TMPBASE_SH/c17-workflow"
    C17_CONFIG="$(node_path "$TMPBASE_SH/c17-config")"
    C17_WFDIR="$(node_path "$TMPBASE_SH/c17-workflow")"

    # C17-0 — harness guards. A missing hook prints nothing, and nothing is the
    # PreToolUse protocol's ALLOW, so every row below would false-green.
    if [ ! -f "$BCTW_HOOK" ] || [ ! -f "$EW_HOOK" ]; then
        fail "C17-0 hook entrypoint MISSING (bctw=$BCTW_HOOK ew=$EW_HOOK) - Section C17 would be vacuous"
        return
    fi
    pass "C17-0 both write-guard entrypoints present"

    # Table: interpreter x verb x target basename. `want` is the CHAIN decision, verified
    # empirically against the real subprocesses: block-clearance-token-write carries it.
    while IFS='|' read -r label interp verb targetkey want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; interp="${interp//[[:space:]]/}"
        verb="${verb//[[:space:]]/}"; targetkey="${targetkey//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        case "$targetkey" in
            sidmarker) target="$dir_fwd/wsid.gh-env" ;;
            sidtoken)  target="$dir_fwd/wsid.off-clearance" ;;
            artifact)  target="$dir_fwd/issue-2108-survey.gh-env" ;;
            plain)     target="$dir_fwd/plain-note.txt" ;;
            *)         target="$dir_fwd/unknown-target-key" ;;
        esac
        cmd="$(_c17_body "$interp" "$verb" "$target")"
        out="$(_c17_run "$(_c5_cmd "$cmd")" "$BCTW_HOOK")"
        assert_not_contains "C17 $label [$interp $verb $targetkey] hook exits 0 (no crash / no timeout)" \
            "<<HOOK_EXIT_" "$out"
        assert_eq "C17 $label [$interp $verb $targetkey]" "$want" "$(gate_decision "$out")"
    done <<'TABLE'
# label                  | interpreter | verb   | target    | want (chain decision)
# --- WRITE into a live session's clearance state: the forgery this guard exists for.
C17-1-body-write         | node        | write  | sidmarker | block
C17-1-body-write         | python      | write  | sidmarker | block
C17-1-body-write         | node        | write  | sidtoken  | block
C17-1-body-write         | python      | write  | sidtoken  | block
# --- DELETE is the symmetric half: removing a marker re-arms the bypass just as writing
#     one does (CPR-ORTH with C5-5).
C17-2-body-delete        | node        | delete | sidmarker | block
C17-2-body-delete        | python      | delete | sidmarker | block
# --- ORDINARY artifact name: the route must still reach an ALLOW, or every block above
#     would be attributable to "an interpreter one-liner was used" and prove nothing.
C17-3-body-plain         | node        | write  | plain     | approve
C17-3-body-plain         | python      | write  | plain     | approve
C17-3-body-plain         | node        | delete | plain     | approve
# --- MENTION-BASED, STEM-AGNOSTIC, and NOT the #2108 stem rule: the artifact name C5-3
#     ALLOWS as a shell redirect is BLOCKED from inside a body, because an opaque program
#     body cannot prove the stem is the whole target. Pinned so it stays deliberate.
C17-4-body-artifact      | node        | write  | artifact  | block
C17-4-body-artifact      | python      | write  | artifact  | block
# --- RECOGNIZED READ-ONLY shape: naming a protected file is not itself the offence, so
#     an anchored read of the very same target is allowed (CPR-UO — reads stay possible).
#     Without these rows every block above would also be satisfied by "mention == block".
C17-5-body-readonly      | node        | read   | sidmarker | approve
C17-5-body-readonly      | python      | read   | sidmarker | approve
C17-5-body-readonly      | node        | read   | sidtoken  | approve
TABLE

    # C17-6 — WHICH guard carries the block, asserted without pinning the division of
    # labour. enforce-worktree sees the same text; its target extraction does not model
    # interpreter bodies, so it answers ALLOW today. Defence-in-depth withheld is not a
    # leak — but it must never become a CRASH, which would take that guard down for this
    # whole input class. So the verdict asserted here is only "a real verdict".
    ew_out="$(_c17_run "$(_c5_cmd "$(_c17_body node write "$dir_fwd/wsid.gh-env")")" "$EW_HOOK")"
    assert_not_contains "C17-6 enforce-worktree survives an interpreter body (no crash)" \
        "<<HOOK_EXIT_" "$ew_out"
    case "$(gate_decision "$ew_out")" in
        approve|block) pass "C17-6 enforce-worktree returns a real verdict for the same body" ;;
        *) fail "C17-6 enforce-worktree returned neither approve nor block for an interpreter body" ;;
    esac

    # C17-7 — Pattern 1 negative assertion. A "block" verdict beside a file on disk is not
    # a block: no row above may have created its target.
    local victim
    for victim in "$dir/wsid.gh-env" "$dir/wsid.off-clearance" "$dir/issue-2108-survey.gh-env"; do
        if [ -e "$victim" ]; then
            fail "C17-7 blocked interpreter target was created at $victim"
        else
            pass "C17-7 blocked interpreter target remains absent ($victim)"
        fi
    done

    # C17-8 — EXECUTE-ON-APPROVE. Everything above is a VERDICT: the hook is asked what
    # it would decide and the interpreter one-liner is never run, so C17-7's "the target
    # is absent" holds whether the guard bit or not — nothing ever tried to create it.
    # This block closes that by wiring the verdict to the action the way PreToolUse does:
    # the command runs if and ONLY if the hook approved it. Now an absent/unchanged victim
    # is evidence, because the same harness demonstrably lands a file when told to.
    _c17_exec_gated_rows

    # SKIPPED: `perl -e`, `ruby -e`, `deno eval`, `bun -e`.
    # Because: interpreter-scan.js judges every LANGUAGE_INTERPRETER_NAMES member through
    # one shared body classifier, so node and python exercise the same code path; the name
    # list itself is asserted in tests/enforce-protected-marker-write.sh.
    # L3 gap: whether a real session's Bash call reaches this hook at all is settings.json
    # routing — covered by tests/TL3-hook-early-gate-allowlist-write.sh.
}

# Section C9 — MALFORMED `session_id` REACHING THE REAL HOOK (review C2). Every other
# section feeds the hook a well-formed string sid. #2108 makes the verdict depend on a
# session-id BODY for the first time, so a non-string sid now flows into stem
# comparison, into observeActiveSessionIds() and into path joins. Any of those may
# throw, and a hook that throws prints nothing — which the PreToolUse protocol reads as
# ALLOW. That is a silent full bypass of the clearance guard, so each shape below is
# asserted on the verdict AND on the subprocess exit status.

# The store here is READABLE and holds `wsid.json`, so `wsid` is an observed active
# session id on disk regardless of what stdin carries. That is the point: the block on
# `wsid.gh-env` must survive a sid the hook cannot use, rather than depending on it.
C9_WFDIR=""
C9_CONFIG=""
C9_LONG_SID=""

# _c9_run <stdin-json> -> raw hook stdout (+ <<HOOK_EXIT_n>> on a non-zero exit)
_c9_run() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        export AGENTS_CONFIG_DIR="$C9_CONFIG"
        export CLAUDE_WORKFLOW_DIR="$C9_WFDIR"
        export WORKFLOW_PLANS_DIR="$C9_WFDIR"
        run_hook_capture "$1" "$RWT" 20 node "$BCTW_HOOK"
    )
}

# _c9_sid_json <sidkey> -> the raw JSON value emitted for "session_id"
_c9_sid_json() {
    case "$1" in
        wellformed) printf '"wsid"' ;;
        empty)      printf '""' ;;
        null)       printf 'null' ;;
        object)     printf '{"id":"wsid"}' ;;
        array)      printf '["wsid"]' ;;
        number)     printf '12345' ;;
        boolean)    printf 'true' ;;
        traversal)  printf '"../../etc/wsid"' ;;
        long)       printf '"%s"' "$C9_LONG_SID" ;;
        *)          printf '"wsid"' ;;
    esac
}

# _c9_payload <sidkey> <command-text> -> PreToolUse stdin for the Bash tool.
# `absent` omits the field entirely — a distinct shape from null (review C2).
_c9_payload() {
    local sidkey="$1" cmd="$2" sidfld=""
    [ "$sidkey" = absent ] || sidfld="$(printf '"session_id":%s,' "$(_c9_sid_json "$sidkey")")"
    printf '{%s"tool_name":"Bash","tool_input":{"command":"%s"}}' "$sidfld" "$(json_esc "$cmd")"
}

run_C9_malformed_sid() {
    local dir dir_fwd label sidkey cmdkey want cmd out

    dir="$TMPBASE_SH/c9-bash"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir"
    dir_fwd="$(node_path "$dir")"
    dir_fwd="${dir_fwd//\\//}"

    mkdir -p "$TMPBASE_SH/c9-config" "$TMPBASE_SH/c9-workflow"
    C9_CONFIG="$(node_path "$TMPBASE_SH/c9-config")"
    printf '{"version":1,"session_id":"wsid"}' > "$TMPBASE_SH/c9-workflow/wsid.json"
    printf '{"version":1,"session_id":"othersid"}' > "$TMPBASE_SH/c9-workflow/othersid.json"
    C9_WFDIR="$(node_path "$TMPBASE_SH/c9-workflow")"

    # 4 KB of sid: past any plausible basename/path budget, and long enough that a
    # regex written with backtracking over the stem would time out rather than answer.
    C9_LONG_SID="$(node -e "process.stdout.write('a'.repeat(4096))" 2>/dev/null)"

    # C9-0 — harness guards. A missing entrypoint or an unreadable store would make
    # every row below pass for a reason that has nothing to do with the sid shape.
    if [ ! -f "$BCTW_HOOK" ]; then
        fail "C9-0 block-clearance-token-write.js MISSING at $BCTW_HOOK - Section C9 would be vacuous"
        return
    fi
    pass "C9-0 block-clearance-token-write.js present"
    if [ -r "$TMPBASE_SH/c9-workflow/wsid.json" ]; then
        pass "C9-0 workflow store is readable and holds wsid.json"
    else
        fail "C9-0 workflow store fixture missing - the on-disk sid the C9 rows rely on does not exist"
        return
    fi
    assert_eq "C9-0 long sid fixture really is 4096 chars" "4096" "${#C9_LONG_SID}"

    # Table: sid SHAPE x target BASENAME. The `plain` and `fp` columns are the
    # discriminator trio's other two thirds (same form as C6-1/C6-3): they prove the
    # route still reaches an ALLOW under this sid, so a `block` on the `tp` row is
    # attributable to the basename classifier and not to a sid-induced hard failure
    # that blocks everything. `wellformed` is the baseline every malformed shape must
    # reproduce exactly — deviation in EITHER direction is the defect.
    while IFS='|' read -r label sidkey cmdkey want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; sidkey="${sidkey//[[:space:]]/}"
        cmdkey="${cmdkey//[[:space:]]/}"; want="${want//[[:space:]]/}"
        case "$cmdkey" in
            tp)    cmd="echo x > $dir_fwd/wsid.gh-env" ;;
            fp)    cmd="echo x > $dir_fwd/issue-2108-survey.gh-env" ;;
            plain) cmd="echo x > $dir_fwd/plain-note.txt" ;;
            *)     cmd="echo unknown-key" ;;
        esac
        out="$(_c9_run "$(_c9_payload "$sidkey" "$cmd")")"
        # The verdict is only meaningful once the subprocess is known to have exited 0:
        # a crash prints nothing, and nothing is the protocol's ALLOW.
        assert_not_contains "C9 $label [$sidkey $cmdkey] hook exits 0 (no crash / no timeout)" \
            "<<HOOK_EXIT_" "$out"
        assert_eq "C9 $label [$sidkey $cmdkey]" "$want" "$(gate_decision "$out")"
    done <<'TABLE'
# label                | sid shape   | command | want
# --- BASELINE: a well-formed sid. Every malformed shape must match these three.
C9-1-baseline          | wellformed  | tp      | block
C9-1-baseline          | wellformed  | fp      | approve
C9-1-baseline          | wellformed  | plain   | approve
# --- null / absent / empty: nothing usable arrives, but wsid.json is still on disk.
C9-2-null-sid          | null        | tp      | block
C9-2-null-sid          | null        | fp      | approve
C9-2-null-sid          | null        | plain   | approve
C9-3-absent-sid        | absent      | tp      | block
C9-3-absent-sid        | absent      | fp      | approve
C9-4-empty-sid         | empty       | tp      | block
C9-4-empty-sid         | empty       | fp      | approve
# --- NON-STRING shapes: `.startsWith` / `.length` / path.join on these throw.
C9-5-object-sid        | object      | tp      | block
C9-5-object-sid        | object      | fp      | approve
C9-5-object-sid        | object      | plain   | approve
C9-6-array-sid         | array       | tp      | block
C9-6-array-sid         | array       | fp      | approve
C9-7-number-sid        | number      | tp      | block
C9-7-number-sid        | number      | fp      | approve
C9-8-boolean-sid       | boolean     | tp      | block
C9-8-boolean-sid       | boolean     | fp      | approve
# --- TRAVERSAL-SHAPED sid: reaches path.join() inside the state-store resolution.
C9-9-traversal-sid     | traversal   | tp      | block
C9-9-traversal-sid     | traversal   | fp      | approve
C9-9-traversal-sid     | traversal   | plain   | approve
# --- 4 KB sid: the string-length edge (skills/_shared/test-design.md, String bullet).
C9-10-long-sid         | long        | tp      | block
C9-10-long-sid         | long        | fp      | approve
C9-10-long-sid         | long        | plain   | approve
TABLE

    # C9-10 is the regression guard for a fixed payload-SIZE fault (not a sid-shape
    # fault): `readStdin()` used to push `buf.slice(0, n)` VIEWS of one reused 4 KB
    # buffer, so stdin past 4096 bytes self-corrupted, JSON.parse threw, and the hook
    # failed OPEN. It now copies each chunk, so a 4 KB sid reaches the classifier and
    # `tp` blocks like every other row.

    # C9-11 — a malformed sid must not confer clearance on ANOTHER session's marker
    # either (CPR-ORTH with C1d). `othersid.json` is in the same store, so its marker is
    # protected no matter what stdin claims the current session is.
    assert_eq "C9-11 other session's marker stays blocked under an object sid" "block" \
        "$(gate_decision "$(_c9_run "$(_c9_payload object "echo x > $dir_fwd/othersid.gh-env")")")"
    assert_eq "C9-11 other session's marker stays blocked under a traversal sid" "block" \
        "$(gate_decision "$(_c9_run "$(_c9_payload traversal "echo x > $dir_fwd/othersid.gh-env")")")"

    # C9-12 — Pattern 1 negative assertion: no blocked row above may have created its
    # target. A "block" verdict beside a file on disk is not a block.
    local victim
    for victim in "$dir/wsid.gh-env" "$dir/othersid.gh-env"; do
        if [ -e "$victim" ]; then
            fail "C9-12 blocked target was created at $victim"
        else
            pass "C9-12 blocked target remains absent ($victim)"
        fi
    done

    # SKIPPED: a sid carrying a NUL byte or a lone UTF-16 surrogate.
    # Because: JSON.parse rejects a raw NUL in the transport before the hook sees it, so
    # the case would assert the JSON parser's behaviour rather than the hook's.
    # L3 gap: a harness that hands the hook a pre-parsed object rather than stdin text
    # could deliver such a value; only a live PreToolUse chain would show it.
}
