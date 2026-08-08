#!/usr/bin/env bash
# Tests: hooks/lib/sentinel-patterns.js
# Tags: tl1, workflow, run-tests, sentinel-patterns, regex, table-driven, mutation-probe, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C2 (HIGH) — table-driven coverage for the NEW
# RUN_TESTS_NOT_NEEDED regex constants and for the two predicates that consume
# them (isSentinel, isStrictSentinel). Both consumers matter and disagree by
# design: isSentinel() decides whether workflow-mark dispatches at all (so the
# LOOKSLIKE fallback must catch malformed forms and produce a diagnostic), while
# isStrictSentinel() is workflow-gate's early-approve door (so it must accept
# ONLY the exact, unchained, unredirected echo). A regression that let the strict
# door accept a chained form would auto-approve arbitrary appended commands.
#
# Every row asserts all four observables at once (dq / look / sent / strict), so
# a loosening that shifts a case from one predicate to another is caught even
# when the coarse "is it a sentinel" answer is unchanged.
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code's permission layer matches the same literal before the
#   hook ever runs (settings.json permissions.allow is a separate matcher and is
#   pinned statically in tests/feature-1644-run-tests-registration-sites.sh).
# - Whether workflow-mark.js's naive `&&` splitter feeds these regexes the
#   fragments this table assumes — that seam is covered by
#   tests/feature-1644-review-gap-c1-run-tests-skip.sh and the main-workflow
#   sentinel suites.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
PATTERNS_N="$AGENTS_DIR_N/hooks/lib/sentinel-patterns.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Dual-pin (#1799): pinning only one of the pair lets supervisor-emit append to
# the developer's real ~/.workflow-plans/. sentinel-patterns.js is pure, but the
# pin is unconditional so a future require() cannot silently start emitting.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

# Fixture repo + neutral CWD: nothing here shells out to git, but a hook module
# that starts doing so must never resolve the developer's real worktree.
FIXTURE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
git -C "$FIXTURE_REPO" config user.email "test@example.com"
git -C "$FIXTURE_REPO" config user.name "test"
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$TMPDIR_BASE" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name -- want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Probe: one node process per row. The command arrives via env (PROBE_CMD) — never
# argv — because MSYS rewrites argv tokens that look like POSIX paths, and several
# rows contain `/tmp/x`.
PROBE="$TMPDIR_BASE/probe.js"
cat > "$PROBE" <<'PROBE_JS'
"use strict";
const P = require(process.env.PATTERNS_MODULE);
const cmd = process.env.PROBE_CMD;
const b = (v) => (v ? "1" : "0");
process.stdout.write(
  "dq" + b(P.RUN_TESTS_NOT_NEEDED_RE_DQ.test(cmd)) +
  "-look" + b(P.RUN_TESTS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd)) +
  "-sent" + b(P.isSentinel(cmd)) +
  "-strict" + b(P.isStrictSentinel(cmd))
);
PROBE_JS
export PATTERNS_MODULE="$PATTERNS_N"

# `{SP}` stands for a literal space at a string edge. The table has NO padding
# around `|`, so an edge space would otherwise be invisible to a reader (and to
# review) even though it is exactly what the anchor cases turn on.
# `{PIPE}` stands for a literal `|`, which cannot appear raw in an IFS='|' row.
eval_subject() {
  local input="$1"
  input="${input//\{SP\}/ }"
  input="${input//\{PIPE\}/|}"
  PROBE_CMD="$input" run_with_timeout node "$PROBE" 2>/dev/null || echo "PROBE_FAIL"
}

