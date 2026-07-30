#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-canary-no-side-effect.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/registry.js, bin/worker-dispatch/workers/test-runner.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, canary, side-effect, fsguard, write-scope, containment, security, TL2, scope:issue-specific
#
# Issue #1643 Stage 1 canary condition, made measurable.
#
# test-runner is declared side-effect-free: registry writeScopes = {} (empty),
# so fsguard.js must refuse EVERY write. This test dispatches it against a
# throwaway repo and proves that, before and after:
#   (a) `git status --porcelain` is unchanged in the target repo
#   (b) `git rev-parse HEAD` is unchanged in the target repo
#   (c) no file appears under PLANS_DIR other than the payload written by the caller
#   (d) an ADJACENT repository is byte-for-byte unchanged (the C2 cross-repo case)
#
# The whole-tree fingerprint (path + size + sha256, sorted) is what makes (a)/(b)
# non-vacuous: status/HEAD alone would miss an ignored or untracked file drop.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - Writes performed by the *tests being run* (tests/run-all.sh is stubbed here).
#     Real suite side effects are outside the dispatcher's containment boundary by
#     design; TL3-worker-dispatch-run-tests.sh runs the real suite subset instead.
#   - Writes to paths outside both fixture repos (e.g. a real $HOME dotfile).
# Closest-to-action mitigation: bin/check-verification-gate.sh category
# hook-registration fires at WORKFLOW_USER_VERIFIED preflight.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_CANARY_INNER:-}" ]; then
    _WD1643_CANARY_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
