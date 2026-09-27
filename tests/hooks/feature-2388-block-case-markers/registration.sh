# Registration (G1-G5) and JS/bash entrypoint-predicate parity (#2388).
# Sourced by tests/hooks/feature-2388-block-case-markers.sh; shares its helpers.
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

echo ""
echo "=== registration ==="

REG_JS="$TMPBASE/reg.js"
cat > "$REG_JS" <<'REGJS'
// One tab-separated line per PreToolUse hook whose command mentions argv[3]:
//   <index> <matcher> <timeout> <type> <command>
const s = require(process.argv[2]);
const name = process.argv[3];
const list = (s.hooks && s.hooks.PreToolUse) || [];
list.forEach((entry, i) => {
  for (const h of entry.hooks || []) {
    if (typeof h.command === "string" && h.command.includes(name)) {
      const t = h.timeout === undefined ? "" : h.timeout;
      process.stdout.write([i, entry.matcher || "", t, h.type || "", h.command].join("\t") + "\n");
    }
  }
});
REGJS
REG_JS_M="$(np "$REG_JS")"
SETTINGS_M="$(np "$SETTINGS_JSON")"
reg_lookup() {
  node "$REG_JS_M" "$SETTINGS_M" "$1" 2>/dev/null
}
MINE="$(reg_lookup hooks/block-case-markers.js)"
SIB="$(reg_lookup hooks/gate-worktree-notes-lang.js)"
MINE_N="$(printf '%s' "$MINE" | grep -c .)"
f_of() {
  printf '%s' "$1" | head -n 1 | cut -f "$2"
}

case_begin "registered-once" "settings.json"
assert_eq "$MINE_N" "1"
case_end

case_begin "matcher-equals-sibling" "settings.json"
# Same tool class as gate-worktree-notes-lang, and placed right after it.
assert_eq "$(f_of "$MINE" 2)" "$(f_of "$SIB" 2)"
assert_eq "$(f_of "$MINE" 2)" "Write|Edit|MultiEdit|editFiles"
SIB_IDX="$(f_of "$SIB" 1)"
assert_eq "$(f_of "$MINE" 1)" "$((SIB_IDX + 1))"
case_end

case_begin "invocation-shape-and-timeout" "settings.json"
assert_eq "$(f_of "$MINE" 4)" "command"
assert_eq "$(f_of "$MINE" 5)" "node \"\$AGENTS_CONFIG_DIR/hooks/block-case-markers.js\""
TO="$(f_of "$MINE" 3)"
if [ -n "$TO" ] && [ "$TO" -le 10 ] 2>/dev/null; then
  pass "timeout-bounded: $TO"
else
  fail "timeout-bounded" "timeout=${TO:-unset}; expected <= 10"
fi
case_end

case_begin "hook-parses-with-main-guard" "hooks/block-case-markers.js"
if [ -f "$HOOK" ] && node --check "$(np "$HOOK")" >/dev/null 2>&1; then
  pass "node --check hooks/block-case-markers.js"
else
  fail "node-check" "hooks/block-case-markers.js missing or not valid Node"
fi
if grep -q 'require.main' "$HOOK" 2>/dev/null; then
  pass "require.main guard present"
else
  fail "require-main-guard" "no require.main guard in hooks/block-case-markers.js"
fi
case_end

