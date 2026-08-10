# Part of tests/feature-1643-worker-dispatch-script-anchor.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# Group K: the child env as a REAL CHILD PROCESS sees it.
#
# Every other env group in this suite calls spawnMod.buildEnv() directly and
# asserts on the object it returns. That leaves one seam entirely unmeasured: the
# WIRING between buildEnv and spawnSync. If run() ever regressed from
#   env: buildEnv(entry, anchors, opts.extraEnv)
# to
#   env: process.env
# (or dropped the `env` key altogether, which makes spawnSync inherit the parent
# env wholesale), every buildEnv assertion in groups G–J would still be green
# while the dispatched child — including `gh`, and including tests/run-all.sh read
# from the branch under review — silently received the operator's entire
# environment: credentials, tokens, everything.
#
# So this group asserts nothing about buildEnv's return value. It plants an
# obviously-synthetic variable in the PARENT of a real dispatch, runs a real
# child process through spawnMod.run(), and asks the CHILD ITSELF which names it
# can see.
#
# Three arms, because a one-arm version could hide behind a special case:
#   real-test-runner  the unmodified registry entry `test-runner`, dispatched the
#                     way the dispatcher really dispatches it: command `bash`,
#                     family-worktree-anchored script tests/run-all.sh.
#   synth-plain       a synthetic entry with an EMPTY envPassthrough, command
#                     `node`. Same expectation as the real arm.
#   synth-declared    the same synthetic entry with the sentinel DECLARED in its
#                     envPassthrough. The child must now SEE it.
#
# The third arm is what makes the first two conclusive. Absence in a child can
# mean "the allowlist filtered it" or "the probe never managed to read its env at
# all"; only a paired arm where the identical probe DOES see the identical name
# distinguishes those. APPDATA — already allowlisted — is the second, per-arm
# positive control, asserted byte-identical rather than merely present.
#
# There is deliberately no skip path anywhere in this group. A probe that cannot
# run is a FAIL: an unproven isolation claim is worth exactly as much as a
# disproven one.

# ---------------------------------------------------------------------------
# Sentinels. Both are undeclared by construction: not on CHILD_ENV_ALLOWLIST and
# not in any worker's envPassthrough (the driver asserts both facts against the
# live registry rather than trusting this comment). Values are inert text and are
# never sent anywhere — no `gh`, no network, no credential shape.
# ---------------------------------------------------------------------------
K_SENTINEL_NAME="WORKER_DISPATCH_LEAK_SENTINEL_1719"
K_SENTINEL_VALUE="leak-sentinel-1719-must-not-reach-any-child"
K_SENTINEL_B_NAME="WORKER_DISPATCH_LEAK_SENTINEL_1719_B"
K_SENTINEL_B_VALUE="second-undeclared-name-1719"

# ---------------------------------------------------------------------------
# Fixtures: an independent family (main + linked worktree) so that group F's
# MAIN-SUITE / LINKED-SUITE discriminator files stay untouched. tests/run-all.sh
# here is a thin bash wrapper that execs the node child probe, which is exactly
# the shape of the real thing: a family-worktree-anchored script, run by `bash`.
# ---------------------------------------------------------------------------
KMAIN_RAW="$TMPD/childenv-main"; mk_repo "$KMAIN_RAW"
mkdir -p "$KMAIN_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: CHILDENV-MAIN 0 passed"\nexit 0\n' > "$KMAIN_RAW/tests/run-all.sh"
chmod +x "$KMAIN_RAW/tests/run-all.sh"
git -C "$KMAIN_RAW" add tests/run-all.sh 2>/dev/null
git -C "$KMAIN_RAW" commit -q --no-verify -m "add run-all" 2>/dev/null

KLINKED_RAW="$TMPD/childenv-linked"
git -C "$KMAIN_RAW" worktree add -q -b feature/child-env-probe "$KLINKED_RAW" >/dev/null 2>&1

