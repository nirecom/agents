# Part of tests/feature-1643-worker-dispatch-script-anchor.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# The node probe (one process per mode, emitting `key=value` lines) and the
# runners that establish the PARENT env each mode needs. Everything here depends
# on the fixtures and helpers the dispatcher defined before sourcing this file.

# ---------------------------------------------------------------------------
# Probe harness: one node process per mode, emitting `key=value` lines.
# ---------------------------------------------------------------------------
PROBE="$TMPD/probe.js"
cat > "$PROBE" <<'PROBEJS'
const fs = require("fs");
const path = require("path");
const [agentsDir, mode, mainRoot, linked, outside, alt] = process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const capMod = require(path.join(agentsDir, "bin/worker-dispatch/capability.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const workers = registry.workers || registry.WORKERS || {};
const trEntry = workers["test-runner"];

// Synthetic entry: one script per anchor token plus one bogus token, all sharing
// the same relative path so the ONLY variable is the anchor.
const probeEntry = {
  name: "probe",
  binaries: {
    scripts: {
      fam: { anchor: "family-worktree", rel: "tests/run-all.sh" },
      main: { anchor: "main-root", rel: "tests/run-all.sh" },
      bogus: { anchor: "no-such-anchor", rel: "tests/run-all.sh" },
    },
  },
};

const errOf = (fn) => { try { fn(); return "NO_THROW"; } catch (e) { return String(e && e.message ? e.message : e); } };

if (mode === "registry") {
  const list = registry.SCRIPT_ANCHORS;
  out("exported", Array.isArray(list) ? "array" : typeof list);
  out("sorted", Array.isArray(list) ? list.slice().sort().join(",") : "NOT_ARRAY");
  out("count", Array.isArray(list) ? list.length : -1);
  let scanned = 0;
  const bad = [];
  for (const wname of Object.keys(workers)) {
    const scripts = (workers[wname].binaries && workers[wname].binaries.scripts) || {};
    for (const key of Object.keys(scripts)) {
      scanned += 1;
      const a = scripts[key].anchor;
      if (!Array.isArray(list) || !list.includes(a)) bad.push(wname + "." + key + "=" + a);
    }
  }
  out("scanned", scanned);
  out("unknown", bad.join(";"));
  out("tr_runall_anchor", trEntry.binaries.scripts.runAll.anchor);
  process.exit(0);
}

const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) { out("anchors_error", anchors.error); process.exit(9); }

if (mode === "resolve") {
  const fam = spawnMod.resolveScript(probeEntry, "fam", anchors, linked);
  const mn = spawnMod.resolveScript(probeEntry, "main", anchors, linked);
  out("fam_under_cwd", anchorMod.isUnder(fam, linked, false) ? 1 : 0);
  out("main_under_mainroot", anchorMod.isUnder(mn, mainRoot, false) ? 1 : 0);
  out("fam_under_mainroot", anchorMod.isUnder(fam, mainRoot, false) ? 1 : 0);
  out("differ", anchorMod.samePath(fam, mn) ? 0 : 1);
  out("bogus_err", errOf(() => spawnMod.resolveScript(probeEntry, "bogus", anchors, linked)));
  out("fam_nocwd_err", errOf(() => spawnMod.resolveScript(probeEntry, "fam", anchors, null)));
  process.exit(0);
}

if (mode === "contain") {
  const ex = (cwd) => { const r = spawnMod.scriptExists(trEntry, "runAll", anchors, cwd); return r === null ? "NULL" : "PATH"; };
  out("exists_family", ex(linked));
  out("exists_mainroot", ex(mainRoot));
  out("exists_outside", ex(outside));
  out("exists_alt", ex(alt));
  out("exists_relative", ex("tests"));
  const runErr = (cwd) => errOf(() => spawnMod.run(trEntry, {
    anchors, command: "bash", script: "runAll", args: [], cwd, timeoutMs: 5000,
  }));
  out("run_outside_err", runErr(outside));
  out("run_alt_err", runErr(alt));
  process.exit(0);
}

if (mode === "timeout") {
  const v = (t) => {
    const p = { cwd: linked, test_args: [] };
    if (t !== null) p.timeout_seconds = t;
    return capMod.validate(p, trEntry, anchors);
  };
  out("ok_120", v(120).ok ? 1 : 0);
  out("ok_3600", v(3600).ok ? 1 : 0);
  out("ok_21600", v(21600).ok ? 1 : 0);
  out("ok_21601", v(21601).ok ? 1 : 0);
  out("ok_0", v(0).ok ? 1 : 0);
  out("default", v(null).value.timeout_seconds);
  process.exit(0);
}

// The set of variables that name WHERE a tool reads its configuration. Shared by
// the env modes below. SSOT for the admission rule and for how the set grows: the
// comment block above CHILD_ENV_ALLOWLIST in the registry.
const CONFIG_PATH_VARS = ["APPDATA", "ProgramData", "PROGRAMDATA", "XDG_CONFIG_HOME", "GH_CONFIG_DIR"];

if (mode === "env") {
  // The two credentials are present in the PARENT env for this probe, which is
  // the only condition under which "does the child see them" is a real question.
  const TOKENS = ["GH_TOKEN", "GITHUB_TOKEN"];
  for (const t of TOKENS) out("parent_has_" + t, typeof process.env[t] === "string" ? 1 : 0);
  // The other direction of the same allowlist: vars that name WHERE a tool reads
  // its config must ARRIVE. Same precondition — the parent has to really hold them.
  for (const v of CONFIG_PATH_VARS) out("parent_cfg_" + v, typeof process.env[v] === "string" ? 1 : 0);
  // The worker set itself is asserted so that a worker added later cannot join
  // the dispatcher without someone deciding what its child env may contain.
  out("worker_names", Object.keys(workers).slice().sort().join(","));
  for (const wname of Object.keys(workers)) {
    const env = spawnMod.buildEnv(workers[wname], anchors, null);
    for (const t of TOKENS) {
      out(t + "__" + wname, Object.prototype.hasOwnProperty.call(env, t) ? 1 : 0);
    }
    // Non-vacuity per worker: an allowlisted var really did come through, so a
    // buildEnv that returned {} could not make the assertions above pass.
    out("PATHOK__" + wname, typeof (env.PATH || env.Path) === "string" ? 1 : 0);
    out("ACDOK__" + wname, env.AGENTS_CONFIG_DIR === anchors.acd ? 1 : 0);
    // Value identity, not mere key presence: an entry that arrives empty or
    // rewritten would not resolve a config dir any better than an absent one.
    for (const v of CONFIG_PATH_VARS) {
      out("CFG__" + v + "__" + wname, env[v] === process.env[v] ? 1 : 0);
    }
  }
  // extraEnv is bounded by the same declaration: a worker cannot be handed a var
  // it never declared, so the passthrough list is the whole story.
  out("extra_undeclared_err", errOf(() => spawnMod.buildEnv(trEntry, anchors, { GH_TOKEN: "x" })));
  out("extra_declared_err", errOf(() =>
    spawnMod.buildEnv(workers["worktree-backup"], anchors, { WORKTREE_BASE_DIR: "x" })));
  process.exit(0);
}

if (mode === "env-missing") {
  // The missing-value branch of buildEnv. The parent deliberately does NOT hold
  // the two higher-priority config vars while it DOES hold the lower-priority
  // ones. What must not happen is the absent names arriving as the four-letter
  // string "undefined" or as "": a child gh would then resolve its config dir
  // against a directory literally named `undefined` instead of falling through to
  // APPDATA, which is strictly worse than the variable being absent.
  //
  // This mode says nothing about MEMBERSHIP — an unset variable is absent from
  // the child env whether or not the allowlist carries it — so it is stable
  // across the #1719 fix by construction.
  const ABSENT = ["GH_CONFIG_DIR", "XDG_CONFIG_HOME"];
  const PRESENT = ["APPDATA", "ProgramData", "PROGRAMDATA"];
  for (const v of ABSENT) out("parent_absent_" + v, typeof process.env[v] === "string" ? 0 : 1);
  for (const v of PRESENT) out("parent_present_" + v, typeof process.env[v] === "string" ? 1 : 0);
  for (const wname of Object.keys(workers)) {
    const env = spawnMod.buildEnv(workers[wname], anchors, null);
    for (const v of ABSENT) {
      out("MISS__" + v + "__" + wname,
        Object.prototype.hasOwnProperty.call(env, v)
          ? "materialized:" + JSON.stringify(env[v])
          : "key-absent");
    }
    for (const v of PRESENT) {
      out("KEEP__" + v + "__" + wname, env[v] === process.env[v] ? "value-identical" : "MISMATCH");
    }
    out("MISSPATHOK__" + wname, typeof (env.PATH || env.Path) === "string" ? 1 : 0);
  }
  process.exit(0);
}

if (mode === "env-edge") {
  // Byte-level passthrough of config-path VALUES.
  //
  // The vehicle is APPDATA — a variable that is ALREADY on the allowlist. Running
  // these rows on GH_CONFIG_DIR / XDG_CONFIG_HOME would make every one of them
  // red purely because those two are not admitted yet, drowning the single
  // membership signal the #1719 groups exist to give in one copy per row.
  // Value handling in buildEnv is one code path for every member of the list, so
  // the vehicle choice costs no coverage.
  //
  // Values are constructed HERE and assigned into process.env rather than planted
  // by the shell: an empty string, a non-ASCII path and a metacharacter string all
  // cross a shell -> OS-env -> node boundary differently on Windows and POSIX, and
  // the claim under test is about buildEnv, not about that boundary. (The shell
  // DOES plant real config-path values for group G, which is where the OS-env
  // transport is exercised.)
  // The two length extremes are named constants because group L re-derives the
  // SAME long value independently, on the far side of a real subprocess.
  // Windows caps a single environment variable near 32767 characters and the
  // whole child environment block draws on the same budget, so 8192 is
  // deliberately large while leaving ample room for the ~15 other names
  // buildEnv copies. A value at the hard cap would test the OS, not buildEnv.
  const LONG_PREFIX = "C:\\gh-cfg-";
  const LONG_LEN = 8192;
  const LONG_VALUE = LONG_PREFIX + "d".repeat(LONG_LEN - LONG_PREFIX.length);
  const EDGE_CASES = [
    { name: "empty-string", value: "" },
    // One character: the shortest value that is still a value, and the row that
    // would catch any off-by-one "treat a 1-char value as empty" handling.
    { name: "single-char", value: "X" },
    { name: "nonexistent-path", value: "/no/such/dir/zzz-1719-does-not-exist" },
    { name: "path-with-space", value: "C:\\Program Files\\GitHub CLI\\cfg dir" },
    { name: "unicode-path", value: "C:\\\u30e6\u30fc\u30b6\u30fc\\\u8a2d\u5b9a\\gh-\u914d\u7f6e-\u03a9" },
    { name: "shell-metachars", value: "$(id); `whoami` && rm -rf / | tee /tmp/pwned" },
    { name: "very-long-path", value: LONG_VALUE },
  ];
  const VEHICLE = "APPDATA";
  // Non-vacuity per row: prove the row really carries the edge property it is
  // named after, so a table someone silently blanded out cannot pass.
  const edgeProp = (c) => {
    if (c.name === "empty-string") return c.value.length === 0 ? "len-0" : "not-empty";
    if (c.name === "single-char") return c.value.length === 1 ? "len-1" : "not-len-1";
    if (c.name === "very-long-path") return c.value.length === LONG_LEN ? "len-8192" : "wrong-length";
    if (c.name === "nonexistent-path") return fs.existsSync(c.value) ? "exists" : "not-on-disk";
    if (c.name === "path-with-space") return /\s/.test(c.value) ? "has-space" : "no-space";
    if (c.name === "unicode-path") return /[^\x00-\x7F]/.test(c.value) ? "non-ascii" : "ascii-only";
    if (c.name === "shell-metachars") return /[$`;|&]/.test(c.value) ? "has-metachars" : "plain";
    return "unknown";
  };
  out("edge_count", EDGE_CASES.length);
  for (const c of EDGE_CASES) {
    process.env[VEHICLE] = c.value;
    out("EDGEPROP__" + c.name, edgeProp(c));
    // Round-trip through the real process env first: if the assignment itself
    // did not survive, the comparison below would be measuring nothing.
    out("EDGEPARENT__" + c.name, process.env[VEHICLE] === c.value ? "intact" : "PARENT_MANGLED");
    const bad = [];
    for (const wname of Object.keys(workers)) {
      const env = spawnMod.buildEnv(workers[wname], anchors, null);
      if (!Object.prototype.hasOwnProperty.call(env, VEHICLE)) { bad.push(wname + ":absent"); continue; }
      // Strict identity: no expansion, no trimming, no quoting, no path
      // normalization. shell:false in spawn.js is what makes the metacharacter
      // row inert at execution time; this is the same claim one layer earlier.
      if (env[VEHICLE] !== c.value) bad.push(wname + ":rewritten");
    }
    out("EDGE__" + c.name, bad.join(","));
  }
  process.exit(0);
}

if (mode === "env-idem") {
  // buildEnv must be a pure read of process.env + the two declaration arrays. If
  // it ever mutated CHILD_ENV_ALLOWLIST (a module-level singleton) or an entry's
  // envPassthrough, the second worker dispatched in a process would inherit the
  // first one's scope — a credential-scope failure that no single-call test sees.
  const entry = workers["issue-reconcile"];
  const allowBefore = registry.CHILD_ENV_ALLOWLIST.slice().join(",");
  const allowLenBefore = registry.CHILD_ENV_ALLOWLIST.length;
  const passBefore = (entry.envPassthrough || []).slice().join(",");
  const snap = (e) => JSON.stringify(Object.keys(e).sort().map((k) => [k, e[k]]));

  const e1 = spawnMod.buildEnv(entry, anchors, null);
  const e2 = spawnMod.buildEnv(entry, anchors, null);
  out("idem_equal", snap(e1) === snap(e2) ? 1 : 0);
  out("idem_fresh_object", e1 === e2 ? 0 : 1);
  out("idem_key_count", Object.keys(e1).length);

  // An extraEnv call in between must not leave a residue in the next plain call.
  spawnMod.buildEnv(entry, anchors, { GH_TOKEN: "not-a-real-token-idempotency-probe" });
  const e3 = spawnMod.buildEnv(entry, anchors, null);
  out("idem_extra_no_residue", snap(e3) === snap(e1) ? 1 : 0);

  out("idem_allowlist_unmutated", registry.CHILD_ENV_ALLOWLIST.slice().join(",") === allowBefore ? 1 : 0);
  out("idem_allowlist_len_unmutated", registry.CHILD_ENV_ALLOWLIST.length === allowLenBefore ? 1 : 0);
  out("idem_passthrough_unmutated", (entry.envPassthrough || []).slice().join(",") === passBefore ? 1 : 0);
  process.exit(0);
}

process.stderr.write("UNKNOWN_MODE");
process.exit(8);
PROBEJS

PROBE_OUT=""
# probe <mode>
probe() {
    PROBE_OUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$1" "$MAIN" "$LINKED" "$OUTSIDE" "$ALT" 2>&1)" || return 1
    return 0
}

# Credentials planted in the parent env. Values are obvious nonsense; they are
# never sent anywhere (no `gh` child runs here).
FAKE_GH_TOKEN="ghp-FAKE0000-not-a-real-token"
FAKE_GITHUB_TOKEN="github-pat-FAKE0000-not-a-real-token"

# Config-location vars planted with real, empty fixture dirs: buildEnv only copies
# strings, but resolveAnchors runs git in this process, and pointing Windows git at
# a non-existent %ProgramData% would make the fixture environment-dependent.
CFG_APPDATA_RAW="$TMPD/cfg-appdata";      mkdir -p "$CFG_APPDATA_RAW"
CFG_PROGDATA_RAW="$TMPD/cfg-programdata"; mkdir -p "$CFG_PROGDATA_RAW"
CFG_XDG_RAW="$TMPD/cfg-xdg";              mkdir -p "$CFG_XDG_RAW"
CFG_GHDIR_RAW="$TMPD/cfg-ghconfig";       mkdir -p "$CFG_GHDIR_RAW"
CFG_APPDATA="$(nodepath "$CFG_APPDATA_RAW")"
CFG_PROGDATA="$(nodepath "$CFG_PROGDATA_RAW")"
CFG_XDG="$(nodepath "$CFG_XDG_RAW")"
CFG_GHDIR="$(nodepath "$CFG_GHDIR_RAW")"

# Both credential and config-location vars are planted here: "does the child see
# it" is only a real question when the parent really has it. ProgramData and
# PROGRAMDATA get the SAME value because Windows env is case-insensitive and two
# different values would have no defined meaning there.
probe_with_planted_env() {
    PROBE_OUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "GH_TOKEN=$FAKE_GH_TOKEN" "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        "APPDATA=$CFG_APPDATA" "ProgramData=$CFG_PROGDATA" "PROGRAMDATA=$CFG_PROGDATA" \
        "XDG_CONFIG_HOME=$CFG_XDG" "GH_CONFIG_DIR=$CFG_GHDIR" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$1" "$MAIN" "$LINKED" "$OUTSIDE" "$ALT" 2>&1)" || return 1
    return 0
}

# The mirror-image parent env: the two HIGHER-priority config vars are removed
# with `env -u` while the lower-priority ones stay planted. `env` takes its
# options before the assignments, hence the ordering below.
probe_with_missing_cfg_env() {
    PROBE_OUT="$(run_with_timeout 60 env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "APPDATA=$CFG_APPDATA" "ProgramData=$CFG_PROGDATA" "PROGRAMDATA=$CFG_PROGDATA" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$1" "$MAIN" "$LINKED" "$OUTSIDE" "$ALT" 2>&1)" || return 1
    return 0
}

pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -1; }
