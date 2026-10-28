#!/usr/bin/env bash
# Tests: skills/session-close/scripts/migrate-own-session-chain.sh
# Tags: TL2, migration, regression-2748, scope:issue-specific, pwsh-not-required
# #2748 M21-M22: the session-close re-migration script (SC-10) forwards the session id to the CLI, stays advisory
# (exit 0) when the CLI fails or is absent, and carries the temporary-migration markers.
# The CLI's own --session behavior and its markers are covered by tests/bin/fix-2748-orphan-progress-migration-session.js.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

SCRIPT_REL="skills/session-close/scripts/migrate-own-session-chain.sh"
CLI_REL="bin/migrate-orphan-progress-files"

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$TMP_ROOT/cwd"
cd "$TMP_ROOT/cwd" || exit 1

# fake_tree <name> <cli-body|-> : copy of the script beside a stand-in CLI ("-" = no CLI); prints the tree root.
fake_tree() {
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/skills/session-close/scripts" "$root/bin"
  cp "$SCRIPT_CHECKOUT_ROOT/$SCRIPT_REL" "$root/$SCRIPT_REL"
  if [ "$2" != "-" ]; then
    printf '%s\n' "$2" >"$root/$CLI_REL"
  fi
  printf '%s' "$root"
}

# markers_in_order <repo-relative file> <comment prefix> : 0 when BEGIN, deletion-condition and END appear in order.
markers_in_order() {
  local file="$SCRIPT_CHECKOUT_ROOT/$1" prefix="$2"
  local desc="orphan progress file -> first_session_id progress file migration"
  local begin_line="$prefix --- BEGIN temporary: $desc added 2026-10-24 ---"
  local end_line="$prefix --- END temporary: $desc ---"
  local cond_prefix="$prefix deletion-condition: remove after 2026-11-22"
  [ -f "$file" ] || return 1
  local n=0 begin=-1 end=-1 line
  local lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    lines+=("$line")
    if [ "$line" = "$begin_line" ] && [ "$begin" -lt 0 ]; then
      begin=$n
    fi
    if [ "$line" = "$end_line" ] && [ "$end" -lt 0 ]; then
      end=$n
    fi
    n=$((n + 1))
  done <"$file"
  [ "$begin" -ge 0 ] || return 1
  case "${lines[$((begin + 1))]:-}" in
    "$cond_prefix"*) ;;
    *) return 1 ;;
  esac
  [ "$end" -gt $((begin + 1)) ]
}

case_begin "script-forwards-session-to-cli" "skills/session-close/scripts/migrate-own-session-chain.sh"
root="$(fake_tree forwards 'process.stdout.write("ARGS=" + process.argv.slice(2).join(" ") + "\n");')"
out="$(AGENTS_MAIN_ROOT="$root" bash "$root/$SCRIPT_REL" sid-m21 2>"$TMP_ROOT/forwards.err")"
rc=$?
if [ "$rc" -eq 0 ]; then pass "M21: the script exits 0"; else fail "M21: the script exits 0" "rc=$rc"; fi
if [ "$out" = "ARGS=--apply --include-active --session sid-m21" ]; then
  pass "M21: the CLI gets --apply --include-active --session <sid> and its output is passed through"
else
  fail "M21: the CLI gets --apply --include-active --session <sid> and its output is passed through" "out=[$out]"
fi
case_end

case_begin "script-advisory-when-cli-fails" "skills/session-close/scripts/migrate-own-session-chain.sh"
root="$(fake_tree cli-fails 'process.exit(1);')"
AGENTS_MAIN_ROOT="$root" bash "$root/$SCRIPT_REL" sid-m21 >/dev/null 2>"$TMP_ROOT/fails.err"
rc=$?
if [ "$rc" -eq 0 ]; then pass "M21: the script exits 0 when the CLI exits 1"; else fail "M21: the script exits 0 when the CLI exits 1" "rc=$rc"; fi
nlines="$(grep -c . "$TMP_ROOT/fails.err")"
if [ "$nlines" = "1" ]; then
  pass "M21: the CLI failure is reported on stderr in exactly one line"
else
  fail "M21: the CLI failure is reported on stderr in exactly one line" "lines=$nlines"
fi
case_end

case_begin "script-noop-when-cli-absent" "skills/session-close/scripts/migrate-own-session-chain.sh"
root="$(fake_tree cli-absent -)"
out="$(AGENTS_MAIN_ROOT="$root" bash "$root/$SCRIPT_REL" sid-m21 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "M21: the script exits 0 and prints nothing when the CLI is absent"
else
  fail "M21: the script exits 0 and prints nothing when the CLI is absent" "rc=$rc out=[$out]"
fi
case_end

case_begin "temporary-migration-markers-in-script" "skills/session-close/scripts/migrate-own-session-chain.sh"
if markers_in_order "$SCRIPT_REL" "#"; then
  pass "M22: the session-close script has BEGIN, deletion-condition and END in this order"
else
  fail "M22: the session-close script has BEGIN, deletion-condition and END in this order"
fi
case_end

echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
