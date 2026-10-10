#!/usr/bin/env bash
# tests/bin/feature-2561-worker-payload-keys.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/workers/issue-close-finalize/state.js
# Tags: worker-dispatch, payload, root-names, state-file, security, untrusted-input, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch):
# - a real skill run whose model writes a payload key the skill text does not name
# - a state file left in a live control dir by the code before the rename
# Closest-to-action mitigation: capability.js refuses every undeclared key before a worker starts.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/target-repo-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/target-repo-fixture.sh"

TMP_ROOT="$(np "$(make_tmp)")"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"

if ! target_repo_fixture_create "$TMP_ROOT"; then
  echo "FAIL: the target repository fixture could not be built"
  exit 1
fi

readonly PROBE="$TMP_ROOT/probe.js"
cat >"$PROBE" <<'PROBE_JS'
"use strict";
// One line per check: ok<TAB>name  or  ng<TAB>name<TAB>detail.
const fs = require("fs");
const path = require("path");

const [, , root, group, targetMain, targetLinked, agentsMain] = process.argv;
const req = (rel) => require(path.join(root, ...rel.split("/")));
const read = (rel) => fs.readFileSync(path.join(root, ...rel.split("/")), "utf8");
const lines = [];
const flat = (v) => String(v === undefined ? "" : v).replace(/\s+/g, " ").slice(0, 400);
const check = (name, cond, detail) => lines.push(cond ? `ok\t${name}` : `ng\t${name}\t${flat(detail)}`);
const sorted = (xs) => Array.from(new Set(xs)).sort().join(",");

// Spellings from before the rename, assembled so this file never holds them.
const OLD = {
  checkoutKey: ["agents", "con" + "fig", "d" + "ir"].join("_"),
  mainKey: "main" + "_" + "root",
  mainPathKey: "main_wor" + "ktree_path",
  checkoutType: "anchor-" + "a" + "cd",
  mainType: "anchor-" + "main" + "-root",
  checkoutAnchor: "a" + "cd",
  mainAnchor: "main" + "-root",
  docsScope: "main" + "-root" + "-docs",
};
const NEW_TYPES = ["anchor-script-checkout-root", "anchor-target-main-root"];
const NEW_ANCHORS = ["family-worktree", "script-checkout-root", "target-main-root"];
const UNKNOWN_FIELD = (key) => `unknown field '${key}' is not declared by this worker's payloadSpec`;

const registry = req("hooks/lib/worker-dispatch-registry.js");
const anchorLib = req("bin/worker-dispatch/anchor.js");
const capability = req("bin/worker-dispatch/capability.js");
const anchors = anchorLib.resolveAnchors(targetMain);
const str = (v) => (typeof v === "string" && v !== "" ? v : "<unresolved>");
const checkoutRoot = str(anchors.scriptCheckoutRoot);
const targetMainRoot = str(anchors.targetMainRoot);

function validate(worker, payload) {
  return capability.validate(payload, registry.workers[worker], anchors);
}

