# tests/fix-1630-config-dir-resolver/standard-predicates.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/lib/agents-config-dir.js
# Tags: hook, worktree, config-dir, resolver, enforce, security, scope:issue-specific
#
# STATUS (pre-C4 RED gate). Sourced by tests/fix-1630-config-dir-resolver.sh.
#   valid-env rows    -> GREEN today (must stay green after C4).
#   missing-env rows  -> RED today: both predicates do `if (!acd) return false;`.
#   stale-env rows    -> RED today: the raw env value is joined with bin/... so the
#                        identity comparison misses the real script.
#   attacker-path row -> RED today AND it is the security row: an attacker-supplied
#                        AGENTS_CONFIG_DIR currently sanctions a script inside the
#                        attacker's own tree.
#
# C6 — resolver integration must be symmetric across ALL THREE mandated entry
# points. seams.sh covers isAllowedWorkerScriptInvocation; this file covers the
# other two, isAllowedComposeDocAppend and isAllowedClarifyGuardLoop, with the
# same four env states each (valid / missing / stale / attacker) so that a fix
# applied to only one call site cannot pass.
#
# Module-level rather than hook-level for the same reason seams.sh records: a
# bare `bash "<acd>/bin/<script>"` is not a Bash write, so the hook ALLOWs it for
# every AGENTS_CONFIG_DIR value and a hook-level row would be vacuously green in
# both directions.
#
# Skipped-Because: an attacker directory that forges BOTH markers
# (<d>/hooks/enforce-worktree.js and <d>/bin) is deliberately NOT asserted here.
# The C4 contract validates markers and adopts such a candidate by design; the
# threat it addresses is a stale/hostile path that is not a config dir, not a
# full config-dir forgery (which already implies write access to a tree the user
# executes hooks from).

# standard_probe <fnName> <cmd> [env assignments...] -> "true"|"false"|"ERROR: ..."
standard_probe() {
    local fn="$1" cmd="$2"; shift 2
    run_with_timeout 30 env -u AGENTS_CONFIG_DIR "$@" node -e '
      const path = require("path");
      const mod = path.join(process.argv[1], "hooks", "enforce-worktree",
                            "main-worktree-allows", "standard.js");
      let m;
      try { m = require(mod); }
      catch (e) { console.log("ERROR: " + e.message); process.exit(0); }
      const f = m[process.argv[2]];
      if (typeof f !== "function") { console.log("ERROR: not exported"); process.exit(0); }
      try { console.log(String(f(process.argv[3], process.argv[4]))); }
      catch (e) { console.log("ERROR: threw " + e.message); }
    ' "$AGENTS_DIR_NODE" "$fn" "$cmd" "$REPO" 2>&1
}

assert_standard() {
    local name="$1" fn="$2" want="$3" cmd="$4"; shift 4
    assert_eq "$name" "$(standard_probe "$fn" "$cmd" "$@")" "$want"
}

