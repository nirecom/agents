# Part of tests/TL3-worker-dispatch-child-env-gh-doc-append.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, gh-cli, doc-append, real-environment, TL3, scope:common
# The node probe (unit / direct / dispatch modes) and the shell-side readers
# that consume it. Sourced so the counters and fixtures above are shared
# (rules/coding/file-split.md Pattern A).
PROBE="$TMPD/gh-doc-probe.js"
cat > "$PROBE" <<'PROBEJS'
const path = require("path");
const childProcess = require("child_process");

const [agentsDir, mode, mainRoot, entryName, script] = process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const entryOf = (n) => {
  const e = (registry.workers || {})[n];
  if (!e) throw new Error("no registry entry '" + n + "'");
  return e;
};

// The only place gh output is ever inspected: reduced to one of three tokens
// inside this process, raw bytes dropped with the local binding, never
// returned, logged or written to disk.
function classify(stdout, status) {
  const blob = String(stdout || "").toLowerCase();
  const m = /ghrc=(\d+)/.exec(blob);
  const ghrc = m ? Number(m[1]) : status;
  if (ghrc === 0) return "authenticated";
  if (/not logged in|gh auth login|no accounts|is invalid|failed to log in/.test(blob)) {
    return "unauthenticated";
  }
  return "inconclusive"; // network / unknown failure — never counted as a pass
}

if (mode === "unit") {
  const ACD = "/fixture-acd-root";
  const anchors = { acd: ACD };
  const TOKEN = process.env.PROBE_FAKE_GH_TOKEN || "fake-token";
  const SECRET = process.env.PROBE_FAKE_SECRET || "fake-secret";

  function withEnv(mods, fn) {
    const saved = {};
    for (const k of Object.keys(mods)) {
      saved[k] = has(process.env, k) ? process.env[k] : undefined;
      if (mods[k] === null) delete process.env[k];
      else process.env[k] = mods[k];
    }
    try {
      return fn();
    } finally {
      for (const k of Object.keys(saved)) {
        if (saved[k] === undefined) delete process.env[k];
        else process.env[k] = saved[k];
      }
    }
  }

  const built = (name, mods) => withEnv(mods, () => spawnMod.buildEnv(entryOf(name), anchors));
  const eq = (got, want) => (got === want ? "ok" : "got:" + JSON.stringify(got));
  const absent = (env, k) => (has(env, k) ? "got:present" : "ok");

  const CASES = [
    ["doc-append/gh-token-reaches-child",
      () => eq(built("doc-append", { GH_TOKEN: TOKEN }).GH_TOKEN, TOKEN)],
    ["doc-append/github-token-reaches-child",
      () => eq(built("doc-append", { GITHUB_TOKEN: TOKEN }).GITHUB_TOKEN, TOKEN)],
    // Controls on entries that already declare the pair: a failure above is
    // then attributable to the registry data, not to a broken harness.
    ["issue-reconcile/gh-token-control",
      () => eq(built("issue-reconcile", { GH_TOKEN: TOKEN }).GH_TOKEN, TOKEN)],
    ["commit-push/github-token-control",
      () => eq(built("commit-push", { GITHUB_TOKEN: TOKEN }).GITHUB_TOKEN, TOKEN)],
    ["doc-append/absent-token-is-omitted-not-blanked",
      () => absent(built("doc-append", { GH_TOKEN: null }), "GH_TOKEN")],
    ["doc-append/undeclared-secret-does-not-reach-child",
      () => absent(built("doc-append", { SOME_UNRELATED_SECRET: SECRET }), "SOME_UNRELATED_SECRET")],
    // Over-widening guard: the tokens belong to the entries that authenticate,
    // never to the allowlist every worker's children inherit.
    ["allowlist/tokens-stay-out-of-the-global-child-env-allowlist",
      () => {
        const list = registry.CHILD_ENV_ALLOWLIST || [];
        const leaked = ["GH_TOKEN", "GITHUB_TOKEN"].filter((n) => list.includes(n));
        return leaked.length === 0 ? "ok" : "got:" + leaked.join(",");
      }],
    // Symmetric counterpart of the widening: workers with no GitHub surface
    // must keep their empty passthrough.
    ["session-close-gate/gh-token-stays-out",
      () => absent(built("session-close-gate", { GH_TOKEN: TOKEN }), "GH_TOKEN")],
    ["doc-append/undeclared-extraenv-is-rejected",
      () => {
        try {
          spawnMod.buildEnv(entryOf("doc-append"), anchors, { SOME_UNRELATED_SECRET: SECRET });
          return "got:accepted";
        } catch (_e) {
          return "ok";
        }
      }],
  ];

  for (const [name, fn] of CASES) {
    let r;
    try {
      r = fn();
    } catch (e) {
      r = "threw:" + String((e && e.message) || e);
    }
    out("U__" + name, r);
  }
  out("unit_case_count", CASES.length);
  process.exit(0);
}

