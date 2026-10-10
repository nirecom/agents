#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/agents-main-root-child-env.sh
# Tests: bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js
# Tags: worker-dispatch, spawn, anchor, child-env, root-names, security, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh after validator.sh — defines
# group_agents_main_root_child_env (#2561): which AGENTS_MAIN_ROOT a dispatcher child receives.

_AGENTS_MAIN_ROOT_CHILD_ENV_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$_AGENTS_MAIN_ROOT_CHILD_ENV_SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

AMR_PROBE="$TMPD/amr-probe.js"
cat > "$AMR_PROBE" <<'AMRJS'
"use strict";
// One line per check: ok<TAB>name  or  ng<TAB>name<TAB>detail.
const fs = require("fs");
const path = require("path");
const [copyRoot, label, want, parentValue, targetMain, retiredCsv] = process.argv.slice(2);
const out = [];
const flat = (v) => String(v).replace(/\s+/g, " ").slice(0, 300);
const check = (name, cond, detail) =>
  out.push(cond ? `ok\t${label}/${name}` : `ng\t${label}/${name}\t${flat(detail === undefined ? "" : detail)}`);
const canon = (p) => {
  if (typeof p !== "string") return String(p);
  let r = p;
  try { r = fs.realpathSync(p); } catch (_e) { /* compare as given */ }
  return r.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
};
const finish = () => { process.stdout.write(out.join("\n") + "\n"); process.exit(0); };
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
// The test's own list, snapshotted before any module runs: a name the module drops stays visible.
const gitNames = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"];
const gitBefore = {};
for (const n of gitNames) if (has(process.env, n)) gitBefore[n] = process.env[n];

let anchorMod = null;
let spawnMod = null;
try {
  anchorMod = require(path.join(copyRoot, "bin", "worker-dispatch", "anchor.js"));
  spawnMod = require(path.join(copyRoot, "bin", "worker-dispatch", "spawn.js"));
} catch (e) {
  check("copied-modules-load", false, e.message);
  finish();
}
check("copied-modules-load", true);

const fn = anchorMod.resolveAgentsMainRoot;
check("resolver-exported", typeof fn === "function", typeof fn);
if (typeof fn === "function") {
  check("resolver-takes-no-argument", fn.length === 0, fn.length);
  // Asked with a path first, on a module instance that has remembered nothing yet: a resolver
  // that honoured its argument would answer with that path here.
  const anchorFile = require.resolve(path.join(copyRoot, "bin", "worker-dispatch", "anchor.js"));
  delete require.cache[anchorFile];
  const handed = require(anchorFile).resolveAgentsMainRoot(parentValue);
  check("resolver-ignores-a-handed-path", want === "null" ? handed === null : canon(handed) === canon(want), handed);
  const first = fn();
  check("resolver-value", want === "null" ? first === null : canon(first) === canon(want), first);
  if (want !== "null") check("resolver-value-is-absolute", typeof first === "string" && path.isAbsolute(first), first);
}

const anchors = anchorMod.resolveAnchors(targetMain);
check("anchors-resolve-for-the-target-repo", anchors.error === null, anchors.error);
const entry = { name: "probe-worker", envPassthrough: [] };
let env = null;
try {
  env = spawnMod.buildEnv(entry, anchors, undefined, undefined);
} catch (e) {
  check("child-env-built", false, e.message);
  finish();
}
check("child-env-built", env !== null && typeof env === "object");
if (want === "null") {
  check("child-env-has-no-AGENTS_MAIN_ROOT-key", !has(env, "AGENTS_MAIN_ROOT"), env.AGENTS_MAIN_ROOT);
} else {
  check("child-env-AGENTS_MAIN_ROOT", canon(env.AGENTS_MAIN_ROOT) === canon(want), env.AGENTS_MAIN_ROOT);
  if (canon(want) !== canon(copyRoot)) {
    check("child-env-value-is-not-the-dispatcher-checkout", canon(env.AGENTS_MAIN_ROOT) !== canon(copyRoot), env.AGENTS_MAIN_ROOT);
  }
}
const leaked = Object.keys(env).filter((k) => canon(env[k]).includes(canon(parentValue)));
check("parent-value-absent-from-child-env", leaked.length === 0, leaked.join(","));
const otherRoots = ["SCRIPT_CHECKOUT_ROOT", "TARGET_MAIN_ROOT", "TARGET_CHECKOUT_ROOT"].filter((k) => has(env, k));
check("no-other-root-name-in-child-env", otherRoots.length === 0, otherRoots.join(","));
const retired = retiredCsv.split(",").filter((s) => s !== "");
check("retired-name-list-available", retired.length > 0, "empty list");
const stale = retired.filter((k) => has(env, k));
check("no-retired-name-in-child-env", stale.length === 0, stale.join(","));
const scoped = spawnMod.buildEnv(entry, anchors, undefined, []);
check("scoped-call-gives-the-same-root-entry", scoped.AGENTS_MAIN_ROOT === env.AGENTS_MAIN_ROOT, scoped.AGENTS_MAIN_ROOT);
check("second-build-is-identical", JSON.stringify(spawnMod.buildEnv(entry, anchors, undefined, undefined)) === JSON.stringify(env));

