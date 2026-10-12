#!/usr/bin/env bash
# Tests: hooks/lib/repo-identity.js, bin/workflow/lib/next-step/repo-dir-guard.js, hooks/workflow-state/inheritance/adopt.js, bin/lib/resume-session/upstream-view.js
# Tags: workflow, gate, hook, bin, git, repo-identity, scope:issue-specific
# fix-1633 (TL1/TL2): the repo-identity comparator moves from the bin-side
# repo-dir-guard into hooks/lib so the workflow gate can use it without a
# hooks -> bin dependency. repo-dir-guard keeps re-exporting the SAME objects,
# and the two hooks/bin consumers require the hooks/lib owner directly.
# No TL3 gap block: local git fixtures cover the surface; no Windows-only or claude -p path (rules/test.md).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"

AGENTS_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
HELPER="$TMP_ROOT/repo-identity-helper.js"

# Fixture repos: MAIN with a linked worktree LINKED, and an unrelated OTHER.
MAIN="$TMP_ROOT/main"
OTHER="$TMP_ROOT/other"
LINKED="$TMP_ROOT/linked"
for r in "$MAIN" "$OTHER"; do
  harness_git_init "$r"
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  git -C "$r" config core.autocrlf false
  # Distinct content per repo: identical trees committed in the same second share a HEAD SHA.
  echo "seed-${r##*/}" >"$r/README.md"
  git -C "$r" add README.md
  git -C "$r" commit -q --no-verify -m init
done
git -C "$MAIN" worktree add -q -b linked-branch "$LINKED"
# A plain directory outside any repo (TMP_ROOT itself is not a git work tree).
NONREPO="$TMP_ROOT/not-a-repo"
mkdir -p "$NONREPO"

# Rows: "OK <name>" / "NG <name> <detail>". argv: agents group main other linked missing
cat >"$HELPER" <<'JS'
"use strict";
const [agents, group, main, other, linked, missing, nonrepo] = process.argv.slice(2);
const rows = [];
function load(rel) {
  try { return require(agents + "/" + rel); } catch (e) { return { __loadError: String(e.message).split("\n")[0] }; }
}
const ri = load("hooks/lib/repo-identity");
function check(name, fn, want) {
  if (ri.__loadError) { rows.push("NG " + name + " module-missing:" + ri.__loadError); return; }
  try {
    const got = fn();
    const ok = JSON.stringify(got) === JSON.stringify(want);
    rows.push((ok ? "OK " : "NG ") + name + " want=" + JSON.stringify(want) + " got=" + JSON.stringify(got));
  } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
}
if (group === "exports") {
  check("verdicts-five-values", () => ri.VERDICTS && Object.assign({}, ri.VERDICTS),
    { SAME: "same", SIBLING: "sibling-worktree", DIFFERENT: "different-repo", UNKNOWN: "unknown", INDETERMINATE: "indeterminate" });
  check("verdicts-frozen", () => Object.isFrozen(ri.VERDICTS), true);
  for (const fn of ["compareRepoIdentity", "compareRepoContentEquivalence", "normalizePathForCompare"]) {
    check("exports-" + fn, () => typeof ri[fn], "function");
  }
} else if (group === "reexport") {
  const guard = require(agents + "/bin/workflow/lib/next-step/repo-dir-guard");
  for (const n of ["VERDICTS", "compareRepoIdentity", "compareRepoContentEquivalence", "normalizePathForCompare"]) {
    check("same-object-" + n, () => ri[n] !== undefined && guard[n] === ri[n], true);
  }
  check("guard-keeps-assert", () => typeof guard.assertRepoDirMatchesSession, "function");
} else if (group === "behavior") {
  check("normalize-posix-drive", () => ri.normalizePathForCompare("/c/Foo/Bar/"), "c:/foo/bar");
  check("normalize-backslash", () => ri.normalizePathForCompare("C:\\Foo\\Bar"), "c:/foo/bar");
  check("normalize-empty-null", () => ri.normalizePathForCompare(""), null);
  check("identity-same", () => ri.compareRepoIdentity(main, main), "same");
  check("identity-sibling-worktree", () => ri.compareRepoIdentity(main, linked), "sibling-worktree");
  check("identity-different-repo", () => ri.compareRepoIdentity(main, other), "different-repo");
  check("identity-missing-path", () => ri.compareRepoIdentity(main, missing), "indeterminate");
  check("identity-null-recorded", () => ri.compareRepoIdentity(null, main), "unknown");
  check("content-equivalent-self", () => ri.compareRepoContentEquivalence(main, main), true);
  check("content-different-repos", () => ri.compareRepoContentEquivalence(main, other), false);
} else if (group === "location") {
  // resolveRepoLocation(dir) -> { toplevel, commonDir } (both normalized) or null.
  const n = (p) => ri.normalizePathForCompare(p);
  const loc = (d) => (typeof ri.resolveRepoLocation === "function" ? ri.resolveRepoLocation(d) : "not-exported");
  check("location-main-checkout", () => loc(main), { toplevel: n(main), commonDir: n(main + "/.git") });
  check("location-linked-worktree-shares-common-dir", () => loc(linked), { toplevel: n(linked), commonDir: n(main + "/.git") });
  check("location-not-a-repo", () => loc(nonrepo), null);
  check("location-missing-path", () => loc(missing), null);
} else if (group === "consumers") {
  // The guard loads first and captures the REAL functions; only then is a spy swapped
  // into the owner's cache entry, so a consumer still routed through the guard misses it.
  if (ri.__loadError) {
    rows.push("NG upstream-view-calls-owner module-missing:" + ri.__loadError);
    rows.push("NG adopt-loads-owner-directly module-missing:" + ri.__loadError);
  } else {
    const riPath = require.resolve(agents + "/hooks/lib/repo-identity");
    require(agents + "/bin/workflow/lib/next-step/repo-dir-guard");
    let calls = 0;
    require.cache[riPath].exports = Object.assign({}, ri, {
      compareRepoIdentity: (...args) => { calls++; return ri.compareRepoIdentity(...args); },
    });
    try {
      const r = require(agents + "/bin/lib/resume-session/upstream-view").decideGranularity(main, other);
      const ok = calls > 0 && r.repo_verdict === ri.VERDICTS.DIFFERENT;
      rows.push((ok ? "OK " : "NG ") + "upstream-view-calls-owner calls=" + calls + " got=" + JSON.stringify(r));
    } catch (e) { rows.push("NG upstream-view-calls-owner threw:" + e.message); }
    const adoptMod = require.cache[require.resolve(agents + "/hooks/workflow-state/inheritance/adopt")];
    const direct = !!adoptMod && adoptMod.children.some((c) => c.id === riPath);
    rows.push((direct ? "OK " : "NG ") + "adopt-loads-owner-directly loaded=" + !!adoptMod);
  }
} else {
  rows.push("NG unknown-group " + group);
}
process.stdout.write(rows.join("\n") + "\n");
JS

