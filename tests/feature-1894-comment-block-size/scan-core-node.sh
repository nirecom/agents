#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/scan-core-node.sh
# Tests: hooks/lib/comment-block-scan.js, bin/review-comment-block-size.d/scan-cli.js
# Tags: comment-block-size, parser, node, table-driven, ssot, parity, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Approach A moves the scan core out of awk and into Node, so that the Edit-time
# PreToolUse hook can call it in-process while the bash CLI reaches it through a
# thin stdin/stdout adapter. That makes hooks/lib/comment-block-scan.js the
# implementation SSOT for comment recognition (CPR-SSOT), and this file is its
# direct unit surface.
#
# Why it is separate from scanner-core.sh even though the case table is the
# same: scanner-core.sh observes the core THROUGH the bash CLI, so a drift
# introduced by the port shows up there only where the CLI happens to expose it
# (one number per file, staged files only, over-threshold runs only). Here the
# module is called directly, so the run list, the run boundaries and the
# sub-threshold state are all observable. Both are needed — the pair is what
# makes the awk to JS port checkable in either direction (CPR-E2E).
#
# TL3 gap (what this test does NOT catch):
# - Real Edit-time latency: the whole point of putting the core in-process is to
#   keep it off the hot path, and nothing here measures that.
# - Whether the module stays require-able from BOTH consumers after packaging /
#   installation (deployed $HOME/.claude copy vs worktree copy).
# - Byte sequences a real editor writes that mktemp fixtures never produce
#   (UTF-16 files, mixed CRLF/LF within one file at scale).
# Closest-to-action mitigation: the bash-side parity table in scanner-core.sh
# runs the same recognition rules through the real CLI on every run.

echo ""
echo "=== N0: module contract ==="

NS_MOD="$AGENTS_DIR/hooks/lib/comment-block-scan.js"
NS_CLI="$AGENTS_DIR/bin/review-comment-block-size.d/scan-cli.js"
NS_DIR="$TMPDIR_BASE/nodescan"
mkdir -p "$NS_DIR"

# Node on Windows chokes on backslash paths inside a JS string literal, and the
# driver receives this path as argv rather than as source text — but the same
# normalization is applied for both, per rules/test/fixture-isolation.md.
ns_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
NS_MOD_P="$(ns_path "$NS_MOD")"
NS_CLI_P="$(ns_path "$NS_CLI")"

# The driver keeps every assertion below to a single scalar on stdout, so a
# thrown exception is never mistaken for a legitimate value.
cat > "$NS_DIR/driver.js" <<'DRIVER'
'use strict';
const fs = require('fs');
const modPath = process.argv[2];
const mode = process.argv[3];
const M = require(modPath);
const out = (v) => process.stdout.write(String(v));

if (mode === 'exports') {
    out(Object.keys(M).sort().join(','));
} else if (mode === 'default') {
    out(M.DEFAULT_MAX_LINES);
} else if (mode === 'parseMaxLines') {
    out(M.parseMaxLines(process.argv[4]));
} else if (mode === 'parseExtensions') {
    out(M.parseExtensions(process.argv[4] === '@undef' ? undefined : process.argv[4]).join('|'));
} else if (mode === 'hasExt') {
    out(M.hasScannableExtension(process.argv[4], M.parseExtensions(process.argv[5])) ? 'yes' : 'no');
} else if (mode === 'excluded') {
    out(M.isExcludedPath(process.argv[4]) ? 'yes' : 'no');
} else if (mode === 'segments') {
    out(M.EXCLUDED_PATH_SEGMENTS.join('|'));
} else {
    // Scanning modes all share one read + one scan.
    const t = Number(process.argv[4]);
    const text = fs.readFileSync(process.argv[5], 'utf8');
    const r = M.scanText(text, t);
    if (mode === 'longest') {
        // Mirrors cb_longest in the dispatcher: the number the report would
        // show, or "none" when nothing is over threshold. Deliberately does NOT
        // assume whether `longest` is filtered by the threshold — the two
        // readings are indistinguishable here, and pinning the wrong one would
        // make this file assert an implementation detail instead of a contract.
        out(r.count > 0 ? r.longest : 'none');
    } else if (mode === 'count') {
        out(r.count);
    } else if (mode === 'runs') {
        out(r.runs.map((x) => x.start + '-' + x.end + ':' + x.len).join(','));
    } else if (mode === 'invariants') {
        // Threshold-reading-independent invariants, asserted as one token.
        const bad = [];
        if (r.count !== r.runs.length) bad.push('count!=runs.length');
        if (r.runs.some((x) => x.len <= t)) bad.push('run<=threshold-present');
        if (r.runs.some((x) => x.end - x.start + 1 !== x.len)) bad.push('span!=len');
        if (r.runs.some((x) => x.start < 1)) bad.push('start<1');
        if (r.count > 0 && r.longest <= t) bad.push('longest<=threshold-with-findings');
        if (r.count === 0 && r.longest > t) bad.push('longest>threshold-without-findings');
        out(bad.length ? bad.join(';') : 'ok');
    } else {
        throw new Error('unknown mode: ' + mode);
    }
}
DRIVER

