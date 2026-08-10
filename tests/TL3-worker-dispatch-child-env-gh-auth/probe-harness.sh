# Part of tests/TL3-worker-dispatch-child-env-gh-auth.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, config-path, gh-cli, auth-resolution, real-environment, TL3, scope:common
#
# The node probe (one process per mode, emitting `key=value` lines) and the
# shell-side helpers that read it: run_probe / pv / expect_class, plus
# trim() and exit_verdict(). Depends on fixtures/counters defined before
# this file is sourced.
#
# Two probe modes:
#   direct    child_process.spawnSync of gh with this process's own env —
#             the dispatcher is not in the call path at all.
#   dispatch  spawnMod.run(), i.e. the env buildEnv() assembled.
# Both emit only `class` / `status` / `timedout` / `spawn_error`.
PROBE="$TMPD/probe.js"
cat > "$PROBE" <<'PROBEJS'
const path = require("path");
const childProcess = require("child_process");

// Child-env measurement, taken AT THE SPAWN SITE: reading process.env would
// measure this process, not what's handed to the gh child — buildEnv()
// constructs a fresh allowlisted object on the dispatched path, so a
// credential present in the parent can be absent in the child or vice versa.
// spawnSync is wrapped BEFORE spawn.js is required, so this is the binding
// that module destructures at load time; `spawnSite` records which call site
// produced the observation. The captured env is reduced to 0/1 and never
// printed, returned, or written (secrecy).
const realSpawnSync = childProcess.spawnSync;
let childEnv = null;
let childEnvSite = "none";
let spawnSite = "none";
childProcess.spawnSync = function (cmd, args, opts) {
  if (cmd === "gh") {
    // An absent `env` means the child inherits this process's env.
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

// The only place gh output is ever inspected: reduced to one of three tokens,
// raw bytes dropped with the local `blob` binding, never returned/logged/written.
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

// The four names gh can authenticate with straight from the environment; none
// may be present in the CHILD, or the gate/dispatched-arm comparison breaks.
// Emitted with every probe so the claim is measured rather than assumed.
const CRED_VARS = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
const credsAbsentIn = (env) => (CRED_VARS.every((n) => typeof env[n] !== "string") ? 1 : 0);

// `child_env_measured` guards `creds_absent` against reading 1 vacuously when no
// gh child ever started. `creds_absent_parent` is the probe's own env, kept
// under its own name so parent and child measurements can't be conflated.
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

// classify() unit cases. Deterministic: synthetic result objects, no gh, no
// network, no timing. A real timeout/spawn-failure can't be induced on demand,
// but its CLASSIFICATION can — that's the part deciding whether an unproven
// arm reads as a pass, the property worth fencing.
if (mode === "classify-selftest") {
  const CASES = [
    // The three ways an arm can fail to produce an answer — all must be
    // `inconclusive`, or an unproven arm would count as proof.
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
  // envPassthrough: [] on purpose — a parent holding GH_TOKEN must not be able
  // to authenticate this child; the config directory must do the work, which
  // is exactly the property #1719 broke.
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
    // spawnMod.run() can throw before ever reaching spawnSync — no child env
    // then, and outEnvFacts() says so rather than guessing.
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
# [env-args...] states the arm's parent-env condition, handed straight to
# `env` (`-u VAR` / `VAR=value`, options first). Fixed prefix is the fixture
# isolation contract: no inherited session id/credential, workflow dirs pinned.
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
