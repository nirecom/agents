# tests/hooks/fix-1630-script-checkout-root-resolver/resolver-units.sh
# Tests: hooks/lib/script-checkout-root.js
# Tags: hook, agents-main-root, resolver, unit, security, scope:issue-specific
#
# Sourced by tests/hooks/fix-1630-script-checkout-root-resolver.sh.
# T4c — resolver units. The contract (candidates are module|realpath in every
# AGENTS_MAIN_ROOT state, 2-point marker validation, null when nothing
# validates) is owned by the header of hooks/lib/script-checkout-root.js.

run_resolver_unit_cases() {

# ---------------------------------------------------------------------------
# Candidate enumeration. The module-relative path comes first, then the
# realpath-resolved module path (which differs when the checkout is reached
# through a symlink — the ~/.claude/* -> agents-repo layout). AGENTS_MAIN_ROOT
# is set explicitly per row: the ambient value of the invoking shell must not
# decide which state a row exercises.
# ---------------------------------------------------------------------------
_sources_valid="$(AGENTS_MAIN_ROOT="$SCRIPT_CHECKOUT_ROOT_NODE" probe sources)"
expect_eq "T4c candidate order with AGENTS_MAIN_ROOT set to a valid checkout" \
    "$_sources_valid" "module,realpath"

_sources_no_env="$(probe_env -u AGENTS_MAIN_ROOT -- sources)"
expect_eq "T4c candidate order with AGENTS_MAIN_ROOT unset" \
    "$_sources_no_env" "module,realpath"

_sources_blank="$(AGENTS_MAIN_ROOT="   " probe sources)"
expect_eq "T4c candidate order with whitespace-only AGENTS_MAIN_ROOT" \
    "$_sources_blank" "module,realpath"

_sources_stale="$(AGENTS_MAIN_ROOT="$STALE" probe sources)"
expect_eq "T4c candidate order with AGENTS_MAIN_ROOT set to a stale dir" \
    "$_sources_stale" "module,realpath"

# The module candidate is this checkout, absolute and forward-slashed by the probe.
_module_dir="$(probe_env -u AGENTS_MAIN_ROOT -- canddir module)"
expect_eq "T4c module candidate resolves to this checkout" \
    "$_module_dir" "$SCRIPT_CHECKOUT_ROOT_NODE"

# ---------------------------------------------------------------------------
# Decoy: a directory carrying BOTH markers, named by AGENTS_MAIN_ROOT. It would
# pass marker validation if it were ever enumerated, so the only thing keeping
# it out is that the variable is not a candidate at all.
# ---------------------------------------------------------------------------
_decoy_raw="$TMPDIR_BASE/decoy-script-checkout-root"
mkdir -p "$_decoy_raw/hooks" "$_decoy_raw/bin"
: > "$_decoy_raw/hooks/enforce-worktree.js"
_decoy="$(norm "$_decoy_raw")"

_sources_decoy="$(AGENTS_MAIN_ROOT="$_decoy" probe sources)"
expect_eq "T4c candidate order with AGENTS_MAIN_ROOT set to a both-marker decoy" \
    "$_sources_decoy" "module,realpath"

_resolved_decoy="$(AGENTS_MAIN_ROOT="$_decoy" probe resolve)"
expect_eq "T4c a both-marker decoy in AGENTS_MAIN_ROOT is not adopted" \
    "$_resolved_decoy" "$SCRIPT_CHECKOUT_ROOT_NODE"

_decoy_present="$(AGENTS_MAIN_ROOT="$_decoy" probe canddir-present "$_decoy")"
expect_eq "T4c a both-marker decoy in AGENTS_MAIN_ROOT is never a candidate dir" \
    "$_decoy_present" "false"

# Anti-vacuity for the row above: the same op must be able to answer true.
_self_present="$(AGENTS_MAIN_ROOT="$_decoy" probe canddir-present "$SCRIPT_CHECKOUT_ROOT_NODE")"
expect_eq "T4c this checkout is a candidate dir (canddir-present control)" \
    "$_self_present" "true"

# ---------------------------------------------------------------------------
# normDir, exercised directly: it is applied to every candidate and shared with
# load-env's own environment read.
# ---------------------------------------------------------------------------
assert_probe "T4c normDir rejects a whitespace-only value" normdir "   " "null"
assert_probe "T4c normDir rejects an empty value" normdir "" "null"
assert_probe "T4c normDir trims surrounding whitespace" \
    normdir "  $SCRIPT_CHECKOUT_ROOT_NODE  " "$SCRIPT_CHECKOUT_ROOT_NODE"

# normalizeCwd + path.resolve: a POSIX drive-letter value (the form Git Bash
# hands to Node on Windows) must be normalized, not passed through verbatim.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        # The /c/... form is derived INSIDE node (op normdir-posix). Passing it
        # from bash would be a false green: MSYS2/Git Bash rewrites
        # POSIX-looking values back to Windows form when it spawns native
        # node.exe, so the input class under test would never arrive.
        assert_probe "T4c normDir turns a POSIX drive-letter path into a real path" \
            normdir-posix "$SCRIPT_CHECKOUT_ROOT_NODE" "$SCRIPT_CHECKOUT_ROOT_NODE"
        ;;
    *)
        skip "T4c normDir POSIX drive-letter normalization (win32-only path form)"
        ;;
esac

