#!/usr/bin/env bash
# Tests: bin/get-config-var, bin/confirm-off, hooks/lib/config-flag.js, hooks/lib/confirm-gate/probe.js
# Tags: tl2, bin, config-flag, get-config-var, confirm-off, bootstrap, no-spawn, scope:issue-specific
# #2681: the shell path of the two config wrappers. Both start one node that loads
# hooks/lib/config-flag.js through an identical bootstrap. Pins the script structure, the
# no-subprocess static pin, symlinked launch, newline identity, a '/'-leading default,
# MSYS_NO_PATHCONV, bootstrap-var hygiene, the no-lib and no-node answers, the confirm-off failure causes, and exit 2 (unset) versus exit 4 (unreadable).
# TL3 gap (what this test does NOT catch): the installed ~/.local/bin symlinks on a real user
# profile and the pwsh twins (bin/get-config-var.ps1, bin/confirm-off.ps1). Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: installer.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

BASE="$(make_tmp)"; readonly BASE
trap 'cd /; rm -rf "$BASE"' EXIT
harness_isolate "$BASE"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID AGENTS_HOOK_DEBUG CF_SYM CF_NL CF_NONE CF_SLASH CF_X CF_PC CONFIG_FLAG_MODE MSYS_NO_PATHCONV
mkdir -p "$BASE/cwd" "$BASE/cfg"
cd "$BASE/cwd" || exit 1
: > "$BASE/cfg/.env"
export AGENTS_MAIN_ROOT="$(np "$BASE/cfg")"

GCV_SRC="$SCRIPT_CHECKOUT_ROOT/bin/get-config-var"
CO_SRC="$SCRIPT_CHECKOUT_ROOT/bin/confirm-off"

# mk_tree <dir>: bin/get-config-var + bin/confirm-off + a copy of hooks/lib (cp, so a module
# that is not yet tracked still lands in the tree).
mk_tree() {
  mkdir -p "$1/bin" "$1/hooks"
  cp "$GCV_SRC" "$CO_SRC" "$1/bin/"
  cp -R "$SCRIPT_CHECKOUT_ROOT/hooks/lib" "$1/hooks/lib"
}
TREE="$BASE/tree"; mk_tree "$TREE"
NOLIB="$BASE/nolib"; mk_tree "$NOLIB"; rm -f "$NOLIB/hooks/lib/config-flag.js"
THROW="$BASE/throw"; mk_tree "$THROW"
printf '"use strict";\nthrow new Error("stub: load-env throws on require");\n' > "$THROW/hooks/lib/load-env.js"
# A node that always fails, first on PATH for the no-node rows (same shape as main-session-sync-toggle.sh).
mkdir -p "$BASE/nonode"
printf '#!/bin/sh\necho "node: simulated failure" >&2\nexit 127\n' > "$BASE/nonode/node"
chmod +x "$BASE/nonode/node"
NONODE_PATH="$BASE/nonode:$PATH"

# run <cmd...>: stdout -> $BASE/out (also $OUT), stderr -> $ERR, exit -> $RC.
OUT=""; ERR=""; RC=0
run() {
  RC=0
  run_with_timeout 60 "$@" > "$BASE/out" 2> "$BASE/err" || RC=$?
  OUT="$(cat "$BASE/out")"; ERR="$(cat "$BASE/err")"
}
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing $(printf '%q' "$2") in $(printf '%q' "$3")" ;; esac; }

# body <file>: the lines between the 13-line envelope head and the 2-line tail, comment lines dropped.
body() { sed -e '1,13d' "$1" | sed -e '$d' | sed -e '$d' | grep -v '^[[:space:]]*#' || true; }
# region <file>: the text between the two bootstrap marker lines, markers excluded.
region() { sed -n '/^# config-flag bootstrap: begin$/,/^# config-flag bootstrap: end$/p' "$1" | sed -e '1d' -e '$d'; }

case_begin "wrappers-carry-no-legacy-plumbing" "bin/confirm-off"
check "confirm-off body never calls get-config-var" 0 "$(body "$CO_SRC" | grep -c 'get-config-var' || true)"
for f in "$GCV_SRC" "$CO_SRC"; do
  for word in mktemp readlink ' tr ' 'cat ' 'pwd -P'; do
    check "$(basename "$f") body has no '$word'" 0 "$(body "$f" | grep -cF -- "$word" || true)"
  done
