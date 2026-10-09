#!/usr/bin/env bash
# tests/hooks/feature-2307-forge-router.sh
# Tests: hooks/lib/forge-router.js, hooks/lib/parse-remote-url.js, hooks/lib/forge/github.js, hooks/lib/forge/stub.js
# Tags: forge, forge-router, codehost, tracker, gitlab, jira, security, scope:issue-specific, TL1, visibility, gh-stub, private-repo-list
# #2307 forge router, test-first. forge-router.js and detectForgeType() do NOT
# exist yet, so EVERY case FAILS today (probe -> THREW:MODULE-MISSING). Intended
# red; do NOT weaken to pass. NOTE: green only after forge-router.js +
# detectForgeType() land. Per-group contracts sit inline before each table.
# TL3 gap: TL1 over pure resolution; does not prove a real hook routes through it.

set -uo pipefail

# Outer timeout so a wedged node cannot stall the suite (rules/test.md).
if command -v timeout >/dev/null 2>&1 && [ -z "${_FORGE2307_INNER:-}" ]; then
    _FORGE2307_INNER=1 timeout 120 bash "$0" "$@"
    exit $?
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
LIB_M="$(nodepath "$SCRIPT_CHECKOUT_ROOT/hooks/lib")"
# harness.sh supplies case_begin/case_end; the local pass/fail below still win.
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 20 "$@"; else perl -e 'alarm 20; exec @ARGV' -- "$@"; fi
}

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/forge-2307-router.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMPBASE"' EXIT

# Probe: forge-router.js binds as `r`, parse-remote-url.js as `p`. A module that
# fails to load becomes a Proxy throwing MODULE-MISSING on any access, so a
# missing forge-router.js reddens only its own cases. Output is always JSON, so a
# string result arrives quoted and stays distinct from a boolean.
PROBE="$TMPBASE/probe.js"
cat > "$PROBE" <<'PROBE_EOF'
"use strict";
const path = require("path");
const LIB = process.argv[2];
function load(rel, name) {
    try {
        return require(path.join(LIB, rel));
    } catch (e) {
        const reason = "MODULE-MISSING:" + name + (e && e.code === "MODULE_NOT_FOUND" ? "" : ":" + (e && e.message));
        return new Proxy({}, { get() { throw new Error(reason); } });
    }
}
const r = load("forge-router.js", "forge-router");
const p = load("parse-remote-url.js", "parse-remote-url");
let v;
try {
    // eslint-disable-next-line no-new-func
    v = new Function("r", "p", "return (" + process.argv[3] + ");")(r, p);
} catch (e) {
    process.stdout.write("THREW:" + (e && e.message ? e.message : String(e)));
    process.exit(0);
}
process.stdout.write(v === undefined ? "undefined" : JSON.stringify(v));
PROBE_EOF

# expect_expr <name> <want> <js-expression>
expect_expr() {
    local name="$1" want="$2" expr="$3" got
    got="$(run_with_timeout node "$PROBE" "$LIB_M" "$expr" 2>&1 || true)"
    if [ "$got" = "$want" ]; then pass "$name"
    else fail "$name (want=$want got=$got)"; fi
}

# expr_table <label> — `name|want|expr` rows on stdin; the expression is the LAST
# field so a `|` inside it survives. Blank/#-comment rows skip; an empty table is
# itself a failure (a table that asserts nothing is a false green).
expr_table() {
    local label="$1" name want expr rows=0
    while IFS='|' read -r name want expr; do
        case "$name" in ""|"#"*) continue ;; esac
        rows=$((rows + 1))
        expect_expr "$label [$name]" "$want" "$expr"
    done
    if [ "$rows" -eq 0 ]; then fail "$label — the table was empty, so it asserted nothing"; fi
}

