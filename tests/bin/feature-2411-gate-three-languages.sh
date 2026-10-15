#!/usr/bin/env bash
# tests/bin/feature-2411-gate-three-languages.sh
# Tests: bin/check-case-markers.sh, bin/check-test-frontmatter.sh, hooks/block-case-markers.js, hooks/lib/precommit-tests-frontmatter.sh, hooks/lib/test-language-registry.json
# Tags: TL2, bin, hooks, case-markers, test-language-registry, pre-commit, scope:issue-specific
# Issue #2411: the marker gate for PowerShell, Python and JavaScript tests, and the bash
# verdicts and wording it must leave byte-identical. Cases live in the sibling directory:
# pin-*.sh hold today's behaviour, gate-*.sh hold the three-language behaviour.
# TL3 gap: a real Claude Code edit reaching the edit hook (mitigation: the real git commit
# and the registered hook command run in tests/hooks/feature-2411-gate-integration.sh).
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

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2411-gate-three-languages"
CHECKER="$SCRIPT_CHECKOUT_ROOT/bin/check-case-markers.sh"
FM_CHECK="$SCRIPT_CHECKOUT_ROOT/bin/check-test-frontmatter.sh"
HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/block-case-markers.js"
PRECOMMIT_LIB="$SCRIPT_CHECKOUT_ROOT/hooks/lib/precommit-tests-frontmatter.sh"
TABLE="$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json"

NEUTRAL_CWD="$TMPBASE/neutral"
BODIES="$TMPBASE/bodies"
EMPTY_ROOT="$TMPBASE/agents-config"
mkdir -p "$NEUTRAL_CWD" "$BODIES" "$EMPTY_ROOT"

LANGS=(pester pytest js)

# lang_set <id> [<stem>] — LF the test file name for <stem>, LREQ the command the reader
# runs under, LREASON the malformed reason the "<id>-malformed" body carries.
lang_set() {
  local stem="${2:-gate}"
  case "$1" in
    pester) LF="$stem.Tests.ps1"; LREQ="pwsh"; LREASON="missing-target" ;;
    pytest) LF="test_$stem.py"; LREQ="uv"; LREASON="missing-target" ;;
    js) LF="$stem.js"; LREQ="node"; LREASON="balance" ;;
    *) LF=""; LREQ=""; LREASON="" ;;
  esac
}

# mkrepo <dir> — fixture repo whose HEAD carries one helper library stub per language.
mkrepo() {
  local d="$1" ext
  harness_git_init "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" config core.autocrlf false
  mkdir -p "$d/tests/lib" "$d/tests/bin" "$d/tests/hooks"
  for ext in sh ps1 py js; do
    printf '\n' > "$d/tests/lib/harness.$ext"
  done
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m init >/dev/null 2>&1
}

# put <repo> <rel> <body-name> — copy a body into the working tree.
put() {
  mkdir -p "$(dirname "$1/$2")"
  cp "$BODIES/$3" "$1/$2"
}

# stage <repo> <rel> <body-name>
stage() {
  put "$1" "$2" "$3"
  git -C "$1" add -- "$2" >/dev/null 2>&1
}

# ck <file>... — the checker from a neutral cwd. Sets CK_RC CK_OUT CK_ERR.
# CK_PATH replaces PATH for the checker when set.
CK_RC=0; CK_OUT=""; CK_ERR=""
CK_PATH=""
ck() {
  CK_RC=0
  (
    cd "$NEUTRAL_CWD" || exit 99
    [ -n "$CK_PATH" ] && PATH="$CK_PATH"
    bash "$RWT" 60 bash "$CHECKER" "$@"
  ) >"$TMPBASE/ck.out" 2>"$TMPBASE/ck.err" || CK_RC=$?
  CK_OUT="$(cat "$TMPBASE/ck.out")"
  CK_ERR="$(cat "$TMPBASE/ck.err")"
}

# ck_exact <label> <rc> <stdout> <stderr> — the whole result, byte for byte.
ck_exact() {
  if [ "$CK_RC" = "$2" ] && [ "$CK_OUT" = "$3" ] && [ "$CK_ERR" = "$4" ]; then
    pass "$1"
  else
    fail "$1" "want rc=$2 out=[$3] err=[$4] got rc=$CK_RC out=[$CK_OUT] err=[$CK_ERR]"
  fi
}

