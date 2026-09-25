#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/scan-core-node.sh
# Tests: hooks/lib/comment-block-scan.js, bin/review-comment-block-size.d/scan-cli.js
# Tags: comment-block-size, parser, node, table-driven, ssot, parity, scope:issue-specific, scope:feature-1894, layer:TL2

# hooks/lib/comment-block-scan.js is the recognition SSOT (CPR-SSOT), shared by
# the Edit-time hook (in-process) and the bash CLI (stdin/stdout adapter); this
# file is its direct unit surface. scanner-core.sh duplicates the case table on
# purpose: it sees the core THROUGH the CLI (one number per file), while the run
# list, boundaries and sub-threshold state are only visible here (CPR-E2E).

# TL3 gap: real Edit-time latency, require-ability from both consumers
# post-packaging, and editor byte sequences mktemp fixtures don't produce
# (UTF-16, mixed CRLF/LF at scale). Mitigation: scanner-core.sh runs the same
# rules through the real CLI on every run.

echo ""
echo "=== N0: module contract ==="

NS_MOD="$AGENTS_DIR/hooks/lib/comment-block-scan.js"
NS_CLI="$AGENTS_DIR/bin/review-comment-block-size.d/scan-cli.js"
NS_DIR="$TMPDIR_BASE/nodescan"
mkdir -p "$NS_DIR"

# Node on Windows chokes on backslash paths; normalize per
# rules/test/fixture-isolation.md.
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
} else if (mode === 'noopTokens') {
    out(M.NEUTRAL_NOOP_TOKENS.join('|'));
} else {
    // Scanning modes all share one read + one scan.
    const t = Number(process.argv[4]);
    const text = fs.readFileSync(process.argv[5], 'utf8');
    const r = M.scanText(text, t);
    if (mode === 'longest') {
        // Mirrors cb_longest in the dispatcher: the number the report would
        // show, or "none" when nothing is over threshold — without assuming
        // whether `longest` is itself threshold-filtered (indistinguishable
        // here, and pinning the wrong reading would assert an internal).
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
        // Neutral lines bridge a run without being counted, so the span is no
        // longer equal to len — only never SMALLER than it, and never inverted.
        if (r.runs.some((x) => x.end < x.start)) bad.push('end<start');
        if (r.runs.some((x) => x.end - x.start + 1 < x.len)) bad.push('span<len');
        if (r.runs.some((x) => x.start < 1)) bad.push('start<1');
        if (r.count > 0 && r.longest <= t) bad.push('longest<=threshold-with-findings');
        if (r.count === 0 && r.longest > t) bad.push('longest>threshold-without-findings');
        out(bad.length ? bad.join(';') : 'ok');
    } else {
        throw new Error('unknown mode: ' + mode);
    }
}
DRIVER

# ns <mode> [args...] -> stdout of the driver; NS_RC/NS_ERR carry the exit code
# and stderr, so a missing module is reported once instead of as N empty diffs.
NS_RC=0
NS_ERR=""
ns() {
    local mode="$1"; shift
    local errf="$NS_DIR/err.txt"
    NS_RC=0
    run_with_timeout 30 node "$NS_DIR/driver.js" "$NS_MOD_P" "$mode" "$@" 2>"$errf" || NS_RC=$?
    NS_ERR="$(cat "$errf" 2>/dev/null || true)"
}
# Same, printing stdout for use inside $( ). NOTE: that subshell drops NS_RC —
# assertions about the exit code must call ns_rc below instead.
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
    for _sym in DEFAULT_MAX_LINES EXCLUDED_PATH_SEGMENTS NEUTRAL_NOOP_TOKENS \
                hasScannableExtension isExcludedPath parseExtensions \
                parseMaxLines scanText; do
        assert_contains "N0/exports-$_sym" "$_sym" "$NS_EXPORTS"
    done
    assert_eq "N0/default-max-lines" "10" "$(nsv default)"
    # The no-op token list is frozen: exact-trim members only, in this order.
    # `;;` is deliberately absent — it terminates a bash `case` branch, so it is
    # real code, not a no-op (the negative half of the pair, CPR-ORTH).
    assert_eq "N0/noop-token-list" ";|:|{}|()|," "$(nsv noopTokens)"

    # Purity: required from the Edit-time hot path, so no config read, no fs, no
    # print. Static because a runtime probe sees only the branches reached here.
    if [ -f "$NS_MOD" ]; then
        assert_absent "N0/no-process-env" "process.env" "$(cat "$NS_MOD")"
        assert_absent "N0/no-console" "console." "$(cat "$NS_MOD")"
        assert_absent "N0/no-fs-require" "require('fs')" "$(cat "$NS_MOD")"
    else
        fail "N0/module-file-exists" "not found: $NS_MOD"
    fi

    # C3: every scanText call site passes the threshold explicitly — a defaulted
    # call re-opens the ambient-config bypass, invisibly to behavioural tests.
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

