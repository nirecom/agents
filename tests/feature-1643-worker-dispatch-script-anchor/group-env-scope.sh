# Part of tests/feature-1643-worker-dispatch-script-anchor.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# Group G: WHICH NAMES reach a child env. The companion part group-env-branches.sh
# covers the branches that are about VALUES rather than membership.

# ===========================================================================
# Group G — buildEnv credential scope (behavioural counterpart of the static
# registry rows in tests/feature-1643-worker-dispatch-schema.sh Group E)
#
# GH_TOKEN / GITHUB_TOKEN used to sit in the global CHILD_ENV_ALLOWLIST, which
# spawn.js applies to every worker. Combined with Group A's family-worktree
# script anchor that put both credentials into the environment of
# tests/run-all.sh — a script read from the branch under review, i.e. code
# nobody has looked at yet. Moving them to issue-reconcile's envPassthrough is
# only a fix if buildEnv actually distinguishes the workers, so the assertion is
# made on the env buildEnv returns, per worker, with both vars really set in the
# parent process.
#
# The group runs in BOTH directions, because the same allowlist decides both. A
# variable that names WHERE a tool reads its configuration must REACH every
# worker: #1719 was the mirror image of the credential leak — the dispatched `gh`
# inherited no config-location var, landed in a different config directory than
# its parent, and failed auth for every gh-driven worker. The admission rule for
# that set is not restated here; its SSOT is the comment block above
# CHILD_ENV_ALLOWLIST in hooks/lib/worker-dispatch-registry.js. What this group
# adds over the static rows in the schema suite is VALUE IDENTITY through the
# real buildEnv, per worker, with the vars really set in the parent process.
# ===========================================================================
group_g() {
    local name tok want v
    if impl_missing "env/token-reaches-issue-reconcile" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe_with_planted_env env; then
        fail "env/token-reaches-issue-reconcile — probe failed: $PROBE_OUT"
        return
    fi
    # Precondition: without this the "0" rows below would be trivially true.
    assert_eq "env/parent-has-gh-token" "1" "$(pv parent_has_GH_TOKEN)"
    assert_eq "env/parent-has-github-token" "1" "$(pv parent_has_GITHUB_TOKEN)"
    # Same precondition for the positive half: an unset parent var would make
    # every cfg- row below pass on `undefined === undefined`.
    for v in APPDATA ProgramData PROGRAMDATA XDG_CONFIG_HOME GH_CONFIG_DIR; do
        assert_eq "env/parent-has-$v" "1" "$(pv "parent_cfg_$v")"
    done
    assert_eq "env/worker-set-is-the-known-nine" \
        "commit-push,doc-append,issue-close-finalize,issue-close-stage,issue-reconcile,session-close-gate,test-runner,worktree-backup,worktree-copy" \
        "$(pv worker_names)"

    while IFS='|' read -r name want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        for tok in GH_TOKEN GITHUB_TOKEN; do
            assert_eq "env/$name/$tok" "$want" "$(pv "${tok}__${name}")"
        done
        # Per-worker non-vacuity: the env is populated, just not with credentials.
        assert_eq "env/$name/path-still-present" "1" "$(pv "PATHOK__${name}")"
        assert_eq "env/$name/acd-pinned-to-anchor" "1" "$(pv "ACDOK__${name}")"
        # …and the positive half, for every worker: buildEnv applies the allowlist
        # unconditionally, so a config-location var reaches all nine or none.
        for v in APPDATA ProgramData PROGRAMDATA XDG_CONFIG_HOME GH_CONFIG_DIR; do
            assert_eq "env/$name/cfg-$v" "1" "$(pv "CFG__${v}__${name}")"
        done
    done <<'TABLE'
issue-reconcile   | 1
commit-push       | 1
issue-close-stage | 1
issue-close-finalize | 1
test-runner       | 0
worktree-copy     | 0
worktree-backup   | 0
doc-append        | 0
session-close-gate | 0
TABLE

    case "$(pv extra_undeclared_err)" in
        *does\ not\ declare\ the\ child\ env\ var*) pass "env/extra-undeclared-rejected" ;;
        *) fail "env/extra-undeclared-rejected — got: $(pv extra_undeclared_err)" ;;
    esac
    assert_eq "env/extra-declared-accepted" "NO_THROW" "$(pv extra_declared_err)"
}
