#!/bin/bash
# tests/fix-1441-new-item-scratchpad-allow.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/enforce-worktree/main-worktree-allows/new-item.js, hooks/enforce-worktree/main-worktree-allows/worktree-command.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/universal-target-allow.js, hooks/lib/bash-write-targets/helpers.js, hooks/lib/claude-scratchpad-base.js
# Tags: enforce-worktree, new-item, scratchpad, plans-dir, ir-migration, scope:issue-specific, pwsh-not-required
#
# Regression canary for #1441 / #1290 / #923: after PR #1420 (WRITE_PATTERNS→IR
# migration) regressed enforce-worktree, the fix restored the sanctioned allow paths.
# This test asserts the post-fix allow/block contract permanently. Each case is one of
# two kinds: ALLOW-expected (sanctioned command must pass from main/non-git CWD) or
# BLOCK-expected (in-repo / bypass / cross-session writes must be denied). If the source
# fix is reverted, the ALLOW-expected cases go RED — that is the canary's purpose.
#
# L3 gap (what this test does NOT catch):
# - Hook registration: tests call enforce-worktree.js directly as a Node.js process,
#   not via the real Claude Code PreToolUse hook chain. L3 would verify the hook
#   actually fires and returns the correct verdict when claude -p runs a Bash command.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
run_with_timeout() { local s="$1"; shift; command -v timeout >/dev/null 2>&1 && timeout "$s" "$@" || perl -e 'alarm shift; exec @ARGV' "$s" "$@" 2>/dev/null || "$@"; }

# ── Setup ─────────────────────────────────────────────────────────────────────
# Use node os.tmpdir() for Windows-native paths so path.dirname in findRepoRoot
# correctly detects in-repo targets on Windows (backslash = real separator in Node).
TMPBASE="$(node -e "var o=require('os'),p=require('path'),f=require('fs');var d=p.join(o.tmpdir(),'test-1441-'+process.pid);f.mkdirSync(d,{recursive:true});process.stdout.write(d);" 2>/dev/null)"
[ -z "$TMPBASE" ] && { echo "FAIL: could not create temp base"; exit 1; }

MAIN_REPO="${TMPBASE}/repo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main; git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"; git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"; git -C "$MAIN_REPO" add README.md; git -C "$MAIN_REPO" commit -q -m "initial"

NONGIT_CWD="${TMPBASE}/nongit"; mkdir -p "$NONGIT_CWD"
TMPPLANS="${TMPBASE}/plans"; mkdir -p "$TMPPLANS"
if command -v cygpath >/dev/null 2>&1; then
    TMPPLANS_NODE="$(cygpath -m "$TMPPLANS")"; MAIN_REPO_NODE="$(cygpath -m "$MAIN_REPO")"
else
    TMPPLANS_NODE="$TMPPLANS"; MAIN_REPO_NODE="$MAIN_REPO"
fi

# Fake session scratchpad: <os-tmpdir>/claude/<slug>/<session-id>/scratchpad
FAKE_SCRATCHPAD="$(node -e "var o=require('os'),p=require('path');process.stdout.write(p.join(o.tmpdir(),'claude','c--test-1441','sess-1441','scratchpad'));" 2>/dev/null)"
mkdir -p "$FAKE_SCRATCHPAD" 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then FAKE_SCRATCHPAD_NODE="$(cygpath -m "$FAKE_SCRATCHPAD")"; else FAKE_SCRATCHPAD_NODE="$FAKE_SCRATCHPAD"; fi

# Two distinct session scratchpads under the same claude base (H2 cross-session scoping).
SCRATCH_SESSA="$(node -e "var o=require('os'),p=require('path');process.stdout.write(p.join(o.tmpdir(),'claude','c--test-1441','sessA','scratchpad'));" 2>/dev/null)"
SCRATCH_SESSB="$(node -e "var o=require('os'),p=require('path');process.stdout.write(p.join(o.tmpdir(),'claude','c--test-1441','sessB','scratchpad'));" 2>/dev/null)"
mkdir -p "$SCRATCH_SESSA" "$SCRATCH_SESSB" 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then
    SCRATCH_SESSA_NODE="$(cygpath -m "$SCRATCH_SESSA")"; SCRATCH_SESSB_NODE="$(cygpath -m "$SCRATCH_SESSB")"
