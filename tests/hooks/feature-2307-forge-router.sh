#!/usr/bin/env bash
# tests/feature-2307-forge-router.sh
# Tests: hooks/lib/forge-router.js, hooks/lib/parse-remote-url.js, hooks/lib/forge/github.js, hooks/lib/forge/stub.js
# Tags: forge, forge-router, codehost, tracker, gitlab, jira, security, scope:issue-specific, TL1
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
