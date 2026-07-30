#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-paths.sh
# Tests: bin/worker-dispatch-paths, bin/worker-dispatch/anchor.js
# Tags: worker-dispatch, paths-resolver, worktree, anchor, main-root, TL2, scope:issue-specific
#
# Issue #1643 — `bin/worker-dispatch-paths` is the read-only resolver every
# calling skill runs as WD-1. It exists because the enforce-worktree overlay
# sanctions ONLY the bare form
#     node "<ACD>/bin/worker-dispatch.js" <worker> <main-root> <payload>
# with no `$VAR`, no substitution and no chaining — so all three arguments must
# reach the command line already literal. The resolver prints exactly:
#     DISPATCH=<abs>
#     MAIN_ROOT=<abs>
#     PLANS_DIR=<abs>
#
# The load-bearing case is MAIN_ROOT: bin/worker-dispatch/anchor.js REJECTS a
# linked worktree in that argument position, and every skill that dispatches runs
# from a linked worktree. A resolver that answered with the caller's own worktree
# would make every dispatch exit 2. Group C drives that with a real
# `git worktree add` fixture.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The real calling skills running WD-1 through a live Claude Code Bash tool,
#     where the hook's tool_input.cwd (not this process's cwd) decides the repo.
#   - A ~/.claude symlinked agents checkout, where the resolver's __dirname anchor
#     and the session's AGENTS_CONFIG_DIR resolve through different real paths.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
RESOLVER="$AGENTS_DIR/bin/worker-dispatch-paths"
RESOLVER_N="$(nodepath "$RESOLVER")"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; [ -n "${2:-}" ] && echo "    reason: $2"; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$RESOLVER" ]; then
    fail "0: bin/worker-dispatch-paths missing"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit $FAIL
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-paths-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
TMPD_N="$(nodepath "$TMPD")"

G() { git -c user.email=test@example.com -c user.name=test -c core.hooksPath=/dev/null "$@"; }

# Canonical comparison form: realpath, forward slashes, lower-cased (Windows
# paths differ only by case/separator between `git`, node and bash).
canon() {
    run_with_timeout 30 node -e '
      const fs = require("fs");
      let p = process.argv[1];
      try { p = fs.realpathSync(p); } catch (e) { /* not-yet-real paths compare as given */ }
      process.stdout.write(p.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase());
    ' "$1" 2>/dev/null
}

# Every value must be an absolute native path: a Windows drive root or a POSIX root.
is_abs() { case "$1" in [A-Za-z]:[/\\]*|/*) return 0 ;; *) return 1 ;; esac; }

value_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ---------------------------------------------------------------------------
# Fixture: a real repo with a real linked worktree.
# ---------------------------------------------------------------------------
FIX_MAIN="$TMPD/fixture-repo"
FIX_LINKED="$TMPD/fixture-linked"
HAVE_WORKTREE=0
mkdir -p "$FIX_MAIN"
if G -C "$FIX_MAIN" init -q -b main >/dev/null 2>&1; then
    echo seed > "$FIX_MAIN/seed.txt"
    G -C "$FIX_MAIN" add -A >/dev/null 2>&1
    G -C "$FIX_MAIN" commit -q --no-verify -m init >/dev/null 2>&1
    if G -C "$FIX_MAIN" worktree add -q -b wd-paths-fixture "$FIX_LINKED" >/dev/null 2>&1; then
        HAVE_WORKTREE=1
    fi
fi

# ===========================================================================
# Group A — normal: shape of stdout
# ===========================================================================
A_OUT="$TMPD/a-stdout.txt"
A_ERR="$TMPD/a-stderr.txt"
run_with_timeout 60 node "$RESOLVER_N" > "$A_OUT" 2> "$A_ERR"
A_RC=$?

group_shape() {
    local out lines keys ok bad
    out="$(cat "$A_OUT")"
    if [ "$A_RC" -ne 0 ]; then
        fail "A1: resolver exit code" "rc=$A_RC stderr=$(cat "$A_ERR")"
        return
    fi
    pass "A1: resolver exits 0 with no arguments"

    lines=$(grep -c '' "$A_OUT")
    if [ "$lines" -eq 3 ]; then
        pass "A2: stdout is exactly 3 lines"
    else
        fail "A2: stdout line count" "want=3 got=$lines out='$out'"
    fi

    keys=$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$A_OUT" | tr '\n' ',')
    if [ "$keys" = "DISPATCH,MAIN_ROOT,PLANS_DIR," ]; then
        pass "A3: keys appear in order DISPATCH, MAIN_ROOT, PLANS_DIR"
    else
        fail "A3: key order" "got='$keys'"
    fi

    ok=1; bad=""
    for k in DISPATCH MAIN_ROOT PLANS_DIR; do
        v="$(value_of "$out" "$k")"
        if [ -z "$v" ] || ! is_abs "$v"; then ok=0; bad="$bad $k='$v'"; fi
    done
    if [ "$ok" -eq 1 ]; then
        pass "A4: every value is a non-empty absolute path"
    else
        fail "A4: non-absolute value(s)" "$bad"
    fi
}

group_dispatch_value() {
    local d tail
    d="$(value_of "$(cat "$A_OUT")" DISPATCH)"
    # Separator-agnostic suffix check: backslashes on Windows, slashes elsewhere.
    tail="$(printf '%s' "$d" | tr '\\' '/')"
    case "$tail" in
        */bin/worker-dispatch.js) pass "A5: DISPATCH ends with bin/worker-dispatch.js" ;;
        *) fail "A5: DISPATCH suffix" "got='$d'" ;;
    esac
    if [ -n "$d" ] && [ -f "$AGENTS_DIR/bin/worker-dispatch.js" ]; then
        pass "A6: the dispatcher DISPATCH names exists on disk"
    else
        fail "A6: dispatcher not on disk" "DISPATCH='$d'"
    fi
}