// Records what each git call of a fresh module instance could still see.
if (process.env.AMR_GIT_REPO_ENV_ROW === "1") {
  const cp = require("child_process");
  const names = gitNames;
  check("all-five-git-repo-names-inherited", Object.keys(gitBefore).length === names.length, Object.keys(gitBefore).join(","));
  const lost = () => names.filter((n) => process.env[n] !== gitBefore[n]).join(",");
  check("git-repo-names-intact-before-the-recorded-calls", lost() === "", lost());
  const wanted = (v) => (want === "null" ? v === null : canon(v) === canon(want));
  const anchorFile = require.resolve(path.join(copyRoot, "bin", "worker-dispatch", "anchor.js"));
  const fresh = () => { delete require.cache[anchorFile]; return require(anchorFile); };
  const calls = [];
  let throwNext = false;
  const realSpawnSync = cp.spawnSync;
  cp.spawnSync = function (cmd, _args, opts) {
    const rec = { cmd, seen: names.filter((n) => has(process.env, n)), env: Boolean(opts) && opts.env !== undefined, status: null };
    calls.push(rec);
    if (throwNext) { throwNext = false; throw new Error("amr-recorder-throw"); }
    const res = realSpawnSync.apply(this, arguments);
    rec.status = res.status;
    return res;
  };
  try {
    const one = fresh();
    const got = one.resolveAgentsMainRoot();
    check("fresh-resolver-asks-git", calls.length > 0, calls.length);
    check("fresh-resolver-value", wanted(got), got);
    check("git-repo-names-restored-after-a-successful-call", lost() === "", lost());
    let seenCalls = calls.length;
    const good = one.resolveAnchors(targetMain);
    check("target-anchors-ask-git", good.error === null && calls.length > seenCalls, `${good.error} calls=${calls.length - seenCalls}`);
    seenCalls = calls.length;
    const bad = one.resolveAnchors(process.env.AMR_NON_GIT_DIR);
    const last = calls[calls.length - 1];
    check("non-git-target-is-refused", bad.error === "target-main-root is not a git repository", bad.error);
    check("refused-git-call-exits-non-zero", calls.length > seenCalls && typeof last.status === "number" && last.status !== 0, last.status);
    check("git-repo-names-restored-after-a-failing-call", lost() === "", lost());
    throwNext = true;
    let thrown = null;
    try { fresh().resolveAgentsMainRoot(); } catch (e) { thrown = e; }
    check("throwing-git-call-reaches-the-caller", thrown !== null && thrown.message === "amr-recorder-throw", thrown && thrown.message);
    check("git-repo-names-restored-after-a-throwing-call", lost() === "", lost());
    seenCalls = calls.length;
    const again = fresh().resolveAgentsMainRoot();
    check("repeated-resolver-asks-git", calls.length > seenCalls, calls.length - seenCalls);
    check("repeated-resolver-value", wanted(again), again);
    check("git-repo-names-restored-after-the-repeat", lost() === "", lost());
  } finally {
    cp.spawnSync = realSpawnSync;
  }
  const notGit = calls.filter((c) => c.cmd !== "git").map((c) => c.cmd);
  check("every-recorded-call-is-git", notGit.length === 0, notGit.join(","));
  const visible = calls.map((c, i) => (c.seen.length > 0 ? `call${i + 1}:${c.seen.join("+")}` : "")).filter((s) => s !== "");
  check("no-git-repo-name-visible-at-any-git-call", visible.length === 0, visible.join(" "));
  check("no-git-call-carries-an-env-option", calls.every((c) => c.env === false), calls.filter((c) => c.env).length);
}
finish();
AMRJS

# _amr_row <label> <copy root> <wanted root | null> [NAME=value...] — runs the probe with every
# root name of the parent environment pointing at a decoy directory, plus the given variables.
_amr_row() {
    local out saw=0 kind name detail
    out="$(AGENTS_MAIN_ROOT="$_AMR_PARENT" run_with_timeout 60 env "${_AMR_PARENT_ENV[@]}" "${@:4}" node "$(nodepath "$AMR_PROBE")" \
        "$(nodepath "$2")" "$1" "$3" "$_AMR_PARENT" "$_AMR_TARGET" "$_AMR_RETIRED" 2>&1)"
    while IFS=$'\t' read -r kind name detail; do
        case "$kind" in
            ok) pass "amr/$name"; saw=1 ;;
            ng) fail "amr/$name — $detail"; saw=1 ;;
            "") ;;
            *) fail "amr/$1: unexpected probe output — $kind $name"; saw=1 ;;
        esac
    done <<< "$out"
    [ "$saw" -eq 1 ] || fail "amr/$1: the probe printed no verdict"
}