function payloadKeys() {
  check("anchors/resolved", anchors.error === null, anchors.error);
  check("anchors/script-checkout-root-is-this-checkout", anchorLib.samePath(checkoutRoot, root), checkoutRoot);
  check("anchors/target-main-root-is-the-target", anchorLib.samePath(targetMainRoot, targetMain), targetMainRoot);
  // The agents main root of this run is a directory of its own: neither the checkout nor the target.
  const isDir = (p) => typeof p === "string" && fs.existsSync(p) && fs.statSync(p).isDirectory();
  check("fixture/agents-main-root-is-a-directory-named-by-the-env", isDir(agentsMain) && process.env.AGENTS_MAIN_ROOT === agentsMain, agentsMain);
  check("fixture/script-checkout-root-is-a-directory", isDir(root), root);
  const apart = !anchorLib.samePath(agentsMain, root) && !anchorLib.samePath(agentsMain, targetMain);
  check("fixture/agents-main-root-differs-from-the-checkout-and-the-target", apart, `${agentsMain} | ${root} | ${targetMain}`);
  check("anchors/script-checkout-root-is-not-the-agents-main-root", !anchorLib.samePath(checkoutRoot, agentsMain), checkoutRoot);
  const base = {
    "worktree-copy": { worktree_path: targetLinked, branch: "target-fixture-linked" },
    "commit-push": { commit_message: "m", branch: "target-fixture-linked", worktree_path: targetLinked, session_id: "sid2561" },
    "issue-close-stage": { issue_number: 7, worktree_path: targetLinked, owner_repo: "acme/widgets" },
    "issue-close-finalize": { phase: "initial", issue_number: 7, root_issue_number: 7, owner_repo: "acme/widgets", session_id: "sid2561" },
  };
  for (const worker of Object.keys(base)) {
    const b = base[worker];
    const plain = validate(worker, b);
    check(`${worker}/base-payload-valid`, plain.ok, plain.errors.join(" | "));
    const fresh = validate(worker, { ...b, script_checkout_root: checkoutRoot });
    check(`${worker}/script_checkout_root-accepted`, fresh.ok, fresh.errors.join(" | "));
    const slash = validate(worker, { ...b, script_checkout_root: checkoutRoot.replace(/\\/g, "/") });
    check(`${worker}/script_checkout_root-forward-slash-accepted`, slash.ok, slash.errors.join(" | "));
    const stale = validate(worker, { ...b, [OLD.checkoutKey]: checkoutRoot });
    check(`${worker}/old-checkout-key-rejected`, stale.errors.includes(UNKNOWN_FIELD(OLD.checkoutKey)), stale.errors.join(" | "));
    const wrong = validate(worker, { ...b, script_checkout_root: targetMain });
    check(
      `${worker}/script_checkout_root-other-root-rejected`,
      wrong.errors.some((e) => e.startsWith("field 'script_checkout_root' must be exactly")),
      wrong.errors.join(" | "),
    );
    // The checkout's own path is accepted (not merely "no error"); the agents main root is not.
    const own = validate(worker, { ...b, script_checkout_root: root });
    check(`${worker}/script_checkout_root-equal-to-the-checkout-accepted`, own.ok && own.errors.length === 0, own.errors.join(" | "));
    const viaEnv = validate(worker, { ...b, script_checkout_root: agentsMain });
    check(
      `${worker}/script_checkout_root-agents-main-root-rejected`,
      !viaEnv.ok && viaEnv.errors.some((e) => e.startsWith("field 'script_checkout_root' must be exactly")),
      viaEnv.errors.join(" | "),
    );
  }
  for (const [worker, oldKey] of [["worktree-copy", OLD.mainKey], ["issue-close-finalize", OLD.mainPathKey]]) {
    const b = base[worker];
    const fresh = validate(worker, { ...b, target_main_root: targetMainRoot });
    check(`${worker}/target_main_root-accepted`, fresh.ok, fresh.errors.join(" | "));
    const stale = validate(worker, { ...b, [oldKey]: targetMainRoot });
    check(`${worker}/old-main-key-rejected`, stale.errors.includes(UNKNOWN_FIELD(oldKey)), stale.errors.join(" | "));
    const wrong = validate(worker, { ...b, target_main_root: targetLinked });
    check(
      `${worker}/target_main_root-linked-worktree-rejected`,
      wrong.errors.some((e) => e.startsWith("field 'target_main_root' must be exactly")),
      wrong.errors.join(" | "),
    );
  }
  const finalize = req("bin/worker-dispatch/workers/issue-close-finalize.js");
  const initial = { issue_number: 7, root_issue_number: 7, owner_repo: "acme/widgets", state_file_path: "x" };
  const missing = finalize.checkRequired(initial, "initial");
  check("issue-close-finalize/initial-requires-target_main_root", missing === "phase=initial requires 'target_main_root'", missing);
  const full = finalize.checkRequired({ ...initial, target_main_root: targetMainRoot }, "initial");
  check("issue-close-finalize/initial-complete-with-target_main_root", full === null, full);
}