# ===========================================================================
# Group B — idempotency
# ===========================================================================
group_idempotent() {
    local o1 o2
    o1="$TMPD/idem-1.txt"; o2="$TMPD/idem-2.txt"
    run_with_timeout 60 node "$RESOLVER_N" > "$o1" 2>/dev/null
    run_with_timeout 60 node "$RESOLVER_N" > "$o2" 2>/dev/null
    if [ ! -s "$o1" ]; then
        fail "B1: idempotency — first run produced no output"
        return
    fi
    if cmp -s "$o1" "$o2"; then
        pass "B1: two consecutive runs produce byte-identical stdout"
    else
        fail "B1: runs differ" "$(diff "$o1" "$o2" 2>&1 | head -6)"
    fi
}

# ===========================================================================
# Group C — CORE: MAIN_ROOT is the MAIN worktree, never the linked one
# ===========================================================================
group_linked_worktree() {
    if [ "$HAVE_WORKTREE" -ne 1 ]; then
        skip "C1/C2: linked-worktree cases" "git worktree add unavailable in this environment"
        return
    fi
    local out rc main_v want linked_c
    want="$(canon "$(nodepath "$FIX_MAIN")")"
    linked_c="$(canon "$(nodepath "$FIX_LINKED")")"

    # C1 — cwd is the LINKED worktree, no argument.
    out=$(cd "$FIX_LINKED" && run_with_timeout 60 node "$RESOLVER_N" 2>/dev/null)
    rc=$?
    main_v="$(canon "$(value_of "$out" MAIN_ROOT)")"
    if [ "$rc" -eq 0 ] && [ "$main_v" = "$want" ] && [ "$main_v" != "$linked_c" ]; then
        pass "C1: run from a LINKED worktree resolves MAIN_ROOT to the MAIN worktree"
    else
        fail "C1: MAIN_ROOT from linked cwd" "rc=$rc got='$main_v' want='$want' linked='$linked_c'"
    fi

    # C2 — same answer when the LINKED worktree is passed as the argument.
    out=$(run_with_timeout 60 node "$RESOLVER_N" "$(nodepath "$FIX_LINKED")" 2>/dev/null)
    rc=$?
    main_v="$(canon "$(value_of "$out" MAIN_ROOT)")"
    if [ "$rc" -eq 0 ] && [ "$main_v" = "$want" ]; then
        pass "C2: a LINKED worktree argument still resolves to the MAIN worktree"
    else
        fail "C2: MAIN_ROOT from linked argument" "rc=$rc got='$main_v' want='$want'"
    fi
}

# ===========================================================================
# Group D — explicit target argument wins over cwd
# ===========================================================================
group_explicit_target() {
    local out rc main_v want cwd_main
    want="$(canon "$(nodepath "$FIX_MAIN")")"
    cwd_main="$(canon "$(value_of "$(cat "$A_OUT")" MAIN_ROOT)")"
    if [ "$want" = "$cwd_main" ]; then
        fail "D1: fixture repo coincides with this checkout's main root — case is not meaningful"
        return
    fi
    out=$(run_with_timeout 60 node "$RESOLVER_N" "$(nodepath "$FIX_MAIN")" 2>/dev/null)
    rc=$?
    main_v="$(canon "$(value_of "$out" MAIN_ROOT)")"
    if [ "$rc" -eq 0 ] && [ "$main_v" = "$want" ]; then
        pass "D1: an explicit target resolves THAT repo's main worktree, not the cwd's"
    else
        fail "D1: explicit target ignored" "rc=$rc got='$main_v' want='$want' cwd-main='$cwd_main'"
    fi
}