else
    SCRATCH_SESSA_NODE="$SCRATCH_SESSA"; SCRATCH_SESSB_NODE="$SCRATCH_SESSB"
fi
SESSA_FWD="${SCRATCH_SESSA_NODE//\\//}"; SESSB_FWD="${SCRATCH_SESSB_NODE//\\//}"

EXT_WORKTREE="${TMPBASE}/worktrees/some-task"
EXT_WORKTREE_WIN="${TMPBASE}\\worktrees\\some-task"

cleanup() { rm -rf "$TMPBASE" "$SCRATCH_SESSA" "$SCRATCH_SESSB" "$FAKE_SCRATCHPAD" 2>/dev/null || true; }
trap cleanup EXIT

PLANS_FWD="${TMPPLANS_NODE//\\//}"
SCRATCH_FWD="${FAKE_SCRATCHPAD_NODE//\\//}"
MAIN_REPO_FWD="${MAIN_REPO_NODE//\\//}"

# ── Hook runners ──────────────────────────────────────────────────────────────
_make_payload() {
    node -e "var o={tool_name:'Bash',tool_input:{command:process.argv[1]},session_id:'test-1441'};process.stdout.write(JSON.stringify(o));" -- "$1" 2>/dev/null
}
run_hook() {
    local p; p="$(_make_payload "$1")"
    ( cd "$MAIN_REPO" && ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" AGENTS_CONFIG_DIR="$MAIN_REPO_NODE" CLAUDE_SESSION_ID=test-1441 MSYS_NO_PATHCONV=1 run_with_timeout 15 node "$HOOK" <<< "$p" 2>/dev/null )
}
run_nongit() {
    local p; p="$(_make_payload "$1")"
    ( cd "$NONGIT_CWD" && ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" AGENTS_CONFIG_DIR="$NONGIT_CWD" CLAUDE_SESSION_ID=test-1441 MSYS_NO_PATHCONV=1 run_with_timeout 15 node "$HOOK" <<< "$p" 2>/dev/null )
}
run_hook_env() {
    local cmd="$1"; shift; local p; p="$(_make_payload "$cmd")"
    ( cd "$MAIN_REPO" || exit 1; for _kv in "$@"; do export "$_kv"; done
      ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" AGENTS_CONFIG_DIR="$MAIN_REPO_NODE" CLAUDE_SESSION_ID=test-1441 MSYS_NO_PATHCONV=1 run_with_timeout 15 node "$HOOK" <<< "$p" 2>/dev/null )
}
# run_hook_unset: like run_hook but explicitly UNSETs the named env vars first
run_hook_unset() {
    local cmd="$1"; shift; local p; p="$(_make_payload "$cmd")"
    ( cd "$MAIN_REPO" || exit 1; for _v in "$@"; do unset "$_v"; done
      ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" AGENTS_CONFIG_DIR="$MAIN_REPO_NODE" CLAUDE_SESSION_ID=test-1441 MSYS_NO_PATHCONV=1 run_with_timeout 15 node "$HOOK" <<< "$p" 2>/dev/null )
}
# run_nongit_env: run_nongit + extra KEY=VAL env vars (mirror of run_hook_env)
run_nongit_env() {
    local cmd="$1"; shift; local p; p="$(_make_payload "$cmd")"
    ( cd "$NONGIT_CWD" || exit 1; for _kv in "$@"; do export "$_kv"; done
      ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" AGENTS_CONFIG_DIR="$NONGIT_CWD" CLAUDE_SESSION_ID=test-1441 MSYS_NO_PATHCONV=1 run_with_timeout 15 node "$HOOK" <<< "$p" 2>/dev/null )
}
is_allow() { [ "$1" = "{}" ]; }
is_block() { echo "$1" | grep -q '"decision":"block"'; }

# SKIPPED: real claude -p session where PreToolUse intercepts these Bash commands live
# Because: requires RUN_E2E=on + real settings.json hook registration; not reproducible at L2
# L3 gap: settings.json hook wiring — whether enforce-worktree.js fires at all in a live session

# ── ALLOW-expected: sanctioned commands the guard must permit ─────────────────
test_already_green() {
    local got
    # AG-P1: heredoc to literal plans-dir path
    got="$(run_hook "cat <<'EOF' > \"${PLANS_FWD}/test-canary.md\""$'\n'"content"$'\n'"EOF"$'\n')"
    if is_allow "$got"; then pass "AG-P1: heredoc literal plans-dir → allow"; else fail "AG-P1: should allow (got: $got)"; fi

    # AG-P2: heredoc $HOME/.workflow-plans
    got="$(run_hook "cat <<'EOF' > \"\$HOME/.workflow-plans/test-canary.md\""$'\n'"content"$'\n'"EOF"$'\n')"
    if is_allow "$got"; then pass "AG-P2: heredoc \$HOME/.workflow-plans → allow"; else fail "AG-P2: should allow (got: $got)"; fi

    # AG-P3: heredoc scratchpad from git-rooted CWD (repoRoot + outside-session-scope)
    got="$(run_hook "cat <<'EOF' > \"${SCRATCH_FWD}/x.md\""$'\n'"content"$'\n'"EOF"$'\n')"
    if is_allow "$got"; then pass "AG-P3: heredoc scratchpad (git CWD) → allow"; else fail "AG-P3: should allow (got: $got)"; fi

    # AG-P6: read-only node -e (no write target visible to hook)
    got="$(run_hook "node -e \"const fs=require('fs');console.log(fs.readFileSync('docs/history.md','utf8').length)\"")"
    if is_allow "$got"; then pass "AG-P6: read-only node -e → allow"; else fail "AG-P6: should allow (got: $got)"; fi

    # AG-P7: node -e writeFileSync to plans-dir
    got="$(run_hook "node -e \"require('fs').writeFileSync(process.env.HOME+'/.workflow-plans/canary.json','{}')\"" )"
    if is_allow "$got"; then pass "AG-P7: node -e writeFileSync plans-dir → allow"; else fail "AG-P7: should allow (got: $got)"; fi

    # AG-P8: bash sanctioned dispatcher (KNOWN_DISPATCH_SUFFIXES)
    got="$(run_hook "bash \"bin/github-issues/issue-create-dispatch.sh\" --dry-run --title \"test\" --labels \"type:task\"")"
    if is_allow "$got"; then pass "AG-P8: bash issue-create-dispatch.sh → allow"; else fail "AG-P8: should allow (got: $got)"; fi

    # AG-P5: gh issue comment — included as ALREADY_GREEN (probe confirmed).
    # NOTE: may be separate root cause (#1246); split to new issue if classification proves it.
    got="$(run_hook "gh issue comment 1109 --body \"test\"")"
    if is_allow "$got"; then pass "AG-P5: gh issue comment → allow"; else fail "AG-P5: should allow (got: $got)"; fi

    # AG-NI-dq-scratchpad: DOUBLE-quoted $SCRATCHPAD path expands and resolves under the
    # session scratchpad → allow. CPR-5 symmetry pair for INV-NI-sq-scratchpad (single-quote blocks).
    got="$(run_hook_env "New-Item -ItemType Directory -Force -Path \"\$SCRATCHPAD/x\"" "SCRATCHPAD=${SCRATCH_SESSA_NODE}")"
    if is_allow "$got"; then pass "AG-NI-dq-scratchpad: New-Item \"\$SCRATCHPAD/x\" (double-quote) → allow"; else fail "AG-NI-dq-scratchpad: should allow (got: $got)"; fi

    # AG-SCRATCH-same-session: SCRATCHPAD=sessA, target under sessA's own dir, from non-git CWD
    # → allow (H2 same-session). CPR-5 symmetry pair for INV-SCRATCH-cross-session.
    got="$(run_nongit_env "echo x > \"${SESSA_FWD}/x.md\"" "SCRATCHPAD=${SCRATCH_SESSA_NODE}")"
    if is_allow "$got"; then pass "AG-SCRATCH-same-session: sessA target (SCRATCHPAD=sessA) → allow"; else fail "AG-SCRATCH-same-session: should allow (got: $got)"; fi

    # AG-WTR-remove / prune: git worktree lifecycle from main worktree (#923)
    # NOTE: EXT_WORKTREE is intentionally NOT registered via `git worktree add` —
    # isAllowedWorktreeCommand (main-worktree-allows/standard.js:73) allowlists the
    # `git worktree remove|prune` command FORM by string-match (after chaining/--force
    # guards), without consulting registration state. Unregistered paths are valid inputs.
    got="$(run_hook "git worktree remove ${EXT_WORKTREE}")"; if is_allow "$got"; then pass "AG-WTR-remove → allow"; else fail "AG-WTR-remove should allow (got: $got)"; fi
    got="$(run_hook "git worktree prune")"; if is_allow "$got"; then pass "AG-WTR-prune → allow"; else fail "AG-WTR-prune should allow (got: $got)"; fi
}

