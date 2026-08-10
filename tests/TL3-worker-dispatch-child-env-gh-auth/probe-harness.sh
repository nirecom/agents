# Part of tests/TL3-worker-dispatch-child-env-gh-auth.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, config-path, gh-cli, auth-resolution, real-environment, TL3, scope:common
#
# The node probe (one process per mode, emitting `key=value` lines) and the
# shell-side helpers that read it: run_probe / pv / expect_class, plus the two
# small deciders the suite's honesty rests on — trim() and exit_verdict().
# Everything here depends on the fixtures and counters the dispatcher defined
# before sourcing this file.

# ---------------------------------------------------------------------------
# Probe harness. Two modes:
#   direct    child_process.spawnSync of gh with this process's own env — the
#             dispatcher is not loaded into the call path at all.
#   dispatch  spawnMod.run(), i.e. the env buildEnv() assembled.
# Both emit only `class` / `status` / `timedout` / `spawn_error`.
# ---------------------------------------------------------------------------
PROBE="$TMPD/probe.js"
cat > "$PROBE" <<'PROBEJS'
const path = require("path");
const childProcess = require("child_process");

// ---------------------------------------------------------------------------
// Child-env measurement, taken AT THE SPAWN SITE.
//
// Reading process.env would measure THIS process, not the environment handed to
// the gh child, and the two are not the same object on the dispatched path:
// buildEnv() constructs a fresh allowlisted object, so a credential present in
// the parent can be absent in the child and vice versa. An assert named
// `credential-free` has to be answered at the boundary it names.
//
// spawnSync is wrapped BEFORE bin/worker-dispatch/spawn.js is required, so the
// wrapper is the binding that module destructures at load time and every gh
// child — direct site and dispatched site alike — is observed where it is
// actually started. `spawnSite` records WHICH site produced the observation, so
// the two are reported distinctly instead of collapsed.
//
// Secrecy is unaffected: the captured object is reduced to a 0/1 here and never
// printed, returned or written.
// ---------------------------------------------------------------------------
const realSpawnSync = childProcess.spawnSync;
let childEnv = null;
let childEnvSite = "none";
let spawnSite = "none";
childProcess.spawnSync = function (cmd, args, opts) {
  if (cmd === "gh") {
    // An absent `env` means the child inherits this process's env, so that IS
    // the child's env at this site.
    childEnv = opts && opts.env ? opts.env : process.env;
    childEnvSite = spawnSite;
  }
  return realSpawnSync.apply(this, arguments);
};
const spawnSync = childProcess.spawnSync;

const [agentsDir, mode, mainRoot, host, entryKind] = process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");

// The only place gh output is ever inspected. It is reduced to one of three
// tokens here and the raw bytes are dropped with the local `blob` binding — they
// are never returned, logged, or written anywhere.
function classify(res) {
  if (res.timedOut) return "inconclusive";
  if (res.status === 0) return "authenticated";
  const blob = String(res.stdout || "").toLowerCase() + "\n" + String(res.stderr || "").toLowerCase();
  if (blob.includes("not logged in") || blob.includes("gh auth login") || blob.includes("no accounts")) {
    return "unauthenticated";
  }
  return "inconclusive"; // network / unknown failure — never silently counted as a pass
}

const GH_ARGS = ["auth", "status", "--hostname", host];
const TIMEOUT_MS = 20000;

// The four names gh can authenticate with straight from the environment. None of
// them may be present in the CHILD: the gate and the dispatched arms are only
// comparable when both run credential-free. Emitted with every probe so the
// claim is measured rather than assumed.
const CRED_VARS = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
const credsAbsentIn = (env) => (CRED_VARS.every((n) => typeof env[n] !== "string") ? 1 : 0);

// `child_env_measured` guards `creds_absent` against reading 1 vacuously: with
// no gh child ever started there is no child env, and "absent" would then mean
// "unobserved". `creds_absent_parent` is the probe's own env, reported under its
// own name so the parent and child measurements can never be mistaken for one
// another.
const outEnvFacts = () => {
  out("child_env_measured", childEnv ? 1 : 0);
  out("env_site", childEnvSite);
  out("creds_absent", childEnv ? credsAbsentIn(childEnv) : 0);
  out("creds_absent_parent", credsAbsentIn(process.env));
};

const report = (res, extra) => {
  out("class", classify(res));
  out("status", typeof res.status === "number" ? res.status : "null");
  out("timedout", res.timedOut ? 1 : 0);
  out("spawn_error", extra ? 1 : 0);
  outEnvFacts();
};

