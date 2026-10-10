# tests/hooks/fix-1630-script-checkout-root-resolver/standard-predicates.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/lib/script-checkout-root.js
# Tags: hook, worktree, agents-main-root, resolver, enforce, security, scope:issue-specific
# Sourced by tests/hooks/fix-1630-script-checkout-root-resolver.sh.
# Three predicates call the resolver. seams.sh covers isAllowedWorkerScriptInvocation;
# this file drives isAllowedComposeDocAppend and isAllowedClarifyGuardLoop through the
# same five AGENTS_MAIN_ROOT states (valid / missing / stale / attacker / forged), and
# all three through the branch taken when the resolver finds no checkout at all.

# standard_probe <fnName> <cmd> [env assignments...] -> "true"|"false"|"ERROR: ..."
standard_probe() {
    local fn="$1" cmd="$2"; shift 2
    run_with_timeout 30 env -u AGENTS_MAIN_ROOT -u AGENTS_HOOK_DEBUG "$@" node -e '
      const path = require("path");
      const mod = path.join(process.argv[1], "hooks", "enforce-worktree",
                            "main-worktree-allows", "standard.js");
      let m;
      try { m = require(mod); }
      catch (e) { console.log("ERROR: " + e.message.split("\n")[0]); process.exit(0); }
      const f = m[process.argv[2]];
      if (typeof f !== "function") { console.log("ERROR: not exported"); process.exit(0); }
      try { console.log(String(f(process.argv[3], process.argv[4]))); }
      catch (e) { console.log("ERROR: threw " + e.message.split("\n")[0]); }
    ' "${PREDICATE_ROOT:-$SCRIPT_CHECKOUT_ROOT_NODE}" "$fn" "$cmd" "$REPO" 2>&1
}

assert_standard() {
    local name="$1" fn="$2" want="$3" cmd="$4"; shift 4
    expect_eq "$name" "$(standard_probe "$fn" "$cmd" "$@")" "$want"
}

run_standard_predicate_cases() {
    local valid="AGENTS_MAIN_ROOT=$SCRIPT_CHECKOUT_ROOT_NODE"

    # An attacker-owned tree that carries `bin` but NOT hooks/enforce-worktree.js.
    local evil_raw="$TMPDIR_BASE/evil-std"
    mkdir -p "$evil_raw/bin/github-issues"
    : > "$evil_raw/bin/compose-doc-append-entry"
    : > "$evil_raw/bin/github-issues/clarify-guard-loop.sh"
    local evil; evil="$(norm "$evil_raw")"

    # The same tree with BOTH markers forged. It would pass marker validation if
    # AGENTS_MAIN_ROOT were a candidate, so these rows hold only because it is not.
    local forged_raw="$TMPDIR_BASE/forged-std"
    mkdir -p "$forged_raw/bin/github-issues" "$forged_raw/hooks"
    : > "$forged_raw/hooks/enforce-worktree.js"
    : > "$forged_raw/bin/compose-doc-append-entry"
    : > "$forged_raw/bin/github-issues/clarify-guard-loop.sh"
    local forged; forged="$(norm "$forged_raw")"

    local fn real evilcmd forgedcmd label
    for label in compose clarify; do
        case "$label" in
            compose)
                fn=isAllowedComposeDocAppend
                real="bash \"$SCRIPT_CHECKOUT_ROOT_NODE/bin/compose-doc-append-entry\" --subject x"
                evilcmd="bash \"$evil/bin/compose-doc-append-entry\" --subject x"
                forgedcmd="bash \"$forged/bin/compose-doc-append-entry\" --subject x"
                ;;
            clarify)
                fn=isAllowedClarifyGuardLoop
                real="bash \"$SCRIPT_CHECKOUT_ROOT_NODE/bin/github-issues/clarify-guard-loop.sh\" 1234"
                evilcmd="bash \"$evil/bin/github-issues/clarify-guard-loop.sh\" 1234"
                forgedcmd="bash \"$forged/bin/github-issues/clarify-guard-loop.sh\" 1234"
                ;;
        esac

        # ── valid env (control) ──────────────────────────────────────────────
        assert_standard "C6-$label valid-env sanctioned script allowed" \
            "$fn" true "$real" "$valid"
        assert_standard "C6-$label valid-env attacker-tree script rejected" \
            "$fn" false "$evilcmd" "$valid"

        # ── missing env (T4b) ────────────────────────────────────────────────
        assert_standard "C6-$label missing-env sanctioned script still allowed" \
            "$fn" true "$real"
        assert_standard "C6-$label missing-env attacker-tree script still rejected" \
            "$fn" false "$evilcmd"

        # ── stale env (T4a) ──────────────────────────────────────────────────
        assert_standard "C6-$label stale-env sanctioned script still allowed" \
            "$fn" true "$real" "AGENTS_MAIN_ROOT=$STALE"
        assert_standard "C6-$label stale-env attacker-tree script still rejected" \
            "$fn" false "$evilcmd" "AGENTS_MAIN_ROOT=$STALE"

        # ── attacker-supplied env (security row) ─────────────────────────────
        assert_standard "C6-$label attacker AGENTS_MAIN_ROOT cannot sanction its own script" \
            "$fn" false "$evilcmd" "AGENTS_MAIN_ROOT=$evil"
        assert_standard "C6-$label attacker AGENTS_MAIN_ROOT does not break the real script" \
            "$fn" true "$real" "AGENTS_MAIN_ROOT=$evil"

        # ── both-marker forgery in the env (security row) ────────────────────
        assert_standard "C6-$label both-marker forged AGENTS_MAIN_ROOT cannot sanction its own script" \
            "$fn" false "$forgedcmd" "AGENTS_MAIN_ROOT=$forged"
        assert_standard "C6-$label both-marker forged AGENTS_MAIN_ROOT does not break the real script" \
            "$fn" true "$real" "AGENTS_MAIN_ROOT=$forged"

        # ── anti-vacuity: no env state widens the accepted command shape ─────
        assert_standard "C6-$label chaining rejected (valid env)" \
            "$fn" false "$real; rm -rf x" "$valid"
        assert_standard "C6-$label chaining rejected (missing env)" \
            "$fn" false "$real; rm -rf x"
        assert_standard "C6-$label chaining rejected (stale env)" \
            "$fn" false "$real; rm -rf x" "AGENTS_MAIN_ROOT=$STALE"
        assert_standard "C6-$label command substitution rejected (missing env)" \
            "$fn" false "$real \$(rm -rf x)"
        assert_standard "C6-$label redirect rejected (missing env)" \
            "$fn" false "$real > \"$REPO/log.txt\""
        assert_standard "C6-$label sibling script under the real root rejected (missing env)" \
            "$fn" false "bash \"$SCRIPT_CHECKOUT_ROOT_NODE/bin/github-issues/issue-create-dispatch.sh\" --title x"
    done

    run_standard_canary_rows "$evil"
}