# The child probe itself: a node program that reports what IT can see. It is
# handed the expected values as argv, so every comparison it makes is against
# bytes that did not travel through the env it is measuring.
K_CHILD_JS_RAW="$TMPD/child-env-probe.js"
cat > "$K_CHILD_JS_RAW" <<'CHILDJS'
const [expAppdata, sName, sValue, sBName] = process.argv.slice(2);
const o = (k, v) => process.stdout.write("child_" + k + "=" + String(v) + "\n");
// Proof of life first: every other line below is only meaningful if this one
// arrived, and a missing `alive` row is a FAIL rather than a silent zero.
o("alive", 1);
o("sentinel_seen", typeof process.env[sName] === "string" ? 1 : 0);
o("sentinel_value_match", process.env[sName] === sValue ? 1 : 0);
o("sentinel_b_seen", typeof process.env[sBName] === "string" ? 1 : 0);
o("appdata_seen", typeof process.env.APPDATA === "string" ? 1 : 0);
o("appdata_match", process.env.APPDATA === expAppdata ? 1 : 0);
o("acd_seen", typeof process.env.AGENTS_CONFIG_DIR === "string" ? 1 : 0);
// Non-vacuity: a child handed a literally empty env would report every name as
// absent and pass the leak assertion for the wrong reason.
o("env_key_count", Object.keys(process.env).length);
process.exit(0);
CHILDJS

# The bash wrapper that the real `test-runner` arm resolves through its
# family-worktree script anchor. `$@` is forwarded so the wrapper carries no
# knowledge of the expected values — the driver passes them as dispatch args.
printf '#!/usr/bin/env bash\nexec node "%s" "$@"\n' "$(nodepath "$K_CHILD_JS_RAW")" \
    > "$KLINKED_RAW/tests/run-all.sh"
chmod +x "$KLINKED_RAW/tests/run-all.sh"

KMAIN="$(nodepath "$KMAIN_RAW")"
KLINKED="$(nodepath "$KLINKED_RAW")"
K_CHILD_JS="$(nodepath "$K_CHILD_JS_RAW")"

# ---------------------------------------------------------------------------
# The parent-side driver: resolves anchors, states the registry preconditions,
# then dispatches the three arms through the REAL spawnMod.run() and re-emits
# each child's own report under an arm prefix.
# ---------------------------------------------------------------------------
K_DRIVER="$TMPD/child-env-driver.js"
cat > "$K_DRIVER" <<'DRIVERJS'
const path = require("path");
const [agentsDir, mainRoot, familyCwd, childJs, expAppdata, sName, sValue, sBName] =
  process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const workers = registry.workers || registry.WORKERS || {};

const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) { out("anchors_error", anchors.error); process.exit(9); }

// Preconditions, all measured against the live registry and the live parent env.
// Without them the "child cannot see it" rows would be satisfied by a sentinel
// that was never planted, or by a name that is legitimately filtered anyway.
out("parent_sentinel_planted", process.env[sName] === sValue ? 1 : 0);
out("parent_sentinel_b_planted", typeof process.env[sBName] === "string" ? 1 : 0);
out("parent_appdata_planted", process.env.APPDATA === expAppdata ? 1 : 0);
// The parent deliberately does NOT hold AGENTS_CONFIG_DIR, which turns the
// child's acd_seen row into a real discriminator: the only way the child can
// hold it is buildEnv setting it from the resolved anchor. A bare `env:
// process.env` regression cannot produce it out of nothing.
out("parent_acd_absent", typeof process.env.AGENTS_CONFIG_DIR === "string" ? 0 : 1);
out("sentinel_not_allowlisted", registry.CHILD_ENV_ALLOWLIST.includes(sName) ? 0 : 1);
out("sentinel_b_not_allowlisted", registry.CHILD_ENV_ALLOWLIST.includes(sBName) ? 0 : 1);
out("appdata_allowlisted", registry.CHILD_ENV_ALLOWLIST.includes("APPDATA") ? 1 : 0);
const declaredBy = Object.keys(workers).filter((w) => {
  const p = workers[w].envPassthrough || [];
  return p.includes(sName) || p.includes(sBName);
});
out("sentinel_declared_by", declaredBy.join(","));

const CHILD_ARGS = [expAppdata, sName, sValue, sBName];
// Synthetic entries differ from each other in ONE field — envPassthrough — so the
// third arm isolates the allowlist as the cause of the absence in the second.
const synth = (name, passthrough) => ({
  name,
  envPassthrough: passthrough,
  binaries: { external: ["node"], scripts: {} },
});

const arms = [
  {
    arm: "real-test-runner",
    entry: workers["test-runner"],
    opts: { command: "bash", script: "runAll", args: CHILD_ARGS },
  },
  {
    arm: "synth-plain",
    entry: synth("probe-plain", []),
    opts: { command: "node", args: [childJs].concat(CHILD_ARGS) },
  },
  {
    arm: "synth-declared",
    entry: synth("probe-declared", [sName]),
    opts: { command: "node", args: [childJs].concat(CHILD_ARGS) },
  },
];

