#!/usr/bin/env bash
# tests/bin/feature-2501-worker-external-derivation.sh
# Tests: bin/worker-dispatch/registry.js, bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, test-runner, external-commands, test-language-registry, fail-closed, TL1, scope:issue-specific
#
# Issue #2501 D7: the test-runner worker declares `binaries.externalFromTestLanguages: true`,
# and bin/worker-dispatch/registry.js derives its effective external set from the
# test-language registry (supported entries' launch.requires + launch.command[0]).
# The hand list EXTERNAL_COMMANDS stays untouched (no pwsh), and a registry that
# fails to load derives nothing (fail-closed: pwsh is never allowed then).
# TL3 gap: a real mixed-language worker run — tests/bin/TL3-worker-dispatch-mixed-language-run.sh.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

expect_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then pass "$label"
  else fail "$label" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# The probe prints key=value lines for one repo-shaped root. It never spawns a
# child: assertCommandAllowed is reached either directly (when exported) or via
# spawn.run() with an empty family, which throws at the cwd check right AFTER the
# command check — so "the command passed" is observable without running anything.
PROBE="$TMPD/probe.js"
cat > "$PROBE" <<'PROBEJS'
const root = process.argv[2];
const extra = process.argv.slice(3);
const os = require("os");
const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const sorted = (a) => Array.from(new Set(a)).sort().join(",");
let reg, spawn, data, tlr;
try {
  reg = require(root + "/bin/worker-dispatch/registry.js");
  spawn = require(root + "/bin/worker-dispatch/spawn.js");
  data = require(root + "/hooks/lib/worker-dispatch-registry.js");
  tlr = require(root + "/hooks/lib/test-language-registry.js");
} catch (e) {
  out("load_error", String(e.message).split("\n")[0]);
  process.exit(0);
}
const tr = data.workers["test-runner"];
const flag = tr && tr.binaries ? tr.binaries.externalFromTestLanguages : undefined;
out("flag_json", JSON.stringify(flag));
out("flag_type", typeof flag);
const badFlags = Object.keys(data.workers).filter((n) => {
  const b = data.workers[n].binaries || {};
  return Object.prototype.hasOwnProperty.call(b, "externalFromTestLanguages") && typeof b.externalFromTestLanguages !== "boolean";
});
out("non_boolean_flags", badFlags.join(","));
out("ext_has_pwsh", data.EXTERNAL_COMMANDS.includes("pwsh") ? 1 : 0);

const lang = tlr.tryLoadRegistry();
out("lang_loaded", lang ? 1 : 0);
const derived = [];
if (lang) {
  for (const e of lang.entries) {
    if (e.status !== "supported" || !e.launch) continue;
    if (typeof e.launch.requires === "string" && e.launch.requires) derived.push(e.launch.requires);
    if (Array.isArray(e.launch.command) && typeof e.launch.command[0] === "string") derived.push(e.launch.command[0]);
  }
}
const declared = (e) => (e.binaries && Array.isArray(e.binaries.external) ? e.binaries.external : []);
out("tr_expected", sorted(declared(tr).concat(derived)));

const call = (fn, arg) => {
  try { return { ok: true, v: Array.from(fn(arg) || []) }; }
  catch (e) { return { ok: false, err: String(e.message).split("\n")[0] }; }
};
const eff = typeof reg.effectiveExternal === "function" ? reg.effectiveExternal : null;
const effAll = typeof reg.effectiveExternalCommands === "function" ? reg.effectiveExternalCommands : null;
out("has_eff", eff ? 1 : 0);
out("has_eff_all", effAll ? 1 : 0);
if (eff) {
  const r = call(eff, tr);
  out("tr_eff", r.ok ? sorted(r.v) : "THREW:" + r.err);
  for (const b of ["pwsh", "uv", "node", "bash"].concat(extra)) out("tr_eff_has_" + b, r.ok && r.v.includes(b) ? 1 : 0);
  const cp = data.workers["commit-push"];
  const c = call(eff, cp);
  out("cp_eff", c.ok ? sorted(c.v) : "THREW:" + c.err);
  out("cp_declared", sorted(declared(cp)));
  const s = call(eff, { name: "synthetic-no-decl", binaries: { external: ["git"], scripts: {} } });
  out("syn_eff", s.ok ? sorted(s.v) : "THREW:" + s.err);
  const y = call(eff, { name: "synthetic-yes", binaries: { external: ["bash"], externalFromTestLanguages: "yes", scripts: {} } });
  out("yes_outcome", y.ok ? (y.v.includes("pwsh") ? "derived" : "not-derived") : "threw");
  if (effAll) {
    const a = call(effAll);
    out("all_eff", a.ok ? sorted(a.v) : "THREW:" + a.err);
    let union = data.EXTERNAL_COMMANDS.slice();
    for (const n of Object.keys(data.workers)) {
      const w = call(eff, data.workers[n]);
      if (w.ok) union = union.concat(w.v);
    }
    out("all_expected", sorted(union));
    out("all_has_pwsh", a.ok && a.v.includes("pwsh") ? 1 : 0);
  }
}

