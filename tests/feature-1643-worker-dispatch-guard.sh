#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-guard.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/lib/worker-dispatch-registry.js, hooks/enforce-worktree.js
# Tags: worker-dispatch, enforce-worktree, hook, guard, overlay, security, lock1, lock2, lock3, TL2, scope:issue-specific
#
# Issue #1643 — guard-side overlay for the single worker-dispatch entry point.
# Canonical form (the ONLY allowed shape):
#     node "<ACD>/bin/worker-dispatch.js" <worker-name> <main-root> <payload-json>
#
# Locks under test (detail plan S1):
#   Lock 1 — script path root must equal the marker-validated AGENTS_CONFIG_DIR
#   Lock 2 — argv <main-root> must equal the repo the guard is currently judging
#   Lock 3 — argv <main-root> must be a MAIN worktree inside getSessionRepoRoots()
#
# Drive surface: the overlay predicate itself (matchWorkerDispatchOverlay), invoked
# with the same (cmd, acd, repoRoot) triple worker-script.js passes it, from a
# process whose cwd is the fixture main worktree so getSessionRepoRoots() anchors
# there. Group W additionally drives the FULL hook exactly like
# tests/fix-1600-finalize-worker-overlay.sh does, to prove the wiring is live.
#
# Deliberate layering note: enforce-worktree.js short-circuits on
# detectWritePredicate() before any main-worktree-allow runs, and a bare
# `node "<path>" a b c` is not classified as a write, so the full hook cannot
# express the BLOCK rows. Asserting them at the hook level would be a false-green
# (they "pass" for the wrong reason). The matrix therefore runs at the predicate
# layer, where a wrong verdict is observable.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real Claude Code PreToolUse invocation where tool_input.cwd differs from the
#     hook process cwd, and the real session's ENFORCE_WORKTREE_ADDITIONAL_REPOS set.
#   - A real ~/.claude symlinked agents checkout driving resolveAgentsConfigDir().
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

# Self re-exec under a hard timeout so a hung node probe can never hang the suite.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_GUARD_INNER:-}" ]; then
    _WD1643_GUARD_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_NODE="$(nodepath "$AGENTS_DIR")"
GUARD_JS="$AGENTS_NODE/hooks/enforce-worktree.js"
OVERLAY_JS="$AGENTS_DIR/hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
WORKER_SCRIPT_JS="$AGENTS_DIR/hooks/enforce-worktree/main-worktree-allows/worker-script.js"
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

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-guard-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

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
# Fixtures
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
ALT_RAW="$TMPD/altrepo";   mk_repo "$ALT_RAW"
LINKED_RAW="$MAIN_RAW/.wt/probe"
git -C "$MAIN_RAW" worktree add -q -b feature/guard-probe "$LINKED_RAW" >/dev/null 2>&1

ACD_RAW="$TMPD/fake-acd"
mkdir -p "$ACD_RAW/hooks" "$ACD_RAW/bin" "$ACD_RAW/xbin"
touch "$ACD_RAW/hooks/enforce-worktree.js" "$ACD_RAW/bin/worker-dispatch.js"
touch "$ACD_RAW/bin/worker-dispatch.js.bak" "$ACD_RAW/xbin/worker-dispatch.js"
OTHER_ACD_RAW="$TMPD/other-acd"
mkdir -p "$OTHER_ACD_RAW/hooks" "$OTHER_ACD_RAW/bin"
touch "$OTHER_ACD_RAW/hooks/enforce-worktree.js" "$OTHER_ACD_RAW/bin/worker-dispatch.js"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
EVIL_RAW="$TMPD/plans-evil"; mkdir -p "$EVIL_RAW"
printf '{}' > "$PLANS_RAW/p.json"
printf '{}' > "$EVIL_RAW/p.json"

MAIN="$(nodepath "$MAIN_RAW")"
ALT="$(nodepath "$ALT_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
ACD="$(nodepath "$ACD_RAW")"
OTHER_ACD="$(nodepath "$OTHER_ACD_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
EVIL="$(nodepath "$EVIL_RAW")"

