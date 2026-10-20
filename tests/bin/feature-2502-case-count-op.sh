#!/usr/bin/env bash
# tests/bin/feature-2502-case-count-op.sh
# Tests: bin/lib/test-language-parts/bash-case-embed.sh, bin/lib/test-language-match/case-addition.sh
# Tags: TL2, bin, case-markers, test-language-registry, test-language-match, table-driven, scope:issue-specific
# Issue #2502 S4-4b: the caseEmbedRules op case-count and _tlm_code_lines, the two yardsticks of
# the case-addition judgment. bash counts its column-0 case markers outside heredocs (rc 1 for
# none); every supported language answers case-count through the registry (rc 69 without its
# runtime); _tlm_code_lines counts lines that are neither blank nor comments in the match-path's
# comment prefix. The per-language units are pinned by the three analyzer tests.
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

# code_lines <file> <match-path> — _tlm_code_lines through the language-match library. Sets CL_RC / CL_OUT.
code_lines() {
  CL_RC=0
  CL_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/test-language-match.sh" || exit 97
tlr_load || exit 96
declare -F _tlm_code_lines >/dev/null || exit 95
_tlm_code_lines "$2" "$3"' _ "$SCRIPT_CHECKOUT_ROOT" "$1" "$2" 2>"$TMPBASE/cl.err")" || CL_RC=$?
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

case_begin "bash-case-count-table" "bin/lib/test-language-parts/bash-case-embed.sh"
# file|rc|stdout
while IFS='|' read -r f want_rc want_out; do
  [ -n "$f" ] || continue
  cc bash "$FX/$f"
  assert_eq "bash case-count $f: rc=$CC_RC out=[$CC_OUT]" "bash case-count $f: rc=$want_rc out=[$want_out]"
done <<'ROWS'
three.sh|0|3
two-begins.sh|0|2
hidden.sh|0|1
none.sh|1|
ROWS
case_end

# --- the op through the registry, every language ---------------------------------------------
printf '%s\n' "Describe 'a' {" "    It 'x' { 1 | Should -Be 1 }" '}' "Describe 'b' {" "    It 'y' { 1 | Should -Be 1 }" '}' >"$FX/two.Tests.ps1"
printf '%s\n' 'def test_a():' '    assert True' '' '' 'def test_b():' '    assert True' >"$FX/test_two.py"
printf '%s\n' '"use strict";' "const { test } = require(\"node:test\");" \
  "$JB(\"a\", \"bin/a.sh\");" 'test("a", () => {});' "$JE();" \
  "$JB(\"b\", \"bin/a.sh\");" 'test("b", () => {});' "$JE();" >"$FX/two.js"

# id|fixture|runtime
LANG_ROWS='pester|two.Tests.ps1|pwsh
pytest|test_two.py|uv
js|two.js|node'

case_begin "case-count-op-dispatch-every-language" "bin/lib/test-language-parts/bash-case-embed.sh"
# The op is reached through the registry for every supported language (the lib calls only
# tlr_call_part); each two-unit fixture answers 2.
while IFS='|' read -r id f rt; do
  if ! command -v "$rt" >/dev/null 2>&1; then skip "$id case-count: $rt not installed"; continue; fi
  cc "$id" "$FX/$f"
  assert_eq "$id case-count: rc=$CC_RC out=[$CC_OUT]" "$id case-count: rc=0 out=[2]"
done <<<"$LANG_ROWS"
case_end

case_begin "case-count-op-runtime-missing-is-69" "bin/lib/test-language-parts/bash-case-embed.sh"
# Without its runtime the op says so (rc 69), never a count and never rc 0.
while IFS='|' read -r id f rt; do
  cc "$id" "$FX/$f" "$(path_without "$rt")"
  assert_eq "$id case-count without $rt: rc=$CC_RC out=[$CC_OUT]" "$id case-count without $rt: rc=69 out=[]"
done <<<"$LANG_ROWS"
case_end

# --- _tlm_code_lines ------------------------------------------------------------------------
printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/a.sh' '' '   # indented comment' 'echo a' '  echo b' '' >"$FX/lines.sh"
printf '%s\n' '"use strict";' '// Tests: bin/a.sh' '  // indented comment' '' 'const a = 1;' '# not a js comment' >"$FX/lines.js"
printf '%s\n' '# Tests: bin/a.sh' '"""A docstring is code."""' '' 'import os' '    # indented comment' 'def test_a():' '    pass' >"$FX/lines.py"

case_begin "code-lines-skip-blank-and-comment-lines" "bin/lib/test-language-match/case-addition.sh"
# file|match-path|count — the comment prefix comes from the match-path's registry entry.
while IFS='|' read -r f m want; do
  [ -n "$f" ] || continue
  code_lines "$FX/$f" "$m"
  assert_eq "_tlm_code_lines $f as $m: rc=$CL_RC out=[$CL_OUT]" "_tlm_code_lines $f as $m: rc=0 out=[$want]"
done <<'ROWS'
lines.sh|tests/bin/x.sh|2
lines.js|tests/bin/x.js|3
lines.py|tests/bin/test_x.py|4
ROWS
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
