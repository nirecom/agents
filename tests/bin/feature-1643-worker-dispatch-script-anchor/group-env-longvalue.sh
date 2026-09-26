# Part of tests/feature-1643-worker-dispatch-script-anchor.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# Group L: the two VALUE-LENGTH extremes across a REAL subprocess boundary
# (#1719 review C4).
#
# Group I already asserts byte-exact preservation of a single-character and an
# 8192-character config-path value — but it asserts it on buildEnv's RETURN
# VALUE, an in-process JavaScript object where a length limit cannot possibly
# bite. Length is precisely the property that stops being free once the value
# has to cross into a real child: on Windows a single environment variable is
# capped near 32767 characters and the child's whole environment block draws on
# the same budget, so an over-long value is truncated or the spawn fails
# outright, and neither outcome is visible one layer up.
#
# So this group plants each extreme in the PARENT of a real spawnMod.run() call
# — the same vehicle group K uses — and asks the CHILD what it received. The
# child never has the expected bytes handed to it through the env it is
# measuring: it is given a generating SPEC on argv (`literal:X` for the short
# arm, `rule:<prefix>:<length>` for the long one) and rebuilds the expectation
# itself, so a truncated value cannot match by comparing a truncated thing to
# itself — and the rebuilt expectation's own length is asserted too.
#
# 8192 is chosen the same way in both places, and the probe's comment is the
# reason: large enough that truncation would be obvious, far enough under the
# platform cap that a pass means "the dispatcher preserved it", not "the OS
# happened to have room today".
#
# APPDATA is the vehicle for the same reason as group I: it is ALREADY on
# CHILD_ENV_ALLOWLIST, so these rows stay green across the #1719 fix and leave
# group G as the single place the membership signal lives.
#
# There is no skip path. A probe that cannot run is a FAIL — an unproven
# preservation claim is worth exactly as much as a disproven one.

# The generating rule, stated once. The driver builds the value from it and the
# child rebuilds the expectation from it independently.
L_LONG_PREFIX='C:\gh-cfg-'
L_LONG_LEN=8192

# ---------------------------------------------------------------------------
# Child probe: reports what IT received, plus its own reconstruction check.
# ---------------------------------------------------------------------------
L_CHILD_JS_RAW="$TMPD/longvalue-child.js"
cat > "$L_CHILD_JS_RAW" <<'LCHILDJS'
const [armName, spec] = process.argv.slice(2);
const o = (k, v) => process.stdout.write("child_" + k + "=" + String(v) + "\n");
// The value is rebuilt from a SPEC carried on argv — `literal:<bytes>` for the
// short arm, `rule:<prefix>:<total-length>` for the long one, whose expansion
// would be pointless to ship as an 8192-character argument. Either way the
// expectation never travels through the environment under measurement, so a
// truncated value has nothing to compare itself favourably against.
function build(s) {
  if (s.indexOf("literal:") === 0) return s.slice("literal:".length);
  const rest = s.slice("rule:".length);
  const i = rest.lastIndexOf(":");
  const prefix = rest.slice(0, i);
  const len = Number(rest.slice(i + 1));
  return prefix + "d".repeat(len - prefix.length);
}
// Proof of life first: every row below is meaningless without it, and a missing
// `alive` row is read as a FAIL by the driver rather than as a quiet zero.
o("alive", 1);
const got = process.env.APPDATA;
o("seen", typeof got === "string" ? 1 : 0);
o("len", typeof got === "string" ? got.length : -1);
o("exact", got === build(spec) ? 1 : 0);
o("spec_len", build(spec).length);
// Non-vacuity: a child handed an empty env would report absence for every name
// and could not distinguish "filtered" from "never started".
o("env_key_count", Object.keys(process.env).length);
o("arm", armName);
process.exit(0);
LCHILDJS
L_CHILD_JS="$(nodepath "$L_CHILD_JS_RAW")"

