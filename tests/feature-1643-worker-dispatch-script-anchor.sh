#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-script-anchor.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# Issue #1643 — the SCRIPT anchor vocabulary (which root a declared script
# resolves against), as distinct from the TRUST anchors covered by
# tests/feature-1643-worker-dispatch-anchor.sh (that suite asserts ACD/MAIN_ROOT
# cannot be moved by caller input; this one asserts which of those roots a given
# script is measured from, and that cwd is proven before it can act as a root).
#
# The regression this file fences:
#   tests/run-all.sh derives its test directory from BASH_SOURCE, not from the
#   process cwd. While `test-runner`'s runAll script carried anchor "main-root",
#   a dispatch from a LINKED worktree resolved main's copy of the script and ran
#   MAIN's suite while reporting success — i.e. it verified the wrong tree. The
#   fix moves that one script to the "family-worktree" anchor, which resolves
#   against the cwd only AFTER assertCwdInFamily has proven it a family member.
#
# Groups:
#   A registry — SCRIPT_ANCHORS is the exported vocabulary; no worker may declare
#     an anchor outside it; test-runner/runAll is family-worktree, NOT main-root.
#   B resolveScript — family-worktree resolves under the passed cwd, main-root
#     under main-root, and the two differ when cwd is a linked worktree.
#   C cwd containment — scriptExists returns null and run() throws for an
#     out-of-family cwd, and run() rejects the cwd BEFORE resolving the script.
#   D anchorRoot — an unknown anchor token, and family-worktree with no cwd,
#     both yield an unresolvable-anchor error (anchorRoot returned null).
#   E timeout_seconds bound — 21600 accepted, 21601 rejected, default still 120.
#   F end-to-end discriminator — a real dispatch whose linked worktree and main
#     worktree carry DIFFERENT tests/run-all.sh must run the linked one.
#   G buildEnv credential scope — GH_TOKEN / GITHUB_TOKEN reach issue-reconcile's
#     children and no other worker's, which is what makes the family-worktree
#     anchor of group A safe to keep.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real /run-tests skill invocation writing the payload and dispatching in
#     one turn against the operator's real agents checkout.
#   - Real linked worktrees behind NTFS junctions or bind mounts, where realpath
#     canonicalization of the family list behaves differently from temp fixtures.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
SPAWN_JS="$AGENTS_DIR/bin/worker-dispatch/spawn.js"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