# ns <mode> [args...] -> stdout of the driver; NS_RC carries the exit code and
# NS_ERR the stderr, so a missing module is reported once, in full, rather than
# as N assertion diffs against an empty string.
NS_RC=0
NS_ERR=""
ns() {
    local mode="$1"; shift
    local errf="$NS_DIR/err.txt"
    NS_RC=0
    run_with_timeout 30 node "$NS_DIR/driver.js" "$NS_MOD_P" "$mode" "$@" 2>"$errf" || NS_RC=$?
    NS_ERR="$(cat "$errf" 2>/dev/null || true)"
}
# Same, but printing the driver's stdout so it can be used inside $( ).
# NOTE: command substitution runs in a subshell, so NS_RC does NOT survive an
# `$(nsv ...)`. Assertions about the exit code must call ns_rc below instead.
nsv() { ns "$@" >"$NS_DIR/out.txt"; cat "$NS_DIR/out.txt"; }

# ns_rc <mode> [args...] -> echoes the exit code, in the same subshell-safe way.
ns_rc() { ns "$@" >/dev/null; printf '%s' "$NS_RC"; }

if ! command -v node >/dev/null 2>&1; then
    skip "N0/node-runtime-unavailable"
    NS_HAVE_NODE=0
else
    NS_HAVE_NODE=1
fi

ns_probe() {
    # <spec> -> path of a rendered fixture file
    render_spec "$1" > "$NS_DIR/probe.txt"
    printf '%s' "$(ns_path "$NS_DIR/probe.txt")"
}

if [ "$NS_HAVE_NODE" = "1" ]; then
    ns exports
    if [ "$NS_RC" != "0" ]; then
        fail "N0/module-is-requirable" "node exited $NS_RC requiring $NS_MOD_P: $NS_ERR"
    else
        pass "N0/module-is-requirable"
    fi
    NS_EXPORTS="$(nsv exports)"
    for _sym in DEFAULT_MAX_LINES EXCLUDED_PATH_SEGMENTS hasScannableExtension \
                isExcludedPath parseExtensions parseMaxLines scanText; do
        assert_contains "N0/exports-$_sym" "$_sym" "$NS_EXPORTS"
    done
    assert_eq "N0/default-max-lines" "10" "$(nsv default)"

    # Purity: the module is required from the Edit-time hot path, so it must not
    # read config, touch the filesystem, or print. Asserted statically because a
    # runtime probe would only catch the branches this suite happens to reach.
    if [ -f "$NS_MOD" ]; then
        assert_absent "N0/no-process-env" "process.env" "$(cat "$NS_MOD")"
        assert_absent "N0/no-console" "console." "$(cat "$NS_MOD")"
        assert_absent "N0/no-fs-require" "require('fs')" "$(cat "$NS_MOD")"
    else
        fail "N0/module-file-exists" "not found: $NS_MOD"
    fi

    # C3: every scanText call site passes the threshold explicitly. A call that
    # relies on a default would silently re-introduce the ambient-config bypass
    # this issue closes, and no behavioural test can see it.
    for _f in "$NS_CLI" "$AGENTS_DIR/hooks/block-comment-block-size.js"; do
        if [ -f "$_f" ]; then
            if grep -n 'scanText(' "$_f" | grep -qv ','; then
                fail "N0/threshold-always-explicit-in-$(basename "$_f")" \
                     "a scanText() call has no second argument"
            else
                pass "N0/threshold-always-explicit-in-$(basename "$_f")"
            fi
        else
            fail "N0/callsite-exists-$(basename "$_f")" "not found: $_f"
        fi
    done
