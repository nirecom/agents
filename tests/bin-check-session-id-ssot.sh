#!/usr/bin/env bash
# Tests: bin/check-session-id-ssot.sh
# Tags: TL2, scope:issue-specific, pwsh-not-required, session-id, ssot, static-guard
# Issue #2270 (C5): a static guard that keeps direct session-id env reads out of
# Node source. Every case but G17/G18 runs against a synthetic `git init` repo,
# so the guard's verdict is decided by the fixture, never by the real tree.
# Contract under test: run with CWD = repo root; exit 0 clean, 1 violations, 2 usage.
# TL3 gap (not caught here): the guard firing as a real pre-commit hook and
# actually blocking a commit. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$AGENTS_DIR/bin/check-session-id-ssot.sh"
RUN_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"

# Whole-file exemption is for RESOLVERS only — the canonical implementations of
# the two id families plus the worktree resolver that feeds them, where every
# direct env read IS the implementation. Both families are represented on
# purpose: exempting one and not the other would push the other's resolver into
# permanent waiver churn.
# The hook/CLI entrypoints that need a pre-resolver fallback (because they run
# before, or without, a resolver context) are NOT path-wide exempt: each direct
# read site there carries an inline "session-id-ssot: waived (...)" comment
# instead (see G14/G15), so the exemption stays scoped to the line that needs it.
ALLOWLIST_PATHS=(
  "hooks/workflow-state/session-id.js"
  "hooks/lib/resolve-workflow-session-id.js"
  "hooks/workflow-state/resolve-worktree-path.js"
  "bin/resolve-worktree-path"
)

# The three pre-resolver fallback entrypoints — covered by inline waivers,
# never by ALLOWLIST_PATHS.
WAIVED_ENTRYPOINTS=(
  "hooks/lib/claude-scratchpad-base.js"
  "hooks/lib/worktree-cleanup-marker.js"
  "bin/supervisor-write-audit"
)

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null 2>&1 || { echo "git not found — check skipped"; exit 77; }

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t ssotguard)"
cleanup() { rm -rf "$TMPDIR_BASE" 2>/dev/null || true; }
trap cleanup EXIT

# Fresh throwaway repo per case; core.hooksPath disabled so the installed
# pre-commit hook cannot fire inside the fixture.
FIXTURE=""
make_fixture() {
  FIXTURE="$TMPDIR_BASE/$1"
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$FIXTURE" config user.email "test@example.com"
  git -C "$FIXTURE" config user.name "Test"
}

# $1 relative path, $2.. content lines
add_file() {
  local rel="$1"; shift
  mkdir -p "$FIXTURE/$(dirname "$rel")"
  printf '%s\n' "$@" > "$FIXTURE/$rel"
  git -C "$FIXTURE" add -- "$rel" 2>/dev/null || true
}

# Runs the guard with CWD = fixture root. Echoes stdout+stderr; rc in GUARD_RC.
GUARD_RC=0
GUARD_OUT=""
run_guard() {
  local out
  out="$(cd "${1:-$FIXTURE}" && \
    env -u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
      AGENTS_CONFIG_DIR="$AGENTS_DIR" \
      bash "$RUN_TIMEOUT" 60 bash "$GUARD" "${@:2}" 2>&1)"
  GUARD_RC=$?
  GUARD_OUT="$out"
}

# $1 label, $2 wanted rc
expect_rc() {
  if [[ "$GUARD_RC" -eq "$2" ]]; then
    pass "$1: exit $GUARD_RC"
  else
    fail "$1: exit $GUARD_RC, want $2 (out: $(echo "$GUARD_OUT" | head -3 | tr '\n' ' '))"
  fi
}

# ---------------------------------------------------------------------------
# G1 / G1b: clean tree exits 0; an unknown flag is a usage error (exit 2), not
# a silent pass — a mistyped flag must never read as "no violations".
# ---------------------------------------------------------------------------
make_fixture g1
add_file "hooks/plain.js" "const x = process.env.HOME;" "module.exports = { x };"
run_guard
expect_rc "G1 (clean tree)" 0

run_guard "$FIXTURE" --no-such-flag
expect_rc "G1b (unknown flag -> usage error)" 2

