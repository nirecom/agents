# The edit-time hook and the commit-time gate on PowerShell, Python and JavaScript tests,
# the tests already in HEAD, and the agreement of the two target predicates (#2411).
# Sourced by tests/bin/feature-2411-gate-three-languages.sh.
# shellcheck shell=bash

echo ""
echo "=== gate: edit-time hook and commit-time gate, three languages ==="

REPO_EDIT="$TMPBASE/repo-edit"
mkrepo "$REPO_EDIT"

case_begin "gate-edit-time-blocks-missing-approves-conforming" "hooks/block-case-markers.js"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" missing
  hook_write "$REPO_EDIT" "tests/bin/$LF" "$_lang-missing"
  assert_eq "$_lang missing -> $HK_DECISION" "$_lang missing -> block"
  has "$_lang block text" "$HK_REASON" "tests/bin/$LF"
  has "$_lang block text" "$HK_REASON" "code=MISSING_CASE_MARKERS"
  lacks "$_lang block text" "$HK_REASON" "case_begin"
  lacks "$_lang block text" "$HK_REASON" "harness.sh"
  lacks "$_lang block text" "$HK_REASON" "$PIN_DOC."
  lang_set "$_lang" conforming
  hook_write "$REPO_EDIT" "tests/bin/$LF" "$_lang-conforming"
  assert_eq "$_lang conforming -> $HK_DECISION" "$_lang conforming -> approve"
done
case_end

case_begin "gate-edit-time-malformed-and-uncertain" "hooks/block-case-markers.js"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" malformed
  hook_write "$REPO_EDIT" "tests/bin/$LF" "$_lang-malformed"
  assert_eq "$_lang malformed -> $HK_DECISION" "$_lang malformed -> block"
  has "$_lang block text" "$HK_REASON" "($LREASON) code=MALFORMED_CASE_MARKER"
done
# Uncertain nesting is only a WARN for the case-marker check, but an uncertain new file whose
# header lists two Tests: tokens is not conforming, so #2502 S4-4b compares its code lines (0 -> 9) and blocks on that.
hook_write "$REPO_EDIT" tests/bin/uncertain.js js-uncertain
assert_eq "js uncertain -> $HK_DECISION" "js uncertain -> block"
has "js uncertain block text" "$HK_REASON" "(case count unavailable: no case unit; code lines 0 -> 9)"
has "js uncertain block text" "$HK_REASON" "code=CASE_ADDED_WITHOUT_MARKERS"
lacks "js uncertain block text" "$HK_REASON" "code=MALFORMED_CASE_MARKER"
lacks "js uncertain block text" "$HK_REASON" "code=MISSING_CASE_MARKERS"
case_end

case_begin "gate-commit-time-blocks-missing-passes-conforming" "hooks/pre-commit"
for _lang in "${LANGS[@]}"; do
  _repo="$TMPBASE/repo-commit-$_lang"
  mkrepo "$_repo"
  lang_set "$_lang" conforming
  stage "$_repo" "tests/bin/$LF" "$_lang-conforming"
  pc_run "$_repo"
  assert_eq "$_lang conforming rc=$PC_RC out=$PC_OUT" "$_lang conforming rc=0 out="
  lang_set "$_lang" missing
  stage "$_repo" "tests/bin/$LF" "$_lang-missing"
  pc_run "$_repo"
  assert_eq "$_lang missing rc=$PC_RC" "$_lang missing rc=1"
  has "$_lang commit text" "$PC_OUT" "HIGH: tests/bin/$LF "
  has "$_lang commit text" "$PC_OUT" "Commit blocked: new test file(s) fail the case-marker gate."
  lacks "$_lang commit text" "$PC_OUT" "case_begin"
  lacks "$_lang commit text" "$PC_OUT" "harness.sh"
done
case_end

# The well-formed counterpart passing this gate is the conforming half of the case above.
case_begin "gate-commit-time-blocks-malformed" "hooks/pre-commit"
for _lang in "${LANGS[@]}"; do
  _repo="$TMPBASE/repo-commit-malformed-$_lang"
  mkrepo "$_repo"
  lang_set "$_lang" malformed
  stage "$_repo" "tests/bin/$LF" "$_lang-malformed"
  pc_run "$_repo"
  assert_eq "$_lang malformed rc=$PC_RC" "$_lang malformed rc=1"
  has "$_lang commit text" "$PC_OUT" "HIGH: tests/bin/$LF "
  has "$_lang commit text" "$PC_OUT" "($LREASON) code=MALFORMED_CASE_MARKER"
  has "$_lang commit text" "$PC_OUT" "Commit blocked: new test file(s) fail the case-marker gate."
  has "$_lang commit text" "$PC_OUT" "Fix marker placement — see skills/_shared/test-design/case-markers/$_lang.md."
  lacks "$_lang commit text" "$PC_OUT" "code=MISSING_CASE_MARKERS"