done
case_end

case_begin "bootstrap-regions-byte-identical" "bin/get-config-var"
R_GCV="$(region "$GCV_SRC")"; R_CO="$(region "$CO_SRC")"
check "get-config-var has exactly one bootstrap begin marker" 1 "$(grep -c '^# config-flag bootstrap: begin$' "$GCV_SRC" || true)"
check "confirm-off has exactly one bootstrap begin marker" 1 "$(grep -c '^# config-flag bootstrap: begin$' "$CO_SRC" || true)"
if [ -n "$R_GCV" ] && [ "$R_GCV" = "$R_CO" ]; then pass "bootstrap regions are non-empty and byte-identical"
else fail "bootstrap regions are non-empty and byte-identical" "gcv=${#R_GCV} bytes, co=${#R_CO} bytes"; fi
case_end

case_begin "node-modules-name-no-subprocess-api" "hooks/lib/config-flag.js"
for rel in hooks/lib/config-flag.js hooks/lib/confirm-gate/probe.js; do
  if [ -f "$SCRIPT_CHECKOUT_ROOT/$rel" ]; then
    check "$rel names child_process 0 times" 0 "$(grep -c 'child_process' "$SCRIPT_CHECKOUT_ROOT/$rel" || true)"
  else
    fail "$rel names child_process 0 times" "file is absent"
  fi
done
case_end

case_begin "symlinked-launch-resolves" "bin/get-config-var"
printf 'CF_SYM=symval\n' > "$BASE/cfg/.env"
mkdir -p "$BASE/links"
ln -s "$TREE/bin/get-config-var" "$BASE/links/gcv" 2>/dev/null || true
if [ -L "$BASE/links/gcv" ]; then
  run bash "$BASE/links/gcv" CF_SYM
  check "a symlink to get-config-var resolves the value" "symval|0" "$OUT|$RC"
else
  skip "symlinked-launch-resolves: ln -s made no symlink here (Windows default copies)"
fi
: > "$BASE/cfg/.env"
case_end

case_begin "value-mode-newline-identity" "bin/get-config-var"
CF_NL="$(printf 'a\nb\n\nx')"; CF_NL="${CF_NL%x}"; export CF_NL
run bash "$TREE/bin/get-config-var" CF_NL
printf 'a\nb' > "$BASE/want"
if cmp -s "$BASE/want" "$BASE/out"; then pass "inner newline kept, trailing newlines dropped, none appended"
else fail "inner newline kept, trailing newlines dropped, none appended" "got $(od -c "$BASE/out" | head -n 3 | tr '\n' ' ')"; fi
unset CF_NL
case_end

# Parity, not verbatim: under Git Bash, MSYS rewrites a '/'-leading argument before any node
# sees it (the pre-#2681 script already printed C:/some/path). The default must come back
# exactly as a plain bash -> node hop delivers it, on every platform; off MSYS that is verbatim.
case_begin "slash-default-matches-plain-node-hop" "bin/get-config-var"
SLASH_WANT="$(node -e 'process.stdout.write(process.argv[1])' /c/some/path)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) check "premise: off MSYS the plain hop keeps the default verbatim" "/c/some/path" "$SLASH_WANT" ;;
esac
run bash "$TREE/bin/get-config-var" CF_SLASH /c/some/path
check "a '/'-leading default matches the plain bash -> node hop" "$SLASH_WANT|0" "$OUT|$RC"
case_end

case_begin "msys-no-pathconv-still-resolves" "bin/get-config-var"
printf 'CF_PC=pcval\n' > "$BASE/cfg/.env"
run env MSYS_NO_PATHCONV=1 bash "$TREE/bin/get-config-var" CF_PC
check "MSYS_NO_PATHCONV=1: the bootstrap still finds its lib and resolves the value" "pcval|0" "$OUT|$RC"
: > "$BASE/cfg/.env"
case_end

