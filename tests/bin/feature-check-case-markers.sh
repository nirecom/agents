#!/usr/bin/env bash
# Tests: bin/check-case-markers.sh
# Tags: TL1, review-tests, case-markers, scope:issue-specific

AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
source "$AGENTS_DIR/tests/lib/harness.sh"

SCRIPT="$AGENTS_DIR/bin/check-case-markers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case_begin "no-header" "bin/check-case-markers.sh"
# File with no # Tests: header → no violation
printf '#!/usr/bin/env bash\necho hi\n' > "$TMP/no-header.sh"
out=$(bash "$SCRIPT" "$TMP/no-header.sh")
if [[ -z "$out" ]]; then
  pass "no-header: no violation when # Tests: is absent"
else
  fail "no-header: unexpected output: $out"
fi

rc=0
bash "$SCRIPT" "$TMP/no-header.sh" || rc=$?
[[ "$rc" -eq 0 ]] && pass "no-header: exit 0" || fail "no-header: expected exit 0, got $rc"
case_end

case_begin "single-path" "bin/check-case-markers.sh"
# File with exactly one # Tests: path → no violation even without case_begin
printf '#!/usr/bin/env bash\n# Tests: bin/tool.sh\necho test\n' > "$TMP/single.sh"
out=$(bash "$SCRIPT" "$TMP/single.sh")
[[ -z "$out" ]] && pass "single-path: no violation" || fail "single-path: unexpected: $out"

rc=0
bash "$SCRIPT" "$TMP/single.sh" || rc=$?
[[ "$rc" -eq 0 ]] && pass "single-path: exit 0" || fail "single-path: expected exit 0, got $rc"
case_end

case_begin "multi-path-no-markers" "bin/check-case-markers.sh"
# File with 2 # Tests: paths and no case_begin → HIGH violation
printf '#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\necho test\n' > "$TMP/multi-no-markers.sh"
out=$(bash "$SCRIPT" "$TMP/multi-no-markers.sh")
if echo "$out" | grep -q "^HIGH:"; then
  pass "multi-path-no-markers: HIGH line emitted"
else
  fail "multi-path-no-markers: expected HIGH line, got: $out"
fi

rc=0
bash "$SCRIPT" "$TMP/multi-no-markers.sh" || rc=$?
[[ "$rc" -eq 1 ]] && pass "multi-path-no-markers: exit 1" || fail "multi-path-no-markers: expected exit 1, got $rc"
case_end

case_begin "multi-path-with-markers" "bin/check-case-markers.sh"
# File with 2 # Tests: paths and case_begin present → no violation
printf '#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\ncase_begin "a" "bin/a.sh"\necho hi\ncase_end\n' \
  > "$TMP/multi-with-markers.sh"
out=$(bash "$SCRIPT" "$TMP/multi-with-markers.sh")
[[ -z "$out" ]] && pass "multi-path-with-markers: no violation" || fail "multi-path-with-markers: unexpected: $out"

rc=0
bash "$SCRIPT" "$TMP/multi-with-markers.sh" || rc=$?
[[ "$rc" -eq 0 ]] && pass "multi-path-with-markers: exit 0" || fail "multi-path-with-markers: expected exit 0, got $rc"
case_end

case_begin "three-paths" "bin/check-case-markers.sh"
# File with 3 # Tests: paths and no case_begin → violation, path count in message
printf '#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh, bin/c.sh\necho test\n' > "$TMP/three.sh"
out=$(bash "$SCRIPT" "$TMP/three.sh")
if echo "$out" | grep -q "3 paths"; then
  pass "three-paths: path count reported correctly"
else
  fail "three-paths: expected '3 paths' in output, got: $out"
fi
case_end

case_begin "self-def-no-call" "bin/check-case-markers.sh"
# #2397 regression: function definition of case_begin (no call) must still trigger violation
printf '#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\ncase_begin() { echo "noop"; }\n' > "$TMP/self-def.sh"
out=$(bash "$SCRIPT" "$TMP/self-def.sh")
if echo "$out" | grep -q "^HIGH:"; then
  pass "self-def-no-call: HIGH line emitted"
else
  fail "self-def-no-call: expected HIGH line, got: $out"
fi

rc=0
bash "$SCRIPT" "$TMP/self-def.sh" || rc=$?
[[ "$rc" -eq 1 ]] && pass "self-def-no-call: exit 1" || fail "self-def-no-call: expected exit 1, got $rc"
case_end

case_begin "heredoc-call" "bin/check-case-markers.sh"
# #2397 regression: case_begin inside a heredoc body satisfies the marker check → no violation
cat > "$TMP/heredoc-file.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
cat <<'INNER'
case_begin "a" "bin/a.sh"
INNER
SH
out=$(bash "$SCRIPT" "$TMP/heredoc-file.sh")
[[ -z "$out" ]] && pass "heredoc-call: no violation" || fail "heredoc-call: unexpected output: $out"

rc=0
bash "$SCRIPT" "$TMP/heredoc-file.sh" || rc=$?
[[ "$rc" -eq 0 ]] && pass "heredoc-call: exit 0" || fail "heredoc-call: expected exit 0, got $rc"
case_end

case_begin "no-args" "bin/check-case-markers.sh"
# #2398 regression: zero arguments → exit 1 with non-empty stderr
rc=0
err=$(bash "$SCRIPT" 2>&1 >/dev/null) || rc=$?
[[ "$rc" -eq 1 ]] && pass "no-args: exit 1" || fail "no-args: expected exit 1, got $rc"
[[ -n "$err" ]] && pass "no-args: non-empty stderr" || fail "no-args: expected non-empty stderr, got empty"
case_end

case_begin "nonexistent-path" "bin/check-case-markers.sh"
# #2398 regression: path that does not exist → exit 1 with "not found" in stderr
rc=0
err=$(bash "$SCRIPT" "$TMP/does-not-exist.sh" 2>&1 >/dev/null) || rc=$?
[[ "$rc" -eq 1 ]] && pass "nonexistent-path: exit 1" || fail "nonexistent-path: expected exit 1, got $rc"
echo "$err" | grep -q "not found" && pass "nonexistent-path: stderr contains 'not found'" \
  || fail "nonexistent-path: expected 'not found' in stderr, got: $err"
case_end

case_begin "indented-call" "bin/check-case-markers.sh"
# #2397 regression: case_begin with leading whitespace (indent) must satisfy the check
printf '#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\n  case_begin "a" "bin/a.sh"\n' > "$TMP/indented-call.sh"
out=$(bash "$SCRIPT" "$TMP/indented-call.sh")
[[ -z "$out" ]] && pass "indented-call: no violation" || fail "indented-call: unexpected output: $out"
rc=0
bash "$SCRIPT" "$TMP/indented-call.sh" || rc=$?
[[ "$rc" -eq 0 ]] && pass "indented-call: exit 0" || fail "indented-call: expected exit 0, got $rc"
case_end
