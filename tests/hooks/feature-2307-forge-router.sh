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

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
LIB_M="$(nodepath "$AGENTS_DIR/hooks/lib")"
# harness.sh supplies case_begin/case_end; the local pass/fail below still win.
. "$AGENTS_DIR/tests/lib/harness.sh"

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
. "$AGENTS_DIR/tests/lib/cli-stub.sh"
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

# L1-L7 contract (#2513): codehostGithub.listPrivateRepoNames() is the union of
#   `gh repo list ... --visibility private` and the same with `--visibility internal`,
#   deduped, private names first. One failing call keeps the other's names; both fail -> [].
#   The gh stub answers per visibility: LPN_PRIV_OUT/RC and LPN_INT_OUT/RC.
echo ""
echo "=== L1-L7: codehostGithub listPrivateRepoNames (private + internal union) ==="
LPN_LOG="$TMPBASE/gh-lpn.log"
LPN_EXPR='r.resolveCodehostDescriptor("https://github.com/test-owner/test-repo.git").listPrivateRepoNames()'
LPN_PRIV_ARGV="gh repo list --limit 1000 --visibility private --json nameWithOwner --jq .[].nameWithOwner"
LPN_INT_ARGV="gh repo list --limit 1000 --visibility internal --json nameWithOwner --jq .[].nameWithOwner"
LPN_STUB_OK=""
if cli_stub_make "$TMPBASE/gh-lpn" gh; then
    cat > "$TMPBASE/gh-lpn/lpn-preload.js" <<'PRELOAD_EOF'
const path = require("path"); const fs = require("fs");
const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();
if ([base(process.execPath), base(process.argv0)].includes("gh")) {
  const a = process.argv.slice(1); if (a.length) a[0] = path.basename(a[0]);
  const line = ["gh"].concat(a).join(" ");
  if (process.env.CLI_STUB_LOG) fs.appendFileSync(process.env.CLI_STUB_LOG, line + "\n");
  const k = /--visibility[ =]internal\b/.test(line) ? "INT" : /--visibility[ =]private\b/.test(line) ? "PRIV" : "";
  fs.writeSync(1, k ? (process.env["LPN_" + k + "_OUT"] || "") : "");
  process.exit(k ? Number(process.env["LPN_" + k + "_RC"] || 0) : 3);
}
PRELOAD_EOF
    CLI_STUB_PRELOAD="$(nodepath "$TMPBASE/gh-lpn/lpn-preload.js")"
    LPN_STUB_OK=1
fi
# lpn_run <priv-out> <priv-rc> <int-out> <int-rc> [expr] — evaluates expr (default LPN_EXPR).
lpn_run() {
    : > "$LPN_LOG"
    LPN_PRIV_OUT="$1" LPN_PRIV_RC="$2" LPN_INT_OUT="$3" LPN_INT_RC="$4" CLI_STUB_LOG="$LPN_LOG" \
        cli_stub_run run_with_timeout node "$PROBE" "$LIB_M" "${5:-$LPN_EXPR}" 2>/dev/null
}
# lpn_case <name> <want> <priv-out> <priv-rc> <int-out> <int-rc>
lpn_case() {
    local got
    if [ -z "$LPN_STUB_OK" ]; then fail "$1 (gh stub unreachable; not run so the real gh stays untouched)"; return; fi
    got="$(lpn_run "$3" "$4" "$5" "$6")"
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1 (want=$2 got=$got log=$(tr '\n' ';' < "$LPN_LOG"))"; fi
}

case_begin "list-private-repo-names-stub-precondition" "hooks/lib/forge/github.js"
if [ -n "$LPN_STUB_OK" ]; then
    PRE="$(lpn_run STUBOK 0 '' 0 '(function(){var cp=process.getBuiltinModule("child_process");var o={encoding:"utf8",windowsHide:true,shell:process.platform==="win32"};return cp.spawnSync("gh",["repo","list","--visibility","private"],o).stdout;})()')"
    if [ "$PRE" = '"STUBOK"' ]; then pass "L0 per-visibility gh stub answers through the shell"
    else LPN_STUB_OK=""; fail "L0 per-visibility gh stub answers through the shell (got=$PRE)"; fi
else
    fail "L0 per-visibility gh stub could not be created"
fi
case_end

case_begin "list-private-repo-names-union" "hooks/lib/forge/github.js"
lpn_case "L1 private + internal -> union, private first" \
    '["test-owner/priv-a","test-owner/priv-b","test-org/int-c"]' \
    $'test-owner/priv-a\ntest-owner/priv-b\n' 0 $'test-org/int-c\n' 0
LPN_SEEN="$(cat "$LPN_LOG" 2>/dev/null)"
if printf '%s\n' "$LPN_SEEN" | grep -qxF "$LPN_PRIV_ARGV"; then pass "L2 gh asked for --visibility private (argv unchanged)"
else fail "L2 gh asked for --visibility private (argv unchanged) (log=$LPN_SEEN)"; fi
if printf '%s\n' "$LPN_SEEN" | grep -qxF "$LPN_INT_ARGV"; then pass "L3 gh asked for --visibility internal (same argv shape)"
else fail "L3 gh asked for --visibility internal (same argv shape) (log=$LPN_SEEN)"; fi
lpn_case "L4 a name in both lists appears once" '["test-owner/a","test-owner/b","test-org/c"]' \
    $'test-owner/a\ntest-owner/b\n' 0 $'test-owner/b\ntest-org/c\n' 0
case_end

case_begin "list-private-repo-names-partial-failure" "hooks/lib/forge/github.js"
lpn_case "L5 internal call fails -> private names still returned" '["test-owner/priv-a"]' \
    $'test-owner/priv-a\n' 0 $'test-org/int-c\n' 1
lpn_case "L6 private call fails -> internal names still returned" '["test-org/int-c"]' \
    $'test-owner/priv-a\n' 1 $'test-org/int-c\n' 0
lpn_case "L7 both calls fail -> []" '[]' $'test-owner/priv-a\n' 1 $'test-org/int-c\n' 1
case_end

case_begin "list-private-repo-names-edge-output" "hooks/lib/forge/github.js"
lpn_case "L8 both calls succeed with empty output -> []" '[]' '' 0 '' 0
lpn_case "L9 CRLF, blank lines and padding dropped in both lists" '["test-owner/a","test-org/c"]' \
    $'test-owner/a\r\n\r\n' 0 $'  test-org/c  \r\n\n' 0
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