# N1 — recognition-rule parity with scanner-core.sh, at the module boundary
# Same rows as the CLI-level C1 table, same `run > T` boundary: T=10 means a
# 10-line run is allowed and 11 is the first finding.
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
# Neutral-line bridging — kept row-for-row identical to C1 in scanner-core.sh
# (CPR-ORTH: the CLI-level and module-level tables are the two directions of
# the same contract, so one must never gain a row the other lacks).
blank-bridges-outside-block   | //a*6 _ //a*6 x=1               | 12
bridge-at-threshold-silent    | //a*5 _ //a*5 x=1               | none
bridge-one-over-threshold     | //a*5 _ //a*6 x=1               | 11
multi-bridge-accumulates      | //a*4 _ //a*4 _ //a*4 x=1       | 12
wide-blank-gap-bridges        | //a*6 _*5 //a*6 x=1             | 12
noop-semicolon-bridges        | //a*6 ; //a*6 x=1               | 12
noop-colon-bridges            | //a*6 : //a*6 x=1               | 12
noop-brace-pair-bridges       | //a*6 {} //a*6 x=1              | 12
noop-paren-pair-bridges       | //a*6 () //a*6 x=1              | 12
noop-comma-bridges            | //a*6 , //a*6 x=1               | 12
noop-token-with-padding-bridges| //a*6 ^^;^^ //a*6 x=1          | 12
# A bridge joins a run, not a marker style: `//` on one side and `#` on the
# other is still ONE run. And inside a /* */ block, `inBlock` is checked before
# neutrality, so a lone `;` there is a counted comment line (10 would be silent).
mixed-marker-bridges          | //a*6 _ #b*6 x=1                | 12
noop-token-inside-block-still-counts| /*a *b*4 ; *b*4 */ x=1    | 11
noop-token-with-code-still-breaks| //a*6 ;x //a*6 x=1           | none
double-semicolon-is-code-not-neutral| //a*6 ;; //a*6 x=1        | none
lone-brace-is-code-not-neutral| //a*6 } //a*6 x=1               | none
code-still-terminates         | //a*6 x=1 //a*6                 | none
blank-only-file-no-run        | _*20 x=1                        | none
TABLE

# The two \s members render_spec cannot carry as a token; same pair as C1.
ns_bridge_probe() {
    local name="$1" sep="$2" i
    {
        for ((i = 1; i <= 6; i++)); do echo "//a"; done
        printf '%b' "$sep"
        for ((i = 1; i <= 6; i++)); do echo "//a"; done
        echo "x=1"
    } > "$NS_DIR/probe.txt"
    assert_eq "N1/$name" "12" "$(nsv longest 10 "$(ns_path "$NS_DIR/probe.txt")")"
}
ns_bridge_probe "formfeed-only-line-bridges" '\f\n'
ns_bridge_probe "nbsp-only-line-bridges" '\xc2\xa0\n'
# The two axes combined: a no-op token padded with NON-ASCII whitespace. The
# token test is `trim() === tok`, and JS trim() strips the whole Unicode
# WhiteSpace class, so NBSP/FF padding must bridge exactly like spaces do.
ns_bridge_probe "nbsp-padded-noop-token-bridges" '\xc2\xa0;\xc2\xa0\n'
ns_bridge_probe "formfeed-padded-noop-token-bridges" '\f;\f\n'
fi

# N2 — run boundaries and count. Module-boundary-only: the CLI reports one
# longest run per file, so an off-by-one in `start`/`end` or a mis-split into
# two runs is invisible there and surfaces as a wrong L<a>-L<b> line for users.
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

    # Span accounting under bridging. `end` is no longer derivable from
    # `start + len - 1`, so first/last are pinned explicitly here — the CLI
    # shows one number per file and cannot see either boundary.
    _p="$(ns_probe "x=1 //a*6 _ //a*6 x=1")"
    assert_eq "N2/bridged-run-span" "2-14:12" "$(nsv runs 10 "$_p")"
    assert_eq "N2/bridged-run-count" "1" "$(nsv count 10 "$_p")"
    assert_eq "N2/bridged-run-invariants" "ok" "$(nsv invariants 10 "$_p")"

    # Neutral lines AFTER the last comment line bridge nothing, so they must
    # not extend `end` — the failure mode the explicit `last` tracking exists
    # to prevent (a run reported as L1-L14 for 11 comment lines).
    _p="$(ns_probe "//a*11 _*3")"
    assert_eq "N2/trailing-neutral-excluded-from-span" "1-11:11" "$(nsv runs 10 "$_p")"

    # A bridged run followed by a plain one: the flush must reset first/last as
    # well as the counter, or the second run inherits the first one's start.
    _p="$(ns_probe "//a*6 ; //a*6 x=1 //b*12")"
    assert_eq "N2/bridged-and-plain-runs" "1-13:12,15-26:12" "$(nsv runs 10 "$_p")"
    assert_eq "N2/bridged-and-plain-invariants" "ok" "$(nsv invariants 10 "$_p")"
fi

# N3 — parseMaxLines (the threshold-parsing SSOT shared with the bash side)
echo ""
echo "=== N3: parseMaxLines ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
while IFS='|' read -r raw want; do
    [ -z "${raw//[[:space:]]/}" ] && [ -z "${want//[[:space:]]/}" ] && continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    # Strip trailing (alignment) whitespace only — the " 7 | 10" row's LEADING
    # space is the case under test and must survive.
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

# N4 — extension and exclusion rules. An INDEPENDENT re-expression of the bash
# ext_ok / path_ok (C7), so it gets its own table rather than inheriting one.
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

# N5 (line-splitting / byte edges) and N6 (scan-cli.js stdout contract) live in
# the sibling folder — rules/coding/file-split.md Pattern A, 500-line HARD limit.
# shellcheck source=./scan-core-node/byte-and-cli-edges.sh
. "$(dirname "${BASH_SOURCE[0]}")/scan-core-node/byte-and-cli-edges.sh"
