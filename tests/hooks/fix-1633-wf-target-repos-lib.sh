#!/usr/bin/env bash
# fix-1633-wf-target-repos-lib.sh
# Tests: hooks/lib/workflow-begun.js, hooks/lib/wf-target-repos.js
# Tags: workflow, gate, hook, git, repo-identity, scope:issue-specific, TL2
# fix-1633 (TL2): readWorkflowBegun (begun / not-begun / unknown) and the WF
# target repo set built from session_start_context.cwd plus the intent's worktrees.

# TL3 gap: only a real session proves session_start_context.cwd and the intent's
# worktree paths hold what clarify-intent wrote; here both are hand-written.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID

AGENTS_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
HELPER="$TMP_ROOT/wf-target-repos-helper.js"
NEUTRAL="$TMP_ROOT/neutral"
mkdir -p "$NEUTRAL"

mk_repo() {
  harness_git_init "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" config core.autocrlf false
  # Distinct content per repo: identical trees committed in the same second share a HEAD SHA.
  echo "seed-${1##*/}" >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q --no-verify -m init
}

# MAIN (+ linked MAINLINKED) is the session-start repo; SIB_SRC (+ linked SIB1)
# and SIB2 are intent siblings; OTHER is unrelated; NONREPO is a plain dir.
MAIN="$(np "$TMP_ROOT/main")"
MAINLINKED="$(np "$TMP_ROOT/main-linked")"
SIB_SRC="$(np "$TMP_ROOT/sib-src")"
SIB1="$(np "$TMP_ROOT/sib1")"
SIB2="$(np "$TMP_ROOT/sib2")"
OTHER="$(np "$TMP_ROOT/other")"
NONREPO="$(np "$TMP_ROOT/not-a-repo")"
MISSING="$(np "$TMP_ROOT")/never-existed"
for r in "$MAIN" "$SIB_SRC" "$SIB2" "$OTHER"; do mk_repo "$r"; done
git -C "$MAIN" worktree add -q -b main-linked "$MAINLINKED"
git -C "$SIB_SRC" worktree add -q -b sib1 "$SIB1"
mkdir -p "$NONREPO"
# POSIX drive form of MAINLINKED (/c/...); empty when cygpath is absent.
POSIX_LINKED=""
if command -v cygpath >/dev/null 2>&1; then POSIX_LINKED="$(cygpath -u "$MAINLINKED")"; fi

# Rows: "OK <name> ..." / "NG <name> ..." / "SKIP <name> ...". The fixture
# writers live in this helper so each group seeds exactly the state it reads.
cat >"$HELPER" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [agents, group, main, mainLinked, sib1, sib2, other, nonrepo, missing, posixLinked] = process.argv.slice(2);
const rows = [];
function load(rel) {
  try { return require(agents + "/" + rel); } catch (e) { return { __loadError: String(e.message).split("\n")[0] }; }
}
const io = require(agents + "/hooks/workflow-state/state-io");
const { VALID_STEPS } = require(agents + "/hooks/workflow-state");
const ri = load("hooks/lib/repo-identity");
const wb = load("hooks/lib/workflow-begun");
const wt = load("hooks/lib/wf-target-repos");
function check(name, mod, fn, want) {
  if (mod.__loadError) { rows.push("NG " + name + " module-missing:" + mod.__loadError); return; }
  try {
    const got = fn();
    const ok = JSON.stringify(got) === JSON.stringify(want);
    rows.push((ok ? "OK " : "NG ") + name + " want=" + JSON.stringify(want) + " got=" + JSON.stringify(got));
  } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
}
// v1 file: every VALID_STEP complete, `steps` overrides, `drop` removes step keys, `extra` is top level.
function writeV1(sid, extra, steps, drop) {
  const st = {};
  for (const s of VALID_STEPS) st[s] = { status: "complete", updated_at: "2026-06-27T10:00:00.000Z" };
  Object.assign(st, steps || {});
  for (const d of drop || []) delete st[d];
  const obj = Object.assign({ session_id: sid, created_at: "2026-06-27T10:00:00.000Z", steps: st }, extra || {});
  fs.writeFileSync(io.getStatePath(sid), JSON.stringify(obj));
}
function writeRaw(sid, text) { fs.writeFileSync(io.getStatePath(sid), text); }
function writeIntent(sid, entries) {
  const lines = ["# intent", "", "## worktrees"];
  for (const e of entries) lines.push("- repo: " + e.repo, "  worktree_path: " + e.path);
  lines.push("", "## other", "");
  fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, sid + "-intent.md"), lines.join("\n"));
}
const verdictOf = (sid) => { const r = wb.readWorkflowBegun(sid); return { verdict: r.verdict, reason: r.reason }; };
const verdictOnly = (sid) => wb.readWorkflowBegun(sid).verdict;
const loc = (d) => (ri.__loadError || typeof ri.resolveRepoLocation !== "function" ? "resolveRepoLocation-missing" : ri.resolveRepoLocation(d));
const membersOf = (sid) => wt.readWfTargetRepos(sid, io.readState(sid));
const shape = (r) => (r && r.ok ? r.members.map((m) => ({ origin: m.origin, repoSlug: m.repoSlug })) : r);

