#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-anchor.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/anchor.js, hooks/lib/agents-config-dir.js
# Tags: worker-dispatch, anchor, trust-anchor, c2, security, TL1, scope:issue-specific
#
# Issue #1643 — C2 core: the dispatcher's trust anchors must not be movable by
# caller-controlled input. Concretely:
#   (a) process cwd pointed at an ALTERNATE repo must leave that repo untouched
#       (no effectful child process against it, no fs write into it),
#   (b) a planted fake agents checkout in $AGENTS_CONFIG_DIR (both marker files
#       present) must NOT become the resolved ACD — the module/realpath anchor wins,
#   (c) argv[3] pointing at a LINKED worktree must exit 2 (git-common-dir check),
#   (d) argv[3] non-git / non-existent / relative must exit 2,
#   (e) `process.cwd()` and `rev-parse --show-toplevel` must not appear anywhere
#       under bin/worker-dispatch/** (regression fence for the design rule).
#
# TL3 gap (what this TL1 test does NOT catch):
#   - A real Claude Code Bash tool call supplying tool_input.cwd, where the guard
#     process and the dispatcher process see different cwds.
#   - Real AGENTS_CONFIG_DIR resolution across a symlinked ~/.claude checkout.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
ANCHOR_JS="$AGENTS_DIR/bin/worker-dispatch/anchor.js"
WD_DIR="$AGENTS_DIR/bin/worker-dispatch"

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

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-anchor-$$")"
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

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
PLANS="$(nodepath "$PLANS_RAW")"
printf '%s' "{\"cwd\":\"$MAIN\",\"test_args\":[],\"timeout_seconds\":15}" > "$PLANS_RAW/tr.json"
PAYLOAD="$(nodepath "$PLANS_RAW/tr.json")"

# Fake agents checkout carrying BOTH trust markers (hooks/enforce-worktree.js + bin/).
FAKE_ACD_RAW="$TMPD/fake-acd"
mkdir -p "$FAKE_ACD_RAW/hooks" "$FAKE_ACD_RAW/bin/worker-dispatch"
touch "$FAKE_ACD_RAW/hooks/enforce-worktree.js"
echo "process.stdout.write('PWNED');" > "$FAKE_ACD_RAW/bin/worker-dispatch.js"
FAKE_ACD="$(nodepath "$FAKE_ACD_RAW")"

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
    DOUT="$(cd "$cwd" && run_with_timeout 60 env \
        "PATH=$SHIM_DIR:$PATH" \
        "WORKFLOW_PLANS_DIR=$PLANS" \
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
# (b) planted fake AGENTS_CONFIG_DIR must not move the resolved ACD
#
# Contract asserted here: bin/worker-dispatch/anchor.js exports an anchor
# resolver (resolveAnchors | resolve | getAnchors) whose result carries the
# agents checkout under `acd` (or `ACD`).
# ===========================================================================
ANCHOR_PROBE="$TMPD/anchor-probe.js"
cat > "$ANCHOR_PROBE" <<'PROBEJS'
const mod = require(process.argv[2]);
const mainRoot = process.argv[3];
const fn = mod.resolveAnchors || mod.resolve || mod.getAnchors;
if (typeof fn !== "function") { process.stderr.write("NO_RESOLVER_EXPORT"); process.exit(3); }
let a;
try { a = fn(mainRoot); } catch (e) { process.stderr.write("THREW:" + e.message); process.exit(4); }
if (!a || typeof a !== "object") { process.stderr.write("NO_OBJECT"); process.exit(5); }
const acd = a.acd || a.ACD;
if (typeof acd !== "string") { process.stderr.write("NO_ACD_FIELD"); process.exit(6); }
process.stdout.write(acd.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase());
PROBEJS

case_b() {
    if impl_missing "fake-acd/module-anchor-wins" "$ANCHOR_JS" "bin/worker-dispatch/anchor.js"; then
        fail "fake-acd/not-the-planted-dir — implementation missing: bin/worker-dispatch/anchor.js"
        return
    fi
    local got rc want
    want="$(nodepath "$AGENTS_DIR" | tr '[:upper:]' '[:lower:]')"
    rc=0
    got="$(run_with_timeout 60 env "AGENTS_CONFIG_DIR=$FAKE_ACD" \
        node "$ANCHOR_PROBE" "$ANCHOR_JS" "$MAIN" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "fake-acd/module-anchor-wins — anchor probe failed (rc=$rc): $got"
        return
    fi
    assert_eq "fake-acd/module-anchor-wins" "$want" "$got"
    # Pattern 1 negative assertion: the planted checkout is never selected.
    if [ "$got" = "$(echo "$FAKE_ACD" | tr '[:upper:]' '[:lower:]')" ]; then
        fail "fake-acd/not-the-planted-dir"
    else
        pass "fake-acd/not-the-planted-dir"
    fi
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

case_a
case_b
case_cd
case_e

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