case_begin "registered-command-runs" "settings.json"
# Run the settings.json command string verbatim through bash -c, with only
# $AGENTS_CONFIG_DIR expanded to this worktree; exit 0 + protocol JSON.
CMD="$(f_of "$MINE" 5)"
AGENTS_M="$(np "$AGENTS_DIR")"
CMD="${CMD//\$AGENTS_CONFIG_DIR/$AGENTS_M}"
E2E_OUT="$TMPBASE/e2e.out"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/e2e-missing.sh" "content=@$BODIES/missing.sh"
E2E_RC=0
(cd "$NEUTRAL_CWD" || exit 99; run_with_timeout 10 env "${HK_ENV_RESET[@]}" "AGENTS_CONFIG_DIR=$CFG_DIR_M" bash -c "$CMD" < "$PAYLOAD_FILE" > "$E2E_OUT" 2>/dev/null) || E2E_RC=$?
assert_eq "$E2E_RC" "0"
HK_OUT="$(cat "$E2E_OUT")"
HK_REASON="$(node "$REASON_JS_M" "$(np "$E2E_OUT")")"
assert_reason_has "registered-command-runs block half" "[block-case-markers]"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/e2e-ok.sh" "content=@$BODIES/conforming.sh"
E2E_RC=0
(cd "$NEUTRAL_CWD" || exit 99; run_with_timeout 10 env "${HK_ENV_RESET[@]}" "AGENTS_CONFIG_DIR=$CFG_DIR_M" bash -c "$CMD" < "$PAYLOAD_FILE" > "$E2E_OUT" 2>/dev/null) || E2E_RC=$?
assert_eq "$E2E_RC" "0"
E2E_SQ="$(tr -d '[:space:]' < "$E2E_OUT")"
assert_eq "${E2E_SQ#*\"decision\":}" "\"approve\"}"
case_end

echo ""
echo "=== parity: isCaseMarkerTarget vs _precommit_is_sh_test_entrypoint ==="

PARITY_JS="$TMPBASE/parity.js"
cat > "$PARITY_JS" <<'PARITYJS'
// Prints "<rel>|<1|0>" per argv rel, from the hook's exported predicate.
let m;
try {
  m = require(process.env.PARITY_HOOK);
} catch (e) {
  console.log("MODULE_MISSING");
  process.exit(3);
}
if (typeof m.isCaseMarkerTarget !== "function") {
  console.log("NO_EXPORT");
  process.exit(4);
}
for (const rel of process.argv.slice(2)) console.log(rel + "|" + (m.isCaseMarkerTarget(rel) ? 1 : 0));
PARITYJS

# rel|expected — targets are the six category roots and flat tests/<name>.sh.
PARITY_ROWS=(
  "tests/hooks/a.sh|1" "tests/bin/a.sh|1" "tests/skills/a.sh|1"
  "tests/agents/a.sh|1" "tests/install/a.sh|1" "tests/tests/a.sh|1"
  "tests/flat.sh|1" "tests/hooks/suite/sub.sh|0" "tests/run-all.sh|0"
  "tests/_archive/x.sh|0" "tests/lib/harness.sh|0" "tests/unknowncat/a.sh|0"
  "tests/hooks/x.Tests.ps1|0" "bin/a.sh|0"
)

case_begin "entrypoint-predicate-parity" "hooks/lib/precommit-tests-frontmatter.sh"
PARITY_RELS=()
for _row in "${PARITY_ROWS[@]}"; do
  PARITY_RELS+=("${_row%|*}")
done
PARITY_HOOK="$(np "$HOOK")"
export PARITY_HOOK
JS_OUT="$(run_with_timeout 30 node "$(np "$PARITY_JS")" "${PARITY_RELS[@]}" 2>&1)"
BASH_OK=0
if [ -f "$PRECOMMIT_LIB" ]; then
  # shellcheck source=../../../hooks/lib/precommit-tests-frontmatter.sh
  . "$PRECOMMIT_LIB"
  declare -F _precommit_is_sh_test_entrypoint >/dev/null 2>&1 && BASH_OK=1
fi
for _row in "${PARITY_ROWS[@]}"; do
  _rel="${_row%|*}"
  _want="${_row##*|}"
  _js="$(printf '%s\n' "$JS_OUT" | grep -F -x -- "$_rel|1" >/dev/null && echo 1)"
  if [ -z "$_js" ]; then
    _js="$(printf '%s\n' "$JS_OUT" | grep -F -x -- "$_rel|0" >/dev/null && echo 0)"
  fi
  _sh=127
  if [ "$BASH_OK" -eq 1 ]; then
    _sh=1
    _precommit_is_sh_test_entrypoint "$_rel" && _sh=0
    _sh=$((1 - _sh))
  fi
  if [ "$_js" = "$_want" ] && [ "$_sh" = "$_want" ]; then
    pass "parity $_rel -> $_want"
  else
    fail "parity $_rel" "want=$_want js=${_js:-none} bash=$_sh js_out=$JS_OUT"
  fi
done
case_end