# ---------------------------------------------------------------------------
# G2-G4: the three in-scope names, each read as a dotted property.
# ---------------------------------------------------------------------------
make_fixture g2
add_file "hooks/bad.js" "const sid = process.env.SESSION_ID;" "module.exports = sid;"
run_guard
expect_rc "G2 (process.env.SESSION_ID flagged)" 1
if echo "$GUARD_OUT" | grep -q "hooks/bad.js"; then
  pass "G2b (report names the offending file)"
else
  fail "G2b (report names the offending file): out='$GUARD_OUT'"
fi

make_fixture g3
add_file "hooks/bad.js" "const sid = process.env.CLAUDE_SESSION_ID || null;"
run_guard
expect_rc "G3 (process.env.CLAUDE_SESSION_ID flagged)" 1

make_fixture g4
add_file "bin/tool.js" "const sid = process.env.CLAUDE_CODE_SESSION_ID;"
run_guard
expect_rc "G4 (process.env.CLAUDE_CODE_SESSION_ID flagged)" 1

# ---------------------------------------------------------------------------
# G5-G6: bracket form with a string literal is the same read spelled otherwise
# (CPR-ORTH) — the guard must not be defeated by quoting style.
# ---------------------------------------------------------------------------
make_fixture g5
add_file "hooks/bad.js" 'const sid = process.env["CLAUDE_CODE_SESSION_ID"];'
run_guard
expect_rc "G5 (bracket + double-quoted literal flagged)" 1

make_fixture g6
add_file "hooks/bad.js" "const sid = process.env['SESSION_ID'];"
run_guard
expect_rc "G6 (bracket + single-quoted literal flagged)" 1

# ---------------------------------------------------------------------------
# G7-G9: out of scope by design. WORKFLOW_SESSION_ID is a different namespace,
# bash expansion is not a Node read, and a computed key is undecidable
# statically — flagging any of them would make the guard unusable.
# ---------------------------------------------------------------------------
make_fixture g7
add_file "hooks/ok.js" "const w = process.env.WORKFLOW_SESSION_ID;"
run_guard
expect_rc "G7 (WORKFLOW_SESSION_ID not in scope)" 0

make_fixture g8
add_file "bin/tool.sh" '#!/usr/bin/env bash' 'echo "$CLAUDE_SESSION_ID ${SESSION_ID}"'
run_guard
expect_rc "G8 (bash \$VAR expansion not in scope)" 0

make_fixture g9
add_file "hooks/ok.js" "const name = pick();" "const v = process.env[name];"
run_guard
expect_rc "G9 (dynamic process.env[name] not in scope)" 0

# ---------------------------------------------------------------------------
# G10-G12: excluded trees. Tests must be free to exercise the raw env, and
# prose that merely quotes the expression is not a code path.
# ---------------------------------------------------------------------------
make_fixture g10
add_file "tests/some-test.sh" "node -e 'console.log(process.env.CLAUDE_SESSION_ID)'"
run_guard
expect_rc "G10 (tests/** excluded)" 0

make_fixture g11
add_file "docs/note.md" "Reads process.env.CLAUDE_CODE_SESSION_ID at startup."
add_file "README.md" "Set process.env.SESSION_ID before running."
run_guard
expect_rc "G11 (docs/** and *.md excluded)" 0

make_fixture g12
add_file "changelog/2026-09.md" "- now reads process.env.SESSION_ID"
run_guard
expect_rc "G12 (changelog/** excluded)" 0

# ---------------------------------------------------------------------------
# G13: the allowlist. The resolver itself is exempt by whole-file path; the
# three pre-resolver fallback entrypoints are exempt only where each direct
# read carries an inline waiver comment (S6-b design).
# ---------------------------------------------------------------------------
make_fixture g13
for p in "${ALLOWLIST_PATHS[@]}"; do
  add_file "$p" "const sid = process.env.CLAUDE_CODE_SESSION_ID || process.env.SESSION_ID;"
done
for p in "${WAIVED_ENTRYPOINTS[@]}"; do
  add_file "$p" \
    "const sid = process.env.CLAUDE_CODE_SESSION_ID || process.env.SESSION_ID; // session-id-ssot: waived (bootstrap) — runs before the resolver is loadable"
done
run_guard
expect_rc "G13 (resolver allowlisted by path; pre-resolver entrypoints waived inline)" 0

# G13b: the allowlist matches a WHOLE path, never a prefix. A sibling whose name
# merely starts with an allowlisted one is ordinary source — the cheapest way to
# smuggle a direct read past a path allowlist is to sit next to an entry.
make_fixture g13b
for p in "${ALLOWLIST_PATHS[@]}"; do
  add_file "${p}-evil.js" "const sid = process.env.CLAUDE_CODE_SESSION_ID;"