for (const a of arms) {
  let r = null;
  try {
    r = spawnMod.run(a.entry, Object.assign({ anchors, cwd: familyCwd, timeoutMs: 60000 }, a.opts));
  } catch (e) {
    out(a.arm + "__run_error", String((e && e.message) || e));
    continue;
  }
  out(a.arm + "__status", r.status);
  out(a.arm + "__spawn_error", r.spawnError === null ? "none" : r.spawnError);
  out(a.arm + "__stderr", String(r.stderr).replace(/[\r\n]+/g, " ").slice(0, 300));
  for (const line of String(r.stdout).split(/\r?\n/)) {
    if (line.indexOf("child_") !== 0) continue;
    const i = line.indexOf("=");
    if (i <= 0) continue;
    out(a.arm + "__" + line.slice(0, i), line.slice(i + 1));
  }
}
process.exit(0);
DRIVERJS

# APPDATA is planted at a real, empty fixture directory for the same reason group
# G plants one: buildEnv only copies strings, but git runs in the driver process.
K_APPDATA_RAW="$TMPD/childenv-appdata"; mkdir -p "$K_APPDATA_RAW"
K_APPDATA="$(nodepath "$K_APPDATA_RAW")"

probe_child_env() {
    PROBE_OUT="$(run_with_timeout 90 env \
        -u AGENTS_CONFIG_DIR -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "APPDATA=$K_APPDATA" \
        "$K_SENTINEL_NAME=$K_SENTINEL_VALUE" "$K_SENTINEL_B_NAME=$K_SENTINEL_B_VALUE" \
        node "$K_DRIVER" "$(nodepath "$AGENTS_DIR")" "$KMAIN" "$KLINKED" "$K_CHILD_JS" \
        "$K_APPDATA" "$K_SENTINEL_NAME" "$K_SENTINEL_VALUE" "$K_SENTINEL_B_NAME" 2>&1)" || return 1
    return 0
}

# Every assert this group owns, by name. Used ONLY to turn an unrunnable probe
# into the full set of FAILs it deserves — the group must never trade an
# unproven isolation claim for a quiet skip or a single summary line.
K_ASSERT_NAMES="
child-env/parent-sentinel-planted
child-env/parent-sentinel-b-planted
child-env/parent-appdata-planted
child-env/parent-lacks-agents-config-dir
child-env/sentinel-is-not-allowlisted
child-env/sentinel-b-is-not-allowlisted
child-env/appdata-is-allowlisted
child-env/sentinel-declared-by-no-worker
child-env/real-test-runner/child-ran
child-env/real-test-runner/child-exit-0
child-env/real-test-runner/no-spawn-error
child-env/real-test-runner/sentinel-not-visible
child-env/real-test-runner/sentinel-b-not-visible
child-env/real-test-runner/appdata-visible
child-env/real-test-runner/appdata-byte-identical
child-env/real-test-runner/acd-set
child-env/real-test-runner/env-non-vacuous
child-env/synth-plain/child-ran
child-env/synth-plain/child-exit-0
child-env/synth-plain/no-spawn-error
child-env/synth-plain/sentinel-not-visible
child-env/synth-plain/sentinel-b-not-visible
child-env/synth-plain/appdata-visible
child-env/synth-plain/appdata-byte-identical
child-env/synth-plain/acd-set
child-env/synth-plain/env-non-vacuous
child-env/synth-declared/child-ran
child-env/synth-declared/child-exit-0
child-env/synth-declared/sentinel-visible
child-env/synth-declared/sentinel-byte-identical
child-env/synth-declared/sentinel-b-still-not-visible
child-env/synth-declared/appdata-byte-identical
"

k_fail_all() {
    local n
    for n in $K_ASSERT_NAMES; do fail "$n — $1"; done
}