function declaredVsInterpreted() {
  const types = [];
  for (const worker of registry.WORKER_NAMES) {
    for (const field of Object.values(registry.workers[worker].payloadSpec)) types.push(field.type);
  }
  const unknown = Array.from(new Set(types)).filter((type) => {
    const res = capability.checkField(undefined, { type, control: "x.json" }, anchors, {});
    return typeof res.error === "string" && res.error.includes("unknown capability type");
  });
  check("types/every-declared-type-is-interpreted", types.length > 0 && unknown.length === 0, unknown.join(","));
  const declaredAnchorTypes = types.concat(registry.STANDARD_ARG_SPEC).filter((t) => t.startsWith("anchor-"));
  check("types/declared-anchor-types", sorted(declaredAnchorTypes) === sorted(NEW_TYPES), sorted(declaredAnchorTypes));
  const caseTypes = Array.from(read("bin/worker-dispatch/capability.js").matchAll(/case "(anchor-[a-z-]+)":/g), (m) => m[1]);
  check("types/interpreted-anchor-types", sorted(caseTypes) === sorted(NEW_TYPES), sorted(caseTypes));
  for (const [label, type, want] of [["script-checkout-root", NEW_TYPES[0], checkoutRoot], ["target-main-root", NEW_TYPES[1], targetMainRoot]]) {
    const hit = capability.checkField(want, { type }, anchors, {});
    check(`types/${label}-type-accepts-its-anchor`, hit.error === undefined && anchorLib.samePath(str(hit.value), want), hit.error);
    const miss = capability.checkField(targetLinked, { type }, anchors, {});
    check(`types/${label}-type-rejects-another-path`, typeof miss.error === "string" && miss.error.startsWith("must be exactly"), miss.error);
  }
  for (const [label, type] of [["checkout", OLD.checkoutType], ["main", OLD.mainType]]) {
    const res = capability.checkField(root, { type }, anchors, {});
    check(`types/old-${label}-type-unknown`, typeof res.error === "string" && res.error.includes("unknown capability type"), res.error);
  }

  const spawn = req("bin/worker-dispatch/spawn.js");
  check("anchors/declared-list", sorted(registry.SCRIPT_ANCHORS) === sorted(NEW_ANCHORS), sorted(registry.SCRIPT_ANCHORS));
  const literal = Array.from(read("bin/worker-dispatch/spawn.js").matchAll(/anchorName === "([a-z-]+)"/g), (m) => m[1]);
  check("anchors/interpreted-list", sorted(literal) === sorted(NEW_ANCHORS), sorted(literal));
  const rootOf = { "script-checkout-root": checkoutRoot, "target-main-root": targetMainRoot, "family-worktree": targetLinked };
  const misplaced = [];
  let scripts = 0;
  for (const worker of registry.WORKER_NAMES) {
    const entry = registry.workers[worker];
    for (const [key, decl] of Object.entries(entry.binaries.scripts)) {
      scripts += 1;
      let abs = null;
      try {
        abs = spawn.resolveScript(entry, key, anchors, targetLinked);
      } catch (e) {
        abs = null;
      }
      const want = rootOf[decl.anchor];
      if (abs === null || want === undefined || !anchorLib.isUnder(abs, want, false)) misplaced.push(`${worker}.${key}:${decl.anchor}`);
    }
  }
  check("anchors/every-declared-script-resolves-under-its-root", scripts > 0 && misplaced.length === 0, misplaced.join(","));
  const synthetic = (anchor) => ({ name: "probe", binaries: { scripts: { one: { anchor, rel: "bin/x.js" } } } });
  for (const anchor of NEW_ANCHORS) {
    let abs = null;
    try {
      abs = spawn.resolveScript(synthetic(anchor), "one", anchors, targetLinked);
    } catch (e) {
      abs = `threw: ${e.message}`;
    }
    check(`anchors/${anchor}-resolves-under-its-root`, anchorLib.isUnder(abs, rootOf[anchor], false), abs);
  }
  for (const [label, anchor] of [["checkout", OLD.checkoutAnchor], ["main", OLD.mainAnchor]]) {
    let message = "resolved";
    try {
      spawn.resolveScript(synthetic(anchor), "one", anchors, targetLinked);
    } catch (e) {
      message = e.message;
    }
    check(`anchors/old-${label}-anchor-unresolvable`, message.includes("unresolvable anchor"), message);
  }
}