const allowed = (entry, cmd) => {
  try {
    if (typeof spawn.assertCommandAllowed === "function") {
      spawn.assertCommandAllowed(entry, cmd);
      return "accepted";
    }
    spawn.run(entry, { anchors: { scriptCheckoutRoot: root, targetMainRoot: root, family: [] }, command: cmd, cwd: os.tmpdir(), args: [] });
    return "accepted";
  } catch (e) {
    return /command '/.test(String(e.message)) ? "rejected" : "accepted";
  }
};
for (const c of ["pwsh", "bash", "definitely-not-allowed"].concat(extra)) out("allow_" + c.replace(/-/g, "_"), allowed(tr, c));
PROBEJS

PROBE_OUT=""
probe() { PROBE_OUT="$(run_with_timeout 60 node "$(np "$PROBE")" "$(np "$1")" "${@:2}" 2>"$TMPD/probe.err")" || true; }
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -1; }

# Fixture root for fail-closed: a copy of the dispatcher and hooks with a corrupted
# language table. tryLoadRegistry resolves the table next to its own JS file, so a
# repo-shaped copy is the only way to make the load fail without touching the repo.
BROKEN="$TMPD/broken"
mkdir -p "$BROKEN/bin"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch" "$BROKEN/bin/worker-dispatch"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$BROKEN/hooks"
printf '{ "schema": 1, "entries": [ not json\n' > "$BROKEN/hooks/lib/test-language-registry.json"

# Fixture root for adding a language: the same copy, with one more supported entry whose
# runtimes no worker file names. The existing entries' wrappers must exist under the root.
ADDED="$TMPD/added"
mkdir -p "$ADDED/bin/lib"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch" "$ADDED/bin/worker-dispatch"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers" "$ADDED/bin/lib/test-wrappers"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$ADDED/hooks"
cat > "$TMPD/add-language.js" <<'ADDJS'
const fs = require("fs");
const file = process.argv[2];
const table = JSON.parse(fs.readFileSync(file, "utf8"));
table.entries.push({
  id: "zzlang",
  status: "supported",
  patterns: ["*.zz"],
  selfIdentifying: true,
  nameStrip: { prefix: "", suffix: ".zz" },
  siblingSuiteDir: false,
  header: { commentPrefix: "#" },
  launch: { unit: "file", requires: "zzruntime", prepare: null, command: ["zzlauncher", "{path}"], timeoutSeconds: null, suiteRootMarker: null },
  caseMarkerReader: null,
  tableDrivenDetector: null,
  helperLibrary: null,
  diagnostics: { nameLabel: ".zz" },
  note: "fixture language",
});
fs.writeFileSync(file, JSON.stringify(table, null, 2));
ADDJS
node "$(np "$TMPD/add-language.js")" "$(np "$ADDED/hooks/lib/test-language-registry.json")"

probe "$SCRIPT_CHECKOUT_ROOT" zzruntime zzlauncher
REAL_HAS_ZZ="$(pv tr_eff_has_zzruntime)$(pv tr_eff_has_zzlauncher)"
REAL_ALLOW_ZZ="$(pv allow_zzruntime)/$(pv allow_zzlauncher)"
if [ -n "$(pv load_error)" ]; then echo "NOTE: real-root probe load error: $(pv load_error)"; fi

case_begin "test-runner-declares-external-from-test-languages" "hooks/lib/worker-dispatch-registry.js"
expect_eq "flag/test-runner-value-is-true" "true" "$(pv flag_json)"
expect_eq "flag/test-runner-value-is-boolean" "boolean" "$(pv flag_type)"
expect_eq "flag/no-worker-holds-a-non-boolean-flag" "" "$(pv non_boolean_flags)"
case_end

case_begin "non-boolean-flag-is-not-honoured" "bin/worker-dispatch/registry.js"
expect_eq "flag/effective-external-present" "1" "$(pv has_eff)"
# Either answer is acceptable (reject by throwing, or treat as undeclared); deriving is not.
case "$(pv yes_outcome)" in threw|not-derived) YES_REJECTED=1 ;; *) YES_REJECTED=0 ;; esac
expect_eq "flag/string-yes-rejected-or-ignored (outcome=$(pv yes_outcome))" "1" "$YES_REJECTED"
case_end

case_begin "effective-external-derives-language-runtimes" "bin/worker-dispatch/registry.js"
expect_eq "derive/real-language-registry-loads" "1" "$(pv lang_loaded)"
expect_eq "derive/includes-pwsh" "1" "$(pv tr_eff_has_pwsh)"
expect_eq "derive/includes-uv" "1" "$(pv tr_eff_has_uv)"
expect_eq "derive/includes-node" "1" "$(pv tr_eff_has_node)"
expect_eq "derive/keeps-declared-bash" "1" "$(pv tr_eff_has_bash)"
TR_EFF="$(pv tr_eff)"
if [ -n "$TR_EFF" ]; then
  expect_eq "derive/equals-declared-union-requires-and-command0" "$(pv tr_expected)" "$TR_EFF"
else
  fail "derive/equals-declared-union-requires-and-command0" "effectiveExternal(test-runner) produced nothing"
fi
case_end

