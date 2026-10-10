#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-anchor.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/anchor.js, hooks/lib/script-checkout-root.js
# Tags: worker-dispatch, anchor, trust-anchor, c2, security, TL1, scope:issue-specific
# TL3 gap (what this TL1 test does NOT catch):
#   - A real Bash tool call supplying tool_input.cwd (guard vs dispatcher cwds differ).
#   - Real script-checkout-root resolution across a symlinked ~/.claude checkout.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u
# Issue #1643 — C2 core: trust anchors must not be movable by caller input.
#   (a) cwd at an ALTERNATE repo leaves that repo untouched (no child, no write),
#   (b) a planted fake agents checkout in $AGENTS_MAIN_ROOT never becomes the
#       script checkout root; the family is the target's, whatever the cwd,
#   (c) argv[3] at a LINKED worktree exits 2 (git-common-dir check),
#   (d) argv[3] non-git / non-existent / relative exits 2,
#   (e) `process.cwd()` / `rev-parse --show-toplevel` never appear under
#       bin/worker-dispatch/** (regression fence for the design rule).

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"
ANCHOR_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/anchor.js"
WD_DIR="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch"

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-anchor-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# Every child (node, git) resolves its home and its workflow dirs under the temp
# root: resolveAnchors reads the plans dir and the state roots from this env.
mkdir -p "$TMPD/home" "$TMPD/plans" "$TMPD/wf"
export HOME="$TMPD/home"
USERPROFILE="$(nodepath "$TMPD/home")"; export USERPROFILE
PLANS_RAW="$TMPD/plans"
PLANS="$(nodepath "$PLANS_RAW")"
WF_PIN="$(nodepath "$TMPD/wf")"   # #2558: worker logs live under the workflow dir
export WORKFLOW_PLANS_DIR="$PLANS" WORKFLOW_STATE_DIR="$WF_PIN"

# The shared harness owns the case markers and the root decoy; it is sourced after
# the home pin so its decoy cache lands in the temp root. The reporters below
# replace its own, which take their arguments in another order.
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

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

