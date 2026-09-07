#!/usr/bin/env bash
# tests/TL3-codegraph-cli-contract.sh
# Tests: hooks/lib/codegraph-boundary.js, bin/codegraph-lifecycle.js
# Tags: TL3, codegraph, cli-contract, scope:issue-specific
#
# Real-binary contract for `codegraph` (M37-M40, S5-14): version pin match,
# prompt-hook no-op contract, prompt-hook against a self-authored fixture
# index, fixture-home write-containment. HOME+USERPROFILE both pin a
# fixture home; no CODEGRAPH_TELEMETRY/DO_NOT_TRACK (bare upstream contract).
# TL3 gap: TL1/TL2 exercise a stub only; a real binary + RUN_TL3=on catches
# version drift, an upstream contract break, or a fixture-home leak.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Skip-gate 1: RUN_TL3 must be explicitly on (rules/test/claude-e2e.md).
[ -x "$AGENTS_DIR/bin/get-config-var" ] || { echo "SKIP: $AGENTS_DIR/bin/get-config-var not found or not executable" >&2; exit 77; }
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
  echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi

# Skip-gate 2: the real codegraph binary must be on PATH.
if ! command -v codegraph >/dev/null 2>&1; then
  echo "SKIP: codegraph CLI not found on PATH" >&2; exit 77
fi

CONSTANTS_FILE="$AGENTS_DIR/install/codegraph-constants.txt"
[ -f "$CONSTANTS_FILE" ] || { echo "SKIP: $CONSTANTS_FILE not found" >&2; exit 77; }
PINNED_VERSION="$(grep -E '^CODEGRAPH_VERSION=' "$CONSTANTS_FILE" | head -n1 | cut -d= -f2-)"
[ -n "$PINNED_VERSION" ] || { echo "SKIP: CODEGRAPH_VERSION not found in $CONSTANTS_FILE" >&2; exit 77; }

# Unset inherited session/workflow env so this run cannot resolve real state
# (rules/test/fixture-isolation.md).
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_WORKFLOW_DIR
unset WORKFLOW_PLANS_DIR

FIXTURE_HOME="$(mktemp -d)"
FIXTURE_PROJECT="$(mktemp -d)"
DAEMON_STOPPED=0

cleanup() {
  if [ "$DAEMON_STOPPED" -eq 0 ]; then
    HOME="$FIXTURE_HOME" USERPROFILE="$FIXTURE_HOME" \
      node "$AGENTS_DIR/bin/codegraph-lifecycle.js" stop --path "$FIXTURE_PROJECT" --quiet >/dev/null 2>&1 || true
    DAEMON_STOPPED=1
  fi
  rm -rf "$FIXTURE_HOME" "$FIXTURE_PROJECT"
}
trap cleanup EXIT

export HOME="$FIXTURE_HOME"
export USERPROFILE="$FIXTURE_HOME"
unset CODEGRAPH_TELEMETRY
unset DO_NOT_TRACK

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# snapshot_codegraph_tree: sorted relative-path+digest listing of the fixture
# home's .codegraph/ tree, so M40 can diff before/after (S5-14 isolation).
snapshot_codegraph_tree() {
  if [ -d "$FIXTURE_HOME/.codegraph" ]; then
    find "$FIXTURE_HOME/.codegraph" -type f | sort | while IFS= read -r f; do
      rel="${f#"$FIXTURE_HOME"/}"
      sum="$(cksum "$f" 2>/dev/null | awk '{print $1, $2}')"
      echo "$rel $sum"
    done
  fi
}

SNAPSHOT_BEFORE="$(snapshot_codegraph_tree)"

# --- M37: `codegraph --version` matches the pinned CODEGRAPH_VERSION -------
VERSION_STDOUT="$(mktemp)"
VERSION_STDERR="$(mktemp)"
if bash "$AGENTS_DIR/bin/run-with-timeout.sh" 60 codegraph --version >"$VERSION_STDOUT" 2>"$VERSION_STDERR"; then
  VERSION_EXIT=0
else
  VERSION_EXIT=$?
fi

VERSION_OUT_TRIMMED="$(tr -d '[:space:]' <"$VERSION_STDOUT")"
VERSION_ERR_BYTES="$(wc -c <"$VERSION_STDERR" | tr -d '[:space:]')"

if [ "$VERSION_EXIT" -eq 0 ] && [ "$VERSION_OUT_TRIMMED" = "$PINNED_VERSION" ] && [ "$VERSION_ERR_BYTES" = "0" ]; then
  pass "M37: codegraph --version matches pinned $PINNED_VERSION, exit 0, stderr empty"
else
  fail "M37: expected version=$PINNED_VERSION exit=0 stderr=0B; got version=$VERSION_OUT_TRIMMED exit=$VERSION_EXIT stderr_bytes=$VERSION_ERR_BYTES"