function writeScopes() {
  const fsguard = req("bin/worker-dispatch/fsguard.js");
  const scopes = registry.WRITE_SCOPES;
  check("scopes/target-main-root-docs-declared", scopes.includes("target-main-root-docs"), scopes.join(","));
  check("scopes/old-docs-scope-not-declared", !scopes.includes(OLD.docsScope), scopes.join(","));
  const keys = Array.from(read("bin/worker-dispatch/fsguard.js").matchAll(/^\s+"([a-z-]+)": \(ctx\) =>/gm), (m) => m[1]);
  check("scopes/interpreted-set-equals-declared-set", sorted(keys) === sorted(scopes), `${sorted(keys)} vs ${sorted(scopes)}`);
  const strays = [];
  for (const worker of registry.WORKER_NAMES) {
    for (const scope of registry.workers[worker].writeScopes) if (!scopes.includes(scope)) strays.push(`${worker}:${scope}`);
  }
  check("scopes/every-worker-scope-is-declared", strays.length === 0, strays.join(","));
  // No worker declares the docs scope, so the canary entry borrows each scope in turn.
  const canary = registry.workers["test-runner"];
  const ctx = { targetMainRoot: targetMain, plansDir: targetMain, controlDir: targetMain, family: [targetMain], backupDir: targetMain, logDir: targetMain };
  const refused = [];
  for (const scope of scopes) {
    canary.writeScopes = [scope];
    try {
      if (fsguard.scopeRootsFor("test-runner", ctx).length === 0) refused.push(`${scope}:no-root`);
    } catch (e) {
      refused.push(`${scope}:${e.message}`);
    }
  }
  check("scopes/every-declared-scope-is-interpreted", scopes.length > 0 && refused.length === 0, refused.join(" | "));
  canary.writeScopes = ["target-main-root-docs"];
  let docs = null;
  try {
    docs = fsguard.scopeRootsFor("test-runner", ctx);
  } catch (e) {
    docs = [`threw: ${e.message}`];
  }
  check("scopes/docs-scope-is-the-target-docs-dir", docs.length === 1 && anchorLib.samePath(docs[0], path.join(targetMain, "docs")), docs.join(","));
  canary.writeScopes = [OLD.docsScope];
  let message = "resolved";
  try {
    fsguard.scopeRootsFor("test-runner", ctx);
  } catch (e) {
    message = e.message;
  }
  check("scopes/old-docs-scope-unknown", message.includes("declares an unknown write scope"), message);
  canary.writeScopes = [];
}

