# tests/hooks/fix-1630-script-checkout-root-resolver/seams.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/lib/script-checkout-root.js
# Tags: hook, worktree, agents-main-root, resolver, enforce, security, scope:issue-specific
# Sourced by tests/hooks/fix-1630-script-checkout-root-resolver.sh.
# Hook-level rows run the REAL hook from a throwaway git main worktree. The identity
# table uses shapes that reach the predicate's root comparison; the retired finalize
# shapes (#1673) are rejected by SHAPE before it, and their row names claim only that.
# Module-level rows assert isAllowedWorkerScriptInvocation directly: a bare sanctioned
# `bash "<script>"` is not a Bash write, so the hook cannot tell the states apart.

# ── Hook-level seam (BLOCK / ALLOW verdicts) ────────────────────────────────
run_seam_cases() {
    local fsd="$REAL_FSD"
    local statefile="$PLANS/sid-finalize-state-1234.json"
    local outcome="$PLANS/sid-issue-close-outcome.json"
    local valid="AGENTS_MAIN_ROOT=$SCRIPT_CHECKOUT_ROOT_NODE"

    # Harness control only: a command that writes nothing prints `{}` whatever script
    # it names, so this pair proves the harness can report ALLOW and nothing about
    # script identity. Attack scenario 3 is the first command plus a redirect.
    assert_guard "T4-ctrl a command that writes nothing is allowed (sanctioned script)" \
        allow "bash \"$REAL_DISPATCH\" --title release" "$valid"
    assert_guard "T4-ctrl a command that writes nothing is allowed (unregistered script: identity is not consulted)" \
        allow "bash \"$SCRIPT_CHECKOUT_ROOT_NODE/bin/github-issues/run-evil.sh\" --title release" "$valid"

    # The three single-line shapes /issue-close-finalize used to emit. The inline
    # AGENTS_MAIN_ROOT="..." is COMMAND TEXT; it never reaches the hook's environment,
    # and it makes the segment match neither sanctioned shape, so these rows stop at
    # the shape check and never reach the identity comparison.
    local f_initial f_loop f_terminal
    f_initial="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$SCRIPT_CHECKOUT_ROOT_NODE" "$fsd" "$REPO" "$fsd")"
    f_loop="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "%s")"' \
        "$SCRIPT_CHECKOUT_ROOT_NODE" "$fsd" "$fsd" "$statefile" "accept")"
    f_terminal="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" bash "%s/run-finalize-terminal.sh" "%s" "%s" "%s")"' \
        "$SCRIPT_CHECKOUT_ROOT_NODE" "$fsd" "$statefile" "1234" "$outcome")"

    local form cmd
    for form in initial loop terminal; do
        case "$form" in
            initial)  cmd="$f_initial" ;;
            loop)     cmd="$f_loop" ;;
            terminal) cmd="$f_terminal" ;;
        esac
        assert_guard "T4-shape finalize $form shape is rejected, AGENTS_MAIN_ROOT valid (#1673)" \
            block "$cmd" "$valid"
        assert_guard "T4-shape finalize $form shape is rejected, AGENTS_MAIN_ROOT missing (#1673)" \
            block "$cmd"
        assert_guard "T4-shape finalize $form shape is rejected, AGENTS_MAIN_ROOT stale (#1673)" \
            block "$cmd" "AGENTS_MAIN_ROOT=$STALE"
    done

    # ── Retired shape, attacker-controlled tree ─────────────────────────────
    # A directory the attacker controls, holding a copy of the finalize scripts and
    # neither marker; every value inside the command text is consistent with it.
    # Same shape as above, so these are shape rejections too (identity rows: below).
    local evil_raw="$TMPDIR_BASE/evil-script-checkout-root"
    mkdir -p "$evil_raw/skills/issue-close-finalize"
    if ! cp -r "$SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/scripts" \
            "$evil_raw/skills/issue-close-finalize/scripts"; then
        fail "T4a-attack fixture" "could not copy the finalize scripts into $evil_raw"
    fi
    local evil; evil="$(norm "$evil_raw")"
    local evil_fsd="$evil/skills/issue-close-finalize/scripts"

    local e_initial
    e_initial="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$evil" "$evil_fsd" "$REPO" "$evil_fsd")"
    assert_guard "T4-shape retired finalize shape naming an attacker tree is rejected (AGENTS_MAIN_ROOT = that tree)" \
        block "$e_initial" "AGENTS_MAIN_ROOT=$evil"
    assert_guard "T4-shape retired finalize shape naming an attacker tree is rejected (AGENTS_MAIN_ROOT missing)" \
        block "$e_initial"
    assert_guard "T4-shape retired finalize shape naming an attacker tree is rejected (AGENTS_MAIN_ROOT stale)" \
        block "$e_initial" "AGENTS_MAIN_ROOT=$STALE"

    # ── Retired shape, unregistered script under the REAL checkout ──────────
    local f_evil
    f_evil="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" bash "%s/run-evil.sh" "%s" "%s" "%s")"' \
        "$SCRIPT_CHECKOUT_ROOT_NODE" "$fsd" "$statefile" "1234" "$outcome")"
    assert_guard "T4-shape retired finalize shape naming an unregistered script is rejected (AGENTS_MAIN_ROOT valid)" \
        block "$f_evil" "$valid"
    assert_guard "T4-shape retired finalize shape naming an unregistered script is rejected (AGENTS_MAIN_ROOT missing)" \
        block "$f_evil"
    assert_guard "T4-shape retired finalize shape naming an unregistered script is rejected (AGENTS_MAIN_ROOT stale)" \
        block "$f_evil" "AGENTS_MAIN_ROOT=$STALE"

    # ── Attack scenario 3: sanctioned identity, write target in the main worktree ──
    assert_guard "T4-ctrl sanctioned script redirecting into the main worktree stays blocked" \
        block "bash \"$REAL_DISPATCH\" --title release > \"$REPO/log.txt\"" "$valid"

    run_hook_identity_rows
}