# ---------------------------------------------------------------------------
# Overlay predicate probe: prints ALLOW when the overlay matched, BLOCK otherwise.
# ---------------------------------------------------------------------------
PROBE_JS="$TMPD/overlay-probe.js"
cat > "$PROBE_JS" <<'PROBEJS'
let mod;
try { mod = require(process.argv[2]); }
catch (e) { process.stdout.write("LOADFAIL:" + e.message.slice(0, 80)); process.exit(0); }
const fn = mod.matchWorkerDispatchOverlay;
if (typeof fn !== "function") { process.stdout.write("NO_EXPORT"); process.exit(0); }
let r;
try { r = fn(process.argv[3], process.argv[4], process.argv[5]); }
catch (e) { process.stdout.write("THREW:" + e.message.slice(0, 80)); process.exit(0); }
process.stdout.write(r === null || r === undefined || r === false ? "BLOCK" : "ALLOW");
PROBEJS

# expand <template> — substitutes the fixture placeholders.
expand() {
    local s="$1"
    s="${s//@ACD@/$ACD}"
    s="${s//@OTHERACD@/$OTHER_ACD}"
    s="${s//@MAIN@/$MAIN}"
    s="${s//@ALT@/$ALT}"
    s="${s//@LINKED@/$LINKED}"
    s="${s//@PLANS@/$PLANS}"
    s="${s//@EVIL@/$EVIL}"
    s="${s//@PIPE@/|}"
    s="${s//@DOLLAR@/$}"
    s="${s//@BQ@/\`}"
    s="${s//@NL@/$'\n'}"
    printf '%s' "$s"
}

overlay_verdict() {
    local cmd="$1" repo_root="$2"
    (cd "$MAIN_RAW" && run_with_timeout 30 env \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$PROBE_JS" "$(nodepath "$OVERLAY_JS")" "$cmd" "$ACD" "$repo_root" 2>&1)
}

CANONICAL='node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json'

# ===========================================================================
# Group A — ALLOW: the six canonical worker forms (classifier both-direction)
# ===========================================================================
group_allow() {
    local w cmd got
    for w in test-runner worktree-copy worktree-backup doc-append issue-reconcile session-close-gate; do
        if [ ! -f "$OVERLAY_JS" ]; then
            fail "allow/$w — implementation missing: hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
            continue
        fi
        cmd="$(expand "node \"@ACD@/bin/worker-dispatch.js\" $w @MAIN@ @PLANS@/p.json")"
        got="$(overlay_verdict "$cmd" "$MAIN")"
        assert_eq "allow/$w" "ALLOW" "$got"
    done
}

# ===========================================================================
# Group B — BLOCK matrix (Lock 1/2/3, arity, enum, payload scope, shell shapes)
# ===========================================================================
group_block() {
    local name tmpl rootkey root cmd got
    while IFS='|' read -r name tmpl rootkey; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        rootkey="$(echo "$rootkey" | xargs)"
        if [ ! -f "$OVERLAY_JS" ]; then
            fail "block/$name — implementation missing: hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
            continue
        fi
        case "$rootkey" in
            MAIN)   root="$MAIN" ;;
            ALT)    root="$ALT" ;;
            LINKED) root="$LINKED" ;;
            *)      root="$MAIN" ;;
        esac
        cmd="$(expand "$tmpl")"
        got="$(overlay_verdict "$cmd" "$root")"
        assert_eq "block/$name" "BLOCK" "$got"
    done <<'TABLE'
