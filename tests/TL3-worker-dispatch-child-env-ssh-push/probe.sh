# Part of tests/TL3-worker-dispatch-child-env-ssh-push.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, ssh-agent, commit-push, real-environment, TL3, scope:common
# The node probe (two modes) plus the shell-side readers. `unit` calls the real
# buildEnv() against the LIVE registry entries; `dispatch` runs the real
# spawn.js run() with command `bash` and reports the child's own stdout, so the
# observation is made INSIDE the child rather than inferred from the parent.
PROBE="$TMPD/ssh-probe.js"
cat > "$PROBE" <<'PROBEJS'
const path = require("path");

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

if (mode === "unit") {
  // Anchor fixture: buildEnv() consults only `acd`, and it must OVERWRITE any
  // inherited AGENTS_CONFIG_DIR rather than copy one through.
  const ACD = "/fixture-acd-root";
  const anchors = { acd: ACD };
  const FAKE = process.env.PROBE_FAKE_SECRET || "unrelated-fake";
  const SOCK = "/fixture/agent.sock";

  // null in `mods` means "absent from the parent env" — distinct from "", which
  // is a real value the allowlist copy is supposed to preserve verbatim.
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
    ["commit-push/ssh-auth-sock-reaches-child",
      () => eq(built("commit-push", { SSH_AUTH_SOCK: SOCK }).SSH_AUTH_SOCK, SOCK)],
    // SSH_AGENT_PID was dropped from commit-push's envPassthrough (HIGH review
    // finding on #1812/#1744): the SSH client authenticates off SSH_AUTH_SOCK
    // alone, and the PID only exposed the agent's lifecycle handle.
    ["commit-push/ssh-agent-pid-does-not-reach-child",
      () => absent(built("commit-push", { SSH_AGENT_PID: "4242" }), "SSH_AGENT_PID")],
    // A socket path with spaces is the realistic Windows temp shape; a value
    // mangled in transit is a live-oracle bug that a plain "is it set" check
    // would report as green.
    ["commit-push/ssh-auth-sock-value-is-copied-verbatim",
      () => eq(built("commit-push", { SSH_AUTH_SOCK: "/tmp/ssh dir/agent 1.sock" }).SSH_AUTH_SOCK,
        "/tmp/ssh dir/agent 1.sock")],
    ["commit-push/ssh-auth-sock-absent-is-omitted-not-blanked",
      () => absent(built("commit-push", { SSH_AUTH_SOCK: null }), "SSH_AUTH_SOCK")],
    ["commit-push/ssh-auth-sock-empty-value-is-preserved",
      () => {
        const env = built("commit-push", { SSH_AUTH_SOCK: "" });
        return has(env, "SSH_AUTH_SOCK") ? eq(env.SSH_AUTH_SOCK, "") : "got:dropped";
      }],
    // Control: an already-declared name must pass through, so a failure above
    // is attributable to the registry data and not to a broken harness.
    ["commit-push/declared-name-control-enforce-worktree",
      () => eq(built("commit-push", { ENFORCE_WORKTREE: "off" }).ENFORCE_WORKTREE, "off")],
    ["commit-push/undeclared-secret-does-not-reach-child",
      () => absent(built("commit-push", { SOME_UNRELATED_SECRET: FAKE }), "SOME_UNRELATED_SECRET")],
    // Scoping guard: only the worker that pushes may hold the signing oracle.
    ["doc-append/ssh-auth-sock-stays-out-of-a-non-pushing-worker",
      () => absent(built("doc-append", { SSH_AUTH_SOCK: SOCK }), "SSH_AUTH_SOCK")],
    // Over-widening guard: the fix belongs in one worker's envPassthrough, not
    // in the global allowlist every worker's children inherit.
    ["allowlist/ssh-names-stay-out-of-the-global-child-env-allowlist",
      () => {
        const list = registry.CHILD_ENV_ALLOWLIST || [];
        const leaked = ["SSH_AUTH_SOCK", "SSH_AGENT_PID"].filter((n) => list.includes(n));
        return leaked.length === 0 ? "ok" : "got:" + leaked.join(",");
      }],
    ["commit-push/agents-config-dir-is-forced-not-inherited",
      () => eq(built("commit-push", { AGENTS_CONFIG_DIR: "/planted-checkout" }).AGENTS_CONFIG_DIR, ACD)],
    ["commit-push/buildenv-is-idempotent-and-non-mutating",
      () => {
        const before = entryOf("commit-push").envPassthrough.length;
        const a = built("commit-push", { SSH_AUTH_SOCK: SOCK });
        const b = built("commit-push", { SSH_AUTH_SOCK: SOCK });
        const after = entryOf("commit-push").envPassthrough.length;
        if (JSON.stringify(a) !== JSON.stringify(b)) return "got:differing-results";
        return before === after ? "ok" : "got:envPassthrough-grew-" + before + "->" + after;
      }],
    ["commit-push/undeclared-extraenv-is-rejected",
      () => {
        try {
          spawnMod.buildEnv(entryOf("commit-push"), anchors, { SOME_UNRELATED_SECRET: FAKE });
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

if (mode === "dispatch") {
  const anchors = anchorMod.resolveAnchors(mainRoot);
  if (anchors.error) {
    out("dispatch_error", 1);
    out("dispatch_message", "anchors: " + anchors.error);
    process.exit(0);
  }
  let res;
  try {
    res = spawnMod.run(entryOf(entryName), {
      anchors, command: "bash", args: ["-c", script], cwd: mainRoot, timeoutMs: 30000,
    });
  } catch (e) {
    out("dispatch_error", 1);
    out("dispatch_message", String((e && e.message) || e));
    process.exit(0);
  }
  out("dispatch_error", res.spawnError || res.timedOut ? 1 : 0);
  out("dispatch_message", res.spawnError ? res.spawnError : (res.timedOut ? "timed out" : "-"));
  out("status", typeof res.status === "number" ? res.status : "null");
  // The child's own report, emitted verbatim as further key=value lines.
  process.stdout.write(String(res.stdout || ""));
  process.exit(0);
}

process.stderr.write("UNKNOWN_MODE");
process.exit(8);
PROBEJS

PROBE_OUT=""
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s|^$1=||p" | head -1; }

# What the dispatched child reports about its OWN environment. `${VAR-<unset>}`
# distinguishes an absent name from an empty one; ssh-add's exit code is the
# reachability signal (2 = could not connect to the agent).
CHILD_SCRIPT='printf "sock=%s\n" "${SSH_AUTH_SOCK-<unset>}"; printf "agentpid=%s\n" "${SSH_AGENT_PID-<unset>}"; printf "unrel=%s\n" "${SOME_UNRELATED_SECRET-<unset>}"; ssh-add -l >/dev/null 2>&1; printf "sshaddrc=%s\n" "$?"'

# run_probe <mode> <entry-name> [env-args...] — env-args are handed straight to
# `env` (`-u VAR` / `VAR=value`). The fixed prefix is the fixture-isolation
# contract: no inherited session id, workflow dirs pinned, ambient agent and
# fake-secret names cleared so every arm states its own condition.
run_probe() {
    local mode="$1" entry="$2"; shift 2
    PROBE_OUT="$(run_with_timeout 90 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        -u SSH_AUTH_SOCK -u SSH_AGENT_PID -u SOME_UNRELATED_SECRET "$@" \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "PROBE_FAKE_SECRET=$FAKE_SECRET" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$mode" "$MAIN" "$entry" "$CHILD_SCRIPT" 2>&1)" || return 1
    return 0
}

# trim <string> — the arm table is written for humans, so every cell is padded.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
