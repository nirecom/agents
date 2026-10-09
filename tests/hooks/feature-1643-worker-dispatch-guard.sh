#!/usr/bin/env bash
# tests/hooks/feature-1643-worker-dispatch-guard.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/lib/worker-dispatch-registry.js, hooks/enforce-worktree.js
# Tags: worker-dispatch, enforce-worktree, hook, guard, overlay, security, lock1, lock2, lock3, control-dir, TL2, scope:issue-specific
#
# Issue #1643 overlay guard + #2434 control-dir extension. Canonical WD-3 form:
#   node "<FAKE_SCRIPT_CHECKOUT_ROOT>/bin/worker-dispatch.js" <worker> <target-main-root> <payload-json>
# Locks 1-3 (script checkout root root, target-main-root match, MAIN worktree in getSessionRepoRoots).
# Drive surface: matchWorkerDispatchOverlay predicate (not the full hook — see
# file comment history for why the BLOCK rows stay at predicate level).
# TL3 gap: real PreToolUse with cwd != hook-cwd; symlinked ~/.claude checkout.

set -u

# Self re-exec under a hard timeout so a hung node probe can never hang the suite.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_GUARD_INNER:-}" ]; then
    _WD1643_GUARD_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_NODE="$(nodepath "$SCRIPT_CHECKOUT_ROOT")"
GUARD_JS="$AGENTS_NODE/hooks/enforce-worktree.js"
OVERLAY_JS="$SCRIPT_CHECKOUT_ROOT/hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
WORKER_SCRIPT_JS="$SCRIPT_CHECKOUT_ROOT/hooks/enforce-worktree/main-worktree-allows/worker-script.js"
REGISTRY_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/worker-dispatch-registry.js"

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
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

FAKE_SCRIPT_CHECKOUT_ROOT_RAW="$TMPD/fake-script-checkout-root"
mkdir -p "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/hooks" "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/bin" "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/xbin"
touch "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/hooks/enforce-worktree.js" "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/bin/worker-dispatch.js"
touch "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/bin/worker-dispatch.js.bak" "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/xbin/worker-dispatch.js"
OTHER_SCRIPT_CHECKOUT_ROOT_RAW="$TMPD/other-script-checkout-root"
mkdir -p "$OTHER_SCRIPT_CHECKOUT_ROOT_RAW/hooks" "$OTHER_SCRIPT_CHECKOUT_ROOT_RAW/bin"
touch "$OTHER_SCRIPT_CHECKOUT_ROOT_RAW/hooks/enforce-worktree.js" "$OTHER_SCRIPT_CHECKOUT_ROOT_RAW/bin/worker-dispatch.js"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
EVIL_RAW="$TMPD/plans-evil"; mkdir -p "$EVIL_RAW"
printf '{}' > "$PLANS_RAW/p.json"
printf '{}' > "$EVIL_RAW/p.json"

MAIN="$(nodepath "$MAIN_RAW")"
ALT="$(nodepath "$ALT_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
FAKE_SCRIPT_CHECKOUT_ROOT="$(nodepath "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW")"
OTHER_SCRIPT_CHECKOUT_ROOT="$(nodepath "$OTHER_SCRIPT_CHECKOUT_ROOT_RAW")"
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
    s="${s//@FAKE_SCRIPT_CHECKOUT_ROOT@/$FAKE_SCRIPT_CHECKOUT_ROOT}"
    s="${s//@OTHER_SCRIPT_CHECKOUT_ROOT@/$OTHER_SCRIPT_CHECKOUT_ROOT}"
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
        node "$PROBE_JS" "$(nodepath "$OVERLAY_JS")" "$cmd" "$FAKE_SCRIPT_CHECKOUT_ROOT" "$repo_root" 2>&1)
}

CANONICAL='node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json'

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
        cmd="$(expand "node \"@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js\" $w @MAIN@ @PLANS@/p.json")"
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
lock3-alt-repo-both        | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json                    | ALT
lock2-mainroot-mismatch    | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json                    | MAIN
lock3-linked-worktree      | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @LINKED@ @PLANS@/p.json                 | LINKED
lock1-other-script-checkout-root            | node "@OTHER_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json             | MAIN
path-bak-suffix            | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js.bak" test-runner @MAIN@ @PLANS@/p.json              | MAIN
path-xbin-prefix           | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/xbin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                 | MAIN
path-unquoted              | node @FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js test-runner @MAIN@ @PLANS@/p.json                    | MAIN
path-single-quoted         | node '@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js' test-runner @MAIN@ @PLANS@/p.json                  | MAIN
path-var-dollar            | node "@DOLLAR@AGENTS_MAIN_ROOT/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json | MAIN
path-tilde                 | node "~/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                      | MAIN
arity-0                    | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js"                                                    | MAIN
arity-1                    | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner                                        | MAIN
arity-2                    | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@                                 | MAIN
arity-4                    | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json extra            | MAIN
unknown-worker             | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" not-a-worker @MAIN@ @PLANS@/p.json                 | MAIN
unknown-worker-case        | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" Test-Runner @MAIN@ @PLANS@/p.json                  | MAIN
payload-outside-plans      | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @MAIN@/p.json                   | MAIN
payload-sibling-prefix     | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @EVIL@/p.json                   | MAIN
payload-dotdot-escape      | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/../plans-evil/p.json    | MAIN
payload-relative           | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ p.json                          | MAIN
meta-semicolon             | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json; id              | MAIN
meta-and-and               | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json && id            | MAIN
meta-pipe                  | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json @PIPE@ cat       | MAIN
meta-cmd-subst             | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @DOLLAR@(pwd) @PLANS@/p.json           | MAIN
meta-backtick              | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @BQ@pwd@BQ@ @PLANS@/p.json             | MAIN
meta-redirect              | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json > @MAIN@/log.txt | MAIN
cd-alt-repo-chain          | cd @ALT@ && node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json       | MAIN
git-c-alt-repo-chain       | git -C @ALT@ status && node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @ALT@ @PLANS@/p.json | MAIN
env-prefix-single          | AGENTS_MAIN_ROOT="@FAKE_SCRIPT_CHECKOUT_ROOT@" node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json | MAIN
env-prefix-bare            | FOO=1 node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json            | MAIN
newline-injection-lf       | node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json@NL@id            | MAIN
newline-injection-leading  | @NL@node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json              | MAIN
interp-bash                | bash "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                  | MAIN
interp-sh                  | sh "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json                    | MAIN
interp-node-flag           | node --experimental-vm-modules "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json | MAIN
eval-wrapper               | eval "@DOLLAR@(node "@FAKE_SCRIPT_CHECKOUT_ROOT@/bin/worker-dispatch.js" test-runner @MAIN@ @PLANS@/p.json)" | MAIN
TABLE
}

