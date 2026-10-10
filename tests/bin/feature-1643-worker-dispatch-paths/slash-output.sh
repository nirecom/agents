#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-paths/slash-output.sh
# Tests: bin/worker-dispatch-paths
# Tags: worker-dispatch, paths-resolver, root-names, slash-form, security, TL2, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-paths.sh, which calls group_slash_output.
# The resolver prints slash-form values under the key TARGET_MAIN_ROOT, usable as literals.
# Uses the parent's pass / fail / skip / run_with_timeout / nodepath / canon / backslash_form / TMPD_N and its pins.
# TL3 gap: a live Bash tool call where the hook's own cwd picks the judged repo; a shell
# other than Git Bash re-reading the printed values (the allow check runs here on them).

_SLASH_OUTPUT_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck source=tests/lib/target-repo-fixture.sh
. "$_SLASH_OUTPUT_SCRIPT_CHECKOUT_ROOT/tests/lib/target-repo-fixture.sh"

_SO_CHECKOUT_N="$(nodepath "$_SLASH_OUTPUT_SCRIPT_CHECKOUT_ROOT")"
_SO_RESOLVER="$_SO_CHECKOUT_N/bin/worker-dispatch-paths"
_SO_BASE="$TMPD_N/slash-output"
_SO_PROBE="$_SO_BASE/probe.js"
_SO_DECOY="$_SO_BASE/decoy-tree"
_SO_SPACE="$_SO_BASE/dir with space"
# The output key from before the rename, assembled so this file never holds it.
_SO_OLD_KEY="MAIN""_ROOT"

_so_probe() { run_with_timeout 60 node "$_SO_PROBE" "$_SO_CHECKOUT_N" "$@" 2>&1; }
_so_value() { sed -n "s/^$2=//p" "$1"; }
_so_resolve() { run_with_timeout 60 node "$_SO_RESOLVER" "$2" >"$1" 2>"$1.err"; }
_so_flat() { tr '\n' ' ' <"$1"; }

_so_setup() {
  mkdir -p "$_SO_DECOY/bin" "$_SO_SPACE"
  target_repo_fixture_create "$_SO_BASE" || return 1
  git init -q "$_SO_SPACE" || return 1
  git -C "$_SO_SPACE" config core.hooksPath /dev/null || return 1
  git -C "$_SO_SPACE" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init || return 1
  cat >"$_SO_PROBE" <<'PROBE_JS'
"use strict";
const [checkout, mode, a, b] = process.argv.slice(2);
if (mode === "anchor") {
  const r = require(checkout + "/bin/worker-dispatch/anchor.js").resolveAnchors(a);
  process.stdout.write(r.error === null ? "ok" : "error: " + r.error);
} else {
  const m = require(checkout + "/hooks/enforce-worktree/main-worktree-allows/worker-script.js");
  process.stdout.write(String(m.isAllowedWorkerScriptInvocation(a, b)));
}
PROBE_JS
}

# _so_shape <out-file>: no backslash, the three keys in order, no pre-rename key.
_so_shape() {
  local out="$1" keys
  if [ -s "$out" ] && ! grep -q '\\' "$out"; then
    pass "shape: none of the three output lines carries a backslash"
  else
    fail "shape: backslash in the resolver output" "$(_so_flat "$out")"
  fi
  keys="$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$out" | tr '\n' ',')"
  if [ "$keys" = "DISPATCH,TARGET_MAIN_ROOT,PLANS_DIR," ]; then
    pass "shape: keys are DISPATCH, TARGET_MAIN_ROOT, PLANS_DIR in that order"
  else
    fail "shape: key names" "got='$keys'"
  fi
  if grep -q "^${_SO_OLD_KEY}=" "$out"; then
    fail "shape: a line still starts with the pre-rename key" "$(_so_flat "$out")"
  elif [ -s "$out" ]; then
    pass "shape: no line starts with the pre-rename key"
  else
    fail "shape: no output to inspect for the pre-rename key"
  fi
}