run_standard_predicate_cases() {
    # An attacker-owned tree that carries `bin` but NOT hooks/enforce-worktree.js,
    # so C4's 2-point marker validation must reject it and fall through.
    local evil_raw="$TMPDIR_BASE/evil-std"
    mkdir -p "$evil_raw/bin/github-issues"
    : > "$evil_raw/bin/compose-doc-append-entry"
    : > "$evil_raw/bin/github-issues/clarify-guard-loop.sh"
    local evil; evil="$(norm "$evil_raw")"

    # fn | real sanctioned command | attacker-tree command | short label
    local fn real evilcmd label
    for label in compose clarify; do
        case "$label" in
            compose)
                fn=isAllowedComposeDocAppend
                real="bash \"$AGENTS_DIR_NODE/bin/compose-doc-append-entry\" --subject x"
                evilcmd="bash \"$evil/bin/compose-doc-append-entry\" --subject x"
                ;;
            clarify)
                fn=isAllowedClarifyGuardLoop
                real="bash \"$AGENTS_DIR_NODE/bin/github-issues/clarify-guard-loop.sh\" 1234"
                evilcmd="bash \"$evil/bin/github-issues/clarify-guard-loop.sh\" 1234"
                ;;
        esac

        # ── valid env (control — GREEN today, must stay green) ───────────────
        assert_standard "C6-$label valid-env sanctioned script allowed" \
            "$fn" true "$real" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"
        assert_standard "C6-$label valid-env attacker-tree script rejected" \
            "$fn" false "$evilcmd" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"

        # ── missing env (T4b) ────────────────────────────────────────────────
        assert_standard "C6-$label missing-env sanctioned script still allowed" \
            "$fn" true "$real"
        assert_standard "C6-$label missing-env attacker-tree script still rejected" \
            "$fn" false "$evilcmd"

        # ── stale env (T4a) ──────────────────────────────────────────────────
        assert_standard "C6-$label stale-env sanctioned script still allowed" \
            "$fn" true "$real" "AGENTS_CONFIG_DIR=$STALE"
        assert_standard "C6-$label stale-env attacker-tree script still rejected" \
            "$fn" false "$evilcmd" "AGENTS_CONFIG_DIR=$STALE"

        # ── attacker-supplied env (security row) ─────────────────────────────
        assert_standard "C6-$label attacker AGENTS_CONFIG_DIR cannot sanction its own script" \
            "$fn" false "$evilcmd" "AGENTS_CONFIG_DIR=$evil"
        assert_standard "C6-$label attacker AGENTS_CONFIG_DIR does not break the real script" \
            "$fn" true "$real" "AGENTS_CONFIG_DIR=$evil"

        # ── anti-vacuity: recovering the config dir must not widen the shape ──
        # These stay false in every env state; if the resolver work accidentally
        # relaxed the argTail scan, exactly these rows flip.
        assert_standard "C6-$label chaining rejected (valid env)" \
            "$fn" false "$real; rm -rf x" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"
        assert_standard "C6-$label chaining rejected (missing env)" \
            "$fn" false "$real; rm -rf x"
        assert_standard "C6-$label chaining rejected (stale env)" \
            "$fn" false "$real; rm -rf x" "AGENTS_CONFIG_DIR=$STALE"
        assert_standard "C6-$label command substitution rejected (missing env)" \
            "$fn" false "$real \$(rm -rf x)"
        assert_standard "C6-$label redirect rejected (missing env)" \
            "$fn" false "$real > \"$REPO/log.txt\""
        assert_standard "C6-$label sibling script under the real root rejected (missing env)" \
            "$fn" false "bash \"$AGENTS_DIR_NODE/bin/github-issues/issue-create-dispatch.sh\" --title x"
    done

    run_standard_canary_rows "$evil"
}

# ── C8 Protection Pattern 1: canary files, asserted unchanged ───────────────
# The predicates above return a verdict; a verdict assertion alone cannot see a
# predicate that answers `false` while its identity/normalisation path has
# already touched the filesystem. Each attack row below runs against a throwaway
# temp tree holding a canary file (never inside the repo) and asserts byte
# equality afterwards.
run_standard_canary_rows() {
    local evil="$1"
    local canary_dir="$TMPDIR_BASE/canary-std"
    mkdir -p "$canary_dir"
    local canary="$canary_dir/protected.txt"
    printf 'CANARY-C6-INTACT\n' > "$canary"
    local before; before="$(cat "$canary")"
    local canary_node; canary_node="$(norm "$canary")"

    # Attack payloads whose text names the canary as a write target.
    standard_probe isAllowedComposeDocAppend \
        "bash \"$AGENTS_DIR_NODE/bin/compose-doc-append-entry\" --subject \$(rm -f \"$canary_node\")" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE" >/dev/null
    standard_probe isAllowedClarifyGuardLoop \
        "bash \"$AGENTS_DIR_NODE/bin/github-issues/clarify-guard-loop.sh\" 1234 > \"$canary_node\"" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE" >/dev/null
    standard_probe isAllowedComposeDocAppend \
        "bash \"$evil/bin/compose-doc-append-entry\" --subject x; : > \"$canary_node\"" \
        "AGENTS_CONFIG_DIR=$evil" >/dev/null

    if [ -f "$canary" ] && [ "$(cat "$canary")" = "$before" ]; then
        pass "C6-canary protected file unchanged after cmd-subst / redirect / chaining attacks"
    else
        fail "C6-canary protected file was modified or removed by a predicate call"
    fi
}