done
case_end

case_begin "gate-commit-time-runtime-absent-passes" "hooks/pre-commit"
for _lang in pester pytest; do
  lang_set "$_lang" missing
  _repo="$TMPBASE/repo-commit-nort-$_lang"
  mkrepo "$_repo"
  stage "$_repo" "tests/bin/$LF" "$_lang-missing"
  PC_PATH="$(no_runtime_path "$LREQ")"
  if [ -z "$PC_PATH" ]; then
    fail "$_lang: PATH without $LREQ" "$(cat "$TMPBASE/shim-no-$LREQ.err")"
    continue
  fi
  pc_run "$_repo"
  PC_PATH=""
  assert_eq "$_lang rc=$PC_RC out=$PC_OUT" "$_lang rc=0 out="
  has "$_lang stderr" "$PC_ERR" "WARN: "
  has "$_lang stderr" "$PC_ERR" "tests/bin/$LF"
done
PC_PATH=""
case_end

# The tracked non-bash test entrypoints of this checkout, as files already in HEAD. The name
# patterns come from the registry entries of the three languages, never from a list here.
OLD_PATS_JS="$TMPBASE/old-pats.js"
cat > "$OLD_PATS_JS" <<'OLDPATSJS'
const t = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const ids = process.argv.slice(3);
for (const e of t.entries) {
  if (!ids.includes(e.id)) continue;
  for (const p of e.patterns) console.log(e.id + "|" + p);
}
OLDPATSJS
OLD_PAT_IDS=()
OLD_PATS=()
OLD_SPECS=()
while IFS='|' read -r _id _pat; do
  [ -n "$_pat" ] || continue
  OLD_PAT_IDS+=("$_id")
  OLD_PATS+=("$_pat")
  OLD_SPECS+=("tests/*/$_pat")
done < <(node "$(np "$OLD_PATS_JS")" "$(np "$TABLE")" "${LANGS[@]}" | tr -d '\r')

REPO_OLD="$TMPBASE/repo-existing"
mkrepo "$REPO_OLD"
OLD_RELS=()
while IFS= read -r _rel; do
  case "$_rel" in
    tests/hooks/*/*|tests/bin/*/*|tests/skills/*/*|tests/agents/*/*|tests/install/*/*|tests/tests/*/*) continue ;;
    tests/hooks/*|tests/bin/*|tests/skills/*|tests/agents/*|tests/install/*|tests/tests/*) ;;
    *) continue ;;
  esac
  [ -d "$REPO_OLD/${_rel%/*}" ] || mkdir -p "$REPO_OLD/${_rel%/*}"
  cp "$SCRIPT_CHECKOUT_ROOT/$_rel" "$REPO_OLD/$_rel"
  OLD_RELS+=("$_rel")
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- "${OLD_SPECS[@]:-tests/no-pattern-in-registry}" 2>/dev/null)
git -C "$REPO_OLD" add -A >/dev/null 2>&1
git -C "$REPO_OLD" commit -q -m "existing tests" >/dev/null 2>&1
for _rel in ${OLD_RELS[@]+"${OLD_RELS[@]}"}; do
  printf '\n' >> "$REPO_OLD/$_rel"
done
git -C "$REPO_OLD" add -A >/dev/null 2>&1

case_begin "gate-existing-tests-are-not-judged" "hooks/pre-commit"
if [ "${#OLD_RELS[@]}" -ge 3 ]; then
  pass "existing non-bash tests listed (${#OLD_RELS[@]})"
else
  fail "existing non-bash tests listed" "found ${#OLD_RELS[@]}"
fi
_staged="$(git -C "$REPO_OLD" diff --cached --name-only | grep -c .)"
assert_eq "staged edits=$_staged" "staged edits=${#OLD_RELS[@]}"
pc_run "$REPO_OLD"
assert_eq "commit-time rc=$PC_RC out=$PC_OUT err=$PC_ERR" "commit-time rc=0 out= err="
case_end

# The edit-time half — one hook run per existing file — is in
# tests/hooks/feature-2411-gate-integration.sh, where it runs the registered command.
case_begin "gate-existing-tests-list-comes-from-the-registry" "hooks/lib/test-language-registry.json"
assert_eq "languages with a name pattern=$(printf '%s\n' ${OLD_PAT_IDS[@]+"${OLD_PAT_IDS[@]}"} | sort -u | paste -sd, -)" \
  "languages with a name pattern=$(printf '%s\n' "${LANGS[@]}" | sort -u | paste -sd, -)"
for _i in "${!OLD_PATS[@]}"; do
  _n=0
  for _rel in ${OLD_RELS[@]+"${OLD_RELS[@]}"}; do
    # shellcheck disable=SC2254
    case "${_rel##*/}" in ${OLD_PATS[$_i]}) _n=$((_n + 1)) ;; esac
  done
  if [ "$_n" -ge 1 ]; then
    pass "${OLD_PAT_IDS[$_i]} ${OLD_PATS[$_i]}: $_n existing test(s) listed"
  else
    fail "${OLD_PAT_IDS[$_i]} ${OLD_PATS[$_i]}" "no existing test listed"
  fi