# _so_values <dispatch> <target-main> <plans>
_so_values() {
  if [ "$1" = "$(printf '%s' "$1" | tr '\\' '/')" ] && [ "$(canon "$1")" = "$(canon "$_SO_CHECKOUT_N/bin/worker-dispatch.js")" ]; then
    pass "values: DISPATCH is this checkout's dispatcher in slash form"
  else
    fail "values: DISPATCH" "got='$1'"
  fi
  if [ -n "$2" ] && [ "$(canon "$2")" = "$(canon "$TARGET_MAIN_ROOT")" ]; then
    pass "values: a linked-worktree target resolves TARGET_MAIN_ROOT to the main worktree"
  else
    fail "values: TARGET_MAIN_ROOT" "got='$2' want='$TARGET_MAIN_ROOT'"
  fi
  if [ "$3" = "$(printf '%s' "$3" | tr '\\' '/')" ] && [ "$(canon "$3")" = "$(canon "$WORKFLOW_PLANS_DIR")" ]; then
    pass "values: PLANS_DIR is the configured plans directory in slash form"
  else
    fail "values: PLANS_DIR" "got='$3' want='$WORKFLOW_PLANS_DIR'"
  fi
}

# _so_stability <out-file> <target-main>: a second run, a path with a space, the error path.
_so_stability() {
  local out="$1" tmr="$2" space_v rc back
  _so_resolve "$_SO_BASE/out2.txt" "$TARGET_CHECKOUT_ROOT"
  if [ -n "$tmr" ] && cmp -s "$out" "$_SO_BASE/out2.txt"; then
    pass "idempotent: a second run prints byte-identical slash-form lines"
  else
    fail "idempotent: runs differ or the new key is missing" "$(_so_flat "$_SO_BASE/out2.txt")"
  fi
  back="$(backslash_form "$TARGET_CHECKOUT_ROOT")"
  case "$back" in
    *\\*)
      _so_resolve "$_SO_BASE/out-back.txt" "$back"
      if [ -n "$tmr" ] && cmp -s "$out" "$_SO_BASE/out-back.txt"; then
        pass "backslash-input: a backslash-form target prints the same slash-form lines"
      else
        fail "backslash-input: output differs from the slash-form run" "arg='$back' $(_so_flat "$_SO_BASE/out-back.txt")"
      fi ;;
    *) skip "backslash-input: a backslash-form target" "this host has no backslash path form" ;;
  esac
  _so_resolve "$_SO_BASE/out-space.txt" "$_SO_SPACE"
  space_v="$(_so_value "$_SO_BASE/out-space.txt" TARGET_MAIN_ROOT)"
  if [ "$space_v" = "$_SO_SPACE" ] || [ "$(canon "${space_v:-missing}")" = "$(canon "$_SO_SPACE")" ]; then
    pass "edge: a target path containing a space is printed whole under the new key"
  else
    fail "edge: space-in-path target" "got='$space_v'"
  fi
  if [ -s "$_SO_BASE/out-space.txt" ] && ! grep -q '\\' "$_SO_BASE/out-space.txt"; then
    pass "edge: the space-in-path output carries no backslash either"
  else
    fail "edge: backslash in the space-in-path output" "$(_so_flat "$_SO_BASE/out-space.txt")"
  fi
  _so_resolve "$_SO_BASE/out-missing.txt" "$_SO_BASE/not-here"
  rc=$?
  if [ "$rc" -eq 1 ] && [ ! -s "$_SO_BASE/out-missing.txt" ] && grep -q '^worker-dispatch-paths: ' "$_SO_BASE/out-missing.txt.err"; then
    pass "error: a missing target exits 1 with empty stdout and a prefixed diagnostic"
  else
    fail "error: missing target" "rc=$rc stdout=$(cat "$_SO_BASE/out-missing.txt")"
  fi
}

