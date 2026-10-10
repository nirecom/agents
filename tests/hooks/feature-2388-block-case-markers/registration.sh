# Registration (G1-G5) and JS/bash entrypoint-predicate parity (#2388).
# Sourced by tests/hooks/feature-2388-block-case-markers.sh; shares its helpers.
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

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
assert_eq "$(f_of "$MINE" 5)" "node \"\$AGENTS_MAIN_ROOT/hooks/block-case-markers.js\""
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
# $AGENTS_MAIN_ROOT expanded to this worktree; exit 0 + protocol JSON.
CMD="$(f_of "$MINE" 5)"
AGENTS_M="$(np "$SCRIPT_CHECKOUT_ROOT")"
CMD="${CMD//\$AGENTS_MAIN_ROOT/$AGENTS_M}"
E2E_OUT="$TMPBASE/e2e.out"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/e2e-missing.sh" "content=@$BODIES/missing.sh"
E2E_RC=0
(cd "$NEUTRAL_CWD" || exit 99; run_with_timeout 10 env "${HK_ENV_RESET[@]}" "AGENTS_MAIN_ROOT=$CFG_DIR_M" bash -c "$CMD" < "$PAYLOAD_FILE" > "$E2E_OUT" 2>/dev/null) || E2E_RC=$?
assert_eq "$E2E_RC" "0"
HK_OUT="$(cat "$E2E_OUT")"
HK_REASON="$(node "$REASON_JS_M" "$(np "$E2E_OUT")")"
assert_reason_has "registered-command-runs block half" "[block-case-markers]"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/e2e-ok.sh" "content=@$BODIES/conforming.sh"
E2E_RC=0
(cd "$NEUTRAL_CWD" || exit 99; run_with_timeout 10 env "${HK_ENV_RESET[@]}" "AGENTS_MAIN_ROOT=$CFG_DIR_M" bash -c "$CMD" < "$PAYLOAD_FILE" > "$E2E_OUT" 2>/dev/null) || E2E_RC=$?
assert_eq "$E2E_RC" "0"
E2E_SQ="$(tr -d '[:space:]' < "$E2E_OUT")"
assert_eq "${E2E_SQ#*\"decision\":}" "\"approve\"}"
case_end

echo ""
echo "=== parity: isCaseMarkerTarget vs _precommit_is_case_marker_target ==="

# The verdict is derived, not written per row: placement class (restated in
# parity_placement) x the registry reader's match (supported + caseMarkerReader).
# Both shipped predicates must equal it; the row's literal pins today's table.
PARITY_JS="$TMPBASE/parity.js"
cat > "$PARITY_JS" <<'PARITYJS'
// argv: <hook|registry> <list-file>. Prints "<rel>|<1|0>" per listed rel.
const fs = require("fs");
const mode = process.argv[2];
const rels = fs.readFileSync(process.argv[3], "utf8").split("\n").filter(Boolean);
let m;
try {
  m = require(mode === "hook" ? process.env.PARITY_HOOK : process.env.PARITY_REGISTRY);
} catch (e) {
  console.log("MODULE_MISSING");
  process.exit(3);
}
const fn = mode === "hook" ? m.isCaseMarkerTarget : m.matchBasename;
if (typeof fn !== "function") {
  console.log("NO_EXPORT");
  process.exit(4);
}
for (const rel of rels) {
  let v;
  if (mode === "hook") {
    v = fn(rel);
  } else {
    const r = fn(rel.split("/").pop());
    v = Boolean(r && r.status === "supported" && r.entry && r.entry.caseMarkerReader);
  }
  console.log(rel + "|" + (v ? 1 : 0));
}
PARITYJS

