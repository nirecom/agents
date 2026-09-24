# Part of tests/feature-1812-worker-dispatch-env-scope.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js
# Tags: worker-dispatch, spawn, env-scope, credential-scope, real-child-process, security, TL2, scope:issue-specific
# Group D — the REAL child process, the seam A and B/C leave unmeasured between
# them: A calls buildEnv() directly, B/C read opts.envScope out of a spawn STUB.
# Dropping `opts.envScope` from spawn.js's own buildEnv() call keeps both green
# while every declared credential reaches every child; this group asks the child.
# Attack shape (protection-fix-tests.md Pattern 2): four declared credentials
# plus one undeclared secret are planted in the parent and the assertions are on
# ABSENCE from the child (Pattern 1), so pre-#1812 code fails rows D1/D2.
REALCHILD="$TMPD/real-child-probe.js"
cat > "$REALCHILD" <<'RCJS'
"use strict";
// argv: agentsDir childCwd mainRoot
const path = require("path");
const [agentsDir, childCwd, mainRoot] = process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const entry = registry.workers["commit-push"];
const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) {
  out("probe_error", "anchors: " + anchors.error);
  process.exit(0);
}

// The child prints its OWN environment. `node -e`, not bash: the reading must
// not be filtered through a shell that invents variables of its own.
const DUMP = "process.stdout.write(JSON.stringify(process.env))";

// Names the child may hold whatever the scope is: the global allowlist (only
// those the parent actually has) plus the forced anchor.
const parentAllowlisted = registry.CHILD_ENV_ALLOWLIST.filter(
  (n) => typeof process.env[n] === "string"
);

function childEnvOf(envScope) {
  const opts = {
    anchors,
    command: "node",
    args: ["-e", DUMP],
    cwd: childCwd,
    timeoutMs: 60000,
  };
  // Omitted vs [] is the distinction row D3 rests on, so the key is set only
  // when the case actually declares one.
  if (envScope !== undefined) opts.envScope = envScope;
  const res = spawnMod.run(entry, opts);
  if (res.spawnError || res.timedOut || res.status !== 0) {
    return { error: res.spawnError || (res.timedOut ? "timed out" : "exit " + res.status) };
  }
  try {
    return { env: JSON.parse(String(res.stdout || "")) };
  } catch (e) {
    return { error: "unparsable child env dump" };
  }
}

// Names Windows' own CreateProcess adds to a child regardless of the env block
// handed to it (measured, not assumed: they appear identically under every
// scope, including the empty one). They name a machine, never a credential, so
// they are excused BY NAME here — and the value-leak row below is name-agnostic
// precisely so that excusing a name cannot excuse a leaked secret.
const PLATFORM_INJECTED = [
  "HOMEDRIVE", "HOMEPATH", "LOGONSERVER", "SYSTEMDRIVE",
  "USERDOMAIN", "USERDOMAIN_ROAMINGPROFILE", "USERNAME", "WINDIR",
];

const PLANTED = [
  "SSH_AUTH_SOCK",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "ENFORCE_WORKTREE",
  "SOME_UNRELATED_SECRET",
];

function report(tag, envScope) {
  const r = childEnvOf(envScope);
  if (r.error) {
    out(tag + "__error", r.error);
    return;
  }
  const env = r.env;
  const has = (k) => Object.prototype.hasOwnProperty.call(env, k);
  out(tag + "__present", PLANTED.filter(has).sort().join(","));
  // Value fidelity, not just presence: a copied-but-mangled socket path is a
  // live-oracle bug a presence check reports as green.
  out(
    tag + "__verbatim",
    PLANTED.filter(has)
      .filter((k) => env[k] !== process.env[k])
      .sort()
      .join(",") || "(all-verbatim)"
  );
  out(tag + "__acd", env.AGENTS_CONFIG_DIR === anchors.acd ? "forced" : "got:" + env.AGENTS_CONFIG_DIR);
  out(tag + "__path", has("PATH") || has("Path") ? "present" : "absent");
  const budget = parentAllowlisted.concat(["AGENTS_CONFIG_DIR"]).concat(
    Array.isArray(envScope) ? envScope : entry.envPassthrough
  );
  // Windows spawn injects `=C:`-shaped drive-cursor entries; Node hides them
  // from process.env, but filter defensively so a leftover is a real name.
  out(
    tag + "__extra",
    Object.keys(env)
      .filter((k) => k.indexOf("=") !== 0)
      .filter((k) => budget.indexOf(k) === -1 && PLATFORM_INJECTED.indexOf(k) === -1)
      .sort()
      .join(",") || "(none)"
  );
  // Name-agnostic: which child names carry a planted credential's VALUE. A
  // credential smuggled through under a different name — the failure mode a
  // name-list check cannot see — shows up here as `<credential>@<childName>`.
  const OUT_OF_SCOPE = PLANTED.filter((n) => budget.indexOf(n) === -1);
  const leaks = [];
  for (const secret of OUT_OF_SCOPE) {
    const v = process.env[secret];
    if (typeof v !== "string" || v === "") continue;
    for (const k of Object.keys(env)) {
      if (env[k] === v) leaks.push(secret + "@" + k);
    }
  }
  out(tag + "__valueleak", leaks.sort().join(",") || "(none)");
}

