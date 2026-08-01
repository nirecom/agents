# tests/fix-1630-config-dir-resolver/seams.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/lib/agents-config-dir.js
# Tags: hook, worktree, config-dir, resolver, enforce, security, scope:issue-specific
#
# #1673 deleted hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# together with the Bash-tool `eval "$(... bash "<finalize-script>" ...)"` path it
# was the sole ALLOW route for. The T4-ctrl / T4a / T4b rows below drive the three
# live single-line finalize eval shapes through the REAL hook; before #1673 the
# overlay ALLOWed the correctly-scoped form and the resolver work (#1630) decided
# whether AGENTS_CONFIG_DIR being missing/stale still recovered that ALLOW. With
# the overlay gone there is no identity match left for these shapes at all — they
# now BLOCK unconditionally, in every AGENTS_CONFIG_DIR state, and stand as
# retired-capability pins (same treatment as tests/fix-1600-finalize-worker-overlay
# /allow-cases.sh and tests/fix-1630-overlay-cross-validation.sh).
#
# The env-state axis (correct / missing / stale) is kept in the row names even
# though every row now asserts BLOCK: it documents that the retirement is total —
# no AGENTS_CONFIG_DIR value brings the eval path back — rather than collapsing
# the three rows into one and losing that coverage.
#
# T4a-attack / T4b-attack rows below were ALREADY block-under-#1630 (the resolver
# refuses to let an attacker-supplied AGENTS_CONFIG_DIR sanction its own finalize
# tree); #1673 makes them block for the simpler reason (no eval identity match at
# all), so their expected verdict is unchanged.
#
# The resolver itself (C4/#1630) is still live and exercised elsewhere in this
# suite: the module-level rows below (sanctioned bare `bash "<script>"` identity)
# and resolver-units.sh / standard-predicates.sh / debug-and-cache.sh all cover
# genuinely-current resolveAgentsConfigDir() call sites untouched by #1673.
#
# Both seams are driven through the REAL hook (hooks/enforce-worktree.js) from a
# throwaway git main worktree, so the printed verdict is the same BLOCK/ALLOW a
# human sees in a session.
#
# Why the three finalize overlay forms and not `bash "<acd>/bin/...script.sh"`:
# a bare sanctioned bash invocation is not a Bash write at all (verified: the
# hook ALLOWs it regardless of AGENTS_CONFIG_DIR), and adding a redirect into a
# registered linked worktree is allowed by the generic write-scope path, so
# neither form can observe the resolver. The finalize `eval "$( ... )"` forms are
# fail-closed by default and reach ALLOW only through the worker-script overlay,
# which is what makes them the sharp repro. The module-level rows at the end
# cover the bare-invocation identity that the hook cannot express.

# ── Hook-level seam (BLOCK / ALLOW verdicts) ────────────────────────────────

run_seam_cases() {

    local fsd="$REAL_FSD"
    local statefile="$PLANS/sid-finalize-state-1234.json"
    local outcome="$PLANS/sid-issue-close-outcome.json"

    # The three live single-line shapes /issue-close-finalize emits. The inline
    # AGENTS_CONFIG_DIR="..." assignment inside the eval is part of the COMMAND
    # TEXT; it never reaches the hook's own process environment, which is why
    # these forms are the sharpest missing-env repro.
    local f_initial f_loop f_terminal
    f_initial="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$AGENTS_DIR_NODE" "$fsd" "$REPO" "$fsd")"
    f_loop="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "%s")"' \
        "$AGENTS_DIR_NODE" "$fsd" "$fsd" "$statefile" "accept")"
    f_terminal="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-finalize-terminal.sh" "%s" "%s" "%s")"' \
        "$AGENTS_DIR_NODE" "$fsd" "$statefile" "1234" "$outcome")"

    local form cmd
    for form in initial loop terminal; do
        case "$form" in
            initial)  cmd="$f_initial" ;;
            loop)     cmd="$f_loop" ;;
            terminal) cmd="$f_terminal" ;;
        esac
        # Control — the overlay's ALLOW route no longer exists (#1673): a
        # correctly-scoped finalize eval blocks the same as every other state.
        assert_guard "T4-ctrl finalize $form, AGENTS_CONFIG_DIR correct — eval path retired (#1673)" \
            block "$cmd" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"
        # T4b — env var absent entirely (subagent / Bash-tool subprocess).
        assert_guard "T4b finalize $form, AGENTS_CONFIG_DIR missing — eval path retired (#1673)" \
            block "$cmd"
        # T4a — env var present but pointing at a marker-less directory.
        assert_guard "T4a finalize $form, AGENTS_CONFIG_DIR stale — eval path retired (#1673)" \
            block "$cmd" "AGENTS_CONFIG_DIR=$STALE"
    done

    # ── Attack scenario 1: attacker-controlled AGENTS_CONFIG_DIR ─────────────
    # A writable directory the attacker fully controls, holding a copy of the
    # finalize scripts. It carries NEITHER marker. Every value inside the
    # command text is internally consistent with it, so today's raw-env trust
    # makes the overlay accept it: the hook ALLOWs an eval of attacker-owned
    # script content from the main worktree. After C4 the resolver rejects the
    # candidate (marker validation), falls through to the module-relative agents
    # root, and the cross-check fails -> BLOCK.
    local evil_raw="$TMPDIR_BASE/evil-acd"
    mkdir -p "$evil_raw/skills/issue-close-finalize"
    cp -r "$AGENTS_DIR/skills/issue-close-finalize/scripts" \
          "$evil_raw/skills/issue-close-finalize/scripts" 2>/dev/null
    local evil; evil="$(norm "$evil_raw")"
    local evil_fsd="$evil/skills/issue-close-finalize/scripts"

    local e_initial
    e_initial="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$evil" "$evil_fsd" "$REPO" "$evil_fsd")"
    assert_guard "T4a-attack attacker-controlled AGENTS_CONFIG_DIR cannot sanction its own finalize script" \
        block "$e_initial" "AGENTS_CONFIG_DIR=$evil"

    # Same attacker tree, but the hook's env is missing/stale rather than
    # attacker-set — the resolver must still land on the real agents root.
    assert_guard "T4b-attack attacker finalize tree stays blocked when AGENTS_CONFIG_DIR is missing" \
        block "$e_initial"
    assert_guard "T4a-attack attacker finalize tree stays blocked when AGENTS_CONFIG_DIR is stale" \
        block "$e_initial" "AGENTS_CONFIG_DIR=$STALE"

    # ── Attack scenario 2: unregistered script under the REAL agents root ────
    # Identity is validated against the #1600 registry, not merely against the
    # config dir, so recovering the config dir must NOT widen what is allowed.
    local f_evil
    f_evil="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-evil.sh" "%s" "%s" "%s")"' \
        "$AGENTS_DIR_NODE" "$fsd" "$statefile" "1234" "$outcome")"
    assert_guard "T4-ctrl unregistered finalize script blocked (AGENTS_CONFIG_DIR correct)" \
        block "$f_evil" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"
    assert_guard "T4b unregistered finalize script stays blocked (AGENTS_CONFIG_DIR missing)" \
        block "$f_evil"
    assert_guard "T4a unregistered finalize script stays blocked (AGENTS_CONFIG_DIR stale)" \
        block "$f_evil" "AGENTS_CONFIG_DIR=$STALE"

    # ── Attack scenario 3: sanctioned identity, out-of-registry write target ──
    # A redirect into the MAIN worktree must stay blocked however the config dir
    # was resolved (the write-scope tail is unchanged by C4).
    assert_guard "T4-ctrl sanctioned script redirecting into the main worktree stays blocked" \
        block "bash \"$REAL_DISPATCH\" --title release > \"$REPO/log.txt\"" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"

    run_worker_module_rows "$evil"
}