# ── Hook-level identity rows ────────────────────────────────────────────────
# Both shapes are Bash writes the hook cannot settle before the predicate, so the
# verdict is the predicate's identity comparison: `eval` of a bare `bash "<path>"` (no
# write target), and a redirect into the linked worktree with that worktree in scope.
# Every allow row has the same shape with an unregistered script next to it.
# root=literal is the unexpanded `$AGENTS_MAIN_ROOT/` text: the hook never rewrites it,
# in either shape, so every such row is a block and the reason carries a hint (#2561).
# Columns: name | want | shape | root | script | AGENTS_MAIN_ROOT state
run_hook_identity_rows() {
    local forged_raw="$TMPDIR_BASE/forged-hook"
    mkdir -p "$forged_raw/hooks" "$forged_raw/bin/github-issues" \
        "$forged_raw/skills/issue-close-finalize/scripts"
    : > "$forged_raw/hooks/enforce-worktree.js"
    : > "$forged_raw/bin/github-issues/issue-create-dispatch.sh"
    : > "$forged_raw/skills/issue-close-finalize/scripts/pre-flight.sh"
    local forged; forged="$(norm "$forged_raw")"
    local scope="ENFORCE_WORKTREE_ADDITIONAL_REPOS=$REPO;$REPO/.wt/x"
    local log="$REPO/.wt/x/log.txt"

    local name want shape root script state rel cmd rows=0
    while IFS='|' read -r name want shape root script state; do
        name="$(_trim "$name")"
        [ -z "$name" ] && continue
        rows=$((rows + 1))
        shape="$(_trim "$shape")"
        case "$(_trim "$root")" in
            real)    root="$SCRIPT_CHECKOUT_ROOT_NODE" ;;
            forged)  root="$forged" ;;
            literal) root='$AGENTS_MAIN_ROOT' ;;
            *)       fail "$name" "unknown root column"; continue ;;
        esac
        case "$shape/$(_trim "$script")" in
            eval/sanctioned)       rel="skills/issue-close-finalize/scripts/pre-flight.sh" ;;
            eval/unregistered)     rel="skills/issue-close-finalize/scripts/run-evil.sh" ;;
            redirect/sanctioned)   rel="bin/github-issues/issue-create-dispatch.sh" ;;
            redirect/unregistered) rel="bin/github-issues/run-evil.sh" ;;
            *)                     fail "$name" "unknown shape or script column"; continue ;;
        esac
        case "$(_trim "$state")" in
            valid)   set -- "AGENTS_MAIN_ROOT=$SCRIPT_CHECKOUT_ROOT_NODE" ;;
            stale)   set -- "AGENTS_MAIN_ROOT=$STALE" ;;
            forged)  set -- "AGENTS_MAIN_ROOT=$forged" ;;
            missing) set -- ;;
            *)       fail "$name" "unknown state column"; continue ;;
        esac
        if [ "$shape" = "eval" ]; then
            cmd="eval \"\$(bash \"$root/$rel\")\""
        else
            cmd="bash \"$root/$rel\" --title x > \"$log\""
            set -- "$@" "$scope"
        fi
        assert_guard "$name" "$(_trim "$want")" "$cmd" "$@"
    done <<'TABLE'
