# tests/fix-1630-config-dir-resolver/resolver-units.sh
# Tests: hooks/lib/agents-config-dir.js
# Tags: hook, config-dir, resolver, unit, security, scope:issue-specific
#
# STATUS: RED until C4 lands. Sourced by tests/fix-1630-config-dir-resolver.sh.
#
# T4c — resolver units driven through the _resolveFromCandidates seam with an
# injected existsSync, so candidate ordering and marker validation are asserted
# without touching the real filesystem.
#
# Contract under test:
#   configDirCandidates()  -> ordered [{dir, source}], source ∈ env|module|realpath
#                             ("env" present only when AGENTS_CONFIG_DIR is set
#                              and non-empty after trimming)
#   marker validation      -> a candidate is valid iff BOTH
#                             <dir>/hooks/enforce-worktree.js AND <dir>/bin exist
#   env fallthrough        -> an invalid env candidate does not abort the search
#   no valid candidate     -> null (callers keep their existing refuse-to-allow
#                             behaviour; the resolver never invents a path)

run_resolver_unit_cases() {

# ---------------------------------------------------------------------------
# Candidate ordering. `env` must come first (an explicit operator setting wins
# when it is valid), then the module-relative path, then the realpath-resolved
# module path (which differs when the checkout is reached through a symlink —
# the ~/.claude/* -> agents-repo layout).
# ---------------------------------------------------------------------------
_sources_with_env="$(AGENTS_CONFIG_DIR="$AGENTS_DIR_NODE" probe sources)"
assert_eq "T4c candidate order with AGENTS_CONFIG_DIR set" \
    "$_sources_with_env" "env,module,realpath"

_sources_no_env="$(env -u AGENTS_CONFIG_DIR node "$PROBE_JS" sources 2>&1)"
assert_eq "T4c candidate order with AGENTS_CONFIG_DIR unset" \
    "$_sources_no_env" "module,realpath"

_sources_blank="$(AGENTS_CONFIG_DIR="   " probe sources)"
assert_eq "T4c whitespace-only AGENTS_CONFIG_DIR yields no env candidate" \
    "$_sources_blank" "module,realpath"

# The module candidate is this checkout, absolute and forward-slashed by the probe.
_module_dir="$(env -u AGENTS_CONFIG_DIR node "$PROBE_JS" canddir module 2>&1)"
assert_eq "T4c module candidate resolves to this checkout" \
    "$_module_dir" "$AGENTS_DIR_NODE"

# normalizeCwd + path.resolve: a POSIX drive-letter env value (the form Git Bash
# hands to Node on Windows) must be normalized, not passed through verbatim.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        # The /c/... form is derived INSIDE node (op canddir-posixenv). Exporting
        # it from bash would be a false green: MSYS2/Git Bash rewrites
        # POSIX-looking env values back to Windows form when it spawns native
        # node.exe, so the input class under test would never arrive.
        _env_dir="$(env -u AGENTS_CONFIG_DIR node "$PROBE_JS" canddir-posixenv "$AGENTS_DIR_NODE" 2>&1)"
        assert_eq "T4c POSIX-form AGENTS_CONFIG_DIR is normalized to a real path" \
            "$_env_dir" "$AGENTS_DIR_NODE"
        ;;
    *)
        pass "T4c POSIX-form AGENTS_CONFIG_DIR normalization (SKIPPED: win32-only path form)"
        ;;
esac

# ---------------------------------------------------------------------------
# _resolveFromCandidates: ordering + 2-point marker validation.
#
# Columns: name | op | candidates | existing-paths | want
#   candidates      "<source>:<dir>,..."
#   existing-paths  ';'-separated paths the injected existsSync reports as present
#
# Both markers are required, so each valid dir contributes two entries.
# ---------------------------------------------------------------------------
run_table <<'TABLE'
T4c-env-valid          | pick | env:/e,module:/m,realpath:/r | /e/hooks/enforce-worktree.js;/e/bin                     | /e
T4c-env-missing-hooks  | pick | env:/e,module:/m,realpath:/r | /e/bin;/m/hooks/enforce-worktree.js;/m/bin              | /m
T4c-env-missing-bin    | pick | env:/e,module:/m,realpath:/r | /e/hooks/enforce-worktree.js;/m/hooks/enforce-worktree.js;/m/bin | /m
T4c-env-absent-dir     | pick | env:/e,module:/m,realpath:/r | /m/hooks/enforce-worktree.js;/m/bin                     | /m
T4c-module-invalid     | pick | env:/e,module:/m,realpath:/r | /r/hooks/enforce-worktree.js;/r/bin                     | /r
T4c-none-valid         | pick | env:/e,module:/m,realpath:/r | /x/hooks/enforce-worktree.js;/x/bin                     | null
T4c-nothing-exists     | pick | env:/e,module:/m,realpath:/r |                                                         | null
T4c-env-wins-over-all  | pick | env:/e,module:/m,realpath:/r | /e/hooks/enforce-worktree.js;/e/bin;/m/hooks/enforce-worktree.js;/m/bin;/r/hooks/enforce-worktree.js;/r/bin | /e
T4c-module-before-real | pick | module:/m,realpath:/r        | /m/hooks/enforce-worktree.js;/m/bin;/r/hooks/enforce-worktree.js;/r/bin | /m
T4c-no-env-candidate   | pick | module:/m,realpath:/r        | /r/hooks/enforce-worktree.js;/r/bin                     | /r
T4c-empty-candidates   | pick |                              | /m/hooks/enforce-worktree.js;/m/bin                     | null
T4c-hooks-file-only    | pick | module:/m                    | /m/hooks/enforce-worktree.js                            | null
T4c-bin-only           | pick | module:/m                    | /m/bin                                                  | null
TABLE

# ---------------------------------------------------------------------------
# Process memoization: repeated calls return the identical value, and the real
# checkout is always resolvable (this repo carries both markers), so the
# resolver must not return null here regardless of the environment.
# ---------------------------------------------------------------------------
_memo_env="$(AGENTS_CONFIG_DIR="$AGENTS_DIR_NODE" probe memo)"
assert_eq "T4c resolveAgentsConfigDir is memoized (env set)" "$_memo_env" "same=true,null=false"

_memo_noenv="$(env -u AGENTS_CONFIG_DIR node "$PROBE_JS" memo 2>&1)"
assert_eq "T4c resolveAgentsConfigDir is memoized (env unset)" "$_memo_noenv" "same=true,null=false"

_resolved_stale="$(AGENTS_CONFIG_DIR="$STALE" node "$PROBE_JS" resolve 2>&1)"
assert_eq "T4c a stale env value falls through to this checkout" \
    "$_resolved_stale" "$AGENTS_DIR_NODE"

_resolved_noenv="$(env -u AGENTS_CONFIG_DIR node "$PROBE_JS" resolve 2>&1)"
assert_eq "T4c a missing env value falls through to this checkout" \
    "$_resolved_noenv" "$AGENTS_DIR_NODE"

}