# ===========================================================================
# Group E — edge: paths with a space
# ===========================================================================
group_space_in_path() {
    local dir out rc main_v want
    dir="$TMPD/dir with space"
    mkdir -p "$dir"
    if ! G -C "$dir" init -q -b main >/dev/null 2>&1; then
        skip "E1: space-in-path case" "git init failed in a path containing a space"
        return
    fi
    echo s > "$dir/s.txt"
    G -C "$dir" add -A >/dev/null 2>&1
    G -C "$dir" commit -q --no-verify -m init >/dev/null 2>&1
    want="$(canon "$(nodepath "$dir")")"
    out=$(run_with_timeout 60 node "$RESOLVER_N" "$(nodepath "$dir")" 2>/dev/null)
    rc=$?
    main_v="$(canon "$(value_of "$out" MAIN_ROOT)")"
    if [ "$rc" -eq 0 ] && [ "$main_v" = "$want" ]; then
        pass "E1: a target directory whose path contains a space resolves correctly"
    else
        fail "E1: space-in-path target" "rc=$rc got='$main_v' want='$want'"
    fi
}

# ===========================================================================
# Group F — error paths: non-zero exit, diagnostic on stderr, EMPTY stdout
# ===========================================================================
assert_error_case() {
    local name="$1" rc="$2" outf="$3" errf="$4"
    local outbytes
    outbytes=$(wc -c < "$outf" | tr -d ' ')
    if [ "$rc" -eq 0 ]; then
        fail "$name: expected non-zero exit" "rc=$rc stdout='$(cat "$outf")'"
        return
    fi
    if [ "$outbytes" -ne 0 ]; then
        fail "$name: stdout must stay empty on error" "stdout='$(cat "$outf")'"
        return
    fi
    if [ ! -s "$errf" ]; then
        fail "$name: expected a diagnostic on stderr" "stderr empty"
        return
    fi
    pass "$name (rc=$rc, empty stdout, diagnostic on stderr)"
}

group_missing_target() {
    local o="$TMPD/f1-out.txt" e="$TMPD/f1-err.txt" rc
    run_with_timeout 60 node "$RESOLVER_N" "$TMPD_N/definitely-not-here-1643" > "$o" 2> "$e"
    rc=$?
    assert_error_case "F1: nonexistent target directory rejected" "$rc" "$o" "$e"
}

group_not_a_repo() {
    local dir o e rc
    dir="$TMPD/plain-dir"
    mkdir -p "$dir"
    if G -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        skip "F2: not-a-git-repository case" "the temp directory is itself inside a git repository"
        return
    fi
    o="$TMPD/f2-out.txt"; e="$TMPD/f2-err.txt"
    run_with_timeout 60 node "$RESOLVER_N" "$(nodepath "$dir")" > "$o" 2> "$e"
    rc=$?
    assert_error_case "F2: existing but non-git target rejected" "$rc" "$o" "$e"
}

# The resolver's own guard: it anchors ACD on its module location, so a copy that
# sits in a tree WITHOUT bin/worker-dispatch.js must refuse rather than print a
# path that cannot be dispatched. The fixture reproduces the layout the script
# requires (bin/ + hooks/lib/) and omits only the dispatcher.
group_dispatcher_absent() {
    local root o e rc
    root="$TMPD/acd-fixture"
    mkdir -p "$root/bin" "$root/hooks/lib"
    cp "$RESOLVER" "$root/bin/worker-dispatch-paths"
    for m in path-normalize workflow-plans-dir; do
        printf 'module.exports = require(%s);\n' \
            "\"$(nodepath "$AGENTS_DIR/hooks/lib/$m.js")\"" > "$root/hooks/lib/$m.js"
    done
    if [ -f "$root/bin/worker-dispatch.js" ]; then
        fail "F3: fixture is invalid — it contains a dispatcher"
        return
    fi
    o="$TMPD/f3-out.txt"; e="$TMPD/f3-err.txt"
    run_with_timeout 60 node "$(nodepath "$root/bin/worker-dispatch-paths")" \
        "$(nodepath "$AGENTS_DIR")" > "$o" 2> "$e"
    rc=$?
    assert_error_case "F3: missing bin/worker-dispatch.js rejected" "$rc" "$o" "$e"
    if grep -qi 'dispatcher' "$e"; then
        pass "F4: the diagnostic names the missing dispatcher"
    else
        fail "F4: diagnostic does not mention the dispatcher" "stderr='$(cat "$e")'"
    fi
}