PAYLOAD_JS="$TMPBASE/payload.js"
cat > "$PAYLOAD_JS" <<'PAYLOAD'
const fs = require("fs");
const [, , cwd, filePath, bodyFile] = process.argv;
process.stdout.write(JSON.stringify({
  tool_name: "Write",
  cwd,
  tool_input: { file_path: filePath, content: fs.readFileSync(bodyFile, "utf8") },
}));
PAYLOAD
REASON_JS="$TMPBASE/reason.js"
cat > "$REASON_JS" <<'REASONJS'
const fs = require("fs");
let o = {};
try { o = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch (e) { o = {}; }
process.stdout.write(String(o.decision || "none") + "\n" + (typeof o.reason === "string" ? o.reason : ""));
REASONJS
REG_JS="$TMPBASE/reg.js"
cat > "$REG_JS" <<'REGJS'
const t = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
for (const e of t.entries) {
  const r = e.caseMarkerReader || {};
  const h = e.helperLibrary || {};
  console.log([e.id, r.file || "-", r.function || "-", h.path || "-"].join("|"));
}
REGJS

# reg_pairs — "<id>|<reader file>|<reader function>|<helper path>" per entry, read from the table.
reg_pairs() {
  node "$(np "$REG_JS")" "$(np "$TABLE")"
}

# hook_write <repo> <rel> <body-name> — a Write of <body> to <rel>. Sets HK_RC, HK_DECISION,
# HK_REASON, HK_ERR. HK_PATH replaces PATH for the hook when set.
HK_RC=0; HK_DECISION="none"; HK_REASON=""; HK_ERR=""
HK_PATH=""
hook_write() {
  local repo_m parsed
  repo_m="$(np "$1")"
  node "$(np "$PAYLOAD_JS")" "$repo_m" "$repo_m/$2" "$(np "$BODIES/$3")" > "$TMPBASE/payload.json"
  HK_RC=0
  (
    cd "$NEUTRAL_CWD" || exit 99
    [ -n "$HK_PATH" ] && PATH="$HK_PATH"
    bash "$RWT" 60 env "AGENTS_MAIN_ROOT=$(np "$EMPTY_ROOT")" node "$(np "$HOOK")" < "$TMPBASE/payload.json"
  ) >"$TMPBASE/hook.out" 2>"$TMPBASE/hook.err" || HK_RC=$?
  HK_ERR="$(cat "$TMPBASE/hook.err")"
  parsed="$(node "$(np "$REASON_JS")" "$(np "$TMPBASE/hook.out")")"
  HK_DECISION="${parsed%%$'\n'*}"
  HK_REASON=""
  case "$parsed" in *$'\n'*) HK_REASON="${parsed#*$'\n'}" ;; esac
}

PC_OK=0
if [ -f "$PRECOMMIT_LIB" ]; then
  # shellcheck source=../../hooks/lib/precommit-tests-frontmatter.sh
  . "$PRECOMMIT_LIB"
  declare -F _precommit_check_tests_case_markers >/dev/null 2>&1 && PC_OK=1
fi
_cfg_dir="$SCRIPT_CHECKOUT_ROOT"

# pc_run <repo> — the commit-time gate with <repo> as cwd. Sets PC_RC PC_OUT PC_ERR.
PC_RC=0; PC_OUT=""; PC_ERR=""
PC_PATH=""
pc_run() {
  PC_RC=0
  if [ "$PC_OK" -ne 1 ]; then
    PC_RC=127; PC_OUT=""; PC_ERR="commit-time gate function not defined"
    return 0
  fi
  (
    cd "$1" || exit 99
    [ -n "$PC_PATH" ] && PATH="$PC_PATH"
    _cfg_dir="$SCRIPT_CHECKOUT_ROOT"
    _precommit_check_tests_case_markers
  ) >"$TMPBASE/pc.out" 2>"$TMPBASE/pc.err" || PC_RC=$?
  PC_OUT="$(cat "$TMPBASE/pc.out")"
  PC_ERR="$(cat "$TMPBASE/pc.err")"
}

# fm_run <repo> <rel>... — check-test-frontmatter.sh --staged with <repo> as cwd.
FM_RC=0; FM_OUT=""; FM_ERR=""
fm_run() {
  local repo="$1"
  shift
  FM_RC=0
  (
    cd "$repo" || exit 99
    bash "$RWT" 90 bash "$FM_CHECK" --staged "$@"
  ) >"$TMPBASE/fm.out" 2>"$TMPBASE/fm.err" || FM_RC=$?
  FM_OUT="$(cat "$TMPBASE/fm.out")"
  FM_ERR="$(cat "$TMPBASE/fm.err")"
}

# shellcheck source=../lib/tool-shim-path.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/tool-shim-path.sh"

# no_runtime_path <tool> — a PATH of tool wrappers without <tool>; empty when one could not be built.
no_runtime_path() {
  tsp_base_path "$TMPBASE/shim-no-$1" "$1" 2>"$TMPBASE/shim-no-$1.err" || true
}

# has / lacks <label> <haystack> <fixed-string>
has() {
  case "$2" in
    *"$3"*) pass "$1: has [$3]" ;;
    *) fail "$1" "lacks [$3]: $2" ;;
  esac
}
lacks() {
  case "$2" in
    *"$3"*) fail "$1" "must not mention [$3]: $2" ;;
    *) pass "$1: no [$3]" ;;
  esac
}

case_begin "pin-bash-entry-reader-and-helper" "hooks/lib/test-language-registry.json"
REG_PAIRS="$(reg_pairs)"
if printf '%s\n' "$REG_PAIRS" | grep -qxF 'bash|bin/lib/test-retire-predicate/case-parser.sh|trp_parse_case_markers|tests/lib/harness.sh'; then
  pass "bash entry keeps its reader part and helper library"
else
  fail "bash entry reader/helper" "$REG_PAIRS"
fi
case_end

# shellcheck source=feature-2411-gate-three-languages/bodies.sh
. "$CASE_DIR/bodies.sh"
# shellcheck source=feature-2411-gate-three-languages/pin-checker.sh
. "$CASE_DIR/pin-checker.sh"
# shellcheck source=feature-2411-gate-three-languages/pin-messages.sh
. "$CASE_DIR/pin-messages.sh"
# shellcheck source=feature-2411-gate-three-languages/gate-checker.sh
. "$CASE_DIR/gate-checker.sh"
# shellcheck source=feature-2411-gate-three-languages/gate-hooks.sh
. "$CASE_DIR/gate-hooks.sh"
# shellcheck source=feature-2411-gate-three-languages/gate-helper-load.sh
. "$CASE_DIR/gate-helper-load.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