fi

# ---------------------------------------------------------------------------
# N1 — recognition-rule parity with scanner-core.sh, at the module boundary
#
# Same rows as the CLI-level C1 table, same `run > T` boundary: T=10 means a
# 10-line run is allowed and 11 is the first finding.
# ---------------------------------------------------------------------------
echo ""
echo "=== N1: comment-line rule / run-length boundary (T=10, flag iff run > 10) ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
while IFS='|' read -r name spec want; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    assert_eq "N1/$name" "$want" "$(nsv longest 10 "$(ns_probe "$spec")")"
done <<'TABLE'
run-9-silent                  | //a*9 x=1                       | none
run-10-at-threshold-silent    | //a*10 x=1                      | none
run-11-flagged                | //a*11 x=1                      | 11
hash-run-11                   | #a*11 x=1                       | 11
shebang-line1-not-counted     | #!/bin/sh #a*10 x=1             | none
shebang-plus-11-flagged       | #!/bin/sh #a*11 x=1             | 11
hashbang-not-on-line1-counts  | x=1 #!/bin/sh #a*10             | 11
leading-whitespace-stripped   | ^^//a*11 x=1                    | 11
mixed-markers-one-run         | //a*5 #b*6 x=1                  | 11
blank-terminates-outside-block| //a*6 _ //a*6 x=1               | none
run-flushed-at-eof            | x=1 //a*11                      | 11
block-open-close              | /*a *b*9 */ x=1                 | 11
block-blank-inside-continues  | /*a *b*4 _ *c*4 */ x=1          | 11
block-unterminated-to-eof     | /*a *b*10                       | 11
block-close-with-trailing-code| /*a *b*9 */^x=1                 | 11
oneline-block-no-block-state  | /*a*/*6 x=1 //b*6               | none
close-marker-at-top-level     | */*11 x=1                       | 11
star-space-is-comment         | *^a*11 x=1                      | 11
star-eol-is-comment           | **11 x=1                        | 11
case-arm-star-paren-not-comment| *)*11 x=1                      | none
star-word-not-comment         | *b*11 x=1                       | none
dashdash-unsupported          | --a*11 x=1                      | none
semicolon-unsupported         | ;a*11 x=1                       | none
percent-unsupported           | %a*11 x=1                       | none
python-triple-quote-unsupported| """*11 x=1                     | none
no-comments-at-all            | x=1*20                          | none
single-line-file              | //a                             | none
TABLE
fi

# ---------------------------------------------------------------------------
# N2 — run boundaries and count
#
# Only reachable at the module boundary: the CLI reports one longest run per
# file, so an off-by-one in `start`/`end` or a mis-split into two runs is
# invisible there and would surface as a wrong L<a>-L<b> detail line for users.
# ---------------------------------------------------------------------------
echo ""
echo "=== N2: run boundaries, count, and structural invariants ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
    _p="$(ns_probe "x=1 //a*11 x=1")"
    assert_eq "N2/single-run-span" "2-12:11" "$(nsv runs 10 "$_p")"
    assert_eq "N2/single-run-count" "1" "$(nsv count 10 "$_p")"
    assert_eq "N2/single-run-invariants" "ok" "$(nsv invariants 10 "$_p")"

    # Two over-threshold runs plus one under: `count` must be 2, and the under-
    # threshold run must not appear in `runs` at all.
    _p="$(ns_probe "//a*11 x=1 //b*5 x=1 //c*12")"
    assert_eq "N2/two-runs-spans" "1-11:11,19-30:12" "$(nsv runs 10 "$_p")"
    assert_eq "N2/two-runs-count" "2" "$(nsv count 10 "$_p")"
    assert_eq "N2/two-runs-invariants" "ok" "$(nsv invariants 10 "$_p")"

    # Sub-threshold only: an empty run list, not a missing key or a crash.
    _p="$(ns_probe "//a*10 x=1")"
    assert_eq "N2/sub-threshold-runs-empty" "" "$(nsv runs 10 "$_p")"
    assert_eq "N2/sub-threshold-count" "0" "$(nsv count 10 "$_p")"
    assert_eq "N2/sub-threshold-invariants" "ok" "$(nsv invariants 10 "$_p")"

    # The same file at a lower threshold: the boundary is a parameter, not a
    # property of the text.
    assert_eq "N2/same-text-lower-threshold-count" "1" "$(nsv count 5 "$_p")"
    assert_eq "N2/same-text-lower-threshold-invariants" "ok" "$(nsv invariants 5 "$_p")"
fi

# ---------------------------------------------------------------------------
# N3 — parseMaxLines (the threshold-parsing SSOT shared with the bash side)
# ---------------------------------------------------------------------------
echo ""
echo "=== N3: parseMaxLines ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
while IFS='|' read -r raw want; do
    [ -z "${raw//[[:space:]]/}" ] && [ -z "${want//[[:space:]]/}" ] && continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    # Trailing whitespace only (needed for column alignment before the `|`) —
    # the " 7 | 10" row's leading space is the case under test and must survive.
    raw="${raw%"${raw##*[![:space:]]}"}"
    want="${want//[[:space:]]/}"
    [ "$raw" = "@empty" ] && raw=""
    assert_eq "N3/parseMaxLines[$raw]" "$want" "$(nsv parseMaxLines "$raw")"
done <<'TABLE'
5        | 5
10       | 10
999      | 999
0        | 10
-3       | 10
abc      | 10
@empty   | 10
1e3      | 10
10.5     | 10
 7       | 10
+7       | 10
0x10     | 10
TABLE
fi

# ---------------------------------------------------------------------------
# N4 — extension and exclusion rules
#
# These are an INDEPENDENT re-expression of the bash ext_ok / path_ok (C7), not
# a shared implementation, so they get their own table rather than inheriting
# the CLI-level one.
# ---------------------------------------------------------------------------
echo ""
echo "=== N4: parseExtensions / hasScannableExtension / isExcludedPath ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
    assert_eq "N4/default-extensions" "js|sh|py" "$(nsv parseExtensions "@undef")"
    assert_eq "N4/empty-string-falls-back" "js|sh|py" "$(nsv parseExtensions "")"
    assert_eq "N4/semicolon-split" "js|ts" "$(nsv parseExtensions "js;ts")"
    assert_eq "N4/empty-elements-dropped" "js|ts" "$(nsv parseExtensions ";js;;ts;")"
    assert_eq "N4/excluded-segments" "node_modules|.git|_archive|_archived" "$(nsv segments)"

while IFS='|' read -r path exts want; do
    [ -z "${path//[[:space:]]/}" ] && continue
    [[ "$path" =~ ^[[:space:]]*# ]] && continue
    path="${path//[[:space:]]/}"
    exts="${exts//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    assert_eq "N4/ext[$path]" "$want" "$(nsv hasExt "$path" "$exts")"
done <<'TABLE'
a.sh                  | js;sh;py | yes
a.js                  | js;sh;py | yes
a.py                  | js;sh;py | yes
a.md                  | js;sh;py | no
a.SH                  | js;sh;py | no
noext                 | js;sh;py | no
sh                    | js;sh;py | no
.sh                   | js;sh;py | yes
a.sh.md               | js;sh;py | no
dir.sh/a.md           | js;sh;py | no
weird.name.js         | js;sh;py | yes
a.ts                  | js;sh;py | no
a.ts                  | ts       | yes
TABLE

while IFS='|' read -r path want; do
    [ -z "${path//[[:space:]]/}" ] && continue
    [[ "$path" =~ ^[[:space:]]*# ]] && continue
    path="${path//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    assert_eq "N4/excluded[$path]" "$want" "$(nsv excluded "$path")"
done <<'TABLE'
src/a.js                        | no
node_modules/a.js               | yes
a/node_modules/b/c.js           | yes
.git/hooks/a.sh                 | yes
_archive/old.sh                 | yes
_archived/old.sh                | yes
tests/_archive/old.sh           | yes
src\node_modules\a.js           | yes
my_node_modules/a.js            | no
node_modules_x/a.js             | no
a/_archiver/b.sh                | no
archive/old.sh                  | no
TABLE
fi

# ---------------------------------------------------------------------------
# N5 — byte- and line-level edge cases the awk core handled implicitly
#
# The port changes who owns line splitting: awk's record separator became
# text.split(/\n/). Every case below is a shape where the two could disagree
# without any recognition rule being wrong.
# ---------------------------------------------------------------------------
echo ""
echo "=== N5: line-splitting and byte-level edges ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
    # Empty file: no runs, no crash, and no phantom trailing line.
    : > "$NS_DIR/probe.txt"
    _p="$(ns_path "$NS_DIR/probe.txt")"
    assert_eq "N5/empty-file-longest" "none" "$(nsv longest 10 "$_p")"
    assert_eq "N5/empty-file-count" "0" "$(nsv count 10 "$_p")"

    # A file that is a single newline: one empty line, still no run.
    printf '\n' > "$NS_DIR/probe.txt"
    assert_eq "N5/lone-newline" "none" "$(nsv longest 10 "$_p")"

    # No trailing newline: the final run must still be flushed. awk got this for
    # free; split() does not.
    { for i in $(seq 1 10); do echo "#c$i"; done; printf '#c11'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/no-trailing-newline-flushes" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/no-trailing-newline-span" "1-11:11" "$(nsv runs 10 "$_p")"

    # Trailing newline must NOT add a phantom 12th line to the run.
    { for i in $(seq 1 11); do echo "#c$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/trailing-newline-no-phantom-line" "1-11:11" "$(nsv runs 10 "$_p")"

    # CRLF: the \r must be stripped before marker recognition, or "*/" and "* "
    # stop matching and a block silently runs to EOF.
    { for i in $(seq 1 11); do printf '// c%s\r\n' "$i"; done; printf 'x=1\r\n'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/crlf-longest" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/crlf-span" "1-11:11" "$(nsv runs 10 "$_p")"

    # CRLF inside a block comment: the close marker carries the \r.
    { printf '/*a\r\n'; for i in $(seq 1 9); do printf '* c%s\r\n' "$i"; done; printf '*/\r\n'; printf 'x=1\r\n'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/crlf-block-closes" "11" "$(nsv longest 10 "$_p")"

    # A leading UTF-8 BOM sits in front of the first marker. Whatever the module
    # decides, it must decide it for line 1 only — the run must not vanish.
    { printf '\xEF\xBB\xBF'; for i in $(seq 1 12); do echo "#c$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/bom-does-not-swallow-the-run" "ok" "$(nsv invariants 10 "$_p")"
    if [ "$(nsv count 10 "$_p")" -ge 1 ]; then
        pass "N5/bom-run-still-detected"
    else
        fail "N5/bom-run-still-detected" "BOM on line 1 suppressed a 12-line run entirely"
    fi

    # Invalid UTF-8 bytes: readFileSync('utf8') turns them into U+FFFD. Every
    # marker is ASCII, so the verdict must be unaffected — and above all the
    # module must not throw on a binary-ish file.
    { for i in $(seq 1 11); do printf '# c%s \xC3\x28\xFF\n' "$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/invalid-utf8-longest" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/invalid-utf8-no-throw" "0" "$(ns_rc longest 10 "$_p")"

    # NUL bytes mid-line: same requirement.
    { for i in $(seq 1 11); do printf '# c%s\000tail\n' "$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/nul-bytes-longest" "11" "$(nsv longest 10 "$_p")"

    # Lone CR as the only separator (classic-Mac endings): NOT a line break for
    # split(/\n/), so this is one very long line and cannot be an 11-line run.
    { for i in $(seq 1 11); do printf '# c%s\r' "$i"; done; printf '\n'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/lone-cr-is-not-a-line-break" "none" "$(nsv longest 10 "$_p")"

    # One enormous line: guards against a quadratic or stack-recursive splitter.
    # 2 MB on a single line, wrapped in a run that must still be found.
    {
        for i in $(seq 1 5); do echo "#c$i"; done
        printf '# '
        head -c 2000000 /dev/zero | tr '\0' 'x'
        printf '\n'
        for i in $(seq 1 5); do echo "#d$i"; done
    } > "$NS_DIR/probe.txt"
    assert_eq "N5/huge-single-line-longest" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/huge-single-line-no-timeout" "0" "$(ns_rc longest 10 "$_p")"

    # Whitespace-only lines terminate a top-level run (they are not comments),
    # but a line of only tabs must behave exactly like a line of only spaces.
    { for i in $(seq 1 6); do echo "#c$i"; done; printf '\t\t\n'; for i in $(seq 1 6); do echo "#d$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/tab-only-line-terminates-run" "none" "$(nsv longest 10 "$_p")"
fi

# ---------------------------------------------------------------------------
# N6 — scan-cli.js: the bash-facing adapter
#
# The bash CLI parses this stdout with the exact reader it used for awk, so the
# line format is a contract, not an implementation detail.
# ---------------------------------------------------------------------------
echo ""
echo "=== N6: scan-cli.js stdout/rc contract ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
    # Sets NS_OUT / NS_ERR / NS_RC in the CURRENT shell — never call it inside
    # $( ), or the exit code is lost with the subshell.
    NS_OUT=""
    ns_cli() {
        local t="$1" f="$2" errf="$NS_DIR/clierr.txt"
        NS_RC=0
        run_with_timeout 30 node "$NS_CLI_P" --threshold "$t" <"$f" \
            >"$NS_DIR/cliout.txt" 2>"$errf" || NS_RC=$?
        NS_OUT="$(cat "$NS_DIR/cliout.txt" 2>/dev/null || true)"
        NS_ERR="$(cat "$errf" 2>/dev/null || true)"
    }

    render_spec "x=1 //a*11 x=1 //b*5 x=1 //c*12" > "$NS_DIR/cli.txt"
    ns_cli 10 "$NS_DIR/cli.txt"
    assert_eq "N6/rc-zero-with-findings" "0" "$NS_RC"
    assert_eq "N6/line-format" "2-12:11,20-31:12" \
        "$(printf '%s\n' "$NS_OUT" | awk 'NF{printf "%s%s-%s:%s", (n++?",":""), $1, $2, $3}')"
    assert_eq "N6/nothing-on-stderr" "" "$NS_ERR"

    render_spec "//a*10 x=1" > "$NS_DIR/cli.txt"
    ns_cli 10 "$NS_DIR/cli.txt"
    assert_eq "N6/rc-zero-without-findings" "0" "$NS_RC"
    assert_eq "N6/no-output-without-findings" "" "${NS_OUT//[[:space:]]/}"

    # rc 2 is the usage error. rc 1 is RESERVED for the blocking verdict and
    # this adapter must never return it — a bash caller that treated 1 as
    # "scanner failed" would fail open on every future block.
    : > "$NS_DIR/cli.txt"
    ns_cli "" "$NS_DIR/cli.txt"
    assert_eq "N6/missing-threshold-is-rc2" "2" "$NS_RC"
    ns_cli "abc" "$NS_DIR/cli.txt"
    assert_eq "N6/non-numeric-threshold-is-rc2" "2" "$NS_RC"

    NS_RC=0
    run_with_timeout 30 node "$NS_CLI_P" </dev/null >/dev/null 2>&1 || NS_RC=$?
    assert_eq "N6/no-args-is-rc2" "2" "$NS_RC"
fi