T4-id eval: the real checkout's sanctioned script is allowed (valid)              | allow | eval     | real    | sanctioned   | valid
T4-id eval: an unregistered script in the same shape is blocked (valid)           | block | eval     | real    | unregistered | valid
T4-id eval: the real checkout's sanctioned script is allowed (missing)            | allow | eval     | real    | sanctioned   | missing
T4-id eval: an unregistered script in the same shape is blocked (missing)         | block | eval     | real    | unregistered | missing
T4-id eval: the real checkout's sanctioned script is allowed (stale)              | allow | eval     | real    | sanctioned   | stale
T4-id eval: an unregistered script in the same shape is blocked (stale)           | block | eval     | real    | unregistered | stale
T4-id eval: the real checkout's sanctioned script is allowed (forged env)         | allow | eval     | real    | sanctioned   | forged
T4-id eval: an unregistered script in the same shape is blocked (forged env)      | block | eval     | real    | unregistered | forged
T4-id eval: a forged tree named by AGENTS_MAIN_ROOT cannot sanction its script    | block | eval     | forged  | sanctioned   | forged
T4-id eval: a forged tree's script is blocked with AGENTS_MAIN_ROOT missing       | block | eval     | forged  | sanctioned   | missing
T4-id redirect: the real checkout's sanctioned script is allowed (valid)          | allow | redirect | real    | sanctioned   | valid
T4-id redirect: an unregistered script in the same shape is blocked (valid)       | block | redirect | real    | unregistered | valid
T4-id redirect: the real checkout's sanctioned script is allowed (forged env)     | allow | redirect | real    | sanctioned   | forged
T4-id redirect: an unregistered script in the same shape is blocked (forged env)  | block | redirect | real    | unregistered | forged
T4-id redirect: a forged tree named by AGENTS_MAIN_ROOT cannot sanction its script | block | redirect | forged | sanctioned   | forged
T4-id redirect: a forged tree's script is blocked with AGENTS_MAIN_ROOT missing   | block | redirect | forged  | sanctioned   | missing
T4-lit eval: literal $AGENTS_MAIN_ROOT path is blocked, never rewritten (valid)   | block | eval     | literal | sanctioned   | valid
T4-lit eval: literal $AGENTS_MAIN_ROOT path is blocked, never rewritten (missing) | block | eval     | literal | sanctioned   | missing
T4-lit eval: literal $AGENTS_MAIN_ROOT path is blocked, never rewritten (stale)   | block | eval     | literal | sanctioned   | stale
T4-lit eval: literal $AGENTS_MAIN_ROOT path is blocked, never rewritten (forged env) | block | eval  | literal | sanctioned   | forged
T4-lit eval: literal $AGENTS_MAIN_ROOT path to an unregistered script is blocked  | block | eval     | literal | unregistered | valid
T4-lit redirect: literal $AGENTS_MAIN_ROOT path is blocked in the redirect shape too | block | redirect | literal | sanctioned | valid
TABLE
    expect_eq "T4-id the identity table asserted every one of its rows" "$rows" "22"

    # The block reason of a literal-variable path names the variable it came through.
    root='$AGENTS_MAIN_ROOT'
    run_guard "eval \"\$(bash \"$root/skills/issue-close-finalize/scripts/pre-flight.sh\")\"" \
        "AGENTS_MAIN_ROOT=$SCRIPT_CHECKOUT_ROOT_NODE" || :
    if printf '%s' "$GUARD_OUT" | grep -qF "is allowed from the main worktree, but this command names it through $root"; then
        pass "T4-lit eval: the block reason carries the variable-path hint"
    else
        fail "T4-lit eval: the block reason carries the variable-path hint" "out=$GUARD_OUT"
    fi

    # The hook only judges; nothing above may have created the redirect target.
    if [ -e "$REPO_RAW/.wt/x/log.txt" ] || [ -e "$REPO_RAW/log.txt" ]; then
        fail "T4-id no hook row created a redirect target" "log.txt exists in the fixture"
    else
        pass "T4-id no hook row created a redirect target"
    fi
}

# ── Module-level seam (true / false) ────────────────────────────────────────