group_agents_main_root_child_env() {
    local base="$TMPD/amr root" plain main linked solo bare bare_linked git_decoy name
    plain="$base/plain-dir"; main="$base/fake-main"; linked="$base/fake-linked"
    solo="$base/solo-repo"; bare="$base/unmarked-main"; bare_linked="$base/unmarked-linked"
    git_decoy="$base/git-env-decoy"
    mkdir -p "$base/parent-decoy"
    _AMR_PARENT="$(nodepath "$base/parent-decoy")"
    _AMR_RETIRED="$(run_with_timeout 30 node "$(nodepath "$_AGENTS_MAIN_ROOT_CHILD_ENV_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js")" \
        --print-retired-env-names 2>/dev/null | tr -d '\r' | tr '\n' ',')"
    _AMR_PARENT_ENV=("AMR_PROBE_RUN=1")
    for name in ${_AMR_RETIRED//,/ }; do _AMR_PARENT_ENV+=("$name=$_AMR_PARENT"); done

    if ! script_checkout_fixture_copy "$plain" bin/worker-dispatch hooks >/dev/null 2>&1; then
        fail "amr/setup: the dispatcher modules could not be copied"
        return
    fi
    mk_repo "$main"; mk_repo "$solo"; mk_repo "$bare"; mk_repo "$base/target-repo"; mk_repo "$git_decoy"
    _AMR_TARGET="$(nodepath "$base/target-repo")"
    # The two-point marker a main worktree must carry to be trusted as the agents repository.
    # The decoy carries it too: only its not being the dispatcher's own repository rules it out.
    mkdir -p "$main/hooks" "$main/bin" "$git_decoy/hooks" "$git_decoy/bin"
    echo "// marker only" > "$main/hooks/enforce-worktree.js"
    echo "// marker only" > "$git_decoy/hooks/enforce-worktree.js"
    if ! git -C "$main" worktree add -q -b amr-linked "$linked" >/dev/null 2>&1 ||
       ! git -C "$bare" worktree add -q -b amr-unmarked "$bare_linked" >/dev/null 2>&1; then
        fail "amr/setup: git worktree add failed"
        return
    fi
    if ! cp -R "$plain/bin" "$plain/hooks" "$linked/" ||
       ! cp -R "$plain/bin" "$plain/hooks" "$solo/" ||
       ! cp -R "$plain/bin" "$plain/hooks" "$bare_linked/"; then
        fail "amr/setup: the dispatcher modules could not be copied into the fixture repositories"
        return
    fi

    _amr_row "linked-copy" "$linked" "$(nodepath "$main")"
    # A repository-selecting git variable inherited by the dispatcher must not move the answer
    # of the row above to the marked decoy repository it names.
    _amr_row "linked-copy-under-inherited-GIT_DIR" "$linked" "$(nodepath "$main")" \
        "GIT_DIR=$(nodepath "$git_decoy/.git")"
    _amr_row "linked-copy-under-inherited-GIT_COMMON_DIR" "$linked" "$(nodepath "$main")" \
        "GIT_COMMON_DIR=$(nodepath "$git_decoy/.git")"
    # All five at once; this row also turns on the probe's per-git-call recorder.
    _amr_row "linked-copy-under-all-inherited-git-repo-names" "$linked" "$(nodepath "$main")" \
        "AMR_GIT_REPO_ENV_ROW=1" "AMR_NON_GIT_DIR=$(nodepath "$plain")" \
        "GIT_DIR=$(nodepath "$git_decoy/.git")" "GIT_COMMON_DIR=$(nodepath "$git_decoy/.git")" \
        "GIT_WORK_TREE=$(nodepath "$git_decoy")" "GIT_INDEX_FILE=$(nodepath "$git_decoy/.git/index")" \
        "GIT_OBJECT_DIRECTORY=$(nodepath "$git_decoy/.git/objects")"
    _amr_row "repo-without-linked-worktree" "$solo" "$(nodepath "$solo")"
    _amr_row "main-worktree-without-markers" "$bare_linked" "null"
    if git -C "$plain" rev-parse --git-dir >/dev/null 2>&1; then
        fail "amr/setup: the temp directory is inside a git repository — the non-git row cannot run"
    else
        _amr_row "non-git-directory" "$plain" "null"
    fi
}