# assert_ne <name> <unwanted> <got>  — negative assertion (regression fence)
assert_ne() {
    local name="$1" bad="$2" got="$3"
    if [ "$bad" != "$got" ]; then
        pass "$name"
    else
        fail "$name — got the forbidden value $(printf '%q' "$bad")"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

impl_missing() {
    if [ -f "$2" ]; then return 1; fi
    fail "$1 — implementation missing: $3"
    return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-scriptanchor-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo init > "$d/README.md"
    git -C "$d" add README.md 2>/dev/null
    git -C "$d" commit -q --no-verify -m initial 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixtures: a real main worktree + a real linked worktree (the family), an
# unrelated repo, and a plain directory. Main and linked carry tests/run-all.sh
# with DIFFERENT marker text — that difference is the whole discriminator.
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
mkdir -p "$MAIN_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: MAIN-SUITE 1 passed"\nexit 0\n' > "$MAIN_RAW/tests/run-all.sh"
chmod +x "$MAIN_RAW/tests/run-all.sh"
git -C "$MAIN_RAW" add tests/run-all.sh 2>/dev/null
git -C "$MAIN_RAW" commit -q --no-verify -m "add run-all" 2>/dev/null

LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/script-anchor-probe "$LINKED_RAW" >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "Results: LINKED-SUITE 1 passed"\nexit 0\n' > "$LINKED_RAW/tests/run-all.sh"
chmod +x "$LINKED_RAW/tests/run-all.sh"

ALT_RAW="$TMPD/altrepo"; mk_repo "$ALT_RAW"
mkdir -p "$ALT_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: ALT-SUITE"\nexit 0\n' > "$ALT_RAW/tests/run-all.sh"

OUTSIDE_RAW="$TMPD/outside"; mkdir -p "$OUTSIDE_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: OUTSIDE-SUITE"\nexit 0\n' > "$OUTSIDE_RAW/tests/run-all.sh"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
ALT="$(nodepath "$ALT_RAW")"
OUTSIDE="$(nodepath "$OUTSIDE_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

# ---------------------------------------------------------------------------
# Probe harness: one node process per mode, emitting `key=value` lines.
# ---------------------------------------------------------------------------
PROBE="$TMPD/probe.js"
cat > "$PROBE" <<'PROBEJS'
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

if (mode === "env") {
  // The two credentials are present in the PARENT env for this probe, which is
  // the only condition under which "does the child see them" is a real question.
  const TOKENS = ["GH_TOKEN", "GITHUB_TOKEN"];
  for (const t of TOKENS) out("parent_has_" + t, typeof process.env[t] === "string" ? 1 : 0);
  for (const wname of Object.keys(workers)) {
    const env = spawnMod.buildEnv(workers[wname], anchors, null);
    for (const t of TOKENS) {
      out(t + "__" + wname, Object.prototype.hasOwnProperty.call(env, t) ? 1 : 0);
    }
    // Non-vacuity per worker: an allowlisted var really did come through, so a
    // buildEnv that returned {} could not make the assertions above pass.
    out("PATHOK__" + wname, typeof (env.PATH || env.Path) === "string" ? 1 : 0);
    out("ACDOK__" + wname, env.AGENTS_CONFIG_DIR === anchors.acd ? 1 : 0);
  }
  // extraEnv is bounded by the same declaration: a worker cannot be handed a var
  // it never declared, so the passthrough list is the whole story.
  out("extra_undeclared_err", errOf(() => spawnMod.buildEnv(trEntry, anchors, { GH_TOKEN: "x" })));
  out("extra_declared_err", errOf(() =>
    spawnMod.buildEnv(workers["worktree-backup"], anchors, { WORKTREE_BASE_DIR: "x" })));
  process.exit(0);
}

process.stderr.write("UNKNOWN_MODE");
process.exit(8);
PROBEJS

PROBE_OUT=""
# probe <mode>
probe() {
    PROBE_OUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$1" "$MAIN" "$LINKED" "$OUTSIDE" "$ALT" 2>&1)" || return 1
    return 0
}

# Same probe, but with both GitHub credentials planted in the parent env. Values
# are obvious nonsense; they are never sent anywhere (no `gh` child runs here).
FAKE_GH_TOKEN="ghp-FAKE0000-not-a-real-token"
FAKE_GITHUB_TOKEN="github-pat-FAKE0000-not-a-real-token"
probe_with_tokens() {
    PROBE_OUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "GH_TOKEN=$FAKE_GH_TOKEN" "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        node "$PROBE" "$(nodepath "$AGENTS_DIR")" "$1" "$MAIN" "$LINKED" "$OUTSIDE" "$ALT" 2>&1)" || return 1
    return 0
}
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -1; }

# ===========================================================================
# Group A — SCRIPT_ANCHORS is the vocabulary, and no worker escapes it
# ===========================================================================
group_a() {
    if impl_missing "registry/script-anchors-exported" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then return; fi
    if ! probe registry; then
        fail "registry/script-anchors-exported — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "registry/script-anchors-exported" "array" "$(pv exported)"
    assert_eq "registry/script-anchors-exact-set" "acd,family-worktree,main-root" "$(pv sorted)"
    assert_eq "registry/script-anchors-count" "3" "$(pv count)"
    # Table-driven guard: a future worker declaring an unlisted anchor fails here
    # instead of failing silently at dispatch time with an unresolvable anchor.
    assert_eq "registry/no-unknown-anchor-declared" "" "$(pv unknown)"
    # Non-vacuity: the loop above must actually have scanned script declarations.
    if [ "$(pv scanned)" -ge 6 ] 2>/dev/null; then
        pass "registry/anchor-scan-non-vacuous"
    else
        fail "registry/anchor-scan-non-vacuous — scanned=$(pv scanned)"
    fi
    assert_eq "registry/test-runner-runall-family-anchored" "family-worktree" "$(pv tr_runall_anchor)"
    # Regression fence: "main-root" is the value that made a linked-worktree
    # dispatch run MAIN's tests/run-all.sh while reporting success.
    assert_ne "registry/test-runner-runall-not-main-root" "main-root" "$(pv tr_runall_anchor)"
}

# ===========================================================================
# Group B / D — resolveScript anchoring and anchorRoot's null verdict
# ===========================================================================
group_bd() {
    if impl_missing "resolve/family-anchored-under-cwd" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe resolve; then
        fail "resolve/family-anchored-under-cwd — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "resolve/family-anchored-under-cwd" "1" "$(pv fam_under_cwd)"
    assert_eq "resolve/main-anchored-under-mainroot" "1" "$(pv main_under_mainroot)"
    assert_eq "resolve/family-anchored-not-under-mainroot" "0" "$(pv fam_under_mainroot)"
    # The discriminator: same rel path, different anchor → different absolute
    # script. A test that passes under both anchors would be worthless here.
    assert_eq "resolve/anchors-yield-different-paths" "1" "$(pv differ)"
    case "$(pv bogus_err)" in
        *unresolvable\ anchor*) pass "anchorroot/unknown-token-unresolvable" ;;
        *) fail "anchorroot/unknown-token-unresolvable — got: $(pv bogus_err)" ;;
    esac
    case "$(pv fam_nocwd_err)" in
        *unresolvable\ anchor*) pass "anchorroot/family-without-cwd-unresolvable" ;;
        *) fail "anchorroot/family-without-cwd-unresolvable — got: $(pv fam_nocwd_err)" ;;
    esac
}