case_begin "effective-external-without-declaration-is-declared-only" "bin/worker-dispatch/registry.js"
CP_EFF="$(pv cp_eff)"
if [ -n "$CP_EFF" ]; then
  expect_eq "nodecl/commit-push-equals-declared" "$(pv cp_declared)" "$CP_EFF"
else
  fail "nodecl/commit-push-equals-declared" "effectiveExternal(commit-push) produced nothing"
fi
expect_eq "nodecl/synthetic-equals-declared" "git" "$(pv syn_eff)"
case_end

case_begin "effective-external-commands-is-union" "bin/worker-dispatch/registry.js"
expect_eq "union/function-present" "1" "$(pv has_eff_all)"
ALL_EFF="$(pv all_eff)"
if [ -n "$ALL_EFF" ]; then
  expect_eq "union/equals-hand-list-union-every-effective-external" "$(pv all_expected)" "$ALL_EFF"
else
  fail "union/equals-hand-list-union-every-effective-external" "effectiveExternalCommands() produced nothing"
fi
expect_eq "union/includes-derived-pwsh" "1" "$(pv all_has_pwsh)"
case_end

case_begin "hand-list-stays-without-pwsh" "hooks/lib/worker-dispatch-registry.js"
if [ -z "$(pv load_error)" ] && [ -n "$(pv ext_has_pwsh)" ]; then
  expect_eq "handlist/external-commands-has-no-pwsh" "0" "$(pv ext_has_pwsh)"
else
  fail "handlist/external-commands-has-no-pwsh" "probe could not read EXTERNAL_COMMANDS"
fi
case_end

case_begin "assert-command-allowed-uses-derived-set" "bin/worker-dispatch/spawn.js"
ALLOW_ROWS=0
while IFS='|' read -r label want key; do
  ALLOW_ROWS=$((ALLOW_ROWS + 1))
  expect_eq "spawn/$label" "$want" "$(pv "$key")"
done <<'EOF'
pwsh-accepted-for-test-runner|accepted|allow_pwsh
bash-accepted-for-test-runner|accepted|allow_bash
random-binary-rejected|rejected|allow_definitely_not_allowed
EOF
expect_eq "spawn/allowlist-table-row-count" "3" "$ALLOW_ROWS"
case_end

probe "$ADDED" zzruntime zzlauncher

case_begin "added-language-runtime-is-derived-without-a-worker-edit" "bin/worker-dispatch/registry.js"
expect_eq "added/fixture-registry-loads" "1" "$(pv lang_loaded)"
expect_eq "added/real-registry-derives-neither" "00" "$REAL_HAS_ZZ"
expect_eq "added/derives-requires" "1" "$(pv tr_eff_has_zzruntime)"
expect_eq "added/derives-command0" "1" "$(pv tr_eff_has_zzlauncher)"
expect_eq "added/keeps-existing-pwsh" "1" "$(pv tr_eff_has_pwsh)"
if diff -r "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch" "$ADDED/bin/worker-dispatch" >/dev/null 2>&1 \
  && cmp -s "$SCRIPT_CHECKOUT_ROOT/hooks/lib/worker-dispatch-registry.js" "$ADDED/hooks/lib/worker-dispatch-registry.js"; then
  pass "added/worker-side-files-are-unchanged"
else
  fail "added/worker-side-files-are-unchanged" "the fixture's dispatcher or worker registry differs from the repo's"
fi
case_end

case_begin "added-language-runtime-is-allowed-undeclared-stays-rejected" "bin/worker-dispatch/spawn.js"
expect_eq "added/real-root-rejects-both" "rejected/rejected" "$REAL_ALLOW_ZZ"
expect_eq "added/spawn-accepts-requires" "accepted" "$(pv allow_zzruntime)"
expect_eq "added/spawn-accepts-command0" "accepted" "$(pv allow_zzlauncher)"
expect_eq "added/spawn-rejects-undeclared" "rejected" "$(pv allow_definitely_not_allowed)"
case_end

probe "$BROKEN"

case_begin "fail-closed-on-language-registry-load-failure" "bin/worker-dispatch/registry.js"
expect_eq "failclosed/fixture-registry-really-fails-to-load" "0" "$(pv lang_loaded)"
expect_eq "failclosed/effective-external-present" "1" "$(pv has_eff)"
expect_eq "failclosed/no-derived-pwsh" "0" "$(pv tr_eff_has_pwsh)"
expect_eq "failclosed/declared-bash-kept" "1" "$(pv tr_eff_has_bash)"
expect_eq "failclosed/union-has-no-pwsh" "0" "$(pv all_has_pwsh)"
case_end

case_begin "assert-command-allowed-fail-closed" "bin/worker-dispatch/spawn.js"
if [ "$(pv lang_loaded)" = "0" ]; then
  expect_eq "failclosed/spawn-rejects-pwsh" "rejected" "$(pv allow_pwsh)"
  expect_eq "failclosed/spawn-still-accepts-bash" "accepted" "$(pv allow_bash)"
else
  fail "failclosed/spawn-rejects-pwsh" "fixture language registry loaded; the fail-closed premise is not established"
fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