done
run_guard
expect_rc "G13b (prefix sibling of an allowlisted path is NOT exempt)" 1

# G13c: the waived entrypoints are exempt only where the waiver is. A SECOND,
# unwaived read in the same file must still be flagged, or the inline waiver
# would silently degrade into the file-level exemption S6-b rejected.
make_fixture g13c
add_file "${WAIVED_ENTRYPOINTS[0]}" \
  "const sid = process.env.CLAUDE_CODE_SESSION_ID; // session-id-ssot: waived (bootstrap) — runs before the resolver is loadable" \
  "const unrelated = 1;" \
  "const other = process.env.CLAUDE_SESSION_ID;"
run_guard
expect_rc "G13c (unwaived second read in a waived entrypoint still flagged)" 1

# ---------------------------------------------------------------------------
# G14-G16: the inline waiver. It is accepted on the same line or the line
# above, and an empty reason is not a waiver — a marker with nothing behind it
# is exactly the rubber stamp the guard exists to prevent.
# ---------------------------------------------------------------------------
make_fixture g14
add_file "hooks/waived.js" \
  "const sid = process.env.SESSION_ID; // session-id-ssot: waived (bootstrap) — runs before the resolver is loadable"
run_guard
expect_rc "G14 (same-line waiver honored)" 0

make_fixture g15
add_file "hooks/waived.js" \
  "// session-id-ssot: waived (bootstrap) — runs before the resolver is loadable" \
  "const sid = process.env.SESSION_ID;"
run_guard
expect_rc "G15 (preceding-line waiver honored)" 0

make_fixture g16
add_file "hooks/waived.js" \
  "const sid = process.env.SESSION_ID; // session-id-ssot: waived (bootstrap) — "
run_guard
expect_rc "G16 (waiver with empty reason still flagged)" 1

# ---------------------------------------------------------------------------
# G17: the allowlist must name only paths that exist. A stale entry silently
# widens the exemption to whatever later takes that path.
# ---------------------------------------------------------------------------
g17_bad=""
for p in "${ALLOWLIST_PATHS[@]}"; do
  [[ -e "$AGENTS_DIR/$p" ]] || g17_bad="$g17_bad $p(missing-in-repo)"
  if [[ -f "$GUARD" ]] && ! grep -qF "$p" "$GUARD"; then
    g17_bad="$g17_bad $p(absent-from-guard)"
  fi
done
[[ -f "$GUARD" ]] || g17_bad="$g17_bad (guard script itself missing)"
if [[ -z "$g17_bad" ]]; then
  pass "G17 (allowlist matches real files and the guard source)"
else
  fail "G17 (allowlist matches real files and the guard source):$g17_bad"
fi

# ---------------------------------------------------------------------------
# G18: the whole point — the real repo is clean under the guard. RED until C1
# and C4 route every remaining direct read through resolveSessionId().
# ---------------------------------------------------------------------------
run_guard "$AGENTS_DIR"
expect_rc "G18 (real repo has no unwaived direct reads)" 0

# ---------------------------------------------------------------------------
# G19: --staged form. The pre-commit hook invokes the guard with --staged so
# only files present in the index are scanned.
# ---------------------------------------------------------------------------
make_fixture g19
add_file "hooks/bad.js" "const sid = process.env.SESSION_ID;"
run_guard "$FIXTURE" --staged
expect_rc "G19 (--staged flag flags a staged violation)" 1

# ---------------------------------------------------------------------------
# G20: positional [file...] form. The pre-commit hook also invokes the guard
# with an explicit changed-file list, so the guard must accept file
# arguments directly and limit its scan to them, rather than always walking
# the whole tree.
# ---------------------------------------------------------------------------
make_fixture g20
add_file "hooks/bad.js" "const sid = process.env.SESSION_ID;"
add_file "hooks/ok.js" "const x = process.env.HOME;"
run_guard "$FIXTURE" hooks/bad.js
expect_rc "G20a (positional file arg flags a violation in that file)" 1

make_fixture g20b
add_file "hooks/bad.js" "const sid = process.env.SESSION_ID;"
add_file "hooks/ok.js" "const x = process.env.HOME;"
run_guard "$FIXTURE" hooks/ok.js
expect_rc "G20b (positional file arg limits the scan to that file)" 0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