lock3-alt-repo-both        | node "@ACD@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json                    | ALT
lock2-mainroot-mismatch    | node "@ACD@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json                    | MAIN
lock3-linked-worktree      | node "@ACD@/bin/worker-dispatch.js" test-runner @LINKED@ @PLANS@/p.json                 | LINKED
lock1-other-acd            | node "@OTHERACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json             | MAIN
path-bak-suffix            | node "@ACD@/bin/worker-dispatch.js.bak" test-runner @MAIN@ @PLANS@/p.json              | MAIN
path-xbin-prefix           | node "@ACD@/xbin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                 | MAIN
path-unquoted              | node @ACD@/bin/worker-dispatch.js test-runner @MAIN@ @PLANS@/p.json                    | MAIN
path-single-quoted         | node '@ACD@/bin/worker-dispatch.js' test-runner @MAIN@ @PLANS@/p.json                  | MAIN
path-var-dollar            | node "@DOLLAR@AGENTS_CONFIG_DIR/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json | MAIN
path-tilde                 | node "~/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                      | MAIN
arity-0                    | node "@ACD@/bin/worker-dispatch.js"                                                    | MAIN
arity-1                    | node "@ACD@/bin/worker-dispatch.js" test-runner                                        | MAIN
arity-2                    | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@                                 | MAIN
arity-4                    | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json extra            | MAIN
unknown-worker             | node "@ACD@/bin/worker-dispatch.js" not-a-worker @MAIN@ @PLANS@/p.json                 | MAIN
unknown-worker-case        | node "@ACD@/bin/worker-dispatch.js" Test-Runner @MAIN@ @PLANS@/p.json                  | MAIN
payload-outside-plans      | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @MAIN@/p.json                   | MAIN
payload-sibling-prefix     | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @EVIL@/p.json                   | MAIN
payload-dotdot-escape      | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/../plans-evil/p.json    | MAIN
payload-relative           | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ p.json                          | MAIN
meta-semicolon             | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json; id              | MAIN
meta-and-and               | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json && id            | MAIN
meta-pipe                  | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json @PIPE@ cat       | MAIN
meta-cmd-subst             | node "@ACD@/bin/worker-dispatch.js" test-runner @DOLLAR@(pwd) @PLANS@/p.json           | MAIN
meta-backtick              | node "@ACD@/bin/worker-dispatch.js" test-runner @BQ@pwd@BQ@ @PLANS@/p.json             | MAIN
meta-redirect              | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json > @MAIN@/log.txt | MAIN
cd-alt-repo-chain          | cd @ALT@ && node "@ACD@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json       | MAIN
git-c-alt-repo-chain       | git -C @ALT@ status && node "@ACD@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json | MAIN
env-prefix-single          | AGENTS_CONFIG_DIR="@ACD@" node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json | MAIN
env-prefix-bare            | FOO=1 node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json            | MAIN
newline-injection-lf       | node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json@NL@id            | MAIN
newline-injection-leading  | @NL@node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json              | MAIN
interp-bash                | bash "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                  | MAIN
interp-sh                  | sh "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                    | MAIN
interp-node-flag           | node --experimental-vm-modules "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json | MAIN
eval-wrapper               | eval "@DOLLAR@(node "@ACD@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json)" | MAIN
TABLE
}

# ===========================================================================
# Group C — SANCTIONED array must not grow (the overlay is the only new surface)
# ===========================================================================
group_sanctioned_count() {
    local n
    n="$(node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8");
      const m = src.match(/const\s+SANCTIONED\s*=\s*\[([\s\S]*?)\]\s*;/);
      if (!m) { process.stdout.write("NO_ARRAY"); process.exit(0); }
      process.stdout.write(String((m[1].match(/"[^"]+"/g) || []).length));
    ' "$(nodepath "$WORKER_SCRIPT_JS")" 2>&1)"
    assert_eq "sanctioned/count-still-10" "10" "$n"
}

# ===========================================================================
# Group D — fail-closed when the SSOT registry module is absent
# The hooks/ tree is copied to a temp dir and the registry removed there, so the
# repository checkout is never mutated.
# ===========================================================================
group_fail_closed() {
    if [ ! -f "$OVERLAY_JS" ]; then
        fail "fail-closed/registry-missing — implementation missing: hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
        return
    fi
    local sandbox="$TMPD/hooks-sandbox"
    rm -rf "$sandbox"
    mkdir -p "$sandbox"
    cp -R "$AGENTS_DIR/hooks" "$sandbox/hooks" 2>/dev/null || true
    rm -f "$sandbox/hooks/lib/worker-dispatch-registry.js"
    local copied="$sandbox/hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
    if [ ! -f "$copied" ]; then
        fail "fail-closed/registry-missing — hooks/ sandbox copy failed"
        return
    fi
    local cmd got
    cmd="$(expand "$CANONICAL")"
    got="$(cd "$MAIN_RAW" && run_with_timeout 30 env \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$PROBE_JS" "$(nodepath "$copied")" "$cmd" "$ACD" "$MAIN" 2>&1)"
    # LOADFAIL is NOT acceptable: S1 requires the require() to be try/catch-wrapped
    # so a partial revert degrades to BLOCK rather than crashing the hook.
    assert_eq "fail-closed/registry-missing" "BLOCK" "$got"
}

# ===========================================================================
# Group W — wiring: worker-script.js must consult the overlay, and the full hook
# must still reach it. Sanity-anchored by a control write that MUST block.
# ===========================================================================
json_payload() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1"
}