# A path that exists but is a FILE is a different failure from a path that does
# not exist: an `fs.existsSync` guard passes it, and only a directory check
# catches it. Without this case a regression to existsSync stays green.
group_target_is_a_file() {
    local f o e rc
    f="$TMPD/not-a-directory.txt"
    echo "I am a regular file, not a repository." > "$f"
    o="$TMPD/f5-out.txt"; e="$TMPD/f5-err.txt"
    run_with_timeout 60 node "$RESOLVER_N" "$(nodepath "$f")" > "$o" 2> "$e"
    rc=$?
    assert_error_case "F5: an existing regular file as target rejected" "$rc" "$o" "$e"
}

# An unreadable target must fail the same way — non-zero, empty stdout,
# diagnostic — rather than emitting a half-resolved triple. POSIX-only: on
# Windows chmod does not remove directory read access, so the case is skipped
# rather than asserted against a permission bit that was never applied.
group_unreadable_target() {
    local dir o e rc
    dir="$TMPD/unreadable-repo"
    mkdir -p "$dir"
    G -C "$dir" init -q -b main >/dev/null 2>&1
    chmod 000 "$dir" 2>/dev/null || true
    if [ -r "$dir" ]; then
        chmod 755 "$dir" 2>/dev/null || true
        skip "F6: unreadable target case" "chmod 000 did not remove read access on this platform"
        return
    fi
    o="$TMPD/f6-out.txt"; e="$TMPD/f6-err.txt"
    run_with_timeout 60 node "$RESOLVER_N" "$(nodepath "$dir")" > "$o" 2> "$e"
    rc=$?
    chmod 755 "$dir" 2>/dev/null || true
    assert_error_case "F6: an unreadable target directory rejected" "$rc" "$o" "$e"
}

# ===========================================================================
# Group G — PLANS_DIR follows the configured value, not a hardcoded default
#
# The dispatcher rejects any payload outside PLANS_DIR, so a resolver that
# ignored the configured directory would make every dispatch unusable in a
# non-default setup. Both directions are covered: a pinned value is honoured,
# and a value the config layer must reject is not silently defaulted away.
# ===========================================================================
group_plans_dir_config() {
    local pinned out rc got e
    pinned="$TMPD/pinned-plans"
    mkdir -p "$pinned"
    out="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$(nodepath "$pinned")" \
        node "$RESOLVER_N" "$(nodepath "$FIX_MAIN")" 2>/dev/null)"
    rc=$?
    got="$(canon "$(value_of "$out" PLANS_DIR)")"
    if [ "$rc" -eq 0 ] && [ "$got" = "$(canon "$(nodepath "$pinned")")" ]; then
        pass "G1: PLANS_DIR honours the configured WORKFLOW_PLANS_DIR"
    else
        fail "G1: PLANS_DIR ignored the configured value" \
            "rc=$rc got='$got' want='$(canon "$(nodepath "$pinned")")'"
    fi

    # Control: with the variable unset the answer differs, so G1 proves the
    # value was READ rather than coinciding with the default.
    out="$(run_with_timeout 60 env -u WORKFLOW_PLANS_DIR node "$RESOLVER_N" \
        "$(nodepath "$FIX_MAIN")" 2>/dev/null)"
    if [ "$(canon "$(value_of "$out" PLANS_DIR)")" = "$(canon "$(nodepath "$pinned")")" ]; then
        fail "G2: the default PLANS_DIR coincides with the pinned fixture — G1 is not meaningful"
    else
        pass "G2: the unpinned default differs from the pinned value"
    fi

    # A relative value is a configuration error, not a base to resolve from.
    e="$TMPD/g3-err.txt"
    out="$TMPD/g3-out.txt"
    run_with_timeout 60 env "WORKFLOW_PLANS_DIR=relative/plans" node "$RESOLVER_N" \
        "$(nodepath "$FIX_MAIN")" > "$out" 2> "$e"
    rc=$?
    assert_error_case "G3: a relative WORKFLOW_PLANS_DIR rejected" "$rc" "$out" "$e"
}

group_shape
group_dispatch_value
group_idempotent
group_linked_worktree
group_explicit_target
group_space_in_path
group_missing_target
group_not_a_repo
group_target_is_a_file
group_unreadable_target
group_plans_dir_config
group_dispatcher_absent

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