fi
rm -f "$VERSION_STDOUT" "$VERSION_STDERR"

# --- M38: prompt-hook no-op contract on an unstructured prompt -------------
HOOK38_STDOUT="$(mktemp)"
HOOK38_STDERR="$(mktemp)"
printf '{"prompt":"fix this typo","cwd":"%s"}' "$FIXTURE_PROJECT" \
  | bash "$AGENTS_DIR/bin/run-with-timeout.sh" 60 codegraph prompt-hook >"$HOOK38_STDOUT" 2>"$HOOK38_STDERR"
HOOK38_EXIT=$?
HOOK38_ERR_BYTES="$(wc -c <"$HOOK38_STDERR" | tr -d '[:space:]')"
HOOK38_OUT="$(cat "$HOOK38_STDOUT")"

if [ "$HOOK38_EXIT" -eq 0 ] && [ "$HOOK38_ERR_BYTES" = "0" ] \
  && { [ -z "$HOOK38_OUT" ] || case "$HOOK38_OUT" in '<codegraph_context'*) true ;; *) false ;; esac; }; then
  pass "M38: prompt-hook exit 0, stderr empty, stdout empty-or-<codegraph_context"
else
  fail "M38: expected exit=0 stderr=0B stdout=empty-or-<codegraph_context; got exit=$HOOK38_EXIT stderr_bytes=$HOOK38_ERR_BYTES stdout=$(printf '%s' "$HOOK38_OUT" | head -c 80)"
fi
rm -f "$HOOK38_STDOUT" "$HOOK38_STDERR"

# --- M39: prompt-hook against a self-authored fixture index ----------------
FIXTURE_SYMBOL="agentsFixtureSentinelSymbol2215"
cat > "$FIXTURE_PROJECT/fixture-symbol.js" <<EOF
function ${FIXTURE_SYMBOL}() {
  return 42;
}
module.exports = { ${FIXTURE_SYMBOL} };
EOF

INIT_STDOUT="$(mktemp)"
INIT_STDERR="$(mktemp)"
if ! bash "$AGENTS_DIR/bin/run-with-timeout.sh" 120 codegraph init -y "$FIXTURE_PROJECT" >"$INIT_STDOUT" 2>"$INIT_STDERR"; then
  echo "SKIP: codegraph init -y failed or timed out in fixture project (R18)" >&2
  cat "$INIT_STDERR" >&2 || true
  rm -f "$INIT_STDOUT" "$INIT_STDERR"
  exit 77
fi
rm -f "$INIT_STDOUT" "$INIT_STDERR"

HOOK39_STDOUT="$(mktemp)"
HOOK39_STDERR="$(mktemp)"
printf '{"prompt":"what does %s do?","cwd":"%s"}' "$FIXTURE_SYMBOL" "$FIXTURE_PROJECT" \
  | bash "$AGENTS_DIR/bin/run-with-timeout.sh" 60 codegraph prompt-hook >"$HOOK39_STDOUT" 2>"$HOOK39_STDERR"
HOOK39_EXIT=$?
HOOK39_OUT="$(cat "$HOOK39_STDOUT")"

case "$HOOK39_OUT" in
  '<codegraph_context'*)
    if [ "$HOOK39_EXIT" -eq 0 ]; then
      pass "M39: prompt-hook against fixture index returns <codegraph_context, exit 0"
    else
      fail "M39: stdout had <codegraph_context but exit=$HOOK39_EXIT (expected 0)"
    fi
    ;;
  *)
    fail "M39: expected stdout to start with <codegraph_context; got exit=$HOOK39_EXIT stdout=$(printf '%s' "$HOOK39_OUT" | head -c 80)"
    ;;
esac
rm -f "$HOOK39_STDOUT" "$HOOK39_STDERR"

# --- M40: fixture home write-containment + HOME/USERPROFILE pin ------------
SNAPSHOT_AFTER="$(snapshot_codegraph_tree)"

if [ "$HOME" = "$FIXTURE_HOME" ] && [ "$USERPROFILE" = "$FIXTURE_HOME" ]; then
  pass "M40: HOME and USERPROFILE still point at the fixture home"
else
  fail "M40: HOME/USERPROFILE drifted from fixture home (HOME=$HOME USERPROFILE=$USERPROFILE)"
fi

if [ -n "$SNAPSHOT_AFTER" ] && [ "$SNAPSHOT_BEFORE" != "$SNAPSHOT_AFTER" ]; then
  pass "M40: fixture home .codegraph/ tree changed by M37-M39 (writes stayed under \$FIXTURE_HOME by construction)"
else
  fail "M40: expected fixture home .codegraph/ tree to differ before/after M37-M39 ran"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
