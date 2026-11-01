# The edit-time hook on an existing (HEAD-tracked) case-marker entrypoint: only a self-implemented
# harness HEAD lacks blocks (#2502 S3), for bash, pytest, pester and js; a HEAD blob git cannot
# give is left out; and an existing pester edit answers within the registered hook timeout.
# Sourced by tests/bin/feature-2411-gate-three-languages.sh. A language whose runtime is not
# installed answers the SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE WARN, so its blocking row expects an
# approve instead.
# shellcheck shell=bash

echo ""
echo "=== gate: existing entrypoints, self-implemented harness against HEAD ==="

EDIT_JS="$TMPBASE/edit-payload.js"
cat > "$EDIT_JS" <<'EDITJS'
const fs = require("fs");
const [, , cwd, filePath, oldFile, newFile] = process.argv;
process.stdout.write(JSON.stringify({
  tool_name: "Edit",
  cwd,
  tool_input: {
    file_path: filePath,
    old_string: fs.readFileSync(oldFile, "utf8"),
    new_string: fs.readFileSync(newFile, "utf8"),
  },
}));
EDITJS
TIMEOUT_JS="$TMPBASE/hook-timeout.js"
cat > "$TIMEOUT_JS" <<'TIMEOUTJS'
const s = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
let t = "";
for (const groups of Object.values(s.hooks || {})) {
  for (const g of groups) {
    for (const h of g.hooks || []) {
      if (typeof h.command === "string" && h.command.includes("hooks/block-case-markers.js")) t = String(h.timeout);
    }
  }
}
process.stdout.write(t);
TIMEOUTJS

# hook_edit <repo> <rel> <old> <new> — an Edit of <rel> replacing <old> with <new>. Sets HK_RC,
# HK_DECISION, HK_REASON, HK_ERR, and HE_MS (the hook's wall time in milliseconds).
HE_MS=0
hook_edit() {
  local repo_m parsed t0 t1
  repo_m="$(np "$1")"
  printf '%s' "$3" > "$TMPBASE/edit.old"
  printf '%s' "$4" > "$TMPBASE/edit.new"
  node "$(np "$EDIT_JS")" "$repo_m" "$repo_m/$2" "$(np "$TMPBASE/edit.old")" "$(np "$TMPBASE/edit.new")" > "$TMPBASE/payload.json"
  HK_RC=0
  t0="${EPOCHREALTIME/[.,]/}"
  (
    cd "$NEUTRAL_CWD" || exit 99
    bash "$RWT" 60 env "AGENTS_MAIN_ROOT=$(np "$EMPTY_ROOT")" node "$(np "$HOOK")" < "$TMPBASE/payload.json"
  ) >"$TMPBASE/hook.out" 2>"$TMPBASE/hook.err" || HK_RC=$?
  t1="${EPOCHREALTIME/[.,]/}"
  HE_MS=$(( (t1 - t0) / 1000 ))
  HK_ERR="$(cat "$TMPBASE/hook.err")"
  parsed="$(node "$(np "$REASON_JS")" "$(np "$TMPBASE/hook.out")")"
  HK_DECISION="${parsed%%$'\n'*}"
  HK_REASON=""
  case "$parsed" in *$'\n'*) HK_REASON="${parsed#*$'\n'}" ;; esac
}

