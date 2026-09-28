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
# #2388: a self-definition is a non-marker candidate line → grammar violation.
echo "$out" | grep -q "malformed case marker (grammar) code=MALFORMED_CASE_MARKER" \
  && pass "self-def-no-call: MALFORMED_CASE_MARKER (grammar)" \
  || fail "self-def-no-call: expected MALFORMED_CASE_MARKER (grammar), got: $out"
case_end

case_begin "heredoc-call" "bin/check-case-markers.sh"
# #2388 inverts the #2397 pin: a marker that lives only in a heredoc body is
# fixture text, not a real marker → the file counts as having none (MISSING).
cat > "$TMP/heredoc-file.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
cat <<'INNER'
case_begin "a" "bin/a.sh"
INNER
SH
out=$(bash "$SCRIPT" "$TMP/heredoc-file.sh")
echo "$out" | grep -q "^HIGH: .*code=MISSING_CASE_MARKERS" \
  && pass "heredoc-call: MISSING_CASE_MARKERS" || fail "heredoc-call: expected MISSING_CASE_MARKERS, got: $out"

rc=0
bash "$SCRIPT" "$TMP/heredoc-file.sh" || rc=$?
[[ "$rc" -eq 1 ]] && pass "heredoc-call: exit 1" || fail "heredoc-call: expected exit 1, got $rc"
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
# #2388 inverts the #2397 pin: an indented marker is not column-0 → grammar violation.
cat > "$TMP/indented-call.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
  case_begin "a" "bin/a.sh"
  case_end
SH
out=$(bash "$SCRIPT" "$TMP/indented-call.sh")
echo "$out" | grep -q "^HIGH: .* line 3: malformed case marker (grammar) code=MALFORMED_CASE_MARKER" \
  && pass "indented-call: MALFORMED_CASE_MARKER (grammar) at line 3" \
  || fail "indented-call: expected line-3 grammar MALFORMED_CASE_MARKER, got: $out"
rc=0
bash "$SCRIPT" "$TMP/indented-call.sh" || rc=$?
[[ "$rc" -eq 1 ]] && pass "indented-call: exit 1" || fail "indented-call: expected exit 1, got $rc"
case_end

# --- #2388: parser-backed classification (none / malformed / uncertain / conforming) ---
# chk <file> — run the checker; sets OUT (stdout), ERR (stderr), RC.
chk() {
  RC=0
  OUT=$(bash "$SCRIPT" "$@" 2>"$TMP/chk.err") || RC=$?
  ERR=$(cat "$TMP/chk.err")
}

# expect_high <label> <regex> — RC must be 1 and OUT must carry a matching HIGH line.
expect_high() {
  [[ "$RC" -eq 1 ]] && pass "$1: exit 1" || fail "$1: expected exit 1, got $RC (out: $OUT)"
  echo "$OUT" | grep -Eq "$2" && pass "$1: HIGH line matches" || fail "$1: expected /$2/, got: $OUT"
}

# expect_clean <label> — RC 0 and no stdout at all (conforming).
expect_clean() {
  [[ "$RC" -eq 0 ]] && pass "$1: exit 0" || fail "$1: expected exit 0, got $RC (out: $OUT)"
  [[ -z "$OUT" ]] && pass "$1: no output" || fail "$1: expected no output, got: $OUT"
}

# expect_warn <label> — RC 0, a WARN UNCERTAIN line, and no HIGH line.
expect_warn() {
  [[ "$RC" -eq 0 ]] && pass "$1: exit 0" || fail "$1: expected exit 0, got $RC (out: $OUT)"
  echo "$OUT" | grep -Eq '^WARN: .* line [0-9]+: case marker nesting uncertain .*code=UNCERTAIN_CASE_MARKER$' \
    && pass "$1: WARN UNCERTAIN_CASE_MARKER" || fail "$1: expected WARN UNCERTAIN line, got: $OUT"
  echo "$OUT" | grep -q '^HIGH:' && fail "$1: unexpected HIGH line: $OUT" || pass "$1: no HIGH line"
}