report("singleton", ["SSH_AUTH_SOCK"]);
report("empty", []);
report("omitted", undefined);
// A name the entry does not declare cannot be smuggled in through envScope: the
// filter runs over envPassthrough, so an unlisted name selects nothing.
report("undeclared_scope", ["SOME_UNRELATED_SECRET"]);

// Reject path (protection-fix-tests.md Pattern 4): a non-array envScope is a
// typo that must THROW, never silently widen the call back to the full set.
try {
  spawnMod.run(entry, {
    anchors, command: "node", args: ["-e", DUMP], cwd: childCwd,
    timeoutMs: 60000, envScope: "SSH_AUTH_SOCK",
  });
  out("string_scope", "accepted");
} catch (e) {
  out("string_scope", "threw");
}
RCJS

group_d() {
    local o
    o="$(run_with_timeout 120 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "SSH_AUTH_SOCK=$FAKE_SSH_SOCK" \
        "GH_TOKEN=$FAKE_GH_TOKEN" "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        "ENFORCE_WORKTREE=on" \
        "SOME_UNRELATED_SECRET=$FAKE_AWS_SECRET" \
        node "$(nodepath "$REALCHILD")" "$(nodepath "$AGENTS_DIR")" "$CWD" "$MAIN" 2>&1)" || {
        fail "D/probe-ran-to-completion" "$o"
        return
    }
    rv() { printf '%s\n' "$o" | sed -n "s|^$1=||p" | head -1; }

    # Without a child that ran, every row below is vacuous rather than passing.
    if [ -n "$(rv singleton__error)$(rv empty__error)$(rv omitted__error)" ]; then
        fail "D/all-three-children-ran" "singleton=$(rv singleton__error) empty=$(rv empty__error) omitted=$(rv omitted__error)"
        return
    fi
    pass "D/all-three-children-ran"

    # D1 — the singleton scope. The socket the push step asks for arrives; the
    # two GitHub tokens and the workflow var the SAME entry declares do not.
    assert_eq "D1/singleton-scope-child-holds-exactly-the-socket" "SSH_AUTH_SOCK" "$(rv singleton__present)"
    assert_eq "D1/singleton-scope-value-copied-verbatim" "(all-verbatim)" "$(rv singleton__verbatim)"
    assert_eq "D1/singleton-scope-no-name-beyond-the-budget" "(none)" "$(rv singleton__extra)"
    assert_eq "D1/singleton-scope-no-credential-under-another-name" "(none)" "$(rv singleton__valueleak)"
    assert_eq "D1/singleton-scope-anchor-is-forced" "forced" "$(rv singleton__acd)"
    assert_eq "D1/singleton-scope-child-is-still-runnable" "present" "$(rv singleton__path)"

    # D2 — the empty scope. `git commit`, the rebase replay and every shell
    # preflight take it, and a repo's core.hooksPath can redirect all three into
    # repository-controlled code: the child must hold NO credential.
    assert_eq "D2/empty-scope-child-holds-no-declared-credential" "" "$(rv empty__present)"
    assert_eq "D2/empty-scope-no-name-beyond-the-budget" "(none)" "$(rv empty__extra)"
    assert_eq "D2/empty-scope-no-credential-under-another-name" "(none)" "$(rv empty__valueleak)"
    assert_eq "D2/empty-scope-anchor-is-forced" "forced" "$(rv empty__acd)"
    assert_eq "D2/empty-scope-child-is-still-runnable" "present" "$(rv empty__path)"

    # D3 — omitted scope: the unchanged pre-#1812 behaviour, kept as the
    # sanctioned allow direction so D1/D2 read as narrowing, not as breakage.
    assert_eq "D3/omitted-scope-child-holds-every-declared-name-present" \
        "ENFORCE_WORKTREE,GH_TOKEN,GITHUB_TOKEN,SSH_AUTH_SOCK" "$(rv omitted__present)"
    assert_eq "D3/omitted-scope-values-copied-verbatim" "(all-verbatim)" "$(rv omitted__verbatim)"
    assert_eq "D3/omitted-scope-no-name-beyond-the-budget" "(none)" "$(rv omitted__extra)"
    assert_eq "D3/omitted-scope-leaks-only-the-undeclared-secret-nowhere" "(none)" "$(rv omitted__valueleak)"

    # D4 — the undeclared parent secret reaches no child under ANY scope: the
    # entry's declaration stays the ceiling that envScope narrows within.
    assert_eq "D4/undeclared-secret-absent-under-the-singleton-scope" \
        "SSH_AUTH_SOCK" "$(rv singleton__present)"
    assert_eq "D4/undeclared-secret-absent-under-the-full-set" \
        "ENFORCE_WORKTREE,GH_TOKEN,GITHUB_TOKEN,SSH_AUTH_SOCK" "$(rv omitted__present)"
    assert_eq "D4/env-scope-cannot-admit-an-undeclared-name" "" "$(rv undeclared_scope__present)"

    # D5 — reject path: a string where an array belongs must throw rather than
    # read as "no narrowing intended" and hand the child everything.
    assert_eq "D5/string-env-scope-is-refused" "threw" "$(rv string_scope)"

    # SKIPPED: a child whose own transport re-execs and re-widens the env.
    # Because: spawn.js hands the env to spawnSync once and has no re-exec path.
    # L3 gap: a real `git push` whose ssh transport re-execs (core.sshCommand,
    # ProxyCommand) is covered by tests/TL3-worker-dispatch-ssh-transport.sh.
}