// -------------------------------------------------------------------------
// classify() unit cases. Deterministic by construction: synthetic result
// objects, no gh, no network, no timing. A real timeout or a real spawn failure
// cannot be induced on demand, but the CLASSIFICATION of one can — and the
// classification is the part that decides whether an unproven arm is allowed to
// read as a pass, which is the property worth fencing.
// -------------------------------------------------------------------------
if (mode === "classify-selftest") {
  const CASES = [
    // The three ways an arm can fail to produce an answer. All must be
    // `inconclusive`; anything else would let an unproven arm count as proof.
    ["timeout", { timedOut: true, status: null, stdout: "", stderr: "" }],
    ["spawn-failure", {
      timedOut: false, status: null, stdout: "", stderr: "",
      error: { code: "ENOENT", message: "spawn gh ENOENT" },
    }],
    ["unrecognized-nonzero", {
      timedOut: false, status: 4,
      stdout: "unexpected response from the API",
      stderr: "dial tcp 140.82.0.1:443: i/o timeout",
    }],
    // timedOut wins even over a zero status: a killed child can still leave a
    // stale zero behind on some platforms, and that must not read as success.
    ["timeout-outranks-status-zero", { timedOut: true, status: 0, stdout: "", stderr: "" }],
  ];
  for (const [name, res] of CASES) {
    const got = classify(res);
    out("SELF__" + name, got === "inconclusive" ? "ok" : "got:" + got);
  }
  // The two definite classifications, so the rows above cannot pass because
  // classify() simply answers "inconclusive" to everything.
  const POS = [
    ["authenticated", { timedOut: false, status: 0, stdout: "Logged in to github.com", stderr: "" }, "authenticated"],
    ["not-logged-in", {
      timedOut: false, status: 1, stdout: "",
      stderr: "You are not logged in to any GitHub hosts. To log in, run: gh auth login",
    }, "unauthenticated"],
    ["no-accounts", { timedOut: false, status: 1, stdout: "", stderr: "no accounts configured" }, "unauthenticated"],
  ];
  for (const [name, res, want] of POS) {
    const got = classify(res);
    out("SELF__" + name, got === want ? "ok" : "got:" + got);
  }
  out("selftest_inconclusive_count", CASES.length);
  out("selftest_definite_count", POS.length);
  process.exit(0);
}

if (mode === "direct") {
  spawnSite = "direct";
  const r = spawnSync("gh", GH_ARGS, {
    env: process.env, shell: false, encoding: "utf8",
    timeout: TIMEOUT_MS, windowsHide: true, maxBuffer: 8 * 1024 * 1024,
  });
  const timedOut = Boolean(r.error && r.error.code === "ETIMEDOUT");
  report({ timedOut, status: typeof r.status === "number" ? r.status : null, stdout: r.stdout, stderr: r.stderr },
    Boolean(r.error) && !timedOut);
  process.exit(0);
}

if (mode === "dispatch") {
  const anchors = anchorMod.resolveAnchors(mainRoot);
  if (anchors.error) { out("anchors_error", anchors.error); process.exit(9); }
  // envPassthrough: [] on purpose. A parent that holds GH_TOKEN must not be able
  // to authenticate this child for it — the config directory has to do the work,
  // which is exactly the property #1719 broke.
  const probeEntry = {
    name: "probe-gh",
    binaries: { external: ["gh"], scripts: {} },
    envPassthrough: [],
    writeScopes: [],
  };
  const entry = entryKind === "registry" ? (registry.workers || {})["issue-reconcile"] : probeEntry;
  if (!entry) { out("entry_error", "no such worker entry"); process.exit(10); }
  let res;
  spawnSite = "dispatch";
  try {
    res = spawnMod.run(entry, { anchors, command: "gh", args: GH_ARGS, cwd: mainRoot, timeoutMs: TIMEOUT_MS });
  } catch (e) {
    // spawnMod.run() can throw before it ever reaches spawnSync, in which case
    // there is no child env — outEnvFacts() says so rather than guessing.
    out("class", "inconclusive");
    out("status", "throw");
    out("timedout", 0);
    out("spawn_error", 1);
    outEnvFacts();
    process.exit(0);
  }
  report(res, Boolean(res.spawnError));
  process.exit(0);
}

process.stderr.write("UNKNOWN_MODE");
process.exit(8);
PROBEJS

PROBE_OUT=""
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -1; }

# run_probe <mode> <entry-kind> [env-args...]
# Every arm states its own parent-env condition in [env-args...]; those are handed
# straight to `env`, so `-u VAR` and `VAR=value` are both usable (options first).
# The fixed prefix is the fixture isolation contract: no inherited session id, no
# inherited credential, and both workflow dirs pinned into the temp tree.
run_probe() {
    local mode="$1" kind="$2"; shift 2
    PROBE_OUT="$(run_with_timeout 60 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID "${STRIP_CREDS[@]}" "$@" \
        "GH_HOST=$TARGET_HOST" \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$mode" "$MAIN" "$TARGET_HOST" "$kind" 2>&1)" || return 1
    return 0
}

# trim <string> — the table below is written for humans, so every cell is padded.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# exit_verdict <fail> <inconclusive> <proven> <required> -> 0 | 1 | 77
#
# The whole exit contract, in one place, so the self-check below evaluates the
# REAL arithmetic rather than a restatement of it that could drift.
#   FAIL > 0                       -> 1  (something was disproved)
#   INCONCLUSIVE or PROVEN < REQ   -> 77 (nothing was disproved AND nothing proved)
#   otherwise                      -> 0
exit_verdict() {
    if [ "$1" -gt 0 ]; then echo 1
    elif [ "$2" -ne 0 ] || [ "$3" -lt "$4" ]; then echo 77
    else echo 0; fi
}

# expect_class <assert-name> <want-class> <required 0|1>
# An arm that cannot be classified is never a pass: a required one poisons the
# whole file into SKIP, so "we proved nothing" can never print as green.
expect_class() {
    local name="$1" want="$2" required="$3" got
    got="$(pv class)"
    if [ "$got" = "inconclusive" ] || [ -z "$got" ]; then
        if [ "$required" = "1" ]; then INCONCLUSIVE=1; fi
        skip "$name — no definite classification (class=$got status=$(pv status) timedout=$(pv timedout))"
        return
    fi
    if [ "$got" = "$want" ]; then
        pass "$name"
        if [ "$required" = "1" ]; then PROVEN=$((PROVEN + 1)); fi
    else
        fail "$name — want class=$want got class=$got (status=$(pv status))"
    fi
}
