# Edit time, tests already in HEAD: every tracked PowerShell, Python and JavaScript test of
# this checkout, one run of the registered hook command per file (#2411). Sourced by
# tests/hooks/feature-2411-gate-integration.sh after edit.sh, whose RUN_CMD it runs.
# shellcheck shell=bash

echo ""
echo "=== existing: every tracked non-bash test through the registered hook command ==="

REGISTRY_JSON="$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json"
EXIST_LANGS=(pester pytest js)

EXIST_JS="$TMPBASE/existing.js"
cat > "$EXIST_JS" <<'EXISTJS'
// patterns <registry> <id>...: "<id>|<name pattern>" per pattern of the named entries.
// payloads <dir> <repo> <rel>...: <dir>/<n>.json, a Write of the file's own content.
// decisions <dir> <repo> <rel>...: the decision in <dir>/<n>.out, one per line.
const fs = require("fs");
const path = require("path");
const [, , mode, a, b, ...rest] = process.argv;
if (mode === "patterns") {
  const ids = [b, ...rest];
  for (const e of JSON.parse(fs.readFileSync(a, "utf8")).entries) {
    if (ids.includes(e.id)) for (const p of e.patterns) console.log(e.id + "|" + p);
  }
} else {
  rest.forEach((rel, i) => {
    if (mode === "payloads") {
      const content = fs.readFileSync(path.join(b, rel), "utf8");
      const payload = { tool_name: "Write", cwd: b, tool_input: { file_path: b + "/" + rel, content } };
      fs.writeFileSync(path.join(a, i + ".json"), JSON.stringify(payload));
      return;
    }
    let o = {};
    try { o = JSON.parse(fs.readFileSync(path.join(a, i + ".out"), "utf8")); } catch (e) { o = {}; }
    console.log(String(o.decision || "none"));
  });
}
EXISTJS
EXIST_JS_M="$(np "$EXIST_JS")"

# The name patterns come from the registry entries of the three languages, never from a
# list or a count written here.
EXIST_PAT_IDS=()
EXIST_PATS=()
EXIST_SPECS=()
while IFS='|' read -r _id _pat; do
  [ -n "$_pat" ] || continue
  EXIST_PAT_IDS+=("$_id")
  EXIST_PATS+=("$_pat")
  EXIST_SPECS+=("tests/*/$_pat")
done < <(node "$EXIST_JS_M" patterns "$(np "$REGISTRY_JSON")" "${EXIST_LANGS[@]}" | tr -d '\r')

REPO_EXIST="$TMPBASE/repo-existing"
cp -R "$TEMPLATE" "$REPO_EXIST"
EXIST_RELS=()
while IFS= read -r _rel; do
  case "$_rel" in
    tests/hooks/*/*|tests/bin/*/*|tests/skills/*/*|tests/agents/*/*|tests/install/*/*|tests/tests/*/*) continue ;;
    tests/hooks/*|tests/bin/*|tests/skills/*|tests/agents/*|tests/install/*|tests/tests/*) ;;
    *) continue ;;
  esac
  [ -d "$REPO_EXIST/${_rel%/*}" ] || mkdir -p "$REPO_EXIST/${_rel%/*}"
  cp "$SCRIPT_CHECKOUT_ROOT/$_rel" "$REPO_EXIST/$_rel"
  EXIST_RELS+=("$_rel")
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- "${EXIST_SPECS[@]:-tests/no-pattern-in-registry}" 2>/dev/null)
git -C "$REPO_EXIST" add -A >/dev/null 2>&1
git -C "$REPO_EXIST" commit -q -m "existing tests" >/dev/null 2>&1

EXIST_DIR="$TMPBASE/existing-edits"
mkdir -p "$EXIST_DIR"
EXIST_DECISIONS=()
EXIST_RCS=()
if [ "${#EXIST_RELS[@]}" -gt 0 ] && [ -n "$REG_CMD" ]; then
  _repo_m="$(np "$REPO_EXIST")"
  _root_m="$(np "$EMPTY_ROOT")"
  node "$EXIST_JS_M" payloads "$(np "$EXIST_DIR")" "$_repo_m" "${EXIST_RELS[@]}"
  for _i in "${!EXIST_RELS[@]}"; do
    _rc=0
    (
      cd "$NEUTRAL_CWD" || exit 99
      run_with_timeout 60 env "AGENTS_MAIN_ROOT=$_root_m" bash -c "$RUN_CMD" < "$EXIST_DIR/$_i.json"
    ) > "$EXIST_DIR/$_i.out" 2> "$EXIST_DIR/$_i.err" || _rc=$?
    EXIST_RCS+=("$_rc")
  done
  while IFS= read -r _d; do
    EXIST_DECISIONS+=("$_d")
  done < <(node "$EXIST_JS_M" decisions "$(np "$EXIST_DIR")" "$_repo_m" "${EXIST_RELS[@]}" | tr -d '\r')
fi

case_begin "existing-tests-list-comes-from-the-registry" "hooks/lib/test-language-registry.json"
assert_eq "languages with a name pattern=$(printf '%s\n' ${EXIST_PAT_IDS[@]+"${EXIST_PAT_IDS[@]}"} | sort -u | paste -sd, -)" \
  "languages with a name pattern=$(printf '%s\n' "${EXIST_LANGS[@]}" | sort -u | paste -sd, -)"
for _i in "${!EXIST_PATS[@]}"; do
  _n=0
  for _rel in ${EXIST_RELS[@]+"${EXIST_RELS[@]}"}; do
    # shellcheck disable=SC2254
    case "${_rel##*/}" in ${EXIST_PATS[$_i]}) _n=$((_n + 1)) ;; esac
  done
  if [ "$_n" -ge 1 ]; then
    pass "${EXIST_PAT_IDS[$_i]} ${EXIST_PATS[$_i]}: $_n existing test(s) listed"
  else
    fail "${EXIST_PAT_IDS[$_i]} ${EXIST_PATS[$_i]}" "no existing test listed"
  fi