# ── ALLOW-expected: sanctioned paths the #1420 fix restored (RED if fix reverted) ─
# Each case asserts ALLOW. These were regressed by PR #1420 and re-permitted by the fix;
# a plain is_allow check makes them the RE-regression canary — reverting the source fix
# turns every case here RED.
test_restored_allows() {
    local got
    # P4: stdout redirect to $SCRATCHPAD env-var (root cause A: expandStaticShellTokens)
    got="$(run_hook_env "bash \"bin/supervisor-review-codex\" --generate > \"\$SCRATCHPAD/sup-out.jsonl\"" "SCRATCHPAD=${FAKE_SCRATCHPAD_NODE}")"
    if is_allow "$got"; then pass "P4: bash --generate > \$SCRATCHPAD/sup-out.jsonl → allow"; else fail "P4: should allow (got: $got)"; fi

    # P4b: brace form ${SCRATCHPAD} (expandStaticShellTokens must handle both $VAR and ${VAR})
    got="$(run_hook_env "bash \"bin/supervisor-review-codex\" --generate > \"\${SCRATCHPAD}/sup-out2.jsonl\"" "SCRATCHPAD=${FAKE_SCRATCHPAD_NODE}")"
    if is_allow "$got"; then pass "P4b: bash --generate > \${SCRATCHPAD}/sup-out2.jsonl (brace form) → allow"; else fail "P4b: should allow (got: $got)"; fi

    # NI-1/NI-3/NI-alias: New-Item external dir (root cause B: isAllowedNewItemCommand)
    got="$(run_hook "New-Item -ItemType Directory -Force -Path \"${EXT_WORKTREE_WIN}\"")"; if is_allow "$got"; then pass "NI-1: New-Item -ItemType Directory -Force -Path <ext> → allow"; else fail "NI-1: should allow (got: $got)"; fi
    got="$(run_hook "New-Item -ItemType Directory -Path \"${EXT_WORKTREE_WIN}/sub\"")"; if is_allow "$got"; then pass "NI-3: New-Item -ItemType Directory -Path <ext> → allow"; else fail "NI-3: should allow (got: $got)"; fi
    got="$(run_hook "ni -ItemType Directory -Force -Path \"${EXT_WORKTREE_WIN}\"")"; if is_allow "$got"; then pass "NI-alias: ni -ItemType Directory <ext> → allow"; else fail "NI-alias: should allow (got: $got)"; fi

    # P3-nongit: heredoc to scratchpad from non-git CWD (root cause C: areAllBashTargetsUnderClaude)
    got="$(run_nongit "cat <<'EOF' > \"${SCRATCH_FWD}/x.md\""$'\n'"content"$'\n'"EOF"$'\n')"
    if is_allow "$got"; then pass "P3-nongit: heredoc scratchpad from non-git CWD → allow"; else fail "P3-nongit: should allow (got: $got)"; fi

    # P3b-nongit: direct (non-heredoc) redirect to scratchpad from non-git CWD — plain-redirect codepath
    got="$(run_nongit "echo x > \"${SCRATCH_FWD}/x.md\"")"
    if is_allow "$got"; then pass "P3b-nongit: direct redirect scratchpad from non-git CWD → allow"; else fail "P3b-nongit: should allow (got: $got)"; fi

    # P4-nongit: root cause A+C interaction — $SCRATCHPAD redirect from non-git CWD, resolving
    # to the real claude scratchpad. Needs BOTH the expansion fix (A) and the claude-dir allowlist (C).
    got="$(run_nongit_env "echo x > \"\$SCRATCHPAD/x.md\"" "SCRATCHPAD=${FAKE_SCRATCHPAD_NODE}")"
    if is_allow "$got"; then pass "P4-nongit: \$SCRATCHPAD redirect from non-git CWD → allow"; else fail "P4-nongit: should allow (got: $got)"; fi
}