# ex_lang <id> — EX_EXT, EX_STEM-based file names, EX_RT (empty: always there), the body lines
# EX_LINES, the anchor EX_ANCHOR and its counter-carrying form EX_CTR, the unrelated edit
# EX_OTHER -> EX_OTHER_NEW, and EX_DETAIL the counter's detail.
ex_lang() {
  case "$1" in
    bash) EX_RT=""; EX_DETAIL="PASS=0"
      EX_LINES=('#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:common' 'source "$(dirname "$0")/../../tests/lib/harness.sh"' 'echo start' 'echo done')
      EX_ANCHOR='echo start'; EX_CTR=$'PASS=0\necho start'; EX_OTHER='echo done'; EX_OTHER_NEW='echo finished' ;;
    pytest) EX_RT=uv; EX_DETAIL="passed=0"
      EX_LINES=('# Tests: bin/a.py' '# Tags: scope:common' 'import sys' 'from pathlib import Path' '' 'sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))' 'import harness' '' '' 'def test_a():' '    assert harness is not None')
      EX_ANCHOR='def test_a():'; EX_CTR=$'passed = 0\n\n\ndef test_a():'; EX_OTHER='    assert harness is not None'; EX_OTHER_NEW='    assert harness' ;;
    pester) EX_RT=pwsh; EX_DETAIL="Passed=0"
      EX_LINES=('# Tests: bin/a.ps1' '# Tags: scope:common' 'BeforeAll {' "    . (Join-Path \$PSScriptRoot '..' 'lib' 'harness.ps1')" '}' "Describe 'a' {" "    It 'runs' { 1 | Should -Be 1 }" '}')
      EX_ANCHOR="Describe 'a' {"; EX_CTR=$'$script:Passed = 0\nDescribe \'a\' {'; EX_OTHER="It 'runs'"; EX_OTHER_NEW="It 'still runs'" ;;
    js) EX_RT=""; EX_DETAIL="PASS=0"
      # node:test keeps the required-runner gate (#2865: existing files too) out of these self-impl rows.
      EX_LINES=('// Tests: bin/a.js' '// Tags: scope:common' 'const { test } = require("node:test");' 'const harness = require("../lib/harness");' 'console.log("start");' 'test("a", () => console.log(typeof harness));')
      EX_ANCHOR='console.log("start");'; EX_CTR=$'let PASS = 0;\nconsole.log("start");'; EX_OTHER='test("a", () => console.log(typeof harness));'; EX_OTHER_NEW='test("a", () => console.log(typeof harness, 1));' ;;
  esac
  case "$1" in
    bash) EX_EXT=sh; EX_REL() { printf 'tests/bin/%s.sh' "$1"; } ;;
    pytest) EX_EXT=py; EX_REL() { printf 'tests/bin/test_%s.py' "${1//-/_}"; } ;;
    pester) EX_EXT=ps1; EX_REL() { printf 'tests/bin/%s.Tests.ps1' "$1"; } ;;
    js) EX_EXT=js; EX_REL() { printf 'tests/bin/%s.js' "$1"; } ;;
  esac
  EX_HAS_RT=1
  if [ -n "$EX_RT" ] && ! command -v "$EX_RT" >/dev/null 2>&1; then EX_HAS_RT=0; fi
}

# ex_write <repo> <rel> <with-counter 0|1> [<extra line>] — the language's body, the anchor
# replaced by its counter form when asked, <extra line> appended (keeps blobs distinct).
ex_write() {
  local body
  body="$(printf '%s\n' "${EX_LINES[@]}")"
  [ "$3" = "1" ] && body="${body/"$EX_ANCHOR"/"$EX_CTR"}"
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$body" > "$1/$2"
  [ -z "${4:-}" ] || printf '%s\n' "$4" >> "$1/$2"
}

EX_LANGS=(bash pytest pester js)
REPO_EX="$TMPBASE/repo-existing-self-impl"
mkrepo "$REPO_EX"
mkdir -p "$REPO_EX/bin"
for _ext in sh ps1 py js; do printf '\n' > "$REPO_EX/bin/a.$_ext"; done
for _lang in "${EX_LANGS[@]}"; do
  ex_lang "$_lang"
  ex_write "$REPO_EX" "$(EX_REL edit-clean)" 0
  ex_write "$REPO_EX" "$(EX_REL edit-debt)" 1
  ex_write "$REPO_EX" "$(EX_REL edit-gone)" 0 "# blob removed below"
  [ "$_lang" = js ] && ex_write "$REPO_EX" "$(EX_REL edit-gone)" 0 "// blob removed below"
done
git -C "$REPO_EX" add -A >/dev/null 2>&1
git -C "$REPO_EX" commit -q -m existing >/dev/null 2>&1