# The bootstrap's drive-letter branch (/c/... -> C:/...) fires only when node on win32 receives a
# drive-mount script path, i.e. under MSYS with MSYS_NO_PATHCONV=1. Off Windows toNative returns every
# path unchanged and no drive mount exists, so there is no branch to reach: the case skips there.
case_begin "msys-drive-letter-path-converts" "bin/get-config-var"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    TREE_M="$(cygpath -m "$TREE")"; DRV="${TREE_M%%:*}"; TREE_C="/${DRV,,}${TREE_M#?:}"
    check "premise: the drive-mount form names the same script" yes "$([ -f "$TREE_C/bin/get-config-var" ] && echo yes || echo no)"
    check "premise: with MSYS_NO_PATHCONV=1 node receives the drive-mount form unconverted" "$TREE_C/bin/get-config-var" \
      "$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(process.argv[1])' "$TREE_C/bin/get-config-var")"
    printf 'CF_PC=drvval\n' > "$BASE/cfg/.env"
    run env MSYS_NO_PATHCONV=1 bash "$TREE_C/bin/get-config-var" CF_PC
    check "a drive-mount script path under MSYS_NO_PATHCONV=1 finds its lib and resolves the value" "drvval|0" "$OUT|$RC"
    run env MSYS_NO_PATHCONV=1 bash "$TREE_C/bin/get-config-var" --is-off CF_PC
    check "same path, --is-off: the lib answers (exit 3 unrecognized, never 4 unreadable)" 3 "$RC"
    : > "$BASE/cfg/.env"
    ;;
  *) skip "msys-drive-letter-path-converts: not MSYS; toNative is a no-op off win32 and drive-mount paths do not exist" ;;
esac
case_end

case_begin "bootstrap-vars-never-leak-into-the-lookup" "bin/get-config-var"
run bash "$TREE/bin/get-config-var" CONFIG_FLAG_MODE dflt
check "CONFIG_FLAG_MODE is not visible to the lookup -> the default" "dflt|0" "$OUT|$RC"
case_end

case_begin "no-lib-get-config-var-answers" "bin/get-config-var"
run bash "$NOLIB/bin/get-config-var" CF_X dflt
check "no config-flag.js, value mode -> the default, exit 0" "dflt|0" "$OUT|$RC"
run env CF_X=exp bash "$NOLIB/bin/get-config-var" CF_X dflt
check "no config-flag.js, value mode -> the export, exit 0" "exp|0" "$OUT|$RC"
run bash "$NOLIB/bin/get-config-var" --is-off CF_X on
check "no config-flag.js, --is-off -> exit 4 (unreadable)" 4 "$RC"
case_end

case_begin "no-node-answers" "bin/get-config-var"
printf 'CF_X=off\n' > "$BASE/cfg/.env"
run env PATH="$NONODE_PATH" bash "$TREE/bin/get-config-var" --is-off CF_X off
check "--is-off without node -> exit 4" 4 "$RC"
run env PATH="$NONODE_PATH" bash "$TREE/bin/get-config-var" CF_X dflt
check "value mode without node -> empty, exit 0" "|0" "$OUT|$RC"
run env PATH="$NONODE_PATH" bash "$TREE/bin/confirm-off" CF_X on
check "confirm-off without node -> ERROR, exit 2" "ERROR|2" "$OUT|$RC"
has "confirm-off without node names the cause" "(no answer from node)" "$ERR"
: > "$BASE/cfg/.env"
case_end

case_begin "confirm-off-error-names-cause" "bin/confirm-off"
run bash "$NOLIB/bin/confirm-off" CF_X on
check "no config-flag.js -> ERROR, exit 2" "ERROR|2" "$OUT|$RC"
has "no config-flag.js -> stderr names lib-missing" "(lib-missing)" "$ERR"
run bash "$THROW/bin/confirm-off" CF_X on
check "load-env throws -> ERROR, exit 2" "ERROR|2" "$OUT|$RC"
has "load-env throws -> stderr names exception" "(exception)" "$ERR"
case_end

case_begin "unset-versus-unreadable" "bin/get-config-var"
run bash "$TREE/bin/get-config-var" --is-off CF_NONE
check "node present, no value, no default -> exit 2 (unset)" 2 "$RC"
run env PATH="$NONODE_PATH" bash "$TREE/bin/get-config-var" --is-off CF_NONE
check "node absent -> exit 4 (unreadable), never 2" 4 "$RC"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
