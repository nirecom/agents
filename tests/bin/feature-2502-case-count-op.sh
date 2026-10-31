#!/usr/bin/env bash
# tests/bin/feature-2502-case-count-op.sh
# Tests: bin/lib/test-language-parts/bash-case-embed.sh
# Tags: TL2, bin, case-markers, test-language-registry, test-language-match, table-driven, scope:issue-specific, node-precommit
# Issue #2502 S4-4b: the caseEmbedRules op case-count, a yardstick of the case-addition judgment.
# bash and js have no case unit apart from their markers, so their case-count is rc 1 for any
# file (user decision 2026-10-24); pester and pytest answer a count; every language is reached
# through the registry (rc 69 without its runtime).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

# path_without / np: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"

FX="$TMPBASE/fx"
mkdir -p "$FX"
MB="case""_begin"  # split so the fixture lines below are not read as markers
ME="case""_end"
JB="case""Begin"
JE="case""End"

# cc <id> <file> [<PATH>] — tlr_call_part <id> caseEmbedRules case-count <file> on this checkout,
# the registry loaded first and <PATH> (when given) set only for the op. Sets CC_RC / CC_OUT.
cc() {
  CC_RC=0
  CC_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/test-language-registry.sh" || exit 97
tlr_load || exit 96
if [ -n "$4" ]; then PATH="$4"; fi
tlr_call_part "$2" caseEmbedRules case-count "$3"' _ "$SCRIPT_CHECKOUT_ROOT" "$1" "$2" "${3:-}" 2>"$TMPBASE/cc.err")" || CC_RC=$?
}

# --- bash fixtures --------------------------------------------------------------------------
printf '%s\n' '#!/usr/bin/env bash' "$MB \"a\" \"bin/a.sh\"" 'echo a' "$ME" \
  "$MB \"b\" \"bin/a.sh\"" 'echo b' "$ME" "$MB \"c\" \"bin/a.sh\"" 'echo c' "$ME" >"$FX/three.sh"
# malformed: the first case is never closed, so two begin lines and one end line.
printf '%s\n' '#!/usr/bin/env bash' "$MB \"a\" \"bin/a.sh\"" 'echo a' \
  "$MB \"b\" \"bin/a.sh\"" 'echo b' "$ME" >"$FX/two-begins.sh"
# one real marker; the heredoc body and the indented line are not units.
printf '%s\n' '#!/usr/bin/env bash' "$MB \"a\" \"bin/a.sh\"" 'echo a' "$ME" \
  "cat <<'EOF'" "$MB \"doc\" \"bin/a.sh\"" "$ME" 'EOF' \
  'if true; then' "  $MB \"indented\" \"bin/a.sh\"" "  $ME" 'fi' >"$FX/hidden.sh"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/a.sh' 'echo plain' >"$FX/none.sh"

case_begin "bash-case-count-is-always-no-unit" "bin/lib/test-language-parts/bash-case-embed.sh"
# Conforming, malformed, hidden-marker and marker-less files alike: rc 1, no count.
for f in three.sh two-begins.sh hidden.sh none.sh; do
  cc bash "$FX/$f"
  assert_eq "bash case-count $f: rc=$CC_RC out=[$CC_OUT]" "bash case-count $f: rc=1 out=[]"
done
case_end

# --- the op through the registry, every language ---------------------------------------------
printf '%s\n' "Describe 'a' {" "    It 'x' { 1 | Should -Be 1 }" '}' "Describe 'b' {" "    It 'y' { 1 | Should -Be 1 }" '}' >"$FX/two.Tests.ps1"
printf '%s\n' 'def test_a():' '    assert True' '' '' 'def test_b():' '    assert True' >"$FX/test_two.py"
printf '%s\n' '"use strict";' "const { test } = require(\"node:test\");" \
  "$JB(\"a\", \"bin/a.sh\");" 'test("a", () => {});' "$JE();" \
  "$JB(\"b\", \"bin/a.sh\");" 'test("b", () => {});' "$JE();" >"$FX/two.js"

# id|fixture|runtime|rc|stdout — each fixture holds two cases; js has no unit, so rc 1.
LANG_ROWS='pester|two.Tests.ps1|pwsh|0|2
pytest|test_two.py|uv|0|2
js|two.js|node|1|'

case_begin "case-count-op-dispatch-every-language" "bin/lib/test-language-parts/bash-case-embed.sh"
# The op is reached through the registry for every supported language (the lib calls only
# tlr_call_part).
while IFS='|' read -r id f rt want_rc want_out; do
  if ! command -v "$rt" >/dev/null 2>&1; then skip "$id case-count: $rt not installed"; continue; fi
  cc "$id" "$FX/$f"
  assert_eq "$id case-count: rc=$CC_RC out=[$CC_OUT]" "$id case-count: rc=$want_rc out=[$want_out]"
done <<<"$LANG_ROWS"
case_end

case_begin "case-count-op-runtime-missing-is-69" "bin/lib/test-language-parts/bash-case-embed.sh"
# Without its runtime the op says so (rc 69), never a count and never rc 0.
while IFS='|' read -r id f rt _rc _out; do
  cc "$id" "$FX/$f" "$(path_without "$rt")"
  assert_eq "$id case-count without $rt: rc=$CC_RC out=[$CC_OUT]" "$id case-count without $rt: rc=69 out=[]"
done <<<"$LANG_ROWS"
case_end

# The code-lines yardstick (#2507: now codeLines in Node) is pinned by
# tests/hooks/feature-2507-case-addition-node.js.

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