FSGUARD_JS="$AGENTS_DIR/bin/worker-dispatch/fsguard.js"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
impl_missing() {
    if [ -e "$2" ]; then return 1; fi
    fail "$1 — implementation missing: $3"; return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-canary-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Whole-tree fingerprint: sorted "<relpath> <size> <sha256>" per file, .git excluded
# (git internals churn on plumbing reads; status/HEAD cover the tracked state).
# ---------------------------------------------------------------------------
FP_JS="$TMPD/fingerprint.js"
cat > "$FP_JS" <<'FPJS'
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const root = process.argv[2];
const out = [];
(function walk(d) {
  let ents = [];
  try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
  for (const e of ents.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (e.name === ".git") continue;
    const p = path.join(d, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    if (!e.isFile()) { out.push(path.relative(root, p).replace(/\\/g, "/") + " nonfile"); continue; }
    let buf;
    try { buf = fs.readFileSync(p); } catch { out.push(path.relative(root, p).replace(/\\/g, "/") + " unreadable"); continue; }
    out.push(path.relative(root, p).replace(/\\/g, "/") + " " + buf.length + " " + crypto.createHash("sha256").update(buf).digest("hex"));
  }
})(root);
process.stdout.write(out.sort().join("\n"));
FPJS

fingerprint() { node "$FP_JS" "$(nodepath "$1")" 2>&1; }

mk_repo() {
    local d="$1"
    mkdir -p "$d/src"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "canary@example.com"
    git -C "$d" config user.name "Canary"
    git -C "$d" config core.hooksPath /dev/null
    printf 'hello\n' > "$d/README.md"
    printf 'x\n' > "$d/src/a.txt"
    printf 'ignored\n' > "$d/.gitignore"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -q --no-verify -m init >/dev/null 2>&1
    printf 'untracked\n' > "$d/untracked.txt"
}

TARGET_RAW="$TMPD/target";  mk_repo "$TARGET_RAW"
ADJ_RAW="$TMPD/adjacent";   mk_repo "$ADJ_RAW"
PLANS_RAW="$TMPD/plans";    mkdir -p "$PLANS_RAW"

mkdir -p "$TARGET_RAW/tests"
cat > "$TARGET_RAW/tests/run-all.sh" <<'RASTUB'
#!/usr/bin/env bash
echo "Results: PASS=2  FAIL=0  SKIP=0"
exit 0
RASTUB
chmod +x "$TARGET_RAW/tests/run-all.sh"
git -C "$TARGET_RAW" add -A >/dev/null 2>&1
git -C "$TARGET_RAW" commit -q --no-verify -m stub >/dev/null 2>&1

TARGET="$(nodepath "$TARGET_RAW")"
ADJ="$(nodepath "$ADJ_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

PAYLOAD_FILE="$PLANS_RAW/canary-worker-test-runner.json"
printf '{"test_args":[],"cwd":"%s","timeout_seconds":60}' "$TARGET" > "$PAYLOAD_FILE"

plans_listing() { (cd "$PLANS_RAW" && find . -type f | LC_ALL=C sort); }

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
T_STATUS_BEFORE="$(git -C "$TARGET_RAW" status --porcelain)"
T_HEAD_BEFORE="$(git -C "$TARGET_RAW" rev-parse HEAD)"
T_FP_BEFORE="$(fingerprint "$TARGET_RAW")"
A_STATUS_BEFORE="$(git -C "$ADJ_RAW" status --porcelain)"
A_HEAD_BEFORE="$(git -C "$ADJ_RAW" rev-parse HEAD)"
A_FP_BEFORE="$(fingerprint "$ADJ_RAW")"
P_LIST_BEFORE="$(plans_listing)"

# ===========================================================================
# Group 0 — false-green fence: the comparator must SEE a change.
# Without this, "unchanged" could just mean the fingerprint is always equal.
# ===========================================================================
group_comparator_selftest() {
    local canary="$TMPD/canary-probe"
    mk_repo "$canary"
    local before after
    before="$(fingerprint "$canary")"
    assert_eq "comparator/stable-when-untouched" "$before" "$(fingerprint "$canary")"
    printf 'sneaky\n' > "$canary/sneaky.txt"
    after="$(fingerprint "$canary")"
    if [ "$before" != "$after" ]; then pass "comparator/detects-new-file"
    else fail "comparator/detects-new-file — fingerprint blind to a new file"; fi
    printf 'mutated\n' > "$canary/README.md"
    if [ "$after" != "$(fingerprint "$canary")" ]; then pass "comparator/detects-content-change"
    else fail "comparator/detects-content-change — fingerprint blind to a content edit"; fi
    rm -rf "$canary"
}

# ===========================================================================
# Group 1 — dispatch test-runner, then assert nothing moved
# ===========================================================================
group_canary_dispatch() {
    if impl_missing "canary/dispatch-runs" "$DISPATCH_JS" "bin/worker-dispatch.js"; then
        fail "canary/target-status-unchanged — implementation missing: bin/worker-dispatch.js"
        fail "canary/target-head-unchanged — implementation missing: bin/worker-dispatch.js"
        fail "canary/target-tree-unchanged — implementation missing: bin/worker-dispatch.js"
        fail "canary/adjacent-status-unchanged — implementation missing: bin/worker-dispatch.js"
        fail "canary/adjacent-head-unchanged — implementation missing: bin/worker-dispatch.js"
        fail "canary/adjacent-tree-unchanged — implementation missing: bin/worker-dispatch.js"
        fail "canary/plans-dir-only-payload — implementation missing: bin/worker-dispatch.js"
        return
    fi
    local out rc=0
    out="$(cd "$TMPD" && run_with_timeout 120 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$DISPATCH_JS")" test-runner "$TARGET" "$(nodepath "$PAYLOAD_FILE")" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^status:'; then
        pass "canary/dispatch-runs"
    else
        fail "canary/dispatch-runs — rc=$rc out=$(printf '%.120s' "$out")"
    fi

    assert_eq "canary/target-status-unchanged"   "$T_STATUS_BEFORE" "$(git -C "$TARGET_RAW" status --porcelain)"
    assert_eq "canary/target-head-unchanged"     "$T_HEAD_BEFORE"   "$(git -C "$TARGET_RAW" rev-parse HEAD)"
    assert_eq "canary/target-tree-unchanged"     "$T_FP_BEFORE"     "$(fingerprint "$TARGET_RAW")"
    assert_eq "canary/adjacent-status-unchanged" "$A_STATUS_BEFORE" "$(git -C "$ADJ_RAW" status --porcelain)"
    assert_eq "canary/adjacent-head-unchanged"   "$A_HEAD_BEFORE"   "$(git -C "$ADJ_RAW" rev-parse HEAD)"
    assert_eq "canary/adjacent-tree-unchanged"   "$A_FP_BEFORE"     "$(fingerprint "$ADJ_RAW")"
    assert_eq "canary/plans-dir-only-payload"    "$P_LIST_BEFORE"   "$(plans_listing)"
}

# ===========================================================================
# Group 2 — declared containment: writeScopes for test-runner is the empty set
# ===========================================================================
group_write_scopes() {
    if impl_missing "writescopes/test-runner-empty" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then
        return
    fi
    local n
    n="$(node -e '
      const reg = require(process.argv[1]);
      const workers = reg.workers || reg;
      const w = workers["test-runner"];
      if (!w) { process.stdout.write("NO_ENTRY"); process.exit(0); }
      const s = w.writeScopes;
      if (s === undefined) { process.stdout.write("NO_FIELD"); process.exit(0); }
      process.stdout.write(String(Array.isArray(s) ? s.length : Object.keys(s).length));
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)"
    assert_eq "writescopes/test-runner-empty" "0" "$n"
}