# ===========================================================================
# Group C — cwd must be a proven family member, and proven BEFORE resolution
# ===========================================================================
group_c() {
    if impl_missing "contain/exists-in-family" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe contain; then
        fail "contain/exists-in-family — probe failed: $PROBE_OUT"
        return
    fi
    # Positive counterparts first — without them the NULLs below prove nothing.
    assert_eq "contain/exists-in-family-linked" "PATH" "$(pv exists_family)"
    assert_eq "contain/exists-in-family-mainroot" "PATH" "$(pv exists_mainroot)"
    # Out-of-family cwds must not even be probeable for existence, although each
    # of these directories really does contain a tests/run-all.sh.
    assert_eq "contain/exists-outside-null" "NULL" "$(pv exists_outside)"
    assert_eq "contain/exists-alt-repo-null" "NULL" "$(pv exists_alt)"
    assert_eq "contain/exists-relative-null" "NULL" "$(pv exists_relative)"
    case "$(pv run_outside_err)" in
        *not\ a\ worktree\ of\ the\ main-root\ family*) pass "contain/run-rejects-outside" ;;
        *) fail "contain/run-rejects-outside — got: $(pv run_outside_err)" ;;
    esac
    case "$(pv run_alt_err)" in
        *not\ a\ worktree\ of\ the\ main-root\ family*) pass "contain/run-rejects-alt-repo" ;;
        *) fail "contain/run-rejects-alt-repo — got: $(pv run_alt_err)" ;;
    esac
    # Ordering: runAll is family-anchored, so if run() resolved the script before
    # validating cwd the failure would be an anchor/resolution error instead.
    case "$(pv run_outside_err)" in
        *anchor*|*could\ not\ be\ resolved*)
            fail "contain/cwd-validated-before-script-resolution — resolution error surfaced first: $(pv run_outside_err)" ;;
        *) pass "contain/cwd-validated-before-script-resolution" ;;
    esac
}

# ===========================================================================
# Group E — timeout_seconds bound (raised 3600 → 21600; default unchanged)
# ===========================================================================
group_e() {
    if impl_missing "timeout/max-21600-accepted" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then return; fi
    if ! probe timeout; then
        fail "timeout/max-21600-accepted — probe failed: $PROBE_OUT"
        return
    fi
    assert_eq "timeout/120-accepted" "1" "$(pv ok_120)"
    assert_eq "timeout/3600-accepted" "1" "$(pv ok_3600)"
    assert_eq "timeout/max-21600-accepted" "1" "$(pv ok_21600)"
    assert_eq "timeout/off-by-one-21601-rejected" "0" "$(pv ok_21601)"
    assert_eq "timeout/zero-rejected" "0" "$(pv ok_0)"
    assert_eq "timeout/default-still-120" "120" "$(pv default)"
}