# A1-A5 contract: detectForgeType(url) -> { type: github|gitlab|unknown, host }.
# A null/""/non-string input -> type "unknown", and it never throws.
echo "=== A1-A5: detectForgeType — remote URL -> forge type ==="
expr_table "A" <<'TABLE'
A1 github https .type|"github"|p.detectForgeType("https://github.com/owner/repo.git").type
A1 github https .host|"github.com"|p.detectForgeType("https://github.com/owner/repo.git").host
A2 github scp .type|"github"|p.detectForgeType("git@github.com:owner/repo.git").type
A3 gitlab https .type|"gitlab"|p.detectForgeType("https://gitlab.com/owner/repo.git").type
A4 bitbucket -> unknown|"unknown"|p.detectForgeType("https://bitbucket.org/owner/repo.git").type
A5 null -> unknown, no throw|"unknown"|(function(){try{return p.detectForgeType(null).type;}catch(e){return "THREW:"+e.message;}})()
A5 empty string -> unknown|"unknown"|(function(){try{return p.detectForgeType("").type;}catch(e){return "THREW:"+e.message;}})()
TABLE

# A6-A9 contract: resolveCodehostDescriptor(url) -> { type, host,
#   hasOpenPrForBranch(), isPrivateRepo(dir) } (real on github, no-op on gitlab);
#   resolveTrackerDescriptor(env, codehostType) -> { type, ... }: env.FORGE_TRACKER
#   selects the tracker, and when unset it follows the codehost.
echo ""
echo "=== A6-A9: descriptor resolution (codehost + tracker) ==="
expr_table "A" <<'TABLE'
A6 github codehost .type|"github"|r.resolveCodehostDescriptor("https://github.com/owner/repo.git").type
A6 github codehost hasOpenPrForBranch is a function|"function"|typeof r.resolveCodehostDescriptor("https://github.com/owner/repo.git").hasOpenPrForBranch
A7 gitlab codehost .type|"gitlab"|r.resolveCodehostDescriptor("https://gitlab.com/owner/repo.git").type
A7 gitlab codehost hasOpenPrForBranch is a no-op function|"function"|typeof r.resolveCodehostDescriptor("https://gitlab.com/owner/repo.git").hasOpenPrForBranch
A8 explicit jira tracker .type|"jira"|r.resolveTrackerDescriptor({FORGE_TRACKER:"jira"}).type
A9 tracker unset follows github codehost|"github"|r.resolveTrackerDescriptor({}, "github").type
TABLE

# A10-A12 contract: codehost and tracker resolve independently; the gitlab
#   isPrivateRepo handler is a no-op returning false; and a jira tracker is its
#   own no-op descriptor, never a silent github fallback (the security case).
echo ""
echo "=== A10-A12: independence + no-fallback (security) ==="
expr_table "A" <<'TABLE'
A10 codehost github and tracker jira are independent|"github/jira"|(function(){var c=r.resolveCodehostDescriptor("https://github.com/o/r.git");var t=r.resolveTrackerDescriptor({FORGE_TRACKER:"jira"},"github");return c.type+"/"+t.type;})()
A11 gitlab isPrivateRepo is a no-op returning false (no GitHub fallback)|false|r.resolveCodehostDescriptor("https://gitlab.com/o/r.git").isPrivateRepo("/tmp/repo")
A12 jira tracker is its own descriptor, never the github tracker (no fallback)|true|(function(){var t=r.resolveTrackerDescriptor({FORGE_TRACKER:"jira"});var g=r.resolveTrackerDescriptor({}, "github");return t.type==="jira" && t.type!==g.type;})()
TABLE

# A13-A15 contract (reviewer C4): FORGE_TRACKER selection edges. Empty string is
#   treated as unset -> follows the codehost. A GitLab codehost with tracker
#   unset resolves to the gitlab (stub) tracker. An explicit but invalid value
#   falls back to the unknown/stub tracker — it never silently follows codehost.
echo ""
echo "=== A13-A15: FORGE_TRACKER fallback edges ==="
expr_table "A" <<'TABLE'
A13 FORGE_TRACKER empty -> follows gitlab codehost|"gitlab"|r.resolveTrackerDescriptor({FORGE_TRACKER:""}, "gitlab").type
A14 tracker unset + gitlab codehost -> gitlab|"gitlab"|r.resolveTrackerDescriptor({}, "gitlab").type
A15 FORGE_TRACKER invalid -> unknown/stub, not codehost|"unknown"|r.resolveTrackerDescriptor({FORGE_TRACKER:"invalid-value"}, "github").type
TABLE

