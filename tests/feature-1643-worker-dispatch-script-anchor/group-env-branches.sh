# Part of tests/feature-1643-worker-dispatch-script-anchor.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# The buildEnv branches that are about VALUES rather than membership:
#   H the missing-value branch  (an allowlisted name the parent does not hold)
#   I value edge cases          (empty / nonexistent / spaced / non-ASCII / meta)
#   J idempotency               (two calls agree; no declaration array mutated)
#
# All three are deliberately INDEPENDENT of whether XDG_CONFIG_HOME and
# GH_CONFIG_DIR are on the allowlist yet, so they stay green across the #1719
# fix and leave group G as the single place where the membership signal lives.

# The nine registered workers. Group G asserts this set against the registry
# (env/worker-set-is-the-known-nine); the groups below reuse it as a driver.
WD_WORKER_NAMES="issue-reconcile commit-push issue-close-stage issue-close-finalize test-runner worktree-copy worktree-backup doc-append session-close-gate"

# ===========================================================================
# Group H — the missing-value branch of buildEnv (#1719 review C2).
#
# buildEnv copies `process.env[name]` for each allowlisted name. The failure mode
# this group fences is the naive form of that loop: assigning unconditionally
# would put the STRING "undefined" (or "") into the child env for every name the
# parent does not hold. For a config-location variable that is strictly worse
# than absence — gh would resolve its config dir against a directory literally
# named `undefined` instead of falling through to the next variable in its chain,
# so the #1719 bug would come back wearing a different hat.
#
# The parent here holds APPDATA / ProgramData / PROGRAMDATA and NOT
# GH_CONFIG_DIR / XDG_CONFIG_HOME, which is also the shape that answers the
# second half of the review point: the lower-priority value must survive
# unchanged while the higher-priority ones are simply not there.
# ===========================================================================
group_h() {
    local name v
    if impl_missing "env-missing/absent-name-is-not-materialized" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe_with_missing_cfg_env env-missing; then
        fail "env-missing/absent-name-is-not-materialized — probe failed: $PROBE_OUT"
        return
    fi
    # Preconditions. Without the first pair the "key-absent" rows would be
    # measuring a parent that never lost anything.
    for v in GH_CONFIG_DIR XDG_CONFIG_HOME; do
        assert_eq "env-missing/parent-lacks-$v" "1" "$(pv "parent_absent_$v")"
    done
    for v in APPDATA ProgramData PROGRAMDATA; do
        assert_eq "env-missing/parent-has-$v" "1" "$(pv "parent_present_$v")"
    done

    for name in $WD_WORKER_NAMES; do
        for v in GH_CONFIG_DIR XDG_CONFIG_HOME; do
            # "key-absent" is the only acceptable answer. A materialized value is
            # echoed back JSON-quoted so a "undefined" / "" regression names itself.
            assert_eq "env-missing/$name/$v-key-absent" "key-absent" "$(pv "MISS__${v}__${name}")"
        done
        for v in APPDATA ProgramData PROGRAMDATA; do
            assert_eq "env-missing/$name/$v-value-survives" "value-identical" "$(pv "KEEP__${v}__${name}")"
        done
        # Non-vacuity: buildEnv really produced an env, so the absences above are
        # not just a wholesale empty object.
        assert_eq "env-missing/$name/path-still-present" "1" "$(pv "MISSPATHOK__${name}")"
    done
}

# ===========================================================================
# Group I — value edge cases (#1719 review C4).
#
# Table-driven per skills/_shared/test-design/parser-regex-tests.md. Each row is
# a config-path VALUE with an awkward shape; the claim is that the child receives
# it byte for byte — no expansion, no quoting, no trimming, no path
# normalization, and certainly no execution.
#
# Both length extremes are rows here: a single character (the shortest value
# that is still a value) and an 8192-character path (see the probe for why that
# length). Group L re-runs the two extremes across a REAL subprocess boundary,
# where a length limit would actually bite; this group is the buildEnv layer.
#
# The vehicle is APPDATA, a variable that is ALREADY allowlisted. Running these
# rows on GH_CONFIG_DIR / XDG_CONFIG_HOME instead would turn all five red purely
# because those two are not admitted yet, restating the group G membership signal
# once per row and burying the one thing this group is here to say. buildEnv
# handles values identically for every allowlist member, so nothing is lost.
# ===========================================================================
group_i() {
    local name want
    if impl_missing "env-edge/table-non-vacuous" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe env-edge; then
        fail "env-edge/table-non-vacuous — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "env-edge/table-non-vacuous" "7" "$(pv edge_count)"

    while IFS='|' read -r name want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        # The row really has the property it is named after (a blanded-out table
        # would otherwise pass the passthrough assert trivially).
        assert_eq "env-edge/$name/carries-the-edge-property" "$want" "$(pv "EDGEPROP__${name}")"
        # The value survived the parent process env, so the comparison below is
        # against the intended bytes and not against something already mangled.
        assert_eq "env-edge/$name/parent-value-intact" "intact" "$(pv "EDGEPARENT__${name}")"
        # …and every worker's child env carries it unchanged. A non-empty value
        # here names the offending workers and how they broke it.
        assert_eq "env-edge/$name/byte-identical-in-every-worker" "" "$(pv "EDGE__${name}")"
    done <<'TABLE'
empty-string     | len-0
single-char      | len-1
nonexistent-path | not-on-disk
path-with-space  | has-space
unicode-path     | non-ascii
shell-metachars  | has-metachars
very-long-path   | len-8192
TABLE
}

# ===========================================================================
# Group J — idempotency (#1719 review C5).
#
# CHILD_ENV_ALLOWLIST is a module-level singleton and each entry's
# envPassthrough is a live array on the registry object. buildEnv concatenates
# them; a `push` where a `concat` was meant would make the FIRST worker
# dispatched in a process widen the scope of every worker after it — the exact
# credential-scope failure the schema suite fences statically, arriving instead
# through call order, which no single-call assertion can see.
# ===========================================================================
group_j() {
    if impl_missing "env-idem/two-calls-agree" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe env-idem; then
        fail "env-idem/two-calls-agree — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "env-idem/two-calls-agree" "1" "$(pv idem_equal)"
    # A shared object handed out twice would satisfy the equality above while
    # letting one caller mutate another caller's env.
    assert_eq "env-idem/returns-a-fresh-object" "1" "$(pv idem_fresh_object)"
    # An extraEnv call in between must leave no residue in the next plain call.
    assert_eq "env-idem/extra-env-leaves-no-residue" "1" "$(pv idem_extra_no_residue)"
    assert_eq "env-idem/allowlist-not-mutated" "1" "$(pv idem_allowlist_unmutated)"
    assert_eq "env-idem/allowlist-length-not-mutated" "1" "$(pv idem_allowlist_len_unmutated)"
    assert_eq "env-idem/passthrough-not-mutated" "1" "$(pv idem_passthrough_unmutated)"
    # Non-vacuity: comparing two empty objects would agree just as happily.
    if [ "$(pv idem_key_count)" -ge 5 ] 2>/dev/null; then
        pass "env-idem/env-non-vacuous"
    else
        fail "env-idem/env-non-vacuous — key count=$(pv idem_key_count)"
    fi
}