function skillTexts() {
  const HEAD = /^\s*(?:Payload keys[^:]*|Every `loop_step` payload[^:]*carries):(.*)$/;
  // Last column: on how many payload lines the text states the value of the key (as each does today).
  const table = [
    ["commit-push", "skills/commit-push/SKILL.md", 1, [], 0],
    ["issue-close-stage", "skills/issue-close-stage/SKILL.md", 1, [], 1],
    ["issue-close-finalize", "skills/issue-close-finalize/SKILL.md", 3, ["target_main_root"], 0],
  ];
  for (const [worker, rel, wantLines, extra, wantValued] of table) {
    const spec = registry.workers[worker].payloadSpec;
    const hits = read(rel).split(/\r?\n/).map((l) => HEAD.exec(l)).filter((m) => m !== null).map((m) => m[1]);
    check(`${worker}/skill-payload-lines-found`, hits.length === wantLines, `found ${hits.length}, want ${wantLines}`);
    const named = [];
    for (const text of hits) for (const m of text.matchAll(/`([a-z][a-z0-9_]*)(?::[^`]*)?`/g)) named.push(m[1]);
    const undeclared = named.filter((key) => !Object.prototype.hasOwnProperty.call(spec, key));
    check(`${worker}/skill-names-only-declared-keys`, named.length > 0 && undeclared.length === 0, undeclared.join(","));
    for (const key of ["script_checkout_root"].concat(extra)) {
      check(`${worker}/skill-names-${key}`, named.includes(key), sorted(named));
    }
    check(`${worker}/skill-payload-lines-carry-script_checkout_root`, hits.length > 0 && hits.every((t) => t.includes("`script_checkout_root`")), hits.length);
    // A stated value is the agents main root variable (never a path of its own); any other
    // parenthesised form after the key counts as a stated value too, so it cannot hide.
    const valued = hits.map((t) => /`script_checkout_root`\s*\(=\s*([^)]*)\)/.exec(t)).filter((m) => m !== null).map((m) => m[1].trim());
    check(`${worker}/skill-states-the-value-on-the-expected-lines`, valued.length === wantValued, `want ${wantValued} line(s), stated on ${valued.length}`);
    check(`${worker}/skill-value-of-script_checkout_root`, valued.every((v) => v === "`AGENTS_MAIN_ROOT`"), valued.join(","));
  }
}

function stateFile() {
  const state = req("bin/worker-dispatch/workers/issue-close-finalize/state.js");
  check("state/schema-version-is-4", state.SCHEMA_VERSION === 4, state.SCHEMA_VERSION);
  const make = (version, checkoutKey, mainKey) => ({
    schema_version: version,
    root_issue_number: 7,
    current_issue_number: 7,
    owner_repo: "acme/widgets",
    [checkoutKey]: checkoutRoot,
    [mainKey]: targetMainRoot,
    phase: "init_done",
    triage_action: "resume_e",
    g5_loop_iteration: 0,
    proposal_counters: { accepted: 0, declined: 0, skipped: 0 },
  });
  const fresh = state.validateState(make(4, "script_checkout_root", "target_main_root"), anchors);
  check("state/new-item-names-accepted", fresh === null, fresh);
  const again = state.validateState(make(4, "script_checkout_root", "target_main_root"), anchors);
  check("state/new-item-names-accepted-twice", again === null, again);
  const oldCheckout = state.validateState(make(4, OLD.checkoutKey, "target_main_root"), anchors);
  check("state/old-checkout-item-rejected", oldCheckout === `state file has an unknown field '${OLD.checkoutKey}'`, oldCheckout);
  const oldMain = state.validateState(make(4, "script_checkout_root", OLD.mainPathKey), anchors);
  check("state/old-main-item-rejected", oldMain === `state file has an unknown field '${OLD.mainPathKey}'`, oldMain);
  const oldVersion = state.validateState(make(3, "script_checkout_root", "target_main_root"), anchors);
  check("state/previous-schema-version-rejected", typeof oldVersion === "string" && oldVersion.includes("'schema_version'"), oldVersion);
  const swapped = make(4, "script_checkout_root", "target_main_root");
  swapped.script_checkout_root = targetMain;
  const swappedRes = state.validateState(swapped, anchors);
  const swappedWant = "state file field 'script_checkout_root' must be exactly";
  check("state/script_checkout_root-other-root-rejected", typeof swappedRes === "string" && swappedRes.startsWith(swappedWant), swappedRes);
  const lacking = make(4, "script_checkout_root", "target_main_root");
  delete lacking.target_main_root;
  const lackingRes = state.validateState(lacking, anchors);
  check("state/missing-target_main_root-rejected", lackingRes === "state file is missing 'target_main_root'", lackingRes);
  check("state/binding-names-target_main_root", state.BINDING_FIELDS.includes("target_main_root"), state.BINDING_FIELDS.join(","));
  check("state/binding-drops-old-main-item", !state.BINDING_FIELDS.includes(OLD.mainPathKey), state.BINDING_FIELDS.join(","));
}

const groups = {
  "payload-keys": payloadKeys,
  "declared-vs-interpreted": declaredVsInterpreted,
  "write-scopes": writeScopes,
  "skill-texts": skillTexts,
  "state-file": stateFile,
};
groups[group]();
process.stdout.write(`${lines.join("\n")}\n`);
PROBE_JS

readonly ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
# A directory of its own standing in for the agents main root: the probe runs with the
# variable naming it, so an anchor that followed the variable would land here.
readonly OTHER_MAIN_DIR="$TMP_ROOT/agents-main"
mkdir -p "$OTHER_MAIN_DIR"

# run_group <group>: one PASS/FAIL per probe line, plus one for the probe finishing.
run_group() {
  local group="$1" out rc=0 status name detail seen=0
  out="$(AGENTS_MAIN_ROOT="$OTHER_MAIN_DIR" run_with_timeout 120 node "$PROBE" "$ROOT_N" "$group" "$TARGET_MAIN_ROOT" "$TARGET_CHECKOUT_ROOT" "$OTHER_MAIN_DIR" 2>"$TMP_ROOT/$group.err")" || rc=$?
  while IFS=$'\t' read -r status name detail; do
    case "$status" in
      ok) pass "$group: $name" ;;
      ng) fail "$group: $name" "${detail:-(no detail)}" ;;
      *) continue ;;
    esac
    seen=$((seen + 1))
  done <<<"$out"
  if [[ "$rc" -ne 0 || "$seen" -eq 0 ]]; then
    fail "$group: probe-finished" "rc=$rc checks=$seen $(tail -n 4 "$TMP_ROOT/$group.err" | tr '\n' ' ')"
  else
    pass "$group: probe-finished"
  fi
}

case_begin "payload-keys-accept-new-reject-old" "bin/worker-dispatch/capability.js"
run_group "payload-keys"
case_end

case_begin "declared-names-equal-interpreted-names" "hooks/lib/worker-dispatch-registry.js"
run_group "declared-vs-interpreted"
case_end

case_begin "write-scope-names" "bin/worker-dispatch/fsguard.js"
run_group "write-scopes"
case_end

case_begin "skill-texts-name-declared-keys" "hooks/lib/worker-dispatch-registry.js"
run_group "skill-texts"
case_end

case_begin "state-file-item-names" "bin/worker-dispatch/workers/issue-close-finalize/state.js"
run_group "state-file"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