# A16-A17 contract (reviewer C6): the gitlab stub codehost is a real no-op, not a
#   silent reuse of the github handler. Its isPrivateRepo is a DISTINCT function
#   from github's (never the same reference) and returns a boolean immediately —
#   proving github's handler (which would call gh) is not what gitlab resolves to.
echo ""
echo "=== A16-A17: stub vs github handler distinction ==="
expr_table "A" <<'TABLE'
A16 github vs gitlab isPrivateRepo are distinct functions (github is not the stub)|true|(function(){var g=r.resolveCodehostDescriptor("https://github.com/o/r.git").isPrivateRepo;var s=r.resolveCodehostDescriptor("https://gitlab.com/o/r.git").isPrivateRepo;return typeof g==="function" && typeof s==="function" && g!==s;})()
A17 gitlab stub isPrivateRepo returns a boolean no-op immediately|"boolean"|typeof r.resolveCodehostDescriptor("https://gitlab.com/o/r.git").isPrivateRepo("/tmp/repo")
TABLE

# V1-V12 contract (#2513): codehost.repoVisibility(remoteUrl) -> "public" | "private" |
#   "internal" | null. github runs `gh api repos/<owner>/<repo> --jq .visibility` (owner/repo
#   from parseOriginOwnerRepo, 15s timeout); a failure, a timeout, an unknown value or an
#   unparsable URL is null and an unparsable URL never reaches gh. The stub codehost is
#   always null. gh is a PATH stub (tests/lib/cli-stub.sh); the real gh is never reached.
echo ""
echo "=== V1-V12: codehost repoVisibility (github + stub) ==="
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
VIS_LOG="$TMPBASE/gh-stub.log"
VIS_EXPR='(function(){var u=process.env.VIS_URL;return r.resolveCodehostDescriptor(u).repoVisibility(u);})()'
VIS_GH="https://github.com/test-owner/test-repo.git"
vis_timeout() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi; }
# vis_run <stdout> <rc> <sleep-ms> <url> <secs> [expr] — evaluates expr (default VIS_EXPR) under the gh stub.
vis_run() {
    : > "$VIS_LOG"
    CLI_STUB_OUT="$1" CLI_STUB_RC="$2" CLI_STUB_SLEEP_MS="$3" CLI_STUB_LOG="$VIS_LOG" VIS_URL="$4" \
        cli_stub_run vis_timeout "$5" node "$PROBE" "$LIB_M" "${6:-$VIS_EXPR}" 2>/dev/null
}
# vis_case <name> <want> <stdout> <rc> <sleep-ms> <url> [secs]
vis_case() {
    local got
    if [ -z "${VIS_STUB_OK:-}" ]; then fail "$1 (gh stub unreachable; not run so the real gh stays untouched)"; return; fi
    got="$(vis_run "$3" "$4" "$5" "$6" "${7:-20}")"
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1 (want=$2 got=$got)"; fi
}

case_begin "repo-visibility-stub-precondition" "hooks/lib/forge/github.js"
VIS_STUB_OK=""
if cli_stub_make "$TMPBASE/gh-stub" gh; then
    PRE="$(vis_run STUBOK 0 0 "$VIS_GH" 20 '(function(){var cp=process.getBuiltinModule("child_process");var o={encoding:"utf8",windowsHide:true};var a=cp.spawnSync("gh",["api","x"],o);var b=cp.spawnSync("gh",["api","x"],Object.assign({shell:process.platform==="win32"},o));return a.stdout+"|"+b.stdout;})()')"
    if [ "$PRE" = '"STUBOK|STUBOK"' ]; then VIS_STUB_OK=1; pass "V0 gh stub reached with and without a shell"
    else fail "V0 gh stub reached with and without a shell (got=$PRE)"; fi
