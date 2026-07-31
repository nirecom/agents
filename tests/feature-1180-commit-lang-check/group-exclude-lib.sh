# tests/feature-1180-commit-lang-check/group-exclude-lib.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/lib/path-coverage-match.js, hooks/lib/glob-match.js
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X shared harness: fixtures, placeholder expansion, result classifiers
# and the local assert_eq. Sourced by group-exclude.sh BEFORE the case files;
# see that file for the group overview and the TL3 gap block.

echo ""
echo "=== Group X: CODE_LANG_EXCLUDE repo-root bypass ==="
echo ""

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

_X_PLATFORM="$(node -p 'process.platform' 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# Shared fixture for the table-driven matching cases (X1..X9).
# Paths are derived from `git rev-parse --show-toplevel` (NOT from the shell's
# own $repo string) so that they carry the same canonical form the SUT's
# repoRoot() will see — this matters on macOS where os.tmpdir() is a symlink.
# ---------------------------------------------------------------------------
_x_repo="$(make_git_repo xcl)"
printf 'const msg = "日本語テスト";\n' > "$_x_repo/test.js"
git -C "$_x_repo" add test.js
_X_ROOT="$(git -C "$_x_repo" rev-parse --show-toplevel)"
_X_PARENT="$(dirname "$_X_ROOT")"
_X_BASE="$(basename "$_X_ROOT")"
# Absolute single-star glob whose leaf-segment wildcard covers the repo root.
# NOTE (characterization): "$_X_ROOT/**" would NOT match — glob entries are
# tested against the repo root itself, and `<root>/**` compiles to `^<root>/.*$`
# which requires at least a trailing separator. Subtree globs must therefore be
# anchored at the PARENT (see @PARENTGLOB@ in X8).
_X_ROOT_GLOB="$_X_PARENT/$(printf '%s' "$_X_BASE" | cut -c1-4)*"
_X_PARENT_GLOB="$_X_PARENT/**"
# Similarly-prefixed sibling of the parent — must NOT match (path-boundary check).
_X_SIBLING="${_X_PARENT}-other"
# Sentinel paths that cannot exist and cannot cover the repo root.
_X_MISS_A="$_X_PARENT/__cle-no-such-dir-a__"
_X_MISS_B="$_X_PARENT/__cle-no-such-dir-b__"
_X_MISS_C="$_X_PARENT/__cle-no-such-dir-c__"

# Robustness fixtures for X21/X22 (see the table in group-exclude-match.sh).
#   _X_DUPES    — the SAME matching entry repeated, to prove de-dup is not needed
#                 for correctness and that repeats cannot flip the verdict.
#   _X_LONGLIST — 250 non-matching sentinel entries followed by ONE real match at
#                 the very end, so the whole list must be walked. This is a DoS
#                 sanity check, not a benchmark: run_check_node wraps the driver in
#                 run_with_timeout 15, and a timeout yields no JSON, which
#                 _x_classify reports as "error" — never as the expected "empty".
_X_DUPES="$_X_ROOT;$_X_ROOT;$_X_ROOT;$_X_ROOT"
_X_LONGLIST=""
_x_i=0
while [ "$_x_i" -lt 250 ]; do
    _X_LONGLIST="$_X_LONGLIST$_X_PARENT/__cle-bulk-${_x_i}__;"
    _x_i=$((_x_i + 1))
done
_X_LONGLIST="$_X_LONGLIST$_X_ROOT"

# Expand table placeholders into concrete paths.
_x_expand() {
    local s="$1"
    s="${s//@DUPES@/$_X_DUPES}"
    s="${s//@LONGLIST@/$_X_LONGLIST}"
    s="${s//@ROOTGLOB@/$_X_ROOT_GLOB}"
    s="${s//@PARENTGLOB@/$_X_PARENT_GLOB}"
    s="${s//@SIBLING@/$_X_SIBLING}"
    s="${s//@MISSA@/$_X_MISS_A}"
    s="${s//@MISSB@/$_X_MISS_B}"
    s="${s//@MISSC@/$_X_MISS_C}"
    s="${s//@PARENT@/$_X_PARENT}"
    s="${s//@ROOT@/$_X_ROOT}"
    printf '%s' "$s"
}

# Classify check() JSON arriving on stdin as empty / nonempty / error.
# "error" covers both a thrown exception and unparsable output, so a case that
# expects "empty" can never be satisfied by a crash.
_x_classify() {
    node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                if (!r.violations) { console.log("error"); return; }
                console.log(r.violations.length > 0 ? "nonempty" : "empty");
            } catch(e) { console.log("error"); }
        })' 2>/dev/null
}

# Same, but classifies BOTH result arrays: "v:<...> h:<...>" (or "error").
# Needed by the hint-tier symmetry cases — the planned gate returns
# { violations: [], hints: [] }, so hints must be suppressed too.
_x_classify_vh() {
    node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                if (!r.violations || !r.hints) { console.log("error"); return; }
                const k = a => a.length > 0 ? "nonempty" : "empty";
                console.log("v:" + k(r.violations) + " h:" + k(r.hints));
            } catch(e) { console.log("error"); }
        })' 2>/dev/null
}

# Run check() against the shared fixture with CODE_LANG=english and the given
# CODE_LANG_EXCLUDE; classify the result as empty / nonempty / error.
_x_verdict() {
    local out
    out="$(run_check_node "$_x_repo" "english" "$1")"
    printf '%s' "$out" | _x_classify
}