# worker_probe <command> [env assignments...] -> "true" | "false" | "ERROR: ..."
# The predicate is loaded from PREDICATE_ROOT when a caller sets it (a copied tree).
worker_probe() {
    local cmd="$1"; shift
    run_with_timeout 30 env -u AGENTS_MAIN_ROOT -u AGENTS_HOOK_DEBUG "$@" node -e '
      const path = require("path");
      const mod = path.join(process.argv[1], "hooks", "enforce-worktree",
                            "main-worktree-allows", "worker-script.js");
      let f;
      try { f = require(mod).isAllowedWorkerScriptInvocation; }
      catch (e) { console.log("ERROR: " + e.message.split("\n")[0]); process.exit(0); }
      if (typeof f !== "function") { console.log("ERROR: not exported"); process.exit(0); }
      try { console.log(String(f(process.argv[2], process.argv[3]))); }
      catch (e) { console.log("ERROR: threw " + e.message.split("\n")[0]); }
    ' "${PREDICATE_ROOT:-$SCRIPT_CHECKOUT_ROOT_NODE}" "$cmd" "$REPO" 2>&1
}

run_worker_module_cases() {
    # Attacker tree: the script path and `bin` exist, hooks/enforce-worktree.js does not.
    local evil_raw="$TMPDIR_BASE/evil-worker"
    mkdir -p "$evil_raw/bin/github-issues"
    : > "$evil_raw/bin/github-issues/issue-create-dispatch.sh"
    local evil; evil="$(norm "$evil_raw")"

    # Forged tree: BOTH markers, so it would validate if the variable were a candidate.
    local forged_raw="$TMPDIR_BASE/forged-worker"
    mkdir -p "$forged_raw/bin/github-issues" "$forged_raw/hooks"
    : > "$forged_raw/hooks/enforce-worktree.js"
    : > "$forged_raw/bin/github-issues/issue-create-dispatch.sh"
    local forged; forged="$(norm "$forged_raw")"

    # Columns: name | want | script tree (real/evil/forged) | AGENTS_MAIN_ROOT state
    local name want tree state cmd root rows=0
    while IFS='|' read -r name want tree state; do
        name="$(_trim "$name")"
        [ -z "$name" ] && continue
        rows=$((rows + 1))
        case "$(_trim "$tree")" in
            real)   root="$SCRIPT_CHECKOUT_ROOT_NODE" ;;
            evil)   root="$evil" ;;
            forged) root="$forged" ;;
            *)      fail "$name" "unknown tree column"; continue ;;
        esac
        cmd="bash \"$root/bin/github-issues/issue-create-dispatch.sh\" --title release"
        case "$(_trim "$state")" in
            valid)    set -- "AGENTS_MAIN_ROOT=$SCRIPT_CHECKOUT_ROOT_NODE" ;;
            stale)    set -- "AGENTS_MAIN_ROOT=$STALE" ;;
            attacker) set -- "AGENTS_MAIN_ROOT=$evil" ;;
            forged)   set -- "AGENTS_MAIN_ROOT=$forged" ;;
            *)        set -- ;;
        esac
        expect_eq "$name" "$(worker_probe "$cmd" "$@")" "$(_trim "$want")"
    done <<'TABLE'
T4-ctrl module: valid AGENTS_MAIN_ROOT allows the sanctioned script                  | true  | real   | valid
T4-ctrl module: valid AGENTS_MAIN_ROOT does not allow an attacker-tree script        | false | evil   | valid
T4b module: missing AGENTS_MAIN_ROOT still allows the sanctioned script              | true  | real   | missing
T4b module: missing AGENTS_MAIN_ROOT does not allow an attacker-tree script          | false | evil   | missing
T4a module: stale AGENTS_MAIN_ROOT still allows the sanctioned script                | true  | real   | stale
T4a module: stale AGENTS_MAIN_ROOT does not allow an attacker-tree script            | false | evil   | stale
T4a module: attacker-controlled AGENTS_MAIN_ROOT cannot sanction its own script      | false | evil   | attacker
T4a module: attacker-controlled AGENTS_MAIN_ROOT does not break the sanctioned script | true | real   | attacker
T4a module: both-marker forged AGENTS_MAIN_ROOT cannot sanction its own script       | false | forged | forged
T4a module: both-marker forged AGENTS_MAIN_ROOT does not break the sanctioned script | true  | real   | forged
T4b module: a both-marker forged tree is not sanctioned with AGENTS_MAIN_ROOT missing | false | forged | missing
TABLE
    expect_eq "T4 module: the state table asserted every one of its rows" "$rows" "11"
}
