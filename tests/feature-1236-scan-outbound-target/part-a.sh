#!/bin/bash
# Part A — extractRepoFlag(command) unit (table-driven, node driver).
# Sourced-and-run standalone: builds its own PASS/FAIL via helpers.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$HERE/helpers.sh"

echo "=== Part A: extractRepoFlag unit (table-driven) ==="

DRIVER_A="$TMPBASE/driver-extract-flag.js"
cat > "$DRIVER_A" <<'NODE'
"use strict";
const path = require("path");
const AGENTS_NODE = process.argv[2];
const CMD         = process.argv[3] || "";

let mod;
try {
    mod = require(path.join(AGENTS_NODE, "hooks", "lib", "forge-write-extract.js"));
} catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND") {
        process.stdout.write(JSON.stringify({ ok: false, missing: true, error: "forge-write-extract.js MODULE_NOT_FOUND" }) + "\n");
        process.exit(0);
    }
    process.stdout.write(JSON.stringify({ ok: false, error: String((e && e.message) || e) }) + "\n");
    process.exit(0);
}

if (typeof mod.extractRepoFlag !== "function") {
    process.stdout.write(JSON.stringify({ ok: false, missing: true, error: "extractRepoFlag not yet exported" }) + "\n");
    process.exit(0);
}

try {
    const v = mod.extractRepoFlag(CMD);
    process.stdout.write(JSON.stringify({ ok: true, value: v === null || v === undefined ? null : v }) + "\n");
} catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: String((e && e.message) || e) }) + "\n");
}
NODE

call_flag() {
    local cmd="$1"
    run_with_timeout 10 node "$DRIVER_A" "$_AGENTS_NODE" "$cmd" 2>/dev/null
}

# Table-driven assertion helper using IFS='|' pattern from test-design.md
assert_flag() {
    local name="$1" want="$2" cmd="$3"
    local out got
    out="$(call_flag "$cmd")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$name — extractRepoFlag not yet implemented"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$name — driver error: $out"
        return
    fi
    got="$(echo "$out" | node -e "
const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(j.value===null?'__NULL__':String(j.value));
" 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name — want='$want' got='$got'"
    fi
}

# Table: name | expected | command
# Expected __NULL__ means extractRepoFlag returns null
while IFS='|' read -r name want cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    assert_flag "$name" "$want" "$cmd"
done <<'TABLE'
long-flag-space         | owner/repo | gh issue create --repo owner/repo --body "x"
long-flag-equals        | owner/repo | gh issue create --repo=owner/repo
short-flag-space        | owner/repo | gh issue create -R owner/repo
short-flag-equals       | owner/repo | gh issue create -R=owner/repo
short-flag-quoted       | owner/repo | gh issue create -R "owner/repo"
long-flag-quoted        | owner/repo | gh issue create --repo "owner/repo"
no-flag                 | __NULL__   | gh issue create --body "x"
quoted-body-contains-R  | __NULL__   | gh issue create --body "-R owner/repo"
quoted-body-contains-repo | __NULL__ | gh issue create --body "--repo sneaky/repo"
body-and-real-flag      | owner/real | gh issue create --body "text" --repo owner/real
body-repo-trailing-text | __NULL__   | gh issue create --title t --body "see --repo attacker/evil for details"
body-repo-eq-midphrase  | __NULL__   | gh issue create --title t --body "x --repo=priv/secret y"
body-repo-prefix-suffix | __NULL__   | gh issue create --title t --body "prefix --repo priv/secret suffix"
real-repo-before-body-smuggle | real/target | gh pr create --repo "real/target" --body "noise --repo evil/x"
real-repo-after-body-smuggle  | good/one    | gh pr create --body "noise --repo evil/x" --repo good/one
TABLE

echo ""
echo "Part A: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