hook_verdict() {
    local cmd="$1" out rc=0
    out="$(printf '%s' "$(json_payload "$cmd")" | (cd "$MAIN_RAW" && run_with_timeout 30 env \
        -u CLAUDE_ENV_FILE \
        "ENFORCE_WORKTREE=on" \
        "AGENTS_CONFIG_DIR=$ACD" \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$GUARD_JS") 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then printf 'CRASH'; return; fi
    case "$out" in
        *'"decision":"block"'*|*'ENFORCE_WORKTREE:'*) printf 'BLOCK' ;;
        *) printf 'ALLOW' ;;
    esac
}

group_wiring() {
    # Live-harness anchor: an ordinary main-worktree write must be blocked, or the
    # ALLOW result below would prove nothing.
    assert_eq "wiring/control-write-blocked" "BLOCK" "$(hook_verdict "touch $MAIN/control.txt")"
    assert_eq "wiring/canonical-not-blocked" "ALLOW" "$(hook_verdict "$(expand "$CANONICAL")")"

    if [ ! -f "$WORKER_SCRIPT_JS" ]; then
        fail "wiring/worker-script-requires-overlay — missing worker-script.js"
        fail "wiring/overlay-before-sanctioned — missing worker-script.js"
        return
    fi
    local req
    req="$(grep -c 'worker-dispatch-overlay' "$WORKER_SCRIPT_JS" 2>/dev/null || true)"
    [ -z "$req" ] && req=0
    if [ "$req" -ge 1 ]; then
        pass "wiring/worker-script-requires-overlay"
    else
        fail "wiring/worker-script-requires-overlay — worker-script.js does not reference worker-dispatch-overlay"
    fi
    # The overlay call must precede the legacy SANCTIONED comparison.
    local call_line sanctioned_line
    call_line="$(grep -n 'matchWorkerDispatchOverlay(' "$WORKER_SCRIPT_JS" 2>/dev/null | grep -v require | head -1 | cut -d: -f1)"
    sanctioned_line="$(grep -n 'const SANCTIONED' "$WORKER_SCRIPT_JS" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$call_line" ] && [ -n "$sanctioned_line" ] && [ "$call_line" -lt "$sanctioned_line" ]; then
        pass "wiring/overlay-before-sanctioned"
    else
        fail "wiring/overlay-before-sanctioned — call=${call_line:-none} sanctioned=${sanctioned_line:-none}"
    fi
}

# ===========================================================================
# Group R — registry presence (the overlay's worker-name enum SSOT)
# ===========================================================================
group_registry() {
    if [ -f "$REGISTRY_JS" ]; then
        pass "registry/module-present"
    else
        fail "registry/module-present — implementation missing: hooks/lib/worker-dispatch-registry.js"
    fi
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WD1643_GUARD_INNER:-}" ]; then
        _WD1643_GUARD_INNER=1 timeout 420 bash "$0" "$@"
        exit $?
    fi
fi

group_registry
group_allow
group_block
group_sanctioned_count
group_fail_closed
group_wiring

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