done
_n=0
while IFS= read -r _rel; do
  [ -n "$_rel" ] || continue
  _n=$((_n + 1))
  case $'\n'"$(printf '%s\n' ${OLD_RELS[@]+"${OLD_RELS[@]}"})"$'\n' in
    *$'\n'"$_rel"$'\n'*) pass "$_rel is in the list" ;;
    *) fail "$_rel" "missing from the list of existing tests" ;;
  esac
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- 'tests/hooks/feature-2326-*.js' 2>/dev/null | grep -v '^tests/hooks/[^/]*/')
if [ "$_n" -ge 1 ]; then
  pass "tests/hooks/feature-2326-*.js tracked ($_n)"
else
  fail "tests/hooks/feature-2326-*.js" "none tracked in this checkout"
fi
# Pester and pytest pins, named here rather than derived from the registry patterns.
for _rel in tests/bin/test-language-registry.Tests.ps1 tests/tests/feature-2476-pester-process-helpers.Tests.ps1 tests/bin/test_main-sort-history.py; do
  if ! git -C "$SCRIPT_CHECKOUT_ROOT" ls-files --error-unmatch -- "$_rel" >/dev/null 2>&1; then
    fail "pinned $_rel" "not tracked in this checkout"
    continue
  fi
  case $'\n'"$(printf '%s\n' ${OLD_RELS[@]+"${OLD_RELS[@]}"})"$'\n' in
    *$'\n'"$_rel"$'\n'*) pass "pinned $_rel is in the list" ;;
    *) fail "pinned $_rel" "missing from the list of existing tests" ;;
  esac
done
case_end

PARITY_JS="$TMPBASE/parity.js"
cat > "$PARITY_JS" <<'PARITYJS'
let m;
try {
  m = require(process.argv[2]);
} catch (e) {
  console.log("MODULE_MISSING");
  process.exit(3);
}
if (typeof m.isCaseMarkerTarget !== "function") {
  console.log("NO_EXPORT");
  process.exit(4);
}
for (const rel of process.argv.slice(3)) console.log(rel + "|" + (m.isCaseMarkerTarget(rel) ? 1 : 0));
PARITYJS

# The commit-time side (#2507): the placement module the Node case-marker gate requires.
PC_PLACEMENT="$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-gates/placement.js"
PC_MARKER_GATE="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js"
parity_pc_wired() {
  if grep -qF 'require("../../../lib/test-gates/placement")' "$PC_MARKER_GATE"; then
    pass "commit-time gate reads its predicate from hooks/lib/test-gates/placement.js"
  else
    fail "commit-time predicate source" "case-markers-gate.js no longer requires the placement module"
  fi
}

case_begin "gate-target-predicates-agree-on-three-languages" "hooks/block-case-markers.js"
PARITY_RELS=()
PARITY_WANT=()
# Literal verdicts: a flat tests/<name> is a target in every language, bash included.
for _lf in a.sh a.Tests.ps1 test_a.py a.js; do
  PARITY_RELS+=("tests/bin/$_lf" "tests/hooks/$_lf" "tests/$_lf" "tests/lib/$_lf" "tests/_archive/$_lf" "tests/bin/suite/$_lf")
  PARITY_WANT+=(1 1 1 0 0 0)