case_begin "depth-in-if" "bin/check-case-markers.sh"
cat > "$TMP/depth-in-if.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if true; then
case_begin "a" "bin/a.sh"
echo hi
case_end
fi
SH
chk "$TMP/depth-in-if.sh"
expect_high "depth-in-if" '^HIGH: .*depth-in-if\.sh line 4: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "unbalanced-begin" "bin/check-case-markers.sh"
cat > "$TMP/unbalanced.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
case_begin "a" "bin/a.sh"
echo hi
SH
chk "$TMP/unbalanced.sh"
# A balance violation reports the file's last line.
expect_high "unbalanced-begin" '^HIGH: .*unbalanced\.sh line 4: malformed case marker \(balance\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "comment-mention-only" "bin/check-case-markers.sh"
cat > "$TMP/comment-only.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# wrap each case with case_begin later
echo hi
SH
chk "$TMP/comment-only.sh"
expect_high "comment-mention-only" '^HIGH: .*comment-only\.sh line 3: malformed case marker \(grammar\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "bad-target-absolute" "bin/check-case-markers.sh"
cat > "$TMP/abs-target.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
case_begin "a" "/abs/bin/a.sh"
echo hi
case_end
SH
chk "$TMP/abs-target.sh"
expect_high "bad-target-absolute" '^HIGH: .*abs-target\.sh line 3: malformed case marker \(target\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "one-line-if-before-marker" "bin/check-case-markers.sh"
# D1: one-line compounds (with or without a trailing redirect/pipe) are depth-neutral.
cat > "$TMP/one-line-if.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if [ -n "$X" ]; then echo x; fi
for f in a b; do echo "$f"; done > /dev/null
while false; do :; done 2>&1 | cat
case "$X" in a) echo a ;; esac
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/one-line-if.sh"
expect_clean "one-line-if-before-marker"
case_end

case_begin "else-fi-one-line" "bin/check-case-markers.sh"
# D1: a non-opener line ending in "; fi" closes the block (-1).
cat > "$TMP/else-fi.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if [ -n "$X" ]; then
  echo x
else echo y; fi
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/else-fi.sh"
expect_clean "else-fi-one-line"
case_end

case_begin "echo-done-not-closer" "bin/check-case-markers.sh"
# D1 guard: "echo all done" has no ";" before the keyword → depth unchanged.
cat > "$TMP/echo-done.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
while true; do
  break
echo all done
done
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/echo-done.sh"
expect_clean "echo-done-not-closer"
case_end

case_begin "multiline-node-e-before-marker" "bin/check-case-markers.sh"
# D2: a multi-line quoted JS body skews depth → uncertain → WARN, exit 0.
cat > "$TMP/node-e.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
node -e '
for (const a of [1]) console.log(a)
'
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/node-e.sh"
expect_warn "multiline-node-e-before-marker"
case_end

case_begin "depth-in-if-after-closed-apostrophe" "bin/check-case-markers.sh"
# An apostrophe inside a closed "..." leaves no quote open, so a real depth
# violation after it stays HIGH (the quote scan, not a raw quote count, decides).
cat > "$TMP/apostrophe-depth.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo "it's"
if true; then
case_begin "a" "bin/a.sh"
echo hi
case_end
fi
SH
chk "$TMP/apostrophe-depth.sh"
expect_high "depth-in-if-after-closed-apostrophe" '^HIGH: .*apostrophe-depth\.sh line 5: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
case_end

# shellcheck source=feature-check-case-markers/lexer-edges.sh
. "$AGENTS_DIR/tests/bin/feature-check-case-markers/lexer-edges.sh"

case_begin "depth-in-if-with-quote-risk" "bin/check-case-markers.sh"
# Known false negative (accepted tradeoff): a real depth violation after a
# line that leaves a quote open is reported as uncertain (WARN), not HIGH.
cat > "$TMP/quote-risk-depth.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo "multi
line"
if true; then
case_begin "a" "bin/a.sh"
echo hi
case_end
fi
SH
chk "$TMP/quote-risk-depth.sh"
expect_warn "depth-in-if-with-quote-risk"
case_end

case_begin "missing-code-tag" "bin/check-case-markers.sh"
cat > "$TMP/missing.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo hi
SH
chk "$TMP/missing.sh"
expect_high "missing-code-tag" '^HIGH: .*missing\.sh \(2 paths in # Tests: header, no case_[a-z]+/case_[a-z]+ markers\) code=MISSING_CASE_MARKERS$'
case_end

case_begin "lib-unavailable" "bin/check-case-markers.sh"
# A copy of the checker with no sibling bin/lib → exit 2, stderr diagnostic, no HIGH.
mkdir -p "$TMP/libless/bin"
cp "$SCRIPT" "$TMP/libless/bin/check-case-markers.sh"
RC=0
OUT=$(bash "$TMP/libless/bin/check-case-markers.sh" "$TMP/missing.sh" 2>"$TMP/chk.err") || RC=$?
ERR=$(cat "$TMP/chk.err")
[[ "$RC" -eq 2 ]] && pass "lib-unavailable: exit 2" || fail "lib-unavailable: expected exit 2, got $RC"
echo "$ERR" | grep -q "check-case-markers.sh: predicate library unavailable" \
  && pass "lib-unavailable: stderr diagnostic" || fail "lib-unavailable: expected diagnostic, got: $ERR"
echo "$OUT" | grep -q '^HIGH:' && fail "lib-unavailable: unexpected HIGH: $OUT" || pass "lib-unavailable: no HIGH line"
case_end