if (mode === "direct") {
  const r = childProcess.spawnSync("bash", ["-c", script], {
    env: process.env, shell: false, encoding: "utf8",
    timeout: 40000, windowsHide: true, maxBuffer: 8 * 1024 * 1024,
  });
  out("dispatch_error", r.error ? 1 : 0);
  out("dispatch_message", r.error ? String(r.error.code || r.error.message) : "-");
  out("class", classify(r.stdout, typeof r.status === "number" ? r.status : null));
  process.exit(0);
}

if (mode === "dispatch") {
  const anchors = anchorMod.resolveAnchors(mainRoot);
  if (anchors.error) {
    out("dispatch_error", 1);
    out("dispatch_message", "anchors: " + anchors.error);
    out("class", "inconclusive");
    process.exit(0);
  }
  let res;
  try {
    res = spawnMod.run(entryOf(entryName), {
      anchors, command: "bash", args: ["-c", script], cwd: mainRoot, timeoutMs: 40000,
    });
  } catch (e) {
    out("dispatch_error", 1);
    out("dispatch_message", String((e && e.message) || e));
    out("class", "inconclusive");
    process.exit(0);
  }
  out("dispatch_error", res.spawnError || res.timedOut ? 1 : 0);
  out("dispatch_message", res.spawnError ? res.spawnError : (res.timedOut ? "timed out" : "-"));
  out("class", classify(res.stdout, res.status));
  process.exit(0);
}

process.stderr.write("UNKNOWN_MODE");
process.exit(8);
PROBEJS

PROBE_OUT=""
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s|^$1=||p" | head -1; }

# gh's own output stays inside the probe; only `ghrc` and the classified verdict
# ever cross a process boundary.
CHILD_SCRIPT='gh auth status --hostname "$GH_HOST" 2>&1; printf "ghrc=%s\n" "$?"'

run_probe() {
    local mode="$1" entry="$2"; shift 2
    PROBE_OUT="$(run_with_timeout 90 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
        -u SOME_UNRELATED_SECRET "$@" \
        "GH_HOST=$TARGET_HOST" "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "PROBE_FAKE_GH_TOKEN=$FAKE_GH_TOKEN" "PROBE_FAKE_SECRET=$FAKE_SECRET" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$mode" "$MAIN" "$entry" "$CHILD_SCRIPT" 2>&1)" || return 1
    return 0
}

expect_class() {
    local name="$1" want="$2" required="$3" got
    got="$(pv class)"
    if [ "$got" = "inconclusive" ] || [ -z "$got" ]; then
        [ "$required" = "1" ] && INCONCLUSIVE=1
        skip "$name — no definite classification ($(pv dispatch_message))"
        return 0
    fi
    if [ "$got" = "$want" ]; then
        pass "$name"
        [ "$required" = "1" ] && PROVEN=$((PROVEN + 1))
    else
        fail "$name — want class=$want got class=$got"
    fi
    return 0
}
