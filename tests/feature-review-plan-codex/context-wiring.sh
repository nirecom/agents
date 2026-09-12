# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Context wiring: --context marker plumbing (single, absent, empty-file guard, multiple)
# ===========================================================================

# ---------------------------------------------------------------------------
# 23. detail-plan --context: context markers appear in prompt
# ---------------------------------------------------------------------------
CTX_FILE="$TMPDIR_BASE/ctx-detail.md"
printf 'INTENT_MARKER_ABCDEF\n---\nOUTLINE_MARKER_GHIJKL\n' > "$CTX_FILE"

CAPTURE23="$TMPDIR_BASE/captured-23.txt"
sed "s|CAPTURE_PLACEHOLDER|$CAPTURE23|" > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
cat > "CAPTURE_PLACEHOLDER"
echo "APPROVED"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

exit_code23=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan --context "$CTX_FILE" --no-log \
  >/dev/null 2>&1 || exit_code23=$?

if [[ $exit_code23 -ne 0 ]]; then
  fail "detail-plan --context: script exited with $exit_code23"
elif grep -q "INTENT_MARKER_ABCDEF" "$CAPTURE23" && \
     grep -q "OUTLINE_MARKER_GHIJKL" "$CAPTURE23" && \
     grep -q "\[CONTEXT START\]" "$CAPTURE23" && \
     grep -q "\[CONTEXT END\]" "$CAPTURE23"; then
  pass "detail-plan --context: intent+outline markers and [CONTEXT START]/[CONTEXT END] present in prompt"
else
  fail "detail-plan --context: expected markers not found. Captured: $(cat "$CAPTURE23" 2>/dev/null | head -20)"
fi

# ---------------------------------------------------------------------------
# 24. outline-plan --context: context marker appears in prompt (NEW wiring)
# ---------------------------------------------------------------------------
CTX_FILE2="$TMPDIR_BASE/ctx-outline.md"
printf 'OUTLINE_CTX_MARKER_XYZ\n' > "$CTX_FILE2"

CAPTURE24="$TMPDIR_BASE/captured-24.txt"
sed "s|CAPTURE_PLACEHOLDER|$CAPTURE24|" > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
cat > "CAPTURE_PLACEHOLDER"
echo "APPROVED directionally sound"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

exit_code24=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format outline-plan --context "$CTX_FILE2" --no-log \
  >/dev/null 2>&1 || exit_code24=$?

if [[ $exit_code24 -ne 0 ]]; then
  fail "outline-plan --context: script exited with $exit_code24"
elif grep -q "OUTLINE_CTX_MARKER_XYZ" "$CAPTURE24" && \
     grep -q "\[CONTEXT START\]" "$CAPTURE24"; then
  pass "outline-plan --context: context marker and [CONTEXT START] present in prompt (new wiring)"
else
  fail "outline-plan --context: expected markers not found. Captured: $(cat "$CAPTURE24" 2>/dev/null | head -20)"
fi

# ---------------------------------------------------------------------------
# 25. outline-plan without --context: [CONTEXT START] must NOT appear
# ---------------------------------------------------------------------------
CAPTURE25="$TMPDIR_BASE/captured-25.txt"
sed "s|CAPTURE_PLACEHOLDER|$CAPTURE25|" > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
cat > "CAPTURE_PLACEHOLDER"
echo "APPROVED directionally sound"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

exit_code25=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format outline-plan --no-log \
  >/dev/null 2>&1 || exit_code25=$?

if [[ $exit_code25 -ne 0 ]]; then
  fail "outline-plan no --context: script exited with $exit_code25"
elif ! grep -q "\[CONTEXT START\]" "$CAPTURE25"; then
  pass "outline-plan no --context: [CONTEXT START] correctly absent from prompt"
else
  fail "outline-plan no --context: [CONTEXT START] unexpectedly present in prompt"
fi

# ---------------------------------------------------------------------------
# 26. detail-plan with empty --context file: [CONTEXT START] must NOT appear
# ---------------------------------------------------------------------------
CTX_EMPTY="$TMPDIR_BASE/ctx-empty.md"
touch "$CTX_EMPTY"

CAPTURE26="$TMPDIR_BASE/captured-26.txt"
sed "s|CAPTURE_PLACEHOLDER|$CAPTURE26|" > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
cat > "CAPTURE_PLACEHOLDER"
echo "APPROVED"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

exit_code26=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan --context "$CTX_EMPTY" --no-log \
  >/dev/null 2>&1 || exit_code26=$?

if [[ $exit_code26 -ne 0 ]]; then
  fail "detail-plan empty --context: script exited with $exit_code26"
elif ! grep -q "\[CONTEXT START\]" "$CAPTURE26"; then
  pass "detail-plan empty --context: [CONTEXT START] correctly absent (empty file guard)"
else
  fail "detail-plan empty --context: [CONTEXT START] unexpectedly present despite empty context file"
fi


# ---------------------------------------------------------------------------
# 30. detail-plan multiple --context: both context bodies concatenated in single block
# ---------------------------------------------------------------------------
CTX_FILE_A="$TMPDIR_BASE/ctx-multi-a.md"
CTX_FILE_B="$TMPDIR_BASE/ctx-multi-b.md"
printf 'MULTI_CTX_MARKER_AAAA\n' > "$CTX_FILE_A"
printf 'MULTI_CTX_MARKER_BBBB\n' > "$CTX_FILE_B"

CAPTURE30="$TMPDIR_BASE/captured-30.txt"
sed "s|CAPTURE_PLACEHOLDER|$CAPTURE30|" > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
cat > "CAPTURE_PLACEHOLDER"
echo "APPROVED"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

exit_code30=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan \
  --context "$CTX_FILE_A" --context "$CTX_FILE_B" --no-log \
  >/dev/null 2>&1 || exit_code30=$?

context_start_count30=0
if [[ -f "$CAPTURE30" ]]; then
  context_start_count30=$(grep -cE '^\[CONTEXT START\]$' "$CAPTURE30" || true)
fi

if [[ $exit_code30 -ne 0 ]]; then
  fail "detail-plan multiple --context: script exited with $exit_code30"
elif grep -q "MULTI_CTX_MARKER_AAAA" "$CAPTURE30" && \
     grep -q "MULTI_CTX_MARKER_BBBB" "$CAPTURE30" && \
     [[ $context_start_count30 -eq 1 ]]; then
  pass "detail-plan multiple --context: both bodies present, single [CONTEXT START] block"
else
  fail "detail-plan multiple --context: expected both markers + single block. start_count=$context_start_count30. Captured: $(cat "$CAPTURE30" 2>/dev/null | head -30)"
fi