echo "=== C2-A: RUN_TESTS_NOT_NEEDED form table ==="
# Columns: name|input|want   (want = dq<0|1>-look<0|1>-sent<0|1>-strict<0|1>)
while IFS='|' read -r name input want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  got="$(eval_subject "$input")"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# --- valid strict form -------------------------------------------------------
valid-strict|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: staged set is docs only>>"|dq1-look1-sent1-strict1
valid-min-reason|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: abc>>"|dq1-look1-sent1-strict1
valid-reason-with-punct|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: docs/*.md only; no code>>"|dq1-look1-sent1-strict1
# --- degenerate reason: recognized as a sentinel, refused by the strict door ---
empty-reason|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: >>"|dq0-look1-sent1-strict0
bare-no-reason|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED>>"|dq0-look1-sent1-strict0
space-instead-of-colon|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED reason>>"|dq0-look1-sent1-strict0
reason-contains-gt|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: a > b>>"|dq0-look1-sent1-strict0
# --- malformed / wrong quoting: not a sentinel at all -------------------------
missing-closing-marker|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason"|dq0-look0-sent0-strict0
single-quoted|echo '<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>'|dq0-look0-sent0-strict0
unquoted|echo <<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>|dq0-look0-sent0-strict0
lowercase-name|echo "<<workflow_run_tests_not_needed: reason>>"|dq0-look0-sent0-strict0
printf-not-echo|printf "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"|dq0-look0-sent0-strict0
# --- residue appended after the sentinel --------------------------------------
trailing-redirect|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>" > /tmp/x|dq0-look0-sent0-strict0
append-redirect|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>" >> /tmp/x|dq0-look0-sent0-strict0
and-chain|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>" && ls /tmp/x|dq0-look0-sent0-strict0
semicolon-chain|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"; ls /tmp/x|dq0-look0-sent0-strict0
pipe-chain|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>" {PIPE} tee /tmp/x|dq0-look0-sent0-strict0
# Greedy-`.*` LOOKSLIKE spans the inner `>>` when the chain ENDS in a sentinel.
# Documented, pre-existing behavior of the whole *_LOOKSLIKE_RE family (see the
# isStrictSentinel header comment) — pinned here so the strict door's dq0/strict0
# stays the thing that actually protects workflow-gate's early approve.
and-chain-ends-in-sentinel|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: r1>>" && echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: r2>>"|dq0-look1-sent1-strict0
# --- edge whitespace ----------------------------------------------------------
leading-space|{SP}echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"|dq0-look0-sent0-strict0
trailing-space|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"{SP}|dq0-look0-sent0-strict0
# --- sibling sentinel must not be absorbed by the run-tests pattern -----------
sibling-write-tests|echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: reason>>"|dq0-look0-sent1-strict1
sibling-review-security|echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: reason>>"|dq0-look0-sent1-strict1
sibling-run-tests-prefix-extended|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED_EXTRA: reason>>"|dq0-look0-sent0-strict0
TABLE

echo ""
echo "=== C2-B: mutation probe (inputs a loosened regex would start accepting) ==="
# Each row below MUST stay rejected by the STRICT constant. The comment on each
# row names the exact source mutation the row kills — if that mutation ever lands
# in hooks/lib/sentinel-patterns.js, the row flips to dq1 and turns this file RED.
while IFS='|' read -r name input want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  got="$(eval_subject "$input")"
  # Compare only the dq/strict halves: the probe returns all four, and the
  # LOOKSLIKE answer is deliberately NOT what these rows are about.
  got="${got%%-sent*}"
  assert_eq "$name" "$want" "$got"
done <<'TABLE'
# kills: [^>]+ -> .+   (reason class widened to accept `>`; would swallow the
#        `>>` terminator and let arbitrary text ride inside the reason field)
kill-reasonclass-gt|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: a > b>>"|dq0-look1
# kills: [^>]+ -> .+   (with `.+` the reason field spans the inner `>>"`, so the
#        STRICT early-approve door would accept a two-command chain as one
#        sentinel — verified: this row flips to dq1 under that mutation)
kill-reasonclass-chain|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: r>>" && echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: r2>>"|dq0-look1
# kills: dropping the trailing `$` anchor (trailing residue silently ignored)
kill-endanchor-redirect|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>" > /tmp/x|dq0-look0
kill-endanchor-semicolon|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"; ls /tmp/x|dq0-look0
kill-endanchor-space|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"{SP}|dq0-look0
# kills: dropping the leading `^` anchor (sentinel-shaped substring inside another
#        command's argument would be honored)
kill-startanchor-space|{SP}echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"|dq0-look0
kill-startanchor-embedded|cd /tmp && echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: reason>>"|dq0-look0
# kills: making the reason optional in the STRICT constant (`: ([^>]+)` -> `(: [^>]*)?`),
#        which would let a reasonless assertion open the skip with no audit text
kill-mandatory-reason-bare|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED>>"|dq0-look1
kill-mandatory-reason-empty|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: >>"|dq0-look1
# kills: relaxing the literal name (e.g. WORKFLOW_RUN_TESTS_NOT_NEEDED[A-Z_]*),
#        which would collide the run-tests skip with any future sibling sentinel
kill-name-suffix|echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED_SOON: reason>>"|dq0-look0
TABLE

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