# ── BLOCK-expected: in-repo / bypass / cross-session writes the guard must deny ─
test_invariant_block() {
    local got
    # INV-P4-unset: $SCRATCHPAD redirect with SCRATCHPAD env var UNSET — BLOCK (fail-closed
    # on unresolvable $VAR). Guards against a future fix blanket-allowing $VAR-prefixed redirects.
    got="$(run_hook_unset "bash \"bin/supervisor-review-codex\" --generate > \"\$SCRATCHPAD/x\"" SCRATCHPAD)"
    if is_block "$got"; then pass "INV-P4-unset: \$SCRATCHPAD redirect with var unset → block"; else fail "INV-P4-unset: should block (got: $got)"; fi

    # INV-P4-inrepo: primary bypass vector — SCRATCHPAD set to an IN-REPO path. The fix
    # must gate on the RESOLVED path being under <os-tmpdir>/claude/, not on the var name.
    got="$(run_hook_env "echo x > \"\$SCRATCHPAD/evil.md\"" "SCRATCHPAD=${MAIN_REPO_FWD}/scratch")"
    if is_block "$got"; then pass "INV-P4-inrepo: \$SCRATCHPAD=in-repo path redirect → block"; else fail "INV-P4-inrepo: should block (got: $got)"; fi

    # INV-P4-nongit-inrepo: A+C interaction with a DISALLOWED resolved path from non-git CWD —
    # SCRATCHPAD pointing into a repo (not under <tmpdir>/claude/) must stay fail-closed.
    got="$(run_nongit_env "echo x > \"\$SCRATCHPAD/x.md\"" "SCRATCHPAD=${MAIN_REPO_FWD}/scratch")"
    if is_block "$got"; then pass "INV-P4-nongit-inrepo: \$SCRATCHPAD=in-repo path from non-git CWD → block"; else fail "INV-P4-nongit-inrepo: should block (got: $got)"; fi

    # INV-NI-sq-scratchpad (H1 bypass canary): SINGLE-quoted '$SCRATCHPAD/x' is a PowerShell
    # LITERAL — no env expansion → resolves to an in-CWD relative "$SCRATCHPAD" dir → block.
    # SCRATCHPAD env IS set to the real scratchpad, proving the block is quote-driven, not var-driven.
    got="$(run_hook_env "New-Item -ItemType Directory -Force -Path '\$SCRATCHPAD/x'" "SCRATCHPAD=${SCRATCH_SESSA_NODE}")"
    if is_block "$got"; then pass "INV-NI-sq-scratchpad: New-Item '\$SCRATCHPAD/x' (single-quote literal) → block"; else fail "INV-NI-sq-scratchpad: single-quote literal should block — H1 INCOMPLETE (got: $got)"; fi

    # INV-NI-argv0: argv0 defense — head token is NOT New-Item/ni; `ni` appears only as a
    # non-head token → block (predicate must not trust a mid-command ni token).
    got="$(run_hook "somecmd ni -ItemType Directory -Path \"${EXT_WORKTREE_WIN}\"")"
    if is_block "$got"; then pass "INV-NI-argv0: non-head ni token → block (argv0 defense)"; else fail "INV-NI-argv0: should block (got: $got)"; fi

    # INV-SCRATCH-cross-session (H2): SCRATCHPAD=sessA but the write target is under sessB's
    # scratchpad dir → block. Exercised from NON-git CWD, where areAllBashTargetsUnderClaude
    # (→ isAllowedScratchpadTarget → session-scoped allow root) is the deciding path.
    got="$(run_nongit_env "echo x > \"${SESSB_FWD}/x.md\"" "SCRATCHPAD=${SCRATCH_SESSA_NODE}")"
    if is_block "$got"; then pass "INV-SCRATCH-cross-session: sessB target (SCRATCHPAD=sessA) from non-git CWD → block"; else fail "INV-SCRATCH-cross-session: cross-session should block — H2 INCOMPLETE (got: $got)"; fi

    # SKIPPED: executing New-Item under real pwsh to confirm the allowed directory is actually created
    # Because: hook verdict is computed from the command string alone; pwsh runtime not needed at L2
    # L3 gap: pwsh alias resolution (ni → New-Item) and -Force semantics in a real PowerShell session
    # NI-2: in-repo path with forward slashes (path.dirname finds repo root correctly)
    got="$(run_hook "New-Item -ItemType Directory -Path \"${MAIN_REPO_FWD}/inrepo-subdir\"")"; if is_block "$got"; then pass "NI-2: New-Item in-repo dir -Path → block"; else fail "NI-2: should block (got: $got)"; fi
    # NI-4: positional in-repo path
    got="$(run_hook "New-Item -ItemType Directory \"${MAIN_REPO_FWD}/evil\"")"; if is_block "$got"; then pass "NI-4: New-Item positional in-repo → block"; else fail "NI-4: should block (got: $got)"; fi
    # NI-5: -ItemType File (only Directory allowed)
    got="$(run_hook "New-Item -ItemType File -Path \"${EXT_WORKTREE_WIN}\\f.txt\"")"; if is_block "$got"; then pass "NI-5: New-Item -ItemType File → block"; else fail "NI-5: should block (got: $got)"; fi
    # NI-6: no path (fail-closed)
    got="$(run_hook "New-Item -ItemType Directory")"; if is_block "$got"; then pass "NI-6: New-Item no path → block"; else fail "NI-6: should block (got: $got)"; fi
    # NI-7: chained command
    got="$(run_hook "New-Item -ItemType Directory -Path \"${EXT_WORKTREE_WIN}\"; Remove-Item foo")"; if is_block "$got"; then pass "NI-7: New-Item chained → block"; else fail "NI-7: should block (got: $got)"; fi
    # In-repo write
    got="$(run_hook "echo x > README.md")"; if is_block "$got"; then pass "INV-inrepo: echo > README.md → block"; else fail "INV-inrepo: should block (got: $got)"; fi
    # Mixed: plans-dir + in-repo sequenced
    got="$(run_hook "cat > \"${PLANS_FWD}/x.md\" && echo y > README.md")"; if is_block "$got"; then pass "INV-mixed: plans-dir && in-repo → block"; else fail "INV-mixed: should block (got: $got)"; fi

    # Negative temp canaries from non-git CWD: areAllBashTargetsUnderClaude must NOT open broad /tmp.
    got="$(run_nongit "echo x > /tmp/evil.md")"; if is_block "$got"; then pass "NEG-TMP1 (nongit): /tmp/evil.md → block"; else fail "NEG-TMP1: should block (got: $got)"; fi
    got="$(run_nongit "echo x > /var/tmp/evil.md")"; if is_block "$got"; then pass "NEG-TMP2 (nongit): /var/tmp/evil.md → block"; else fail "NEG-TMP2: should block (got: $got)"; fi
    local TMPDIR_FWD; TMPDIR_FWD="$(node -e "var o=require('os');console.log(o.tmpdir().replace(/\\\\/g,'/'))" 2>/dev/null)"
    got="$(run_nongit "echo x > \"${TMPDIR_FWD}/evil.md\"")"; if is_block "$got"; then pass "NEG-TMP3 (nongit): tmpdir-root/evil.md → block"; else fail "NEG-TMP3: should block (got: $got)"; fi
    got="$(run_nongit "echo x > /tmp/not-claude/file.md")"; if is_block "$got"; then pass "NEG-TMP4 (nongit): /tmp/not-claude/file.md → block"; else fail "NEG-TMP4: should block (got: $got)"; fi
}

# ── Run all ───────────────────────────────────────────────────────────────────
echo "=== fix-1441 regression canary: post-fix allow/block contract (#1441/#1290/#923) ==="

echo ""; echo "--- ALLOW-expected: sanctioned commands the guard must permit ---"
test_already_green
echo ""; echo "--- ALLOW-expected: paths the #1420 fix restored (RED if fix reverted) ---"
test_restored_allows
echo ""; echo "--- BLOCK-expected: in-repo / bypass / cross-session writes ---"
test_invariant_block

echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