case_begin "edit-existing-gains-counter-blocks" "hooks/block-case-markers.js"
for _lang in "${EX_LANGS[@]}"; do
  ex_lang "$_lang"
  _rel="$(EX_REL edit-clean)"
  hook_edit "$REPO_EX" "$_rel" "$EX_ANCHOR" "$EX_CTR"
  if [ "$EX_HAS_RT" -ne 1 ]; then
    assert_eq "$_lang (no $EX_RT): decision=$HK_DECISION" "$_lang (no $EX_RT): decision=approve"
  else
    assert_eq "$_lang: decision=$HK_DECISION" "$_lang: decision=block"
    has "$_lang existing file gains a counter" "$HK_REASON" "$_rel: HIGH: $_rel line"
    has "$_lang existing file gains a counter" "$HK_REASON" "(counter-init $EX_DETAIL) code=SELF_IMPLEMENTED_HARNESS"
  fi
done
case_end

case_begin "edit-existing-debt-unrelated-edit-approves" "hooks/block-case-markers.js"
for _lang in "${EX_LANGS[@]}"; do
  ex_lang "$_lang"
  hook_edit "$REPO_EX" "$(EX_REL edit-debt)" "$EX_OTHER" "$EX_OTHER_NEW"
  assert_eq "$_lang HEAD counter kept: decision=$HK_DECISION" "$_lang HEAD counter kept: decision=approve"
  lacks "$_lang HEAD counter kept" "$HK_REASON" "SELF_IMPLEMENTED_HARNESS"
done
case_end

# The registered timeout of the hook (settings.json), in seconds.
HOOK_TIMEOUT_S="$(node "$(np "$TIMEOUT_JS")" "$(np "$SCRIPT_CHECKOUT_ROOT/settings.json")" 2>/dev/null || true)"
case_begin "edit-existing-pester-within-hook-timeout" "hooks/block-case-markers.js"
ex_lang pester
if [ "$EX_HAS_RT" -ne 1 ]; then
  skip "pester timing: pwsh is not installed (the WARN path parses nothing)"
elif ! [[ "$HOOK_TIMEOUT_S" =~ ^[0-9]+$ ]]; then
  fail "hook timeout" "no numeric timeout for hooks/block-case-markers.js in settings.json: [$HOOK_TIMEOUT_S]"
else
  # An existing pester entrypoint parses twice (the edit and its HEAD copy).
  hook_edit "$REPO_EX" "$(EX_REL edit-clean)" "$EX_ANCHOR" "$EX_CTR"
  assert_eq "pester existing edit: decision=$HK_DECISION" "pester existing edit: decision=block"
  if [ "$HE_MS" -lt $(( HOOK_TIMEOUT_S * 1000 )) ]; then
    pass "pester existing edit answered in ${HE_MS} ms (< ${HOOK_TIMEOUT_S} s)"
  else
    fail "pester existing edit" "took ${HE_MS} ms, registered hook timeout is ${HOOK_TIMEOUT_S} s"
  fi
fi
case_end

case_begin "edit-existing-unreadable-head-blob-approves" "hooks/block-case-markers.js"
for _lang in "${EX_LANGS[@]}"; do
  ex_lang "$_lang"
  _rel="$(EX_REL edit-gone)"
  _sha="$(git -C "$REPO_EX" rev-parse "HEAD:$_rel" 2>/dev/null || true)"
  rm -f "$REPO_EX/.git/objects/${_sha:0:2}/${_sha:2}"
  if [ -z "$(git -C "$REPO_EX" ls-tree --name-only HEAD -- "$_rel" 2>/dev/null)" ]; then
    fail "$_lang unreadable blob" "ls-tree no longer lists $_rel"
  elif git -C "$REPO_EX" cat-file -e "HEAD:$_rel" 2>/dev/null; then
    fail "$_lang unreadable blob" "the blob of $_rel is still readable"
  else
    hook_edit "$REPO_EX" "$_rel" "$EX_ANCHOR" "$EX_CTR"
    assert_eq "$_lang unreadable HEAD blob: decision=$HK_DECISION" "$_lang unreadable HEAD blob: decision=approve"
    lacks "$_lang unreadable HEAD blob" "$HK_REASON" "SELF_IMPLEMENTED_HARNESS"
  fi
done
case_end
