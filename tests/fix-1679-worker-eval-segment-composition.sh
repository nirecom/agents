#!/bin/bash
# tests/fix-1679-worker-eval-segment-composition.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js, skills/issue-close-finalize/SKILL.md
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Issue #1679 (S-8) — isAllowedWorkerScriptInvocation's eval-unwrap regex is
# END-ANCHORED:
#   /^\s*eval\s+"\$\(bash\s+"([^"]+)"\s*\)"\s*(?:\|\|\s*exit\s+0\s*)?$/
# so a sanctioned pre-flight.sh eval stops matching the moment ANY benign
# companion segment is present — a leading `cd "<repo>" &&`, a trailing
# `; echo "OWNER_REPO=$OWNER_REPO"`, or a `2>&1` fd-dup. That single anchor is
# the root cause of the large majority of the logged blocked incidents, all of
# which are the documented /issue-close-finalize pre-flight shape.
#
# The fix replaces the anchor with a segment-composition rule: exactly ONE
# sanctioned segment, and every companion segment must be write=null AND
# non-env-mutating (new ENV_MUTATION_RE / ASSIGN_RE guards). The env-mutation
# guards close the confused-deputy hole that a naive composition rule would open
# together with the S-7 $AGENTS_CONFIG_DIR prefix resolution: detectWritePredicate
# classifies `export VAR=val`, `VAR=val`, `unset VAR` and `source f` as read
# (null), so without them an attacker could repoint AGENTS_CONFIG_DIR in a
# companion segment and have the sanctioned segment resolve against it.
#
# IN1679-*  real logged blocked command strings — RED before the fix, GREEN after
#           (IN1679-6 is the already-working bare shape: GREEN before AND after).
# AD1679-*  adversarial compositions — BLOCK before AND after the fix. These are
#           the security boundary the S-8 widening must not breach.
# E2E1679-* end-to-end decision + block-reason assertions on the same surface.
# MU1679-*  TL1 unit rows calling isAllowedWorkerScriptInvocation() directly, so
#           the predicate is isolated from every other branch of the hook.
#
# Drive surface (full hook, TL2):
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR=<fake-acd> \
#      WORKFLOW_PLANS_DIR=<plans> node hooks/enforce-worktree.js)
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real /session-close → /issue-close-finalize chain issuing the eval from a
#     genuine main worktree with a live AGENTS_CONFIG_DIR and real finalize scripts.
#   - Whether the hook is actually registered as PreToolUse in settings.json, so a
#     real Claude Code session routes the Bash command through it at all.
#   - Real shell expansion of $AGENTS_CONFIG_DIR inside the eval sub-shell.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

# Self-re-exec under a hard timeout BEFORE any fixture is built, so the outer
# process never pays for the git init / worktree add it is about to discard.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1679_SEG_INNER:-}" ]; then
        _FIX1679_SEG_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1679-seg-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_bash_payload() {
    local cmd="$1"
    local q; q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

# Run the guard with cwd set to <main-worktree>.
# Returns: 0 = ALLOW, 1 = BLOCK, 2 = CRASH.
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1"; shift
    local main_wt="$1"; shift
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        -C "$main_wt" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        return 2
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# `env -C` is a GNU coreutils extension (>=8.28). Fallback: subshell `cd` + env.
if ! env -C "$TMPDIR_BASE" true 2>/dev/null; then
    run_guard() {
        local payload="$1"; shift
        local main_wt="$1"; shift
        GUARD_RC=0
        GUARD_OUT="$(cd "$main_wt" && printf '%s' "$payload" | run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE \
            "ENFORCE_WORKTREE=on" \
            "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
            "$@" \
            node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
        if [ "$GUARD_RC" -ne 0 ]; then
            return 2
        fi
        if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
            return 1
        fi
        return 0
    }
fi

assert_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; out: $GUARD_OUT)" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

# ----------------------------------------------------------------------------
# Fixtures — one shared main worktree + linked worktree + fake acd + plans dir.
# No case mutates fixture state, so a single build keeps the 25+ guard spawns
# inside the 120s budget. Pattern lifted from tests/fix-1600-finalize-worker-overlay.sh.
# ----------------------------------------------------------------------------

setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$wt_path"; else echo "$wt_path"; fi
}