# ── Canary file: each attack must be REJECTED and must leave the file alone ──
# A verdict alone cannot see a predicate that answers `false` after its identity
# path already touched the filesystem, so both are asserted, on a throwaway tree.
run_standard_canary_rows() {
    local evil="$1"
    local canary_dir="$TMPDIR_BASE/canary-std"
    mkdir -p "$canary_dir"
    local canary="$canary_dir/protected.txt"
    printf 'CANARY-C6-INTACT\n' > "$canary"
    local before; before="$(cat "$canary")"
    local canary_node; canary_node="$(norm "$canary")"

    assert_standard "C6-canary command substitution naming the canary is rejected" \
        isAllowedComposeDocAppend false \
        "bash \"$SCRIPT_CHECKOUT_ROOT_NODE/bin/compose-doc-append-entry\" --subject \$(rm -f \"$canary_node\")"
    assert_standard "C6-canary redirect onto the canary is rejected" \
        isAllowedClarifyGuardLoop false \
        "bash \"$SCRIPT_CHECKOUT_ROOT_NODE/bin/github-issues/clarify-guard-loop.sh\" 1234 > \"$canary_node\""
    assert_standard "C6-canary attacker-tree chaining onto the canary is rejected" \
        isAllowedComposeDocAppend false \
        "bash \"$evil/bin/compose-doc-append-entry\" --subject x; : > \"$canary_node\"" \
        "AGENTS_MAIN_ROOT=$evil"

    if [ -f "$canary" ] && [ "$(cat "$canary")" = "$before" ]; then
        pass "C6-canary protected file unchanged after cmd-subst / redirect / chaining attacks"
    else
        fail "C6-canary protected file was modified or removed by a predicate call"
    fi
}

# ── Fail-closed: the resolver finds no checkout ─────────────────────────────
# The predicates are loaded from a copy of hooks/ whose root has no `bin`, so both
# resolver candidates fail validation. Creating `bin` afterwards is the control: the
# same copy then allows the same commands. worker_probe comes from seams.sh.

# _fail_closed_phase <want> <note> <command root> [env assignments...]
_fail_closed_phase() {
    local want="$1" note="$2" cmdroot="$3"; shift 3
    local label kind fn rel args cmd got rows=0
    while IFS='|' read -r label kind fn rel args; do
        label="$(_trim "$label")"
        [ -z "$label" ] && continue
        rows=$((rows + 1))
        cmd="bash \"$cmdroot/$(_trim "$rel")\" $(_trim "$args")"
        case "$(_trim "$kind")" in
            worker) got="$(worker_probe "$cmd" "$@")" ;;
            *)      got="$(standard_probe "$(_trim "$fn")" "$cmd" "$@")" ;;
        esac
        expect_eq "C6-null $label: $note" "$got" "$want"
    done <<'TABLE'
isAllowedComposeDocAppend       | standard | isAllowedComposeDocAppend | bin/compose-doc-append-entry               | --subject x
isAllowedClarifyGuardLoop       | standard | isAllowedClarifyGuardLoop | bin/github-issues/clarify-guard-loop.sh    | 1234
isAllowedWorkerScriptInvocation | worker   | -                         | bin/github-issues/issue-create-dispatch.sh | --title release
TABLE
    expect_eq "C6-null all three predicates were asserted: $note" "$rows" "3"
}

run_fail_closed_cases() {
    local copy_raw="$TMPDIR_BASE/nobin"
    mkdir -p "$copy_raw"
    if ! cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$copy_raw/hooks"; then
        fail "C6-null fixture" "could not copy hooks/ into $copy_raw"
        return
    fi
    local copy; copy="$(norm "$copy_raw")"
    local PREDICATE_ROOT="$copy"

    _fail_closed_phase false "no checkout resolves, so the copy's own script is rejected" "$copy"
    _fail_closed_phase false "a valid AGENTS_MAIN_ROOT does not stand in for the missing checkout" \
        "$SCRIPT_CHECKOUT_ROOT_NODE" "AGENTS_MAIN_ROOT=$SCRIPT_CHECKOUT_ROOT_NODE"

    mkdir -p "$copy_raw/bin"
    _fail_closed_phase true "control — with bin/ present the same copy allows its own script" "$copy"
}