run_group() {
  local group="$1" out verdict name rest
  if ! out="$(run_with_timeout 60 node "$(np "$HELPER")" "$AGENTS_NODE" "$group" \
      "$(np "$MAIN")" "$(np "$OTHER")" "$(np "$LINKED")" "$(np "$TMP_ROOT")/does-not-exist" \
      "$(np "$NONREPO")" 2>&1)"; then
    fail "$group: helper exited non-zero" "$out"
    return 0
  fi
  [ -n "$out" ] || { fail "$group: helper printed nothing"; return 0; }
  while IFS=' ' read -r verdict name rest; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = "OK" ]; then pass "$group/$name"; else fail "$group/$name" "$rest"; fi
  done <<<"$out"
}

# requires_owner <file> <label> — the consumer requires hooks/lib/repo-identity
# and no longer reaches into the bin-side guard.
requires_owner() {
  local file="$SCRIPT_CHECKOUT_ROOT/$1" label="$2"
  if [ ! -f "$file" ]; then fail "$label: source missing" "$1"; return 0; fi
  if grep -Eq "require\\([\"'][./]*(hooks/)?lib/repo-identity[\"']\\)" "$file"; then
    pass "$label: requires hooks/lib/repo-identity"
  else
    fail "$label: requires hooks/lib/repo-identity" "no require of lib/repo-identity in $1"
  fi
  if grep -q "next-step/repo-dir-guard" "$file"; then
    fail "$label: no bin-side guard require" "$1 still requires next-step/repo-dir-guard"
  else
    pass "$label: no bin-side guard require"
  fi
}

echo "=== fix-1633: repo-identity lib ==="

case_begin "repo-identity-exports" "hooks/lib/repo-identity.js"
run_group exports
case_end

case_begin "repo-identity-behavior" "hooks/lib/repo-identity.js"
run_group behavior
case_end

case_begin "repo-identity-resolve-location" "hooks/lib/repo-identity.js"
run_group location
case_end

case_begin "repo-dir-guard-reexports-same-objects" "bin/workflow/lib/next-step/repo-dir-guard.js"
run_group reexport
case_end

case_begin "adopt-requires-hooks-lib" "hooks/workflow-state/inheritance/adopt.js"
requires_owner "hooks/workflow-state/inheritance/adopt.js" "adopt.js"
case_end

case_begin "upstream-view-requires-hooks-lib" "bin/lib/resume-session/upstream-view.js"
requires_owner "bin/lib/resume-session/upstream-view.js" "upstream-view.js"
case_end

case_begin "consumers-use-owner-at-runtime" "bin/lib/resume-session/upstream-view.js"
run_group consumers
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