else
    fail "V0 gh stub could not be created"
fi
case_end

case_begin "repo-visibility-github-answers" "hooks/lib/forge/github.js"
vis_case "V1 gh says public -> \"public\"" '"public"' $'public\n' 0 0 "$VIS_GH"
GH_LOGGED="$(cat "$VIS_LOG" 2>/dev/null)"
if [ "$GH_LOGGED" = "gh api repos/test-owner/test-repo --jq .visibility" ]; then pass "V2 gh argv is api repos/test-owner/test-repo --jq .visibility"
else fail "V2 gh argv is api repos/test-owner/test-repo --jq .visibility (log=$GH_LOGGED)"; fi
vis_case "V3 gh says private -> \"private\"" '"private"' $'private\n' 0 0 "$VIS_GH"
vis_case "V4 gh says internal -> \"internal\"" '"internal"' $'internal\n' 0 0 "$VIS_GH"
vis_case "V5 scp-form origin, gh says private -> \"private\"" '"private"' $'private\n' 0 0 "git@github.com:test-owner/test-repo.git"
case_end

case_begin "repo-visibility-github-failures-null" "hooks/lib/forge/github.js"
vis_case "V6 gh exits nonzero (stdout public) -> null" 'null' $'public\n' 1 0 "$VIS_GH"
vis_case "V7 gh prints an unknown value -> null" 'null' $'secret\n' 0 0 "$VIS_GH"
vis_case "V8 gh prints nothing -> null" 'null' '' 0 0 "$VIS_GH"
# The stub answers "public" only after 17s, past the 15s descriptor timeout.
vis_case "V9 gh exceeds the timeout -> null (late public ignored)" 'null' $'public\n' 0 17000 "$VIS_GH" 45
case_end

case_begin "repo-visibility-unparsable-and-stub" "hooks/lib/forge/stub.js"
vis_case "V10 unparsable owner (test_owner) -> null" 'null' $'public\n' 0 0 "https://github.com/test_owner/test-repo.git"
if [ ! -s "$VIS_LOG" ]; then pass "V10 unparsable owner never reaches gh"; else fail "V10 unparsable owner never reaches gh (log=$(cat "$VIS_LOG"))"; fi
vis_case "V11 stub codehost (unknown host) -> null" 'null' $'public\n' 0 0 "https://bitbucket.org/test-owner/test-repo.git"
if [ ! -s "$VIS_LOG" ]; then pass "V11 stub codehost never runs gh"; else fail "V11 stub codehost never runs gh (log=$(cat "$VIS_LOG"))"; fi
case_end

case_begin "is-private-repo-unchanged" "hooks/lib/forge/github.js"
if [ -n "$VIS_STUB_OK" ]; then
    GOT="$(vis_run $'true\n' 0 0 "$VIS_GH" 20 'r.resolveCodehostDescriptor(process.env.VIS_URL).isPrivateRepo(process.env.VIS_URL)')"
    if [ "$GOT" = "true" ] && [ "$(cat "$VIS_LOG")" = "gh api repos/test-owner/test-repo --jq .private" ]; then
        pass "V12 isPrivateRepo still asks --jq .private and returns true"
    else fail "V12 isPrivateRepo still asks --jq .private and returns true (got=$GOT log=$(cat "$VIS_LOG"))"; fi
else fail "V12 isPrivateRepo unchanged (gh stub unreachable; not run)"; fi
case_end