# ---------------------------------------------------------------------------
# Parent-side driver. Sets the value into its OWN process.env (not through the
# shell) for the same reason group I does: a shell -> OS-env -> node hop handles
# lengths differently per platform and would measure that hop instead of the
# dispatcher. The hop under test here is buildEnv -> spawnSync -> child.
# ---------------------------------------------------------------------------
L_DRIVER="$TMPD/longvalue-driver.js"
cat > "$L_DRIVER" <<'LDRIVERJS'
const path = require("path");
const [agentsDir, mainRoot, familyCwd, childJs, prefix, longLenRaw] = process.argv.slice(2);
const spawnMod = require(path.join(agentsDir, "bin/worker-dispatch/spawn.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const longLen = Number(longLenRaw);

const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) { out("anchors_error", anchors.error); process.exit(9); }

// Precondition: the vehicle really is allowlisted, so an absent value in the
// child would mean truncation or a wiring defect, never "correctly filtered".
out("appdata_allowlisted", registry.CHILD_ENV_ALLOWLIST.includes("APPDATA") ? 1 : 0);

// envPassthrough is empty on purpose: nothing but the allowlist can carry the
// value, so the arms measure the allowlist path and only that.
const entry = {
  name: "probe-longvalue",
  envPassthrough: [],
  binaries: { external: ["node"], scripts: {} },
};

// The SAME spec string drives the planted value here and the expectation the
// child rebuilds, so the two can never drift apart into a self-satisfying
// comparison of a truncated value with itself.
function build(s) {
  if (s.indexOf("literal:") === 0) return s.slice("literal:".length);
  const rest = s.slice("rule:".length);
  const i = rest.lastIndexOf(":");
  const p = rest.slice(0, i);
  const len = Number(rest.slice(i + 1));
  return p + "d".repeat(len - p.length);
}

const arms = [
  { arm: "single-char", spec: "literal:X" },
  { arm: "very-long-path", spec: "rule:" + prefix + ":" + longLen },
];

for (const a of arms) {
  a.value = build(a.spec);
  process.env.APPDATA = a.value;
  // Round-trip through the real parent env first: if the assignment itself did
  // not survive, every child row below would be measuring the wrong bytes.
  out(a.arm + "__parent_intact", process.env.APPDATA === a.value ? 1 : 0);
  out(a.arm + "__parent_len", process.env.APPDATA.length);
  // The buildEnv layer, restated here only so a child mismatch can be attributed
  // to the subprocess boundary rather than left ambiguous.
  const built = spawnMod.buildEnv(entry, anchors, null);
  out(a.arm + "__built_exact", built.APPDATA === a.value ? 1 : 0);
  let r = null;
  try {
    r = spawnMod.run(entry, {
      anchors, command: "node", args: [childJs, a.arm, a.spec],
      cwd: familyCwd, timeoutMs: 60000,
    });
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
LDRIVERJS

probe_longvalue() {
    PROBE_OUT="$(run_with_timeout 90 env \
        -u AGENTS_CONFIG_DIR -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$L_DRIVER" "$(nodepath "$AGENTS_DIR")" "$MAIN" "$LINKED" "$L_CHILD_JS" \
        "$L_LONG_PREFIX" "$L_LONG_LEN" 2>&1)" || return 1
    return 0
}

# Every assert this group owns, by name — used ONLY to turn an unrunnable probe
# into the full set of FAILs it deserves, never into a skip.
L_ASSERT_NAMES="
env-longvalue/appdata-is-allowlisted
env-longvalue/single-char/parent-value-intact
env-longvalue/single-char/buildenv-byte-identical
env-longvalue/single-char/child-ran
env-longvalue/single-char/child-exit-0
env-longvalue/single-char/no-spawn-error
env-longvalue/single-char/child-saw-the-value
env-longvalue/single-char/child-length-preserved
env-longvalue/single-char/child-expectation-full-length
env-longvalue/single-char/child-byte-identical
env-longvalue/single-char/child-env-non-vacuous
env-longvalue/very-long-path/parent-value-intact
env-longvalue/very-long-path/buildenv-byte-identical
env-longvalue/very-long-path/child-ran
env-longvalue/very-long-path/child-exit-0
env-longvalue/very-long-path/no-spawn-error
env-longvalue/very-long-path/child-saw-the-value
env-longvalue/very-long-path/child-length-preserved
env-longvalue/very-long-path/child-expectation-full-length
env-longvalue/very-long-path/child-byte-identical
env-longvalue/very-long-path/child-env-non-vacuous
"

l_fail_all() {
    local n
    for n in $L_ASSERT_NAMES; do fail "$n — $1"; done
}

# ===========================================================================
# Group L — value-length extremes across the real subprocess boundary
# ===========================================================================
group_l() {
    local arm want_len
    if [ ! -f "$SPAWN_JS" ]; then
        l_fail_all "implementation missing: bin/worker-dispatch/spawn.js"
        return
    fi
    if ! probe_longvalue; then
        l_fail_all "longvalue probe failed: $(printf '%s' "$PROBE_OUT" | tr '\n' ' ')"
        return
    fi

    assert_eq "env-longvalue/appdata-is-allowlisted" "1" "$(pv appdata_allowlisted)"

    for arm in single-char very-long-path; do
        if [ "$arm" = "single-char" ]; then want_len=1; else want_len="$L_LONG_LEN"; fi
        # The parent really held the value at its full length, so a shorter
        # value in the child is truncation and not a mis-planted fixture.
        assert_eq "env-longvalue/$arm/parent-value-intact" "1" "$(pv "${arm}__parent_intact")"
        assert_eq "env-longvalue/$arm/buildenv-byte-identical" "1" "$(pv "${arm}__built_exact")"
        # The child really ran: without this, "the value did not arrive" and
        # "nothing ever started" would look identical.
        assert_eq "env-longvalue/$arm/child-ran" "1" "$(pv "${arm}__child_alive")"
        assert_eq "env-longvalue/$arm/child-exit-0" "0" "$(pv "${arm}__status")"
        assert_eq "env-longvalue/$arm/no-spawn-error" "none" "$(pv "${arm}__spawn_error")"
        assert_eq "env-longvalue/$arm/child-saw-the-value" "1" "$(pv "${arm}__child_seen")"
        # Length is called out separately from identity so a truncation reports
        # the length it actually got instead of a bare "not identical".
        assert_eq "env-longvalue/$arm/child-length-preserved" "$want_len" "$(pv "${arm}__child_len")"
        # Non-vacuity for the identity row: the child's INDEPENDENTLY rebuilt
        # expectation is itself the full length, so a match cannot be two
        # equally-truncated strings agreeing with each other.
        assert_eq "env-longvalue/$arm/child-expectation-full-length" "$want_len" "$(pv "${arm}__child_spec_len")"
        assert_eq "env-longvalue/$arm/child-byte-identical" "1" "$(pv "${arm}__child_exact")"
        if [ "$(pv "${arm}__child_env_key_count")" -ge 3 ] 2>/dev/null; then
            pass "env-longvalue/$arm/child-env-non-vacuous"
        else
            fail "env-longvalue/$arm/child-env-non-vacuous — child env key count=$(pv "${arm}__child_env_key_count")"
        fi
    done
}
