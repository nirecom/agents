#!/usr/bin/env bash
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/block-clearance-token-write/bash-scan/scan.js, hooks/lib/protected-basenames.js, hooks/lib/active-session-ids.js
# Tags: block-clearance-token-write, bash-scan, protected-basename, session-context, malformed-input, fail-closed, subprocess, security, scope:issue-specific, pwsh-not-required
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