# L1-L9 contract (#2513): codehostGithub.listPrivateRepoNames() makes exactly ONE
#   `gh repo list --limit 1000 --json nameWithOwner,visibility --jq <tsv>` call (no
#   --visibility filter). Each line is `<VISIBILITY>\t<nameWithOwner>`; private/internal
#   rows are kept (case-insensitive) in first-seen order, deduped; public, unknown and
#   malformed rows are dropped; a failing call -> []. The gh stub answers every call alike.
echo ""
echo "=== L1-L9: codehostGithub listPrivateRepoNames (one visibility-tagged listing) ==="
LPN_LOG="$TMPBASE/gh-lpn.log"
LPN_EXPR='r.resolveCodehostDescriptor("https://github.com/test-owner/test-repo.git").listPrivateRepoNames()'
LPN_STUB_OK=""
if cli_stub_make "$TMPBASE/gh-lpn" gh; then LPN_STUB_OK=1; fi
# lpn_run <stdout> <rc> [expr] — evaluates expr (default LPN_EXPR) under the gh stub.
lpn_run() {
    : > "$LPN_LOG"
    CLI_STUB_OUT="$1" CLI_STUB_RC="$2" CLI_STUB_SLEEP_MS=0 CLI_STUB_LOG="$LPN_LOG" \
        cli_stub_run run_with_timeout node "$PROBE" "$LIB_M" "${3:-$LPN_EXPR}" 2>/dev/null
}
# lpn_case <name> <want> <stdout> <rc>
lpn_case() {
    local got
    if [ -z "$LPN_STUB_OK" ]; then fail "$1 (gh stub unreachable; not run so the real gh stays untouched)"; return; fi
    got="$(lpn_run "$3" "$4")"
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1 (want=$2 got=$got log=$(tr '\n' ';' < "$LPN_LOG"))"; fi
}

case_begin "list-private-repo-names-stub-precondition" "hooks/lib/forge/github.js"
if [ -n "$LPN_STUB_OK" ]; then
    PRE="$(lpn_run STUBOK 0 '(function(){var cp=process.getBuiltinModule("child_process");var o={encoding:"utf8",windowsHide:true,shell:process.platform==="win32"};return cp.spawnSync("gh",["repo","list"],o).stdout;})()')"
    LPN_PRE_LOG="$(cat "$LPN_LOG")"
    if [ "$PRE" = '"STUBOK"' ] && [ "$LPN_PRE_LOG" = "gh repo list" ]; then pass "L0 gh stub answers through the shell and logs its argv"
    else LPN_STUB_OK=""; fail "L0 gh stub answers through the shell and logs its argv (got=$PRE log=$LPN_PRE_LOG)"; fi
else
    fail "L0 gh stub could not be created"
fi
case_end

case_begin "list-private-repo-names-single-listing" "hooks/lib/forge/github.js"
lpn_case "L1 mixed PRIVATE/INTERNAL/PUBLIC rows -> private + internal in order, public excluded" \
    '["test-owner/priv-a","test-org/int-c","test-owner/priv-b"]' \
    $'PRIVATE\ttest-owner/priv-a\nPUBLIC\ttest-owner/pub-x\nINTERNAL\ttest-org/int-c\nPRIVATE\ttest-owner/priv-b\n' 0
LPN_SEEN="$(cat "$LPN_LOG" 2>/dev/null)"
LPN_N="$(grep -c '^gh ' "$LPN_LOG" 2>/dev/null)"
if [ "$LPN_N" = "1" ]; then pass "L2 exactly one gh spawn per listPrivateRepoNames()"
else fail "L2 exactly one gh spawn per listPrivateRepoNames() (spawns=$LPN_N log=$LPN_SEEN)"; fi
# cmd.exe (shell:true on Windows) may deliver the |-bearing jq arg still wrapped in double quotes.
LPN_ARGV="$(printf '%s' "$LPN_SEEN" | head -n 1 | tr -d '"')"
LPN_JQ="${LPN_ARGV#*--jq }"
if [[ "$LPN_ARGV" == "gh repo list "* ]] && [[ "$LPN_ARGV" != *--visibility* ]] \
    && [[ "$LPN_ARGV" == *" --json nameWithOwner,visibility "* ]] && [[ "$LPN_ARGV" == *" --jq "* ]] \
    && [[ "$LPN_JQ" == *.visibility*.nameWithOwner*@tsv* ]]; then
    pass "L3 argv: no --visibility flag, --json nameWithOwner,visibility, jq emits visibility+nameWithOwner as tsv"