# ===========================================================================
# Group F — end-to-end: a dispatch targeting the LINKED worktree must run the
# LINKED tests/run-all.sh. Main's copy prints MAIN-SUITE, the linked copy prints
# LINKED-SUITE; under the pre-fix main-root anchor this run reported success
# while executing MAIN's suite.
# ===========================================================================
group_f() {
    if impl_missing "e2e/runs-linked-suite" "$DISPATCH_JS" "bin/worker-dispatch.js"; then
        fail "e2e/does-not-run-main-suite — implementation missing: bin/worker-dispatch.js"
        fail "e2e/status-pass — implementation missing: bin/worker-dispatch.js"
        return
    fi
    local pfile out rc status
    pfile="$PLANS_RAW/tr-linked.json"
    printf '%s' "{\"cwd\":\"$LINKED\",\"test_args\":[],\"timeout_seconds\":60}" > "$pfile"
    rc=0
    out="$(cd "$MAIN_RAW" && run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$DISPATCH_JS" test-runner "$MAIN" "$(nodepath "$pfile")" 2>&1)" || rc=$?
    status="$(printf '%s\n' "$out" | sed -n 's/^status: *//p' | head -1)"
    assert_eq "e2e/exit0" "0" "$rc"
    assert_eq "e2e/status-pass" "pass" "$status"
    case "$out" in
        *LINKED-SUITE*) pass "e2e/runs-linked-suite" ;;
        *) fail "e2e/runs-linked-suite — output did not name the linked suite: $out" ;;
    esac
    case "$out" in
        *MAIN-SUITE*) fail "e2e/does-not-run-main-suite — main's tests/run-all.sh was executed instead" ;;
        *) pass "e2e/does-not-run-main-suite" ;;
    esac
}

# ===========================================================================
# Group G — buildEnv credential scope (behavioural counterpart of the static
# registry rows in tests/feature-1643-worker-dispatch-schema.sh Group E)
#
# GH_TOKEN / GITHUB_TOKEN used to sit in the global CHILD_ENV_ALLOWLIST, which
# spawn.js applies to every worker. Combined with Group A's family-worktree
# script anchor that put both credentials into the environment of
# tests/run-all.sh — a script read from the branch under review, i.e. code
# nobody has looked at yet. Moving them to issue-reconcile's envPassthrough is
# only a fix if buildEnv actually distinguishes the workers, so the assertion is
# made on the env buildEnv returns, per worker, with both vars really set in the
# parent process.
# ===========================================================================
group_g() {
    if impl_missing "env/token-reaches-issue-reconcile" "$SPAWN_JS" "bin/worker-dispatch/spawn.js"; then return; fi
    if ! probe_with_tokens env; then
        fail "env/token-reaches-issue-reconcile — probe failed: $PROBE_OUT"
        return
    fi
    # Precondition: without this the "0" rows below would be trivially true.
    assert_eq "env/parent-has-gh-token" "1" "$(pv parent_has_GH_TOKEN)"
    assert_eq "env/parent-has-github-token" "1" "$(pv parent_has_GITHUB_TOKEN)"

    local name tok want
    while IFS='|' read -r name want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        for tok in GH_TOKEN GITHUB_TOKEN; do
            assert_eq "env/$name/$tok" "$want" "$(pv "${tok}__${name}")"
        done
        # Per-worker non-vacuity: the env is populated, just not with credentials.
        assert_eq "env/$name/path-still-present" "1" "$(pv "PATHOK__${name}")"
        assert_eq "env/$name/acd-pinned-to-anchor" "1" "$(pv "ACDOK__${name}")"
    done <<'TABLE'
issue-reconcile   | 1
test-runner       | 0
worktree-copy     | 0
worktree-backup   | 0
doc-append        | 0
session-close-gate | 0
TABLE

    case "$(pv extra_undeclared_err)" in
        *does\ not\ declare\ the\ child\ env\ var*) pass "env/extra-undeclared-rejected" ;;
        *) fail "env/extra-undeclared-rejected — got: $(pv extra_undeclared_err)" ;;
    esac
    assert_eq "env/extra-declared-accepted" "NO_THROW" "$(pv extra_declared_err)"
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WD1643_SCRIPTANCHOR_INNER:-}" ]; then
        _WD1643_SCRIPTANCHOR_INNER=1 timeout 240 bash "$0" "$@"
        exit $?
    fi
fi

group_a
group_bd
group_c
group_e
group_f
group_g

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