# ---------------------------------------------------------------------------
# _resolveFromCandidates: ordering + 2-point marker validation, with an injected
# existsSync so the real filesystem is never touched.
#
# Columns: name | op | candidates ("<source>:<dir>,...") | existing-paths | want
#   existing-paths  ';'-separated paths the injected existsSync reports as present
# Both markers are required, so each valid dir contributes two entries; the
# three-deep rows repeat a source label. existing-paths is always a ';' list:
# Git Bash rewrites a lone /m/bin to M:/bin on the way to node, a list it leaves.
# ---------------------------------------------------------------------------
run_table <<'TABLE'
T4c-first-valid          | pick | module:/m,realpath:/r           | /m/hooks/enforce-worktree.js;/m/bin                     | /m
T4c-first-missing-hooks  | pick | module:/m,realpath:/r           | /m/bin;/r/hooks/enforce-worktree.js;/r/bin              | /r
T4c-first-missing-bin    | pick | module:/m,realpath:/r           | /m/hooks/enforce-worktree.js;/r/hooks/enforce-worktree.js;/r/bin | /r
T4c-first-absent-dir     | pick | module:/m,realpath:/r           | /r/hooks/enforce-worktree.js;/r/bin                     | /r
T4c-second-invalid       | pick | module:/a,module:/m,realpath:/r | /r/hooks/enforce-worktree.js;/r/bin                     | /r
T4c-none-valid           | pick | module:/a,module:/m,realpath:/r | /x/hooks/enforce-worktree.js;/x/bin                     | null
T4c-nothing-exists       | pick | module:/a,module:/m,realpath:/r |                                                         | null
T4c-first-wins-over-all  | pick | module:/a,module:/m,realpath:/r | /a/hooks/enforce-worktree.js;/a/bin;/m/hooks/enforce-worktree.js;/m/bin;/r/hooks/enforce-worktree.js;/r/bin | /a
T4c-module-before-real   | pick | module:/m,realpath:/r           | /m/hooks/enforce-worktree.js;/m/bin;/r/hooks/enforce-worktree.js;/r/bin | /m
T4c-empty-candidates     | pick |                                 | /m/hooks/enforce-worktree.js;/m/bin                     | null
T4c-hooks-file-only      | pick | module:/m                       | /m/hooks/enforce-worktree.js;/x/bin                     | null
T4c-bin-only             | pick | module:/m                       | /m/bin;/x/hooks/enforce-worktree.js                     | null
T4c-single-both-markers  | pick | module:/m                       | /m/bin;/m/hooks/enforce-worktree.js                     | /m
TABLE
expect_eq "T4c the pick table asserted every one of its rows" "$RUN_TABLE_ROWS" "13"

# ---------------------------------------------------------------------------
# Process memoization: repeated calls return the identical value, and the real
# checkout is always resolvable (this repo carries both markers), so the
# resolver must not return null here regardless of the environment.
# ---------------------------------------------------------------------------
_memo_env="$(AGENTS_MAIN_ROOT="$SCRIPT_CHECKOUT_ROOT_NODE" probe memo)"
expect_eq "T4c resolveScriptCheckoutRoot is memoized (env set)" "$_memo_env" "same=true,null=false"

_memo_noenv="$(probe_env -u AGENTS_MAIN_ROOT -- memo)"
expect_eq "T4c resolveScriptCheckoutRoot is memoized (env unset)" "$_memo_noenv" "same=true,null=false"

_resolved_stale="$(AGENTS_MAIN_ROOT="$STALE" probe resolve)"
expect_eq "T4c a stale AGENTS_MAIN_ROOT does not change the resolved checkout" \
    "$_resolved_stale" "$SCRIPT_CHECKOUT_ROOT_NODE"

_resolved_noenv="$(probe_env -u AGENTS_MAIN_ROOT -- resolve)"
expect_eq "T4c a missing AGENTS_MAIN_ROOT does not change the resolved checkout" \
    "$_resolved_noenv" "$SCRIPT_CHECKOUT_ROOT_NODE"

# ---------------------------------------------------------------------------
# Real symlink: an install dir whose hooks/lib links into this checkout and
# which carries neither marker. --preserve-symlinks keeps __dirname on the link
# (node resolves it by default, which would make the module candidate the
# checkout and the case vacuous), so only the realpath candidate can validate.
# ---------------------------------------------------------------------------
_install_raw="$TMPDIR_BASE/symlink-install"
mkdir -p "$_install_raw/hooks"
# nativestrict: fail instead of silently copying when Windows cannot link.
( export MSYS=winsymlinks:nativestrict
  ln -s "$SCRIPT_CHECKOUT_ROOT/hooks/lib" "$_install_raw/hooks/lib" ) 2>/dev/null
if [ -L "$_install_raw/hooks/lib" ]; then
    _via_link="$(run_with_timeout 30 env -u AGENTS_MAIN_ROOT -u AGENTS_HOOK_DEBUG node --preserve-symlinks -e '
      const m = require(process.argv[1]);
      const key = (p) => String(p).replace(/\\/g, "/").toLowerCase();
      const cands = m.scriptCheckoutRootCandidates();
      const mod = cands.find((c) => c.source === "module");
      const got = m.resolveScriptCheckoutRoot();
      const hit = cands.find((c) => c.dir === got);
      console.log("module_is_checkout=" + (key(mod.dir) === key(process.argv[2])) +
                  ",source=" + (hit ? hit.source : "none") +
                  ",resolved=" + String(got).replace(/\\/g, "/"));
    ' "$(norm "$_install_raw")/hooks/lib/script-checkout-root.js" "$SCRIPT_CHECKOUT_ROOT_NODE" 2>&1)"
    expect_eq "T4c a marker-less install dir symlinked into this checkout resolves via realpath" \
        "$_via_link" "module_is_checkout=false,source=realpath,resolved=$SCRIPT_CHECKOUT_ROOT_NODE"
else
    skip "T4c real-symlink install layout (symlink creation unavailable on this host)"
fi

}