# Fake AGENTS_CONFIG_DIR carrying BOTH trust markers (hooks/enforce-worktree.js
# and bin/) so hooks/lib/agents-config-dir.js accepts it as a legitimate agents
# checkout — the hostile marker-less case is owned by tests/fix-1630-*.sh.
setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues" "$d/hooks"
    touch "$d/hooks/enforce-worktree.js"
    touch "$d/bin/check-unstaged-tracked.sh"
    touch "$d/bin/issue-close-gate.sh"
    # AD1679-7 target: present on disk but deliberately NOT in SANCTIONED.
    touch "$d/bin/evil.sh"
    mkdir -p "$d/skills/issue-close-finalize/scripts"
    touch "$d/skills/issue-close-finalize/scripts/pre-flight.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-initial.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-loop-step.js"
    touch "$d/skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

setup_plans_dir() {
    local d="$TMPDIR_BASE/plans-$1"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

REPO="$(setup_main_worktree "repo")"
LINKED="$(add_linked_worktree "$REPO" "wt1" "feat/x")"
ACD="$(setup_fake_acd "main")"
PLANS="$(setup_plans_dir "main")"
SCRIPTS="$ACD/skills/issue-close-finalize/scripts"

# The literal (unexpanded) prefix is what PreToolUse actually receives, because
# the hook fires BEFORE the shell expands the command.
PF_LITERAL='$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/pre-flight.sh'
PF_RESOLVED="$SCRIPTS/pre-flight.sh"

# eval-wrapped sanctioned segment. $1 = script path literal.
pf_eval() { printf 'eval "$(bash "%s")"' "$1"; }

# Convenience: run one command through the guard against the shared fixture.
guard() {
    local cmd="$1"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$REPO" \
        "AGENTS_CONFIG_DIR=$ACD" "WORKFLOW_PLANS_DIR=$PLANS" || rc=$?
    return $rc
}

# ============================================================================
# IN — real logged blocked forms. All are the documented pre-flight/run-initial
#      shapes; every one but IN1679-6 is RED before the fix.
# ============================================================================

test_in_cases() {
    echo "=== IN: real logged blocked command forms ==="
    local cmd rc

    # IN1679-1 — the single most-observed blocked form (leading `cd` segment).
    cmd="$(printf 'cd "%s" && %s && echo "OWNER_REPO=$OWNER_REPO"' "$REPO" "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-1: cd <repo> && pre-flight eval && echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-2 — the form that blocked the #1679 filing session itself.
    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-2: pre-flight eval || exit 0; echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-3 — same as IN1679-2 but with the acd already resolved.
    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-3: resolved-path pre-flight eval || exit 0; echo → ALLOW (RED before fix)" "$rc"

    # IN1679-4 — fd-dup between the sanctioned segment and the companion segment.
    cmd="$(printf '%s 2>&1 && echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-4: pre-flight eval 2>&1 && echo OWNER_REPO → ALLOW (RED before fix)" "$rc"

    # IN1679-5 — S-6 2-argument run-initial.sh plus a trailing echo companion.
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234")"; echo "STATUS=$STATUS"' \
        "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-5: run-initial 2-arg eval; echo STATUS → ALLOW (RED before fix)" "$rc"

    # IN1679-6 — the bare shape documented in issue-close-finalize/SKILL.md.
    # Already allowed by the #1484 eval-unwrap; pinned here as the no-regression anchor.
    cmd="$(pf_eval "$PF_LITERAL")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "IN1679-6: bare pre-flight eval, no companion segment → ALLOW (no regression)" "$rc"
}

# ============================================================================
# AD — adversarial compositions. BLOCK before AND after the S-8 widening.
# ============================================================================

test_ad_cases() {
    echo "=== AD: adversarial segment compositions (must stay BLOCK) ==="
    local cmd rc

    # AD1679-1: companion segment on a NEW LINE performing a real write.
    cmd="$(printf '%s || exit 0\nrm -f README.md' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-1: pre-flight + newline + rm -f README.md → BLOCK" "$rc"

    # AD1679-2: companion segment redirects into the main worktree.
    cmd="$(printf '%s && echo x > out.txt' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-2: pre-flight + echo x > out.txt → BLOCK" "$rc"

    # AD1679-3: write hidden inside a command substitution in the companion.
    cmd="$(printf '%s && echo "$(rm -f x)"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-3: pre-flight + echo \"\$(rm -f x)\" → BLOCK" "$rc"

    # AD1679-4: opaque dynamic eval as the companion segment.
    cmd="$(printf '%s ; eval "$DYNAMIC"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-4: pre-flight + eval \"\$DYNAMIC\" → BLOCK" "$rc"

    # AD1679-5: git write as the companion segment.
    cmd="$(printf '%s && git commit -m x' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-5: pre-flight + git commit -m x → BLOCK" "$rc"

    # AD1679-6: TWO sanctioned segments — the rule admits exactly one.
    cmd="$(printf '%s && %s' "$(pf_eval "$PF_LITERAL")" "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-6: pre-flight eval chained twice → BLOCK" "$rc"

    # AD1679-7: eval of a non-sanctioned script under acd, with a read companion.
    cmd="$(printf 'eval "$(bash "%s/bin/evil.sh")" ; echo hi' "$ACD")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-7: eval of non-allowlisted <acd>/bin/evil.sh ; echo hi → BLOCK" "$rc"

    # AD1679-8: pipe into a writer whose target lands in the main worktree.
    # The plan wrote this row as `| tee /tmp/x`, but that target is OUTSIDE
    # session scope, and ENFORCE_WORKTREE deliberately guards only writes into
    # the main worktree — so `/tmp/x` is allowed by design and cannot express the
    # boundary at TL2. A main-worktree-relative target expresses the same intent
    # (a writer must not ride along on the sanctioned segment) observably.
    cmd="$(printf '%s | tee out.txt' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-8: pre-flight + | tee out.txt (main-worktree target) → BLOCK" "$rc"

    # AD1679-8b: the plan's literal form, pinned with its correct expectation so
    # the in-scope/out-of-scope distinction above stays explicit rather than
    # silently dropped. This is ENFORCE_WORKTREE's documented scope, not a gap.
    cmd="$(printf '%s | tee /tmp/x' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "AD1679-8b: pre-flight + | tee /tmp/x (out-of-scope target) → ALLOW by design" "$rc"

    # ---- Confused-deputy guards (ENV_MUTATION_RE / ASSIGN_RE) ---------------
    # Each of the four leading segments below is classified read (null) by
    # detectWritePredicate, so a write-only composition rule would admit them —
    # and each can repoint the very variable the sanctioned segment resolves against.

    # AD1679-9: export repoints AGENTS_CONFIG_DIR before the sanctioned segment.
    cmd="$(printf 'export AGENTS_CONFIG_DIR=/evil; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-9: export AGENTS_CONFIG_DIR=/evil; + pre-flight → BLOCK (env mutation)" "$rc"

    # AD1679-10: bare assignment, same effect.
    cmd="$(printf 'AGENTS_CONFIG_DIR=/evil ; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-10: AGENTS_CONFIG_DIR=/evil ; + pre-flight → BLOCK (assignment)" "$rc"

    # AD1679-11: unset makes the literal prefix resolve against nothing.
    cmd="$(printf 'unset AGENTS_CONFIG_DIR; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-11: unset AGENTS_CONFIG_DIR; + pre-flight → BLOCK (env mutation)" "$rc"

    # AD1679-12: `source` can mutate the environment arbitrarily and opaquely.
    cmd="$(printf 'source /tmp/x.sh && %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "AD1679-12: source /tmp/x.sh && + pre-flight → BLOCK (opaque env mutation)" "$rc"
}

# ============================================================================
# E2E — decision + block-reason assertions against the real hook process.
# ============================================================================

test_e2e_cases() {
    echo "=== E2E: real hook process, main worktree on branch main ==="
    local cmd rc

    cmd="$(printf 'cd "%s" && %s && echo "OWNER_REPO=$OWNER_REPO"' "$REPO" "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-1: IN1679-1 through hooks/enforce-worktree.js → exit 0 (RED before fix)" "$rc"

    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-2: IN1679-2 through hooks/enforce-worktree.js → exit 0 (RED before fix)" "$rc"

    # E2E1679-3 also asserts the block REASON, not just the decision: an
    # adversarial composition must be refused as a main-worktree write, not
    # silently allowed nor blocked for some unrelated reason.
    cmd="$(printf '%s || exit 0\nrm -f README.md' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-3: AD1679-1 through the real hook → BLOCK" "$rc"
    if [ "$rc" -eq 1 ]; then
        if echo "$GUARD_OUT" | grep -q "main worktree"; then
            pass "E2E1679-3-reason: block reason mentions 'main worktree'"
        else
            fail "E2E1679-3-reason: block reason lacks 'main worktree' (out: $GUARD_OUT)"
        fi
    else
        fail "E2E1679-3-reason: not blocked, reason unassertable (rc=$rc)"
    fi

    cmd="$(printf 'export AGENTS_CONFIG_DIR=/evil; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-4: AD1679-9 through the real hook → BLOCK" "$rc"

    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234")"' \
        "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-5: run-initial 2-arg form (S-6) through the real hook → exit 0 (RED before fix)" "$rc"
}

# =============================================================================
# TL1 — Direct unit tests for companion-segment ENV_MUTATION guard (S-8)
# =============================================================================
# These call isAllowedWorkerScriptInvocation() directly (no subprocess).
# Before fix: env-mutation BLOCK cases are GREEN (existing behavior),
# but benign-companion ALLOW cases that need segmentation are RED (bug not fixed).
# After fix: all GREEN.
#
# Why TL1 in addition to the TL2 rows above: the TL2 driver observes only the
# hook's final decision, which is the OR/AND of several predicates. If
# isAllowedWorkerScriptInvocation itself regressed but some other branch of
# hooks/enforce-worktree.js happened to block (or allow) the same string, TL2
# could not tell the difference. These rows isolate the predicate.
#
# The acd is resolved by hooks/lib/agents-config-dir.js from
# process.env.AGENTS_CONFIG_DIR (marker-validated), so the shared fake-acd
# fixture is passed through env; repoRoot is the shared main worktree, which
# owns one registered linked worktree.

TL1_JS="$TMPDIR_BASE/tl1-worker-script.js"

cat > "$TL1_JS" <<'TL1_EOF'
"use strict";
const assert = require("assert");
const { isAllowedWorkerScriptInvocation } = require(process.env.TL1_WORKER_JS);

const repoRoot = process.env.TL1_REPO;

// Literal (unexpanded) pre-flight eval — exactly what PreToolUse receives.
const PF =
  'eval "$(bash "$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/pre-flight.sh")"';

const cases = [
  // -- ENV_MUTATION companion segments: BLOCK before AND after the fix. ------
  ["MU1679-TL1-1", PF + ' && export AGENTS_CONFIG_DIR=/evil', false,
    "export in companion segment"],
  ["MU1679-TL1-2", PF + ' ; AGENTS_CONFIG_DIR=/evil', false,
    "bare assignment in companion segment"],
  ["MU1679-TL1-3", PF + ' && unset AGENTS_CONFIG_DIR', false,
    "unset in companion segment"],
  ["MU1679-TL1-4", PF + ' && source /tmp/x.sh', false,
    "source in companion segment"],
  ["MU1679-TL1-5", PF + ' && eval "$DYNAMIC"', false,
    "opaque eval in companion segment"],
  ["MU1679-TL1-6", 'export AGENTS_CONFIG_DIR=/evil; ' + PF, false,
    "mutation BEFORE the sanctioned segment"],

  // -- Benign companion segments: ALLOW after the fix. ----------------------
  ["MU1679-TL1-7", 'cd "' + repoRoot + '" && ' + PF + ' && echo "OWNER_REPO=$OWNER_REPO"', true,
    "leading cd + trailing echo companions"],
  ["MU1679-TL1-8", PF + ' || exit 0', true,
    "|| exit 0 tail"],
  ["MU1679-TL1-9", PF, true,
    "no companion segment"],
];

// The bash side parses one TAB-delimited record per line, so every detail
// string is flattened first — Node's AssertionError message is multi-line.
const flat = (s) => String(s).replace(/\s+/g, " ").trim();
const emit = (status, label, detail) =>
  console.log([status, label, flat(detail)].join("\t"));

for (const [label, cmd, expected, why] of cases) {
  let actual;
  try {
    actual = isAllowedWorkerScriptInvocation(cmd, repoRoot);
  } catch (e) {
    emit("NG", label, why + " -> THREW " + e.message);
    continue;
  }
  try {
    assert.strictEqual(
      actual, expected,
      why + " -> expected " + expected + ", got " + actual
    );
    emit("OK", label, why + " -> " + (expected ? "ALLOW" : "BLOCK"));
  } catch (e) {
    emit("NG", label, e.message);
  }
}
TL1_EOF

test_tl1_cases() {
    echo "=== TL1: isAllowedWorkerScriptInvocation() called directly ==="
    local out rc=0
    out="$(run_with_timeout 30 env \
        "AGENTS_CONFIG_DIR=$ACD" \
        "TL1_WORKER_JS=${_AGENTS_DIR_NODE}/hooks/enforce-worktree/main-worktree-allows/worker-script.js" \
        "TL1_REPO=$REPO" \
        node "$TL1_JS" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "MU1679-TL1: runner crashed (rc=$rc; out: $out)"
        return
    fi
    local status label detail
    while IFS=$'\t' read -r status label detail; do
        [ -z "${status:-}" ] && continue
        case "$status" in
            OK) pass "$label: $detail" ;;
            NG) fail "$label: $detail" ;;
            *)  fail "MU1679-TL1: unparsable runner line: $status $label $detail" ;;
        esac
    done <<< "$out"
}

# ============================================================================
# Run all
# ============================================================================

test_in_cases
test_ad_cases
test_e2e_cases
test_tl1_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