# ===========================================================================
# Group C — SANCTIONED array must not grow (the overlay is the only new surface)
# Baseline is 7, not the original 10: #1673 desanctioned 3 entries
# (bin/issue-close-gate.sh, bin/github-issues/issue-close-stage-triage.sh,
# bin/github-issues/parent-body-update.sh) because those scripts are no longer
# invoked directly by the Bash tool from the main worktree — they are now
# subprocess-only, called by the worker-dispatch scripts that replaced the
# retired finalize-worker-overlay.js. This assertion still catches unintended
# growth (or further unexplained shrinkage) past that known baseline.
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
    assert_eq "sanctioned/count-still-7" "7" "$n"
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
    cp -R "$SCRIPT_CHECKOUT_ROOT/hooks" "$sandbox/hooks" 2>/dev/null || true
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
        node "$PROBE_JS" "$(nodepath "$copied")" "$cmd" "$FAKE_SCRIPT_CHECKOUT_ROOT" "$MAIN" 2>&1)"
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
        "ENFORCE_WORKTREE=on" \
        "AGENTS_MAIN_ROOT=$FAKE_SCRIPT_CHECKOUT_ROOT" \
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
    sanctioned_line="$(grep -n 'SANCTIONED.some(' "$WORKER_SCRIPT_JS" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$call_line" ] && [ -n "$sanctioned_line" ] && [ "$call_line" -lt "$sanctioned_line" ]; then
        pass "wiring/overlay-before-sanctioned"
    else
        fail "wiring/overlay-before-sanctioned — call=${call_line:-none} sanctioned=${sanctioned_line:-none}"
    fi
}

# ===========================================================================
# Group 2434-C — #2434 control-dir payload ALLOW; legacy PLANS still ALLOW
# ===========================================================================
CTRL_RAW_2434="$TMPD/wdir-2434"; mkdir -p "$CTRL_RAW_2434"
CTRL_2434="$(nodepath "$CTRL_RAW_2434")"
SID_2434="test2434guard"
mkdir -p "$CTRL_RAW_2434/$SID_2434.control"
CTRL_PAYLOAD_2434="$CTRL_2434/$SID_2434.control/worker-test-runner-1.json"
printf '{}' > "$CTRL_RAW_2434/$SID_2434.control/worker-test-runner-1.json"

# Like overlay_verdict but also exports WORKFLOW_STATE_DIR for control-dir check.
overlay_verdict_ctrl() {
    local cmd="$1" repo_root="$2"
    (cd "$MAIN_RAW" && run_with_timeout 30 env \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        "WORKFLOW_STATE_DIR=$CTRL_2434" \
        node "$PROBE_JS" "$(nodepath "$OVERLAY_JS")" "$cmd" "$FAKE_SCRIPT_CHECKOUT_ROOT" "$repo_root" 2>&1)
}

group_control_dir_allow() {
    if [ ! -f "$OVERLAY_JS" ]; then
        fail "2434-ctrl/control-dir-payload-allowed — overlay absent"
        fail "2434-ctrl/legacy-plans-still-allowed — overlay absent"
        return
    fi
    # WD-3 form with payload in <sid>.control/ → ALLOW after fix.
    # Before fix: overlay checks only PLANS residency → BLOCK → FAIL.
    local ctrl_cmd
    ctrl_cmd="$(printf 'node "%s/bin/worker-dispatch.js" test-runner "%s" "%s"' \
        "$FAKE_SCRIPT_CHECKOUT_ROOT" "$MAIN" "$CTRL_PAYLOAD_2434")"
    assert_eq "2434-ctrl/control-dir-payload-allowed" "ALLOW" \
        "$(overlay_verdict_ctrl "$ctrl_cmd" "$MAIN")"
    # Legacy PLANS payload must remain ALLOW (existing-behaviour contract; passes today).
    assert_eq "2434-ctrl/legacy-plans-still-allowed" "ALLOW" \
        "$(overlay_verdict "$(expand "$CANONICAL")" "$MAIN")"
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

case_begin "registry" "hooks/lib/worker-dispatch-registry.js"
group_registry
case_end

case_begin "overlay-allow-block" "hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js"
group_allow
group_block
group_sanctioned_count
group_fail_closed
case_end

case_begin "wiring" "hooks/enforce-worktree/main-worktree-allows/worker-script.js"
group_wiring
case_end

case_begin "control-dir" "hooks/enforce-worktree.js"
group_control_dir_allow
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