if (group === "begun") {
  check("no-state-file-not-begun", wb, () => verdictOf("lib-begun-nostate"), { verdict: "not-begun", reason: "no-state" });
  writeRaw("lib-begun-corrupt", "{not json");
  check("corrupt-json-unknown", wb, () => verdictOf("lib-begun-corrupt"), { verdict: "unknown", reason: "state-unreadable" });
  writeRaw("lib-begun-future", JSON.stringify({ version: 999, session_id: "lib-begun-future", events: [] }));
  check("unknown-future-version-unknown", wb, () => verdictOf("lib-begun-future"), { verdict: "unknown", reason: "state-unreadable" });
  check("traversal-sid-unknown-no-throw", wb, () => verdictOf("../../etc/passwd"), { verdict: "unknown", reason: "invalid-session-id" });
  io.updateTopLevel("lib-begun-pending", () => {});
  check("v2-initial-pending-not-begun", wb, () => verdictOnly("lib-begun-pending"), "not-begun");
  io.markStep("lib-begun-inprog", "workflow_init", "in_progress");
  check("in-progress-begun", wb, () => verdictOnly("lib-begun-inprog"), "begun");
  io.markStep("lib-begun-complete", "workflow_init", "complete");
  check("complete-begun", wb, () => verdictOnly("lib-begun-complete"), "begun");
  io.markStep("lib-begun-skipped", "workflow_init", "skipped");
  check("skipped-begun", wb, () => verdictOnly("lib-begun-skipped"), "begun");
  // v1 read defaults (applyLegacyV1ReadDefaults): no clarify_intent -> workflow_init complete.
  writeV1("lib-begun-v1-old", {}, {}, ["clarify_intent", "workflow_init"]);
  check("v1-no-clarify-no-init-begun", wb, () => verdictOnly("lib-begun-v1-old"), "begun");
  writeV1("lib-begun-v1-ci-pending", {}, { clarify_intent: { status: "pending", updated_at: null } }, ["workflow_init"]);
  check("v1-clarify-pending-no-init-not-begun", wb, () => verdictOnly("lib-begun-v1-ci-pending"), "not-begun");
} else if (group === "targets") {
  writeV1("lib-t-nocwd", {});
  check("session-start-cwd-missing", wt, () => membersOf("lib-t-nocwd"), { ok: false, reason: "session-start-cwd-missing" });
  writeV1("lib-t-nonrepo", { cwd: nonrepo });
  check("session-start-cwd-not-a-repo", wt, () => membersOf("lib-t-nonrepo"), { ok: false, reason: "session-start-cwd-not-a-repo" });
  writeV1("lib-t-nointent", { cwd: main });
  check("no-intent-main-only", wt, () => shape(membersOf("lib-t-nointent")), [{ origin: "session-start", repoSlug: null }]);
  check("no-intent-main-location", wt, () => membersOf("lib-t-nointent").members[0].location, loc(main));
  writeV1("lib-t-two", { cwd: main });
  writeIntent("lib-t-two", [{ repo: "o/sib-src", path: sib1 }, { repo: "o/sib2", path: sib2 }]);
  check("intent-two-worktrees-three-members", wt, () => shape(membersOf("lib-t-two")), [
    { origin: "session-start", repoSlug: null },
    { origin: "intent-worktrees", repoSlug: "o/sib-src" },
    { origin: "intent-worktrees", repoSlug: "o/sib2" },
  ]);
  check("intent-sibling-location-resolved", wt, () => membersOf("lib-t-two").members[1].location, loc(sib1));
  // #2748: a session-downstream reads <first_session_id>-intent.md; its own-sid intent is ignored.
  writeV1("lib-t-downstream", { cwd: main });
  io.updateTopLevel("lib-t-downstream", (s) => { s.previous_session_ids = ["lib-t-first"]; s.upstream_session_id = "lib-t-first"; });
  writeIntent("lib-t-downstream", [{ repo: "o/sib-src", path: sib1 }]);
  writeIntent("lib-t-first", [{ repo: "o/sib2", path: sib2 }]);
  check("downstream-reads-first-session-intent", wt, () => shape(membersOf("lib-t-downstream")), [
    { origin: "session-start", repoSlug: null },
    { origin: "intent-worktrees", repoSlug: "o/sib2" },
  ]);
  check("read-main-repo-location", wt, () => wt.readMainRepoLocation(membersOf("lib-t-two").members), loc(main));
} else if (group === "classify") {
  writeV1("lib-c-main", { cwd: main });
  const v = (sid, d) => { const r = wt.classifyDirAgainstWfTargetRepos(membersOf(sid).members, d); return r && r.verdict; };
  check("linked-worktree-of-main-in", wt, () => v("lib-c-main", mainLinked), "in");
  check("other-repo-out", wt, () => v("lib-c-main", other), "out");
  check("missing-path-location-unknown", wt, () => v("lib-c-main", missing), "location-unknown");
  check("in-carries-location", wt, () => wt.classifyDirAgainstWfTargetRepos(membersOf("lib-c-main").members, mainLinked).location, loc(mainLinked));
  writeV1("lib-c-unresolved", { cwd: main });
  writeIntent("lib-c-unresolved", [{ repo: "o/later", path: missing }]);
  check("unresolved-sibling-other-possibly-in", wt, () => v("lib-c-unresolved", other), "possibly-in");
  check("unresolved-sibling-member-location-null", wt, () => membersOf("lib-c-unresolved").members[1].location, null);
  if (posixLinked) check("posix-drive-form-in", wt, () => v("lib-c-main", posixLinked), "in");
  else rows.push("SKIP posix-drive-form-in cygpath-absent");
} else {
  rows.push("NG unknown-group " + group);
}
process.stdout.write(rows.join("\n") + "\n");
JS

run_group() {
  local group="$1" out verdict name rest
  if ! out="$(cd "$NEUTRAL" && run_with_timeout 60 node "$(np "$HELPER")" "$AGENTS_NODE" "$group" \
      "$MAIN" "$MAINLINKED" "$SIB1" "$SIB2" "$OTHER" "$NONREPO" "$MISSING" "$POSIX_LINKED" 2>&1)"; then
    fail "$group: helper exited non-zero" "$out"
    return 0
  fi
  [ -n "$out" ] || { fail "$group: helper printed nothing"; return 0; }
  while IFS=' ' read -r verdict name rest; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      OK) pass "$group/$name" ;;
      SKIP) skip "$group/$name ($rest)" ;;
      *) fail "$group/$name" "$rest" ;;
    esac
  done <<<"$out"
}

echo "=== fix-1633: workflow-begun / wf-target-repos libs ==="

case_begin "workflow-begun-verdicts" "hooks/lib/workflow-begun.js"
run_group begun
case_end

case_begin "wf-target-repos-members" "hooks/lib/wf-target-repos.js"
run_group targets
case_end

case_begin "wf-target-repos-classify" "hooks/lib/wf-target-repos.js"
run_group classify
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