done
_n=0
while IFS= read -r _rel; do
  [ -n "$_rel" ] || continue
  _n=$((_n + 1))
  case $'\n'"$(printf '%s\n' ${EXIST_RELS[@]+"${EXIST_RELS[@]}"})"$'\n' in
    *$'\n'"$_rel"$'\n'*) pass "$_rel is in the list" ;;
    *) fail "$_rel" "missing from the list of existing tests" ;;
  esac
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- 'tests/hooks/feature-2326-*.js' 2>/dev/null | grep -v '^tests/hooks/[^/]*/')
if [ "$_n" -ge 1 ]; then
  pass "tests/hooks/feature-2326-*.js tracked ($_n)"
else
  fail "tests/hooks/feature-2326-*.js" "none tracked in this checkout"
fi
case_end

case_begin "existing-tests-edit-time-approves-each-one" "hooks/block-case-markers.js"
if [ "${#EXIST_RELS[@]}" -ge 1 ]; then
  pass "existing non-bash tests listed (${#EXIST_RELS[@]})"
else
  fail "existing non-bash tests listed" "none"
fi
assert_eq "decisions read=${#EXIST_DECISIONS[@]}" "decisions read=${#EXIST_RELS[@]}"
assert_eq "exit statuses read=${#EXIST_RCS[@]}" "exit statuses read=${#EXIST_RELS[@]}"
for _i in "${!EXIST_RELS[@]}"; do
  assert_eq "${EXIST_RELS[$_i]} -> ${EXIST_DECISIONS[$_i]:-none}" "${EXIST_RELS[$_i]} -> approve"
  assert_eq "${EXIST_RELS[$_i]} rc=${EXIST_RCS[$_i]:-unset}" "${EXIST_RELS[$_i]} rc=0"
done
case_end

# The marker gate's commit-time half stays in tests/bin/feature-2411-gate-three-languages.sh,
# on the gate function alone: a real commit of these files stops earlier, at the header rules
# some of them predate. The helper load rule is checked here, on an edit to every one.
case_begin "existing-tests-are-not-asked-for-a-helper-load" "bin/check-test-frontmatter.sh"
for _rel in ${EXIST_RELS[@]+"${EXIST_RELS[@]}"}; do
  printf '\n' >> "$REPO_EXIST/$_rel"
done
git -C "$REPO_EXIST" add -A >/dev/null 2>&1
assert_eq "staged edits=$(git -C "$REPO_EXIST" diff --cached --name-only | grep -c .)" "staged edits=${#EXIST_RELS[@]}"
_fm_rc=0
(
  cd "$REPO_EXIST" || exit 99
  run_with_timeout 90 bash "$SCRIPT_CHECKOUT_ROOT/bin/check-test-frontmatter.sh" --staged ${EXIST_RELS[@]+"${EXIST_RELS[@]}"}
) > "$TMPBASE/exist-fm.out" 2> "$TMPBASE/exist-fm.err" || _fm_rc=$?
# rc 1 is allowed: some tracked tests predate the header rules and are reported for those.
case "$_fm_rc" in
  0|1) pass "existing ${#EXIST_RELS[@]} tests: the check ran (rc=$_fm_rc)" ;;
  *) fail "existing tests: the check ran" "rc=$_fm_rc err=$(tr '\n' ' ' < "$TMPBASE/exist-fm.err" | cut -c 1-400)" ;;
esac
if grep -qF "MISSING_HARNESS_SOURCE: " "$TMPBASE/exist-fm.err" "$TMPBASE/exist-fm.out"; then
  fail "existing tests" "asked for a helper load: $(grep -hF "MISSING_HARNESS_SOURCE: " "$TMPBASE/exist-fm.err" "$TMPBASE/exist-fm.out" | head -n 3 | tr '\n' ' ')"
else
  pass "existing tests: none is asked for a helper load"
fi
case_end