# ===========================================================================
# Group K — subprocess wiring and secret non-leakage, asserted from the child
# ===========================================================================
group_k() {
    local arm
    if [ ! -f "$SPAWN_JS" ]; then
        k_fail_all "implementation missing: bin/worker-dispatch/spawn.js"
        return
    fi
    if ! probe_child_env; then
        k_fail_all "child-env probe failed: $(printf '%s' "$PROBE_OUT" | tr '\n' ' ')"
        return
    fi

    # --- Preconditions -----------------------------------------------------
    assert_eq "child-env/parent-sentinel-planted" "1" "$(pv parent_sentinel_planted)"
    assert_eq "child-env/parent-sentinel-b-planted" "1" "$(pv parent_sentinel_b_planted)"
    assert_eq "child-env/parent-appdata-planted" "1" "$(pv parent_appdata_planted)"
    # The parent must NOT hold AGENTS_CONFIG_DIR, or the per-arm acd-set row
    # below would be satisfied by plain inheritance instead of by buildEnv.
    assert_eq "child-env/parent-lacks-agents-config-dir" "1" "$(pv parent_acd_absent)"
    # The sentinels must be undeclared for the leak assertion to mean anything;
    # if someone ever adds either name to the allowlist, this says so instead of
    # letting the leak rows flip to green for the wrong reason.
    assert_eq "child-env/sentinel-is-not-allowlisted" "1" "$(pv sentinel_not_allowlisted)"
    assert_eq "child-env/sentinel-b-is-not-allowlisted" "1" "$(pv sentinel_b_not_allowlisted)"
    assert_eq "child-env/appdata-is-allowlisted" "1" "$(pv appdata_allowlisted)"
    assert_eq "child-env/sentinel-declared-by-no-worker" "" "$(pv sentinel_declared_by)"

    # --- The two arms that must NOT see the sentinel -----------------------
    for arm in real-test-runner synth-plain; do
        # The child really ran. Without this row, "did not see the sentinel"
        # would be indistinguishable from "never started".
        assert_eq "child-env/$arm/child-ran" "1" "$(pv "${arm}__child_alive")"
        assert_eq "child-env/$arm/child-exit-0" "0" "$(pv "${arm}__status")"
        assert_eq "child-env/$arm/no-spawn-error" "none" "$(pv "${arm}__spawn_error")"
        # The claim: an undeclared parent variable is invisible to the child.
        # This is the row that goes red if run() ever passes process.env.
        assert_eq "child-env/$arm/sentinel-not-visible" "0" "$(pv "${arm}__child_sentinel_seen")"
        assert_eq "child-env/$arm/sentinel-b-not-visible" "0" "$(pv "${arm}__child_sentinel_b_seen")"
        # Paired positive control: the child's env is NOT simply empty — an
        # allowlisted name arrived, and arrived byte for byte.
        assert_eq "child-env/$arm/appdata-visible" "1" "$(pv "${arm}__child_appdata_seen")"
        assert_eq "child-env/$arm/appdata-byte-identical" "1" "$(pv "${arm}__child_appdata_match")"
        # AGENTS_CONFIG_DIR is set from the resolved anchor, never inherited. The
        # probe's parent has it unset (asserted above), so a child that holds it
        # proves the env was BUILT by buildEnv rather than inherited wholesale.
        assert_eq "child-env/$arm/acd-set" "1" "$(pv "${arm}__child_acd_seen")"
        if [ "$(pv "${arm}__child_env_key_count")" -ge 3 ] 2>/dev/null; then
            pass "child-env/$arm/env-non-vacuous"
        else
            fail "child-env/$arm/env-non-vacuous — child env key count=$(pv "${arm}__child_env_key_count")"
        fi
    done

    # --- The arm that MUST see it ------------------------------------------
    # Same probe, same parent, same dispatch path; the only difference is that
    # the entry declares the name. If this arm were red too, the absences above
    # would prove nothing about the allowlist.
    assert_eq "child-env/synth-declared/child-ran" "1" "$(pv "synth-declared__child_alive")"
    assert_eq "child-env/synth-declared/child-exit-0" "0" "$(pv "synth-declared__status")"
    assert_eq "child-env/synth-declared/sentinel-visible" "1" "$(pv "synth-declared__child_sentinel_seen")"
    assert_eq "child-env/synth-declared/sentinel-byte-identical" "1" "$(pv "synth-declared__child_sentinel_value_match")"
    # …and only the DECLARED name crosses: the second undeclared sentinel stays
    # out even for the entry that declared the first one.
    assert_eq "child-env/synth-declared/sentinel-b-still-not-visible" "0" "$(pv "synth-declared__child_sentinel_b_seen")"
    assert_eq "child-env/synth-declared/appdata-byte-identical" "1" "$(pv "synth-declared__child_appdata_match")"
}