# Byte-level snapshot of a directory tree (path + sha256 of every file).
snapshot() {
    (cd "$1" && find . -type f -not -path './.git/*' | LC_ALL=C sort | while read -r f; do
        printf '%s ' "$f"
        node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex")+"\n")' "$f"
    done)
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
ALT_RAW="$TMPD/altrepo";   mk_repo "$ALT_RAW"
echo "alt-secret" > "$ALT_RAW/alt-file.txt"
MAIN="$(nodepath "$MAIN_RAW")"
ALT="$(nodepath "$ALT_RAW")"

LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/anchor-probe "$LINKED_RAW" >/dev/null 2>&1
LINKED="$(nodepath "$LINKED_RAW")"

NONGIT_RAW="$TMPD/plain-dir"; mkdir -p "$NONGIT_RAW"
NONGIT="$(nodepath "$NONGIT_RAW")"

printf '%s' "{\"cwd\":\"$MAIN\",\"test_args\":[],\"timeout_seconds\":15}" > "$PLANS_RAW/tr.json"
PAYLOAD="$(nodepath "$PLANS_RAW/tr.json")"

# Fake agents checkout carrying BOTH trust markers (hooks/enforce-worktree.js + bin/).
FAKE_CHECKOUT_RAW="$TMPD/fake-script-checkout"
mkdir -p "$FAKE_CHECKOUT_RAW/hooks" "$FAKE_CHECKOUT_RAW/bin/worker-dispatch"
touch "$FAKE_CHECKOUT_RAW/hooks/enforce-worktree.js"
echo "process.stdout.write('PWNED');" > "$FAKE_CHECKOUT_RAW/bin/worker-dispatch.js"
FAKE_CHECKOUT="$(nodepath "$FAKE_CHECKOUT_RAW")"

# ---------------------------------------------------------------------------
# Child-process recorder: shims on PATH log every invocation, then exec the real
# binary. Lets us assert "no effectful child process against the alt repo".
# ---------------------------------------------------------------------------
SHIM_DIR="$TMPD/shims"
SPAWN_LOG="$TMPD/spawn.log"
mkdir -p "$SHIM_DIR"
: > "$SPAWN_LOG"
for real_bin in git gh uv docker bash; do
    real_path="$(command -v "$real_bin" 2>/dev/null || true)"
    [ -z "$real_path" ] && continue
    cat > "$SHIM_DIR/$real_bin" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "$real_bin" "\$*" >> "$SPAWN_LOG"
exec "$real_path" "\$@"
SHIM
    chmod +x "$SHIM_DIR/$real_bin"
done

DOUT=""
DRC=0
# run_dispatch <cwd> <args...>
run_dispatch() {
    local cwd="$1"; shift
    DRC=0
    DOUT="$(cd "$cwd" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID \
        "PATH=$SHIM_DIR:$PATH" \
        "WORKFLOW_PLANS_DIR=$PLANS" "WORKFLOW_STATE_DIR=$WF_PIN" \
        node "$DISPATCH_JS" "$@" 2>&1)" || DRC=$?
}

# ===========================================================================
# (a) cwd pointed at an alternate repo — that repo must be inert
# ===========================================================================
case_a() {
    if impl_missing "cwd-alt-repo/untouched" "$DISPATCH_JS" "bin/worker-dispatch.js"; then
        fail "cwd-alt-repo/no-effectful-spawn — implementation missing: bin/worker-dispatch.js"
        fail "cwd-alt-repo/head-unchanged — implementation missing: bin/worker-dispatch.js"
        return
    fi
    local before after head_before head_after alt_hits
    before="$(snapshot "$ALT_RAW")"
    head_before="$(git -C "$ALT_RAW" rev-parse HEAD)"
    : > "$SPAWN_LOG"

    run_dispatch "$ALT_RAW" test-runner "$MAIN" "$PAYLOAD"

    after="$(snapshot "$ALT_RAW")"
    head_after="$(git -C "$ALT_RAW" rev-parse HEAD)"
    assert_eq "cwd-alt-repo/untouched" "$before" "$after"
    assert_eq "cwd-alt-repo/head-unchanged" "$head_before" "$head_after"
    # Any recorded child process naming the alt repo is a C2 violation.
    alt_hits="$(grep -c -- "$ALT" "$SPAWN_LOG" 2>/dev/null || true)"
    [ -z "$alt_hits" ] && alt_hits=0
    assert_eq "cwd-alt-repo/no-effectful-spawn" "0" "$alt_hits"
}

# ===========================================================================
# (b) planted fake AGENTS_MAIN_ROOT must not move the script checkout root
#
# Contract asserted here: bin/worker-dispatch/anchor.js exports an anchor
# resolver (resolveAnchors | resolve | getAnchors) whose result carries the
# running script's checkout under `scriptCheckoutRoot` and the target's
# worktrees under `family`.
# Probe: <anchor.js> <target-main-root> <field> prints that field; --canon
# <path>... prints paths in the form a list field takes (realpath, sorted).
# ===========================================================================
ANCHOR_PROBE="$TMPD/anchor-probe.js"
cat > "$ANCHOR_PROBE" <<'PROBEJS'
const fs = require("fs");
const norm = (p) => p.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
const real = (p) => { try { return fs.realpathSync.native(p); } catch (_e) { return p; } };
const list = (ps) => ps.map((p) => norm(real(p))).sort().join("\n");
if (process.argv[2] === "--canon") { process.stdout.write(list(process.argv.slice(3))); process.exit(0); }
const mod = require(process.argv[2]);
const targetMainRoot = process.argv[3];
const field = process.argv[4];
const fn = mod.resolveAnchors || mod.resolve || mod.getAnchors;
if (typeof fn !== "function") { process.stderr.write("NO_RESOLVER_EXPORT"); process.exit(3); }
let a;
try { a = fn(targetMainRoot); } catch (e) { process.stderr.write("THREW:" + e.message); process.exit(4); }
if (!a || typeof a !== "object") { process.stderr.write("NO_OBJECT"); process.exit(5); }
const value = a[field];
if (Array.isArray(value)) {
  if (a.error) { process.stderr.write("ANCHOR_ERROR:" + a.error); process.exit(7); }
  process.stdout.write(list(value));
  process.exit(0);
}
if (typeof value !== "string") { process.stderr.write("NO_FIELD:" + field); process.exit(6); }
process.stdout.write(norm(value));
PROBEJS

case_b() {
    if impl_missing "fake-script-checkout-root/module-anchor-wins" "$ANCHOR_JS" "bin/worker-dispatch/anchor.js"; then
        fail "fake-script-checkout-root/not-the-planted-dir — implementation missing: bin/worker-dispatch/anchor.js"
        return
    fi
    local got rc want
    want="$(nodepath "$SCRIPT_CHECKOUT_ROOT" | tr '[:upper:]' '[:lower:]')"
    rc=0
    got="$(run_with_timeout 60 env "AGENTS_MAIN_ROOT=$FAKE_CHECKOUT" \
        node "$ANCHOR_PROBE" "$ANCHOR_JS" "$MAIN" scriptCheckoutRoot 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "fake-script-checkout-root/module-anchor-wins — anchor probe failed (rc=$rc): $got"
        return
    fi
    assert_eq "fake-script-checkout-root/module-anchor-wins" "$want" "$got"
    # Pattern 1 negative assertion: the planted checkout is never selected.
    if [ "$got" = "$(echo "$FAKE_CHECKOUT" | tr '[:upper:]' '[:lower:]')" ]; then
        fail "fake-script-checkout-root/not-the-planted-dir"
    else
        pass "fake-script-checkout-root/not-the-planted-dir"
    fi
}

# ===========================================================================
# (b2) the family is the TARGET's worktree set, wherever the caller stands.
# Rows: name | cwd | target-main-root | expected members (comma-separated).
# The control row resolves the cwd-side repo itself: its family is a different
# set, so a family taken from the caller's toplevel cannot pass the first row.
# ===========================================================================
case_family() {
    if impl_missing "family/cwd-alt-target-main" "$ANCHOR_JS" "bin/worker-dispatch/anchor.js"; then return; fi
    local name cwd target members want got rc alt_only main_family
    local -a member_list
    alt_only="$(node "$ANCHOR_PROBE" --canon "$ALT")"
    main_family="$(node "$ANCHOR_PROBE" --canon "$MAIN" "$LINKED")"
    if [ -n "$alt_only" ] && [ "$alt_only" != "$main_family" ]; then
        pass "family/fixture-premise-cwd-repo-family-differs"
    else
        fail "family/fixture-premise-cwd-repo-family-differs — alt=$alt_only main=$main_family"
    fi
    while IFS='|' read -r name cwd target members; do
        [ -z "$name" ] && continue
        name="$(echo "$name" | xargs)"; cwd="$(echo "$cwd" | xargs)"
        target="$(echo "$target" | xargs)"; members="$(echo "$members" | xargs)"
        IFS=',' read -r -a member_list <<< "$members"
        want="$(node "$ANCHOR_PROBE" --canon "${member_list[@]}")"
        rc=0
        got="$(cd "$cwd" && run_with_timeout 60 node "$ANCHOR_PROBE" "$ANCHOR_JS" "$target" family 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "family/$name — anchor probe failed (rc=$rc): $got"
            continue
        fi
        assert_eq "family/$name" "$want" "$got"
        [ "$target" = "$ALT" ] && continue
        case $'\n'"$got"$'\n' in
            *$'\n'"$alt_only"$'\n'*) fail "family/$name/excludes-cwd-repo — got=$(printf '%q' "$got")" ;;
            *) pass "family/$name/excludes-cwd-repo" ;;
        esac
    done <<TABLE