# parity_placement <rel> — sets _PL: eligible | excluded | unknown | outside.
# Fork-free (it runs once per tracked path); no language knowledge lives here.
parity_placement() {
  case "$1" in
    tests/_archive/*|tests/lib/*|tests/run-all.sh) _PL=excluded ;;
    tests/hooks/*/*|tests/bin/*/*|tests/skills/*/*|tests/agents/*/*|tests/install/*/*|tests/tests/*/*) _PL=excluded ;;
    tests/hooks/*|tests/bin/*|tests/skills/*|tests/agents/*|tests/install/*|tests/tests/*) _PL=eligible ;;
    tests/*/*) _PL=unknown ;;
    tests/*) _PL=eligible ;;
    *) _PL=outside ;;
  esac
}

# rel|today's verdict — the six category roots, flat tests/<name>, and names the
# registry places in a language without a case-marker reader (or in none at all).
PARITY_ROWS=(
  "tests/hooks/a.sh|1" "tests/bin/a.sh|1" "tests/skills/a.sh|1"
  "tests/agents/a.sh|1" "tests/install/a.sh|1" "tests/tests/a.sh|1"
  "tests/flat.sh|1" "tests/hooks/suite/sub.sh|0" "tests/run-all.sh|0"
  "tests/_archive/x.sh|0" "tests/lib/harness.sh|0" "tests/unknowncat/a.sh|0"
  "tests/hooks/x.Tests.ps1|0" "bin/a.sh|0"
  "tests/hooks/test_a.py|0" "tests/hooks/a.js|0" "tests/hooks/a.test.js|0"
  "tests/hooks/.sh|0" "tests/flat.Tests.ps1|0" "tests/hooks/test_a.sh|1"
)

# parity_run <hook|registry> <list-file> — the Node side's "<rel>|<0|1>" lines.
parity_run() {
  run_with_timeout 60 node "$(np "$PARITY_JS")" "$1" "$(np "$2")" 2>&1
}
# parity_bash <rel> — sets _PB: 1 when _precommit_is_case_marker_target returns 0.
parity_bash() {
  _PB=127
  [ "$BASH_OK" -eq 1 ] || return 0
  if _precommit_is_case_marker_target "$1"; then _PB=1; else _PB=0; fi
}

PARITY_HOOK="$(np "$HOOK")"
PARITY_REGISTRY="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.js")"
export PARITY_HOOK PARITY_REGISTRY
BASH_OK=0
if [ -f "$PRECOMMIT_LIB" ]; then
  # shellcheck source=../../../hooks/lib/precommit-tests-frontmatter.sh
  . "$PRECOMMIT_LIB"
  declare -F _precommit_is_case_marker_target >/dev/null 2>&1 && BASH_OK=1
fi
_cfg_dir="$SCRIPT_CHECKOUT_ROOT"

case_begin "entrypoint-predicate-parity" "hooks/lib/precommit-tests-frontmatter.sh"
PARITY_LIST="$TMPBASE/parity-rows.txt"
: > "$PARITY_LIST"
for _row in "${PARITY_ROWS[@]}"; do
  printf '%s\n' "${_row%|*}" >> "$PARITY_LIST"
done
JS_OUT="$(parity_run hook "$PARITY_LIST")"
REG_OUT="$(parity_run registry "$PARITY_LIST")"
for _row in "${PARITY_ROWS[@]}"; do
  _rel="${_row%|*}"
  _pin="${_row##*|}"
  _reg="$(printf '%s\n' "$REG_OUT" | grep -F -x -e "$_rel|1" -e "$_rel|0" | head -n 1)"
  _reg="${_reg##*|}"
  _want=0
  parity_placement "$_rel"
  [ "$_PL" = eligible ] && [ "$_reg" = 1 ] && _want=1
  _js="$(printf '%s\n' "$JS_OUT" | grep -F -x -e "$_rel|1" -e "$_rel|0" | head -n 1)"
  _js="${_js##*|}"
  parity_bash "$_rel"
  _sh="$_PB"
  if [ -n "$_reg" ] && [ "$_want" = "$_pin" ] && [ "$_js" = "$_want" ] && [ "$_sh" = "$_want" ]; then
    pass "parity $_rel -> $_want"
  else
    fail "parity $_rel" "pin=$_pin derived=$_want registry=${_reg:-none} js=${_js:-none} bash=$_sh js_out=$JS_OUT reg_out=$REG_OUT"
  fi
done
case_end

case_begin "entrypoint-predicate-parity-tracked-tests" "hooks/block-case-markers.js"
# Every tracked tests/ path: Node and bash agree with each other and the derivation.
PARITY_ALL="$TMPBASE/parity-all.txt"
git -C "$SCRIPT_CHECKOUT_ROOT" ls-files tests > "$PARITY_ALL" 2>/dev/null
ALL_JS="$(parity_run hook "$PARITY_ALL")"
ALL_REG="$(parity_run registry "$PARITY_ALL")"
_derived=""
_bash=""
while IFS='|' read -r _rel _r; do
  _w=0
  parity_placement "$_rel"
  [ "$_PL" = eligible ] && [ "$_r" = 1 ] && _w=1
  _derived="${_derived}${_rel}|${_w}
"
  parity_bash "$_rel"
  _bash="${_bash}${_rel}|${_PB}
"
done <<< "$ALL_REG"
_n_all="$(grep -c . "$PARITY_ALL")"
_n_reg="$(printf '%s' "$_derived" | grep -c .)"
if [ "$_n_all" -gt 0 ] && [ "$_n_reg" = "$_n_all" ]; then
  pass "tracked-tests: registry verdict for all $_n_all paths"
else
  fail "tracked-tests-count" "listed=$_n_all derived=$_n_reg head=$(printf '%s' "$ALL_REG" | head -n 3)"
fi
# parity_same <name> <got> — whole-list equality with the derivation; shows first diffs.
parity_same() {
  if [ "$2" = "${_derived%$'\n'}" ]; then
    pass "tracked-tests: $1 equals placement x registry"
  else
    fail "tracked-tests: $1" "$(diff <(printf '%s\n' "${_derived%$'\n'}") <(printf '%s\n' "$2") | head -n 8)"
  fi
}
parity_same "isCaseMarkerTarget" "$ALL_JS"
parity_same "_precommit_is_case_marker_target" "${_bash%$'\n'}"
case_end