# ── Module-level seam (true / false) ────────────────────────────────────────
#
# Skipped-Because: the bare `bash "<acd>/bin/<script>.sh" <args>` identity has no
# hook-level expression — it is not a Bash write, so the hook ALLOWs it for every
# AGENTS_CONFIG_DIR value and a hook-level row would be vacuously green in both
# directions. It is asserted directly on isAllowedWorkerScriptInvocation instead.

# worker_probe <command> [env assignments...] -> "true" | "false" | "ERROR: ..."
worker_probe() {
    local cmd="$1"; shift
    run_with_timeout 30 env -u AGENTS_CONFIG_DIR "$@" node -e '
      const path = require("path");
      const mod = path.join(process.argv[1], "hooks", "enforce-worktree",
                            "main-worktree-allows", "worker-script.js");
      let f;
      try { f = require(mod).isAllowedWorkerScriptInvocation; }
      catch (e) { console.log("ERROR: " + e.message); process.exit(0); }
      if (typeof f !== "function") { console.log("ERROR: not exported"); process.exit(0); }
      try { console.log(String(f(process.argv[2], process.argv[3]))); }
      catch (e) { console.log("ERROR: threw " + e.message); }
    ' "$AGENTS_DIR_NODE" "$cmd" "$REPO" 2>&1
}

assert_worker() {
    local name="$1" want="$2" cmd="$3"; shift 3
    assert_eq "$name" "$(worker_probe "$cmd" "$@")" "$want"
}

run_worker_module_rows() {
    local evil="$1"
    local evil_bin="$evil/bin/github-issues"
    mkdir -p "$(if command -v cygpath >/dev/null 2>&1; then cygpath -u "$evil_bin"; else echo "$evil_bin"; fi)"

    local sanctioned="bash \"$REAL_DISPATCH\" --title release"
    local nonsanctioned="bash \"$evil_bin/issue-create-dispatch.sh\" --title release"

    assert_worker "T4-ctrl module: sanctioned script with a correct AGENTS_CONFIG_DIR" \
        true "$sanctioned" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"
    assert_worker "T4-ctrl module: non-sanctioned script with a correct AGENTS_CONFIG_DIR" \
        false "$nonsanctioned" "AGENTS_CONFIG_DIR=$AGENTS_DIR_NODE"

    assert_worker "T4a module: stale AGENTS_CONFIG_DIR still allows the sanctioned script" \
        true "$sanctioned" "AGENTS_CONFIG_DIR=$STALE"
    assert_worker "T4a module: stale AGENTS_CONFIG_DIR does NOT allow a non-sanctioned script" \
        false "$nonsanctioned" "AGENTS_CONFIG_DIR=$STALE"
    assert_worker "T4a module: attacker-controlled AGENTS_CONFIG_DIR cannot sanction its own script" \
        false "$nonsanctioned" "AGENTS_CONFIG_DIR=$evil"

    assert_worker "T4b module: missing AGENTS_CONFIG_DIR still allows the sanctioned script" \
        true "$sanctioned"
    assert_worker "T4b module: missing AGENTS_CONFIG_DIR does NOT allow a non-sanctioned script" \
        false "$nonsanctioned"
}