# ===========================================================================
# Group 3 — enforced containment: fsguard rejects every path for test-runner
# (negative assertion on the protected resource, both directions)
# ===========================================================================
group_fsguard() {
    if impl_missing "fsguard/test-runner-rejects-all" "$FSGUARD_JS" "bin/worker-dispatch/fsguard.js"; then
        fail "fsguard/other-worker-allows-declared-scope — implementation missing: bin/worker-dispatch/fsguard.js"
        return
    fi
    local res
    res="$(node -e '
      const g = require(process.argv[1]);
      const check = g.assertWritable || g.checkWrite || g.isWritable || g.default;
      if (typeof check !== "function") { process.stdout.write("NO_EXPORT"); process.exit(0); }
      const [main, plans, adj] = [process.argv[2], process.argv[3], process.argv[4]];
      const paths = [main + "/x.txt", main + "/tests/x.txt", plans + "/x.json", adj + "/x.txt"];
      const allowed = [];
      for (const p of paths) {
        let ok = false;
        try { const r = check("test-runner", p, { mainRoot: main, plansDir: plans }); ok = (r === true || r === undefined); }
        catch { ok = false; }
        if (ok) allowed.push(p);
      }
      process.stdout.write(allowed.length ? "ALLOWED:" + allowed.join(",") : "NONE");
    ' "$(nodepath "$FSGUARD_JS")" "$TARGET" "$PLANS" "$ADJ" 2>&1)"
    assert_eq "fsguard/test-runner-rejects-all" "NONE" "$res"

    # Both-direction coverage: a worker that DOES declare plans-dir must be able
    # to write there, or "rejects all" would be trivially true for everyone.
    res="$(node -e '
      const g = require(process.argv[1]);
      const check = g.assertWritable || g.checkWrite || g.isWritable || g.default;
      if (typeof check !== "function") { process.stdout.write("NO_EXPORT"); process.exit(0); }
      let ok = false;
      try { const r = check("issue-reconcile", process.argv[3] + "/out.jsonl", { mainRoot: process.argv[2], plansDir: process.argv[3] }); ok = (r === true || r === undefined); }
      catch (e) { ok = false; }
      process.stdout.write(ok ? "ALLOWED" : "REJECTED");
    ' "$(nodepath "$FSGUARD_JS")" "$TARGET" "$PLANS" 2>&1)"
    assert_eq "fsguard/other-worker-allows-declared-scope" "ALLOWED" "$res"
}

group_comparator_selftest
group_canary_dispatch
group_write_scopes
group_fsguard

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
