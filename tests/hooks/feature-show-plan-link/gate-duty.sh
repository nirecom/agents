# #2729 stage 2: the after-write plan-link duty follows each stage's gate (G1-G7).
# Sourced by ../feature-show-plan-link.sh — inherits PLANS_DIR, HOOK, run_with_timeout, pass/fail
# and the confirm-env-fixture helpers. The plan-stage CONFIRM keys are read from
# $AGENTS_MAIN_ROOT/.env only, so each case writes its own .env (export / .env.local are ignored).
# Wording regexes match tests/hooks/feature-2650-plan-link-turn-scope.js (END_OF_TURN_RE etc.).

GD_END_OF_TURN="End this turn's last text block"
GD_SUMMARY_RE='[Ss][Uu][Mm][Mm][Aa][Rr][Yy]'
GD_SEQ=0

# gd_ctx <json> [KEY=VAL ...] — additionalContext of one hook run against a fresh .env.
# GD_EXPORT (KEY=VAL) and GD_LOCAL (KEY=VAL) additionally set an export / a .env.local entry.
gd_ctx() {
  local json="$1" dir
  shift
  GD_SEQ=$((GD_SEQ + 1))
  dir="$_ISOLATION_TMP_ROOT/gd-cfg-$GD_SEQ"
  (
    confirm_env_root "$dir" "$@"
    [ -n "${GD_LOCAL:-}" ] && confirm_env_local "$dir" "$GD_LOCAL"
    [ -n "${GD_EXPORT:-}" ] && export "${GD_EXPORT?}"
    printf '%s' "$json" | run_with_timeout node "$HOOK" 2>/dev/null
  ) | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch (e) { process.exit(0); }
    process.stdout.write(String((d.hookSpecificOutput || {}).additionalContext || ''));
  " 2>/dev/null
}

# gd_after_entry <ctx> <stage> — the line right after the "<stage>: " entry line.
gd_after_entry() {
  printf '%s' "$1" | run_with_timeout node -e "
    const lines = require('fs').readFileSync(0,'utf8').split('\n');
    const i = lines.findIndex((l) => l.startsWith(process.argv[1] + ': '));
    process.stdout.write(i >= 0 && i + 1 < lines.length ? lines[i + 1] : '');
  " "$2" 2>/dev/null
}

gd_write_json() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"tool_response":{"success":true}}' "$1"
}

# gd_expect <desc> <ctx> <on|off> — ON: end-of-turn duty, no summary wording; OFF: the reverse.
gd_expect() {
  local desc="$1" ctx="$2" want="$3" has_end=no has_sum=no
  [[ "$ctx" == *"$GD_END_OF_TURN"* ]] && has_end=yes
  printf '%s' "$ctx" | grep -qE "$GD_SUMMARY_RE" && has_sum=yes
  if [ -z "$ctx" ]; then
    fail "$desc — no additionalContext"
  elif [ "$want" = on ] && [ "$has_end" = yes ] && [ "$has_sum" = no ]; then
    pass "$desc"
  elif [ "$want" = off ] && [ "$has_end" = no ] && [ "$has_sum" = yes ]; then
    pass "$desc"
  else
    fail "$desc — want $want, end-of-turn=$has_end summary=$has_sum — ctx=$(printf '%q' "$ctx")"
  fi
}

echo "=== G1: .env CONFIRM_DETAIL=off -> summary-once duty, no end-of-turn duty ==="
gd_expect "G1 .env OFF -> OFF wording" \
  "$(gd_ctx "$(gd_write_json "$PLANS_DIR/gd-detail.md")" CONFIRM_DETAIL=off)" off

echo "=== G2: .env CONFIRM_DETAIL=on -> end-of-turn duty ==="
gd_expect "G2 .env ON -> ON wording" \
  "$(gd_ctx "$(gd_write_json "$PLANS_DIR/gd-detail.md")" CONFIRM_DETAIL=on)" on

echo "=== G3: .env on + export CONFIRM_DETAIL=off -> the export is ignored (ON wording) ==="
gd_expect "G3 export off over .env on -> ON wording" \
  "$(GD_EXPORT=CONFIRM_DETAIL=off gd_ctx "$(gd_write_json "$PLANS_DIR/gd-detail.md")" CONFIRM_DETAIL=on)" on

echo "=== G4: .env on + .env.local CONFIRM_DETAIL=off -> .env.local is ignored (ON wording) ==="
gd_expect "G4 .env.local off over .env on -> ON wording" \
  "$(GD_LOCAL=CONFIRM_DETAIL=off gd_ctx "$(gd_write_json "$PLANS_DIR/gd-detail.md")" CONFIRM_DETAIL=on)" on

echo "=== G5: .env CONFIRM_INTENT=off -> intent is never OFF (ON wording) ==="
gd_expect "G5 intent off -> ON wording" \
  "$(gd_ctx "$(gd_write_json "$PLANS_DIR/gd-intent.md")" CONFIRM_INTENT=off)" on

echo "=== G6: .env CONFIRM_OUTLINE=off -> OFF wording for an outline write ==="
gd_expect "G6 outline .env OFF -> OFF wording" \
  "$(gd_ctx "$(gd_write_json "$PLANS_DIR/gd-outline.md")" CONFIRM_OUTLINE=off)" off

echo "=== G7: one call writes outline (OFF) and detail (ON) -> the duty splits per stage ==="
GD_MIX_JSON="$(run_with_timeout node -e '
const d = process.argv[1];
process.stdout.write(JSON.stringify({ tool_name: "editFiles", tool_response: { success: true },
  tool_input: { edits: [{ path: d + "/gdmix-outline.md" }, { path: d + "/gdmix-detail.md" }] } }));' "$PLANS_DIR")"
GD_MIX_CTX="$(gd_ctx "$GD_MIX_JSON" CONFIRM_OUTLINE=off CONFIRM_DETAIL=on)"
GD_MIX_OUT="$(gd_after_entry "$GD_MIX_CTX" outline)"
GD_MIX_DET="$(gd_after_entry "$GD_MIX_CTX" detail)"
if printf '%s' "$GD_MIX_OUT" | grep -qE "$GD_SUMMARY_RE" && [[ "$GD_MIX_OUT" != *"$GD_END_OF_TURN"* ]]; then
  pass "G7 outline (OFF) entry is followed by the summary-once duty"
else
  fail "G7 outline (OFF) entry is followed by the summary-once duty — next=$(printf '%q' "$GD_MIX_OUT") ctx=$(printf '%q' "$GD_MIX_CTX")"
fi
if [[ "$GD_MIX_DET" == *"last text block"* ]]; then
  pass "G7 detail (ON) entry is followed by the end-of-turn duty"
else
  fail "G7 detail (ON) entry is followed by the end-of-turn duty — next=$(printf '%q' "$GD_MIX_DET") ctx=$(printf '%q' "$GD_MIX_CTX")"
fi