# _so_usable <dispatch> <target-main>: the printed values as literal dispatcher arguments.
_so_usable() {
  local dispatch="$1" tmr="$2" got payload cmd bad retired name
  local -a decoy_env
  got="$(_so_probe anchor "$tmr")"
  if [ "$got" = "ok" ]; then
    pass "usable: anchor.js accepts the slash-form value as an absolute main worktree"
  else
    fail "usable: anchor.js refused the slash-form value" "$got"
  fi
  got="$(_so_probe anchor "$TARGET_CHECKOUT_ROOT")"
  case "$got" in
    *"is not a main worktree") pass "usable: anchor.js still refuses the linked worktree in that position" ;;
    *) fail "usable: linked worktree verdict" "$got" ;;
  esac

  payload="$WORKFLOW_STATE_DIR/s2561.control/worker-test-runner-1.json"
  cmd="node \"$dispatch\" test-runner \"$tmr\" \"$payload\""
  got="$(ENFORCE_WORKTREE_ADDITIONAL_REPOS="$tmr" _so_probe allow "$cmd" "$tmr")"
  if [ "$got" = "true" ]; then
    pass "allow: the literal slash-form command line passes the worker-script allow check"
  else
    fail "allow: the resolver's own values were refused" "got='$got' cmd='$cmd'"
  fi
  # Every root name, current and retired, names the decoy tree for the next two verdicts.
  decoy_env=("AGENTS_MAIN_ROOT=$_SO_DECOY" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$tmr")
  retired="$(run_with_timeout 30 node "$_SO_CHECKOUT_N/tests/lib/root-decoy-build.js" --print-retired-env-names 2>/dev/null | tr -d '\r')"
  for name in $retired; do decoy_env+=("$name=$_SO_DECOY"); done
  if [ -n "$retired" ]; then
    pass "allow: the retired root names are available to point at the decoy tree"
  else
    fail "allow: the retired root name list is empty — the decoy cases cover one name only"
  fi
  got="$(run_with_timeout 60 env "${decoy_env[@]}" node "$_SO_PROBE" "$_SO_CHECKOUT_N" allow "$cmd" "$tmr" 2>&1)"
  if [ "$got" = "true" ]; then
    pass "allow: root names pointing at another tree do not change the verdict"
  else
    fail "allow: an env value changed the verdict" "got='$got'"
  fi
  bad="node \"$_SO_DECOY/bin/worker-dispatch.js\" test-runner \"$tmr\" \"$payload\""
  got="$(run_with_timeout 60 env "${decoy_env[@]}" node "$_SO_PROBE" "$_SO_CHECKOUT_N" allow "$bad" "$tmr" 2>&1)"
  if [ "$got" = "false" ]; then
    pass "allow: a dispatcher under the env-named tree is refused"
  else
    fail "allow: env-named dispatcher accepted" "got='$got'"
  fi
  bad="node \"$dispatch\" test-runner \"$TARGET_CHECKOUT_ROOT\" \"$payload\""
  got="$(ENFORCE_WORKTREE_ADDITIONAL_REPOS="$tmr" _so_probe allow "$bad" "$TARGET_CHECKOUT_ROOT")"
  if [ "$got" = "false" ]; then
    pass "allow: a linked worktree in the TARGET_MAIN_ROOT position is refused"
  else
    fail "allow: linked worktree accepted" "got='$got'"
  fi
  bad="node \"$dispatch\" test-runner \"$tmr\" \"$_SO_BASE/elsewhere/worker-test-runner-1.json\""
  got="$(ENFORCE_WORKTREE_ADDITIONAL_REPOS="$tmr" _so_probe allow "$bad" "$tmr")"
  if [ "$got" = "false" ]; then
    pass "allow: a payload outside the control and plans directories is refused"
  else
    fail "allow: stray payload accepted" "got='$got'"
  fi
}

group_slash_output() {
  local out="$_SO_BASE/out.txt" rc dispatch_v tmr_v plans_v
  mkdir -p "$_SO_BASE"
  if ! _so_setup; then
    fail "slash-output setup: the target repository fixture could not be built"
    return
  fi
  _so_resolve "$out" "$TARGET_CHECKOUT_ROOT"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(grep -c '' "$out")" -eq 3 ]; then
    pass "setup: the resolver prints three lines for a linked-worktree target"
  else
    fail "setup: resolver run" "rc=$rc stderr=$(cat "$out.err")"
  fi
  _so_shape "$out"
  dispatch_v="$(_so_value "$out" DISPATCH)"
  tmr_v="$(_so_value "$out" TARGET_MAIN_ROOT)"
  plans_v="$(_so_value "$out" PLANS_DIR)"
  _so_values "$dispatch_v" "$tmr_v" "$plans_v"
  _so_stability "$out" "$tmr_v"
  # Without the value there is nothing to hand on: record it and stop here.
  if [ -z "$tmr_v" ]; then
    fail "usable: no TARGET_MAIN_ROOT value to hand on to the dispatcher"
    return
  fi
  _so_usable "$dispatch_v" "$tmr_v"
}
