#!/usr/bin/env bash
# tests/hooks/feature-2447-native-isolation.sh
# Tests: hooks/lib/native-isolation.js
# Tags: TL1, hook, native-isolation, worktree, fail-open, scope:issue-specific
# #2447/#1680: shared worktree_entered_at / worktree_exited_at predicate. A
# readStateFn is injected per case, so no real state file is ever read.
# isUnderNativeIsolation = entered && !exited; hasExitedWorktree = exited.
# Every malformed / missing / throwing input must fail open to false.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"
cd "$T"

NI_MOD="$(np "$AGENTS_DIR/hooks/lib/native-isolation.js")"
ENTERED="2026-09-29T00:00:00.000Z"
EXITED="2026-09-29T01:00:00.000Z"

# ni_eval <fn> <sid> <mode> → prints true | false | missing-export | load-error:<msg> | threw:<msg>
# <sid> "-" means empty string, "null" means null. <mode> selects the injected readStateFn.
ni_eval() {
    node -e '
const [mod, fn, sidArg, mode, entered, exited] = process.argv.slice(1);
let m;
try { m = require(mod); } catch (e) { process.stdout.write("load-error:" + e.code); process.exit(0); }
if (typeof m[fn] !== "function") { process.stdout.write("missing-export"); process.exit(0); }
const sid = sidArg === "-" ? "" : sidArg === "null" ? null : sidArg;
const calls = [];
const table = {
  active:        () => ({ worktree_entered_at: entered, worktree_exited_at: null }),
  exited:        () => ({ worktree_entered_at: entered, worktree_exited_at: exited }),
  exitedOnly:    () => ({ worktree_entered_at: null, worktree_exited_at: exited }),
  notEntered:    () => ({ worktree_entered_at: null, worktree_exited_at: null }),
  nullState:     () => null,
  throws:        () => { throw new Error("boom"); },
  noFields:      () => ({ events: [] }),
  badEntered:    () => ({ worktree_entered_at: "not-a-date", worktree_exited_at: null }),
  badExited:     () => ({ worktree_entered_at: entered, worktree_exited_at: "garbage" }),
  emptyStrings:  () => ({ worktree_entered_at: "", worktree_exited_at: "" }),
  nonString:     () => ({ worktree_entered_at: 1727568000000, worktree_exited_at: 1727571600000 }),
  primitive:     () => "not-an-object",
};
const readStateFn = (s) => { calls.push(s); return table[mode](s); };
let out;
try { out = m[fn](sid, readStateFn); } catch (e) { process.stdout.write("threw:" + e.message); process.exit(0); }
if (mode === "active" && sid && calls[0] !== sid) { process.stdout.write("wrong-sid:" + calls[0]); process.exit(0); }
process.stdout.write(out === true ? "true" : out === false ? "false" : "non-bool:" + JSON.stringify(out));
' "$NI_MOD" "$1" "$2" "$3" "$ENTERED" "$EXITED"
}

expect() { # expect <want> <label> <got>
    if [[ "$3" == "$1" ]]; then pass "$2"; else fail "$2" "want=$1 got=$3"; fi
}

SID="test-2447-ni"

# --- isUnderNativeIsolation ---
expect true  "NI-1: entered set, exited null → isUnderNativeIsolation true"   "$(ni_eval isUnderNativeIsolation "$SID" active)"
expect false "NI-2: entered set, exited set → isUnderNativeIsolation false"   "$(ni_eval isUnderNativeIsolation "$SID" exited)"
expect false "NI-3: entered null → isUnderNativeIsolation false"              "$(ni_eval isUnderNativeIsolation "$SID" notEntered)"
expect false "NI-4: exited only (entered null) → isUnderNativeIsolation false" "$(ni_eval isUnderNativeIsolation "$SID" exitedOnly)"

# --- hasExitedWorktree ---
expect true  "HE-1: exited set → hasExitedWorktree true"                      "$(ni_eval hasExitedWorktree "$SID" exited)"
expect false "HE-2: exited null → hasExitedWorktree false"                    "$(ni_eval hasExitedWorktree "$SID" active)"
expect false "HE-3: neither set → hasExitedWorktree false"                    "$(ni_eval hasExitedWorktree "$SID" notEntered)"
expect true  "HE-4: exitedOnly (entered null, exited set) → hasExitedWorktree true" "$(ni_eval hasExitedWorktree "$SID" exitedOnly)"

# --- fail-open matrix: both predicates must answer false ---
for fn in isUnderNativeIsolation hasExitedWorktree; do
    expect false "FO-sid-empty [$fn]: sessionId '' → false"            "$(ni_eval "$fn" - active)"
    expect false "FO-sid-null [$fn]: sessionId null → false"           "$(ni_eval "$fn" null exited)"
    expect false "FO-null-state [$fn]: readStateFn returns null → false" "$(ni_eval "$fn" "$SID" nullState)"
    expect false "FO-throw [$fn]: readStateFn throws → false (no throw)" "$(ni_eval "$fn" "$SID" throws)"
    expect false "FO-no-fields [$fn]: state without worktree fields → false" "$(ni_eval "$fn" "$SID" noFields)"
    expect false "FO-empty-str [$fn]: empty-string timestamps → false"  "$(ni_eval "$fn" "$SID" emptyStrings)"
    expect false "FO-non-string [$fn]: numeric timestamps → false"     "$(ni_eval "$fn" "$SID" nonString)"
    expect false "FO-primitive [$fn]: non-object state → false"        "$(ni_eval "$fn" "$SID" primitive)"
done

# --- invalid date strings ---
expect false "BAD-1: invalid entered_at → isUnderNativeIsolation false"      "$(ni_eval isUnderNativeIsolation "$SID" badEntered)"
expect false "BAD-2: invalid exited_at → hasExitedWorktree false"            "$(ni_eval hasExitedWorktree "$SID" badExited)"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