else fail "L3 argv: no --visibility flag, --json nameWithOwner,visibility, jq emits visibility+nameWithOwner as tsv (argv=$LPN_ARGV)"; fi
lpn_case "L4 a duplicated name appears once (first-seen order)" '["test-owner/a","test-owner/b"]' \
    $'PRIVATE\ttest-owner/a\nINTERNAL\ttest-owner/a\nPRIVATE\ttest-owner/b\n' 0
case_end

case_begin "list-private-repo-names-failure" "hooks/lib/forge/github.js"
lpn_case "L5 gh exits non-zero (valid stdout) -> []" '[]' $'PRIVATE\ttest-owner/priv-a\n' 1
lpn_case "L6 empty output -> []" '[]' '' 0
case_end

case_begin "list-private-repo-names-edge-output" "hooks/lib/forge/github.js"
lpn_case "L7 CRLF, blank lines and padding tolerated" '["test-owner/a","test-org/c"]' \
    $'PRIVATE\ttest-owner/a\r\n\r\n  INTERNAL\ttest-org/c  \r\n\n' 0
lpn_case "L8 malformed rows dropped (no tab, unknown SECRET, empty name)" '["test-owner/ok"]' \
    $'test-owner/notab\nSECRET\ttest-owner/s\nPRIVATE\t\nPRIVATE\ttest-owner/ok\n' 0
lpn_case "L9 lowercase / mixed-case visibility accepted, public dropped" '["test-owner/a","test-org/b"]' \
    $'private\ttest-owner/a\nInternal\ttest-org/b\npublic\ttest-owner/c\n' 0
case_end

# L10: a row is exactly "<visibility>\t<name>"; any other shape is malformed and dropped.
case_begin "list-private-repo-names-malformed-table" "hooks/lib/forge/github.js"
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    lpn_case "L10 $name" "$want" "$(printf '%b' "$input")" 0
done <<'TABLE'
extra-tab-three-fields|private\tgroup/a\textra\n|[]
empty-visibility|\tgroup/name\n|[]
empty-name|private\t\n|[]
uppercase-kept|PRIVATE\tok/repo\n|["ok/repo"]
whitespace-only-line|   \t  \n|[]
crlf-line-endings|private\tacme/x\r\ninternal\tacme/y\r\n|["acme/x","acme/y"]
TABLE
case_end

# L11: gh carries the --limit 1000 cap; the parser adds no client-side cap of its own.
case_begin "list-private-repo-names-listing-cap" "hooks/lib/forge/github.js"
LPN_BIG=""
for i in $(seq 1 1000); do LPN_BIG+=$'public\tp/'"$i"$'\n'; done
LPN_BIG+=$'private\tlate/row1001\n'
lpn_case "L11 a private row at position 1001 is still returned" '["late/row1001"]' "$LPN_BIG" 0
if [[ "$(tr -d '"' < "$LPN_LOG")" == *" --limit 1000 "* ]]; then pass "L11 gh argv carries --limit 1000"
else fail "L11 gh argv carries --limit 1000 (log=$(tr '\n' ';' < "$LPN_LOG"))"; fi
case_end

# L12: the listing spawn timeout (4000 ms) stays under the 5 s scan-outbound hook budget.
case_begin "list-private-repo-names-spawn-timeout" "hooks/lib/forge/github.js"
LPN_TO="$(run_with_timeout node -e 'const cp = require("child_process"); const seen = [];
cp.spawnSync = (c, a, o) => { seen.push(String(c) + ":" + (o && o.timeout)); return { status: 0, stdout: "", stderr: "", error: null }; };
require(process.argv[1]).codehostGithub.listPrivateRepoNames(); process.stdout.write(seen.join(","));' \
    "$LIB_M/forge/github.js" 2>&1)"
if [ "$LPN_TO" = "gh:4000" ]; then pass "L12 listPrivateRepoNames spawns gh with timeout 4000"
else fail "L12 listPrivateRepoNames spawns gh with timeout 4000 (got=$LPN_TO)"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