done
PARITY_OUT="$(cd "$NEUTRAL_CWD" && node "$(np "$PARITY_JS")" "$(np "$HOOK")" "${PARITY_RELS[@]}" 2>&1)"
PARITY_PC_OUT="$(cd "$NEUTRAL_CWD" && node "$(np "$PARITY_JS")" "$(np "$PC_PLACEMENT")" "${PARITY_RELS[@]}" 2>&1)"
parity_pc_wired
_i=0
for _rel in "${PARITY_RELS[@]}"; do
  _want="${PARITY_WANT[$_i]}"
  _i=$((_i + 1))
  _js="$(printf '%s\n' "$PARITY_OUT" | grep -F -x -e "$_rel|1" -e "$_rel|0" | head -n 1)"
  _js="${_js##*|}"
  _sh="$(printf '%s\n' "$PARITY_PC_OUT" | grep -F -x -e "$_rel|1" -e "$_rel|0" | head -n 1)"
  _sh="${_sh##*|}"
  if [ "$_js" = "$_want" ] && [ "$_sh" = "$_want" ]; then
    pass "target $_rel -> $_want (edit-time and commit-time agree)"
  else
    fail "target $_rel" "want=$_want edit-time=${_js:-none} commit-time=$_sh"
  fi
done
case_end

# #2502 S3-5: the reader-less classification (a placed file whose registry entry has no
# caseMarkerReader) on the same path table: the hook export against placement.js (commit time).
PARITY_RL_JS="$TMPBASE/parity-readerless.js"
cat > "$PARITY_RL_JS" <<'PARITYRLJS'
let m;
try {
  m = require(process.argv[2]);
} catch (e) {
  console.log("MODULE_MISSING");
  process.exit(3);
}
if (typeof m.isReaderlessCaseMarkerTarget !== "function") {
  console.log("NO_EXPORT");
  process.exit(4);
}
for (const rel of process.argv.slice(3)) console.log(rel + "|" + (m.isReaderlessCaseMarkerTarget(rel) ? 1 : 0));
PARITYRLJS

case_begin "gate-readerless-predicates-agree" "hooks/block-case-markers.js"
# name|path|want (1 = reader-less target, 0 = not one).
PARITY_RL_TABLE="readerless-bin|tests/bin/test_a.rb|1
readerless-hooks|tests/hooks/test_a.rb|1
readerless-top|tests/test_a.rb|1
excluded-lib|tests/lib/test_a.rb|0
excluded-archive|tests/_archive/test_a.rb|0
excluded-suite-subfile|tests/bin/suite/test_a.rb|0
excluded-outside-tests|bin/test_a.rb|0
unmatched-json|tests/bin/fixture.json|0
has-reader-sh|tests/bin/a.sh|0
has-reader-js|tests/bin/a.js|0"
PARITY_RELS=()
while IFS='|' read -r _name _rel _want; do
  PARITY_RELS+=("$_rel")
done <<<"$PARITY_RL_TABLE"
PARITY_OUT="$(cd "$NEUTRAL_CWD" && node "$(np "$PARITY_RL_JS")" "$(np "$HOOK")" "${PARITY_RELS[@]}" 2>&1)"
PARITY_PC_OUT="$(cd "$NEUTRAL_CWD" && node "$(np "$PARITY_RL_JS")" "$(np "$PC_PLACEMENT")" "${PARITY_RELS[@]}" 2>&1)"
parity_pc_wired
while IFS='|' read -r _name _rel _want; do
  _js="$(printf '%s\n' "$PARITY_OUT" | grep -F -x -e "$_rel|1" -e "$_rel|0" | head -n 1)"
  _js="${_js##*|}"
  _sh="$(printf '%s\n' "$PARITY_PC_OUT" | grep -F -x -e "$_rel|1" -e "$_rel|0" | head -n 1)"
  _sh="${_sh##*|}"
  if [[ "$_js" == "$_want" && "$_sh" == "$_want" && "$_js" == "$_sh" ]]; then
    pass "reader-less target [$_name] $_rel -> $_want (edit-time and commit-time agree)"
  else
    fail "reader-less target [$_name] $_rel" "want=$_want edit-time=${_js:-none} (${PARITY_OUT%%$'\n'*}) commit-time=$_sh"
  fi
done <<<"$PARITY_RL_TABLE"
case_end
