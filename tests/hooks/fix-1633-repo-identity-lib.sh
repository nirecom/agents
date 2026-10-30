#!/usr/bin/env bash
# Tests: hooks/lib/repo-identity.js, bin/workflow/lib/next-step/repo-dir-guard.js, hooks/workflow-state/inheritance/adopt.js, bin/lib/resume-session/upstream-view.js
# Tags: workflow, gate, hook, bin, git, repo-identity, scope:issue-specific, progress-file, regression-2748
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

# #2594: the upstream view points at session-progress.md of the FIRST generation, resolved
# from the upstream's inheritance chain, and names the section to read first.
PF_HELPER="$TMP_ROOT/progress-view-helper.js"
cat >"$PF_HELPER" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [agents] = process.argv.slice(2);
const S = require(agents + "/hooks/workflow-state/state-io");
const plans = process.env.WORKFLOW_PLANS_DIR;
const rows = [];
// pf-up inherited from pf-root, whose state is gone: pf-root is the oldest reachable sid.
// #2748: the session chain is the raw state's own keys, never a hand-written inherited_from event.
const pfUp = S.createInitialState("pf-up", { cwd: "/x", git_branch: "feature/x" });
pfUp.upstream_session_id = "pf-root";
pfUp.previous_session_ids = ["pf-root"];
fs.writeFileSync(S.getStatePath("pf-up"), JSON.stringify(pfUp, null, 2));
fs.mkdirSync(plans, { recursive: true });
fs.writeFileSync(path.join(plans, "pf-up-intent.md"), "# intent\n");
fs.writeFileSync(path.join(plans, "pf-root-session-progress.md"), "## Current state\nroot-body\n");
fs.writeFileSync(path.join(plans, "pf-none-intent.md"), "# intent\n");
const { buildUpstreamView } = require(agents + "/bin/lib/resume-session/upstream-view");
const v = buildUpstreamView({ upstreamSid: "pf-up", heirSid: null });
const pf = v && v.progress_file;
const p = pf && typeof pf === "object" ? String(pf.path || "") : "";
rows.push((path.basename(p) === "pf-root-session-progress.md" ? "OK " : "NG ") + "progress-file-root-path got=" + JSON.stringify(pf));
rows.push((pf && pf.section === "Current state" ? "OK " : "NG ") + "progress-file-first-section got=" + JSON.stringify(pf));
const none = buildUpstreamView({ upstreamSid: "pf-none", heirSid: null });
const absent = none && none.availability !== "none" && (none.progress_file === undefined || none.progress_file === null);
rows.push((absent ? "OK " : "NG ") + "progress-file-absent-without-file got=" + JSON.stringify(none && none.progress_file) + " availability=" + (none && none.availability));
process.stdout.write(rows.join("\n") + "\n");
JS

case_begin "upstream-view-progress-file" "bin/lib/resume-session/upstream-view.js"
PF_OUT="$(run_with_timeout 60 node "$(np "$PF_HELPER")" "$AGENTS_NODE" 2>&1)" || true
[ -n "$PF_OUT" ] || fail "progress-file: helper printed nothing"
while IFS=' ' read -r verdict name rest; do
  case "$verdict" in
    OK) pass "progress-file/$name" ;;
    NG) fail "progress-file/$name" "$rest" ;;
    "") : ;;
    *) fail "progress-file: helper output" "$verdict $name $rest" ;;
  esac
done <<<"$PF_OUT"
case_end

# #2594: the real `bin/resume-session-detect --from` CLI carries progress_file into its JSON, so a
# CLI that dropped the field fails here even while buildUpstreamView keeps it. Reuses the pf-* fixture.
# No heir: the parent session's id and the live transcripts must never be resolved.
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$TMP_ROOT/transcripts" "$TMP_ROOT/neutral"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP_ROOT/transcripts")"
DETECT_CHECK="$TMP_ROOT/detect-check.js"
cat >"$DETECT_CHECK" <<'JS'
"use strict";
// argv: <label> <rc> <want rc> <want progress path | "none">; stdin: the CLI's stdout.
const fs = require("fs");
const path = require("path");
const [label, rc, wantRc, wantPath] = process.argv.slice(2);
const rows = [];
const raw = fs.readFileSync(0, "utf8");
rows.push((rc === wantRc ? "OK " : "NG ") + label + "-exit want=" + wantRc + " got=" + rc);
let v = null;
try { v = JSON.parse(raw.trim()); } catch (e) { v = null; }
rows.push((v && v.type === "upstream" ? "OK " : "NG ") + label + "-emits-upstream-json got=" + JSON.stringify(raw.slice(0, 300)));
const pf = v ? v.progress_file : undefined;
const norm = (p) => { const r = path.resolve(p); return process.platform === "win32" ? r.toLowerCase() : r; };
if (wantPath === "none") {
  rows.push((v && pf === undefined ? "OK " : "NG ") + label + "-no-progress-field got=" + JSON.stringify(pf));
  rows.push((!/session-progress\.md/.test(raw) ? "OK " : "NG ") + label + "-no-invented-progress-path");
} else {
  const p = pf && typeof pf.path === "string" ? pf.path : "";
  rows.push((p && path.isAbsolute(p) && norm(p) === norm(wantPath) ? "OK " : "NG ") + label + "-root-generation-absolute-path want=" + JSON.stringify(wantPath) + " got=" + JSON.stringify(p));
  rows.push((p && fs.existsSync(p) ? "OK " : "NG ") + label + "-path-names-the-existing-file");
  rows.push((pf && pf.section === "Current state" ? "OK " : "NG ") + label + "-first-section-is-Current-state got=" + JSON.stringify(pf && pf.section));
}
process.stdout.write(rows.join("\n") + "\n");
JS

# detect_from <label> <upstream sid> <want rc> <want progress path | none>
detect_from() {
  local out rc rows verdict name rest
  out="$(cd "$TMP_ROOT/neutral" && run_with_timeout 60 node "$AGENTS_NODE/bin/resume-session-detect" --from "$2" 2>/dev/null)" && rc=0 || rc=$?
  rows="$(printf '%s' "$out" | run_with_timeout 60 node "$(np "$DETECT_CHECK")" "$1" "$rc" "$3" "$4" 2>&1)" || true
  [ -n "$rows" ] || { fail "$1: checker printed nothing"; return 0; }
  while IFS=' ' read -r verdict name rest; do
    case "$verdict" in
      OK) pass "detect-from/$name" ;;
      NG) fail "detect-from/$name" "$rest" ;;
      "") : ;;
      *) fail "detect-from: checker output" "$verdict $name $rest" ;;
    esac
  done <<<"$rows"
}

case_begin "resume-session-detect-from-progress-file" "bin/lib/resume-session/upstream-view.js"
detect_from "handed-off" pf-up 0 "$(np "$WORKFLOW_PLANS_DIR")/pf-root-session-progress.md"
case_end

case_begin "resume-session-detect-from-without-progress-file" "bin/lib/resume-session/upstream-view.js"
detect_from "no-progress-file" pf-none 0 none
detect_from "unknown-session" pf-never-existed 3 none
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