cwd-alt-target-main  | $ALT  | $MAIN | $MAIN,$LINKED
cwd-main-target-main | $MAIN | $MAIN | $MAIN,$LINKED
control-cwd-repo-own | $ALT  | $ALT  | $ALT
TABLE
}

# ===========================================================================
# (c)/(d) argv[3] must be an existing, absolute, MAIN worktree root
# ===========================================================================
case_cd() {
    local name arg want
    while IFS='|' read -r name arg want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        arg="$(echo "$arg" | xargs)"
        want="$(echo "$want" | xargs)"
        impl_missing "mainroot/$name" "$DISPATCH_JS" "bin/worker-dispatch.js" && continue
        run_dispatch "$MAIN_RAW" test-runner "$arg" "$PAYLOAD"
        assert_eq "mainroot/$name" "$want" "$DRC"
    done <<TABLE
linked-worktree   | $LINKED                     | 2
non-git-dir       | $NONGIT                     | 2
non-existent      | $TMPD/nope/nope             | 2
relative-dot      | .                           | 2
relative-path     | ./mainrepo                  | 2
plans-dir-as-root | $PLANS                      | 2
TABLE
}

# ===========================================================================
# (e) source scan — forbidden cwd-derived anchors must not appear
# ===========================================================================
case_e() {
    if [ ! -d "$WD_DIR" ]; then
        fail "source-scan/no-process-cwd — implementation missing: bin/worker-dispatch/"
        fail "source-scan/no-show-toplevel — implementation missing: bin/worker-dispatch/"
        return
    fi
    local cwd_hits top_hits
    cwd_hits="$(grep -rn 'process\.cwd()' "$WD_DIR" "$DISPATCH_JS" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "source-scan/no-process-cwd" "0" "$cwd_hits"
    top_hits="$(grep -rn -- '--show-toplevel' "$WD_DIR" "$DISPATCH_JS" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "source-scan/no-show-toplevel" "0" "$top_hits"
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WD1643_ANCHOR_INNER:-}" ]; then
        _WD1643_ANCHOR_INNER=1 timeout 240 bash "$0" "$@"
        exit $?
    fi
fi

case_begin "cwd-alt-repo-inert" "bin/worker-dispatch.js"
case_a
case_end

case_begin "script-checkout-root-anchor" "hooks/lib/script-checkout-root.js"
case_b
case_end

case_begin "family-anchor" "bin/worker-dispatch/anchor.js"
case_family
case_end

case_begin "target-main-root-validation" "bin/worker-dispatch.js"
case_cd
case_end

case_begin "source-scan" "bin/worker-dispatch/anchor.js"
case_e
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
