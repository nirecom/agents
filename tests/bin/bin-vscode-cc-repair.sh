#!/usr/bin/env bash
# tests/bin/bin-vscode-cc-repair.sh
# Tests: bin/vscode-cc-repair
# Tags: bin, vscode, extension-patch, scope:common, pwsh-not-required, TL2

# TL3 gap (what this test does NOT catch): - the real ~2.6 MB minified anthropic.claude-code bundle (node --check timing, latin1 round-trip fidelity, classifier behaviour on the genuine token soup);
#   - the real installed home-relative extension roots: root discovery runs through an injected fixture HOME/USERPROFILE, so the machine's actual ~/.vscode*/extensions tree is never read or written; POSIX extension roots (.vscode-server*, WSL/remote layouts) are fixture-only by an accepted tradeoff — only the Windows host is exercised for real path normalization;
#   - the two pre-rename concurrency branches (`raced` -> exit 0, `changed-during-patch` -> exit 1): only a real concurrent writer (VS Code auto-update, a second patch run) can land inside the re-read/rename window, and runtime filesystem faults on the write path (.bak write, tmp write, rename, post-rename verify) — see the Skipped-Because block in tests/bin/bin-vscode-cc-repair/failclosed-paths.sh.
# Documented SKIP categories (each increments SKIP and prints why): win32 case-insensitive root dedup (T5d-2): not Windows_NT; symlink root dedup (T5d-3): `ln -s` yields a copy, not a link, on this host;
#   directory-alias cases (C5-a*, C9-d*): neither `ln -s` nor `mklink /J` usable; git index mode (C3-e02): this checkout not a git repo, or the script not tracked yet; direct shebang execution (C3-e03): host cannot exec an extensionless `#!` file.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer.

set -euo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/vscode-cc-repair/index.js"
REQUIRE_PATH="./bin/vscode-cc-repair/index.js"
PARTS_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-vscode-cc-repair"

if [ ! -f "$SCRIPT" ]; then
  echo "SKIP (RED): $SCRIPT not yet implemented — TDD RED phase"
  exit 77
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
# isolation (#2512): pin state and plans dirs once for this file and its sourced parts.
mkdir -p "$TMPROOT/isolation/workflow-state" "$TMPROOT/isolation/plans"
export WORKFLOW_STATE_DIR="$TMPROOT/isolation/workflow-state" WORKFLOW_PLANS_DIR="$TMPROOT/isolation/plans"

PASS=0
FAIL=0
SKIP=0

# ---- helpers ---------------------------------------------------------------

run_with_timeout() { "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$@"; }

check() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then echo "PASS: $desc"; PASS=$((PASS + 1))
  else echo "FAIL: $desc -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

check_contains() {
  local desc="$1" needle="$2" hay="$3"
  if grep -qF -- "$needle" <<< "$hay"; then echo "PASS: $desc"; PASS=$((PASS + 1))
  else echo "FAIL: $desc -- missing [$needle] in: $hay"; FAIL=$((FAIL + 1)); fi
}

check_absent() {
  local desc="$1" needle="$2" hay="$3"
  if grep -qF -- "$needle" <<< "$hay"; then
    echo "FAIL: $desc -- unexpected [$needle] in: $hay"; FAIL=$((FAIL + 1))
  else echo "PASS: $desc"; PASS=$((PASS + 1)); fi
}

# Whole-token match so `patched` never matches `would-patch` and `already` never
# matches the `already=0` counter inside the summary line.
check_token() {
  local desc="$1" tok="$2" hay="$3"
  if grep -qE -- "(^|[[:space:]])${tok}([[:space:]]|\$)" <<< "$hay"; then
    echo "PASS: $desc"; PASS=$((PASS + 1))
  else echo "FAIL: $desc -- token [$tok] not in: $hay"; FAIL=$((FAIL + 1)); fi
}

check_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then echo "FAIL: $desc -- exists: $path"; FAIL=$((FAIL + 1))
  else echo "PASS: $desc"; PASS=$((PASS + 1)); fi
}

check_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then echo "PASS: $desc"; PASS=$((PASS + 1))
  else echo "FAIL: $desc -- missing: $path"; FAIL=$((FAIL + 1)); fi
}

bytes() { wc -c < "$1" | tr -d '[:space:]'; }
count_tmp() { find "$1" -name '*.tmp.js' 2>/dev/null | wc -l | tr -d '[:space:]'; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d '[:space:]'; }

# Native form of a fixture path: on Windows `pwd -W` yields C:/... which exercises
# the script's C:/ -> C:\ normalization branch for real. Never a hardcoded path.
native_path() { (cd "$1" && pwd -W 2>/dev/null || pwd); }

new_root() { mktemp -d "$TMPROOT/root.XXXXXX"; }

# Directory alias (<link> -> <target>) for the realpath-dedup and escaping-alias
# fixtures. A POSIX symlink is preferred; on Windows_NT `ln -s` silently produces a
# real COPY (MSYS default), so a junction is created instead. Returns non-zero when
# neither mechanism is usable, so the caller emits a documented SKIP.
make_dir_alias() { # <link> <target>
  local link="$1" target="$2" lw tw
  if [ "${OS:-}" = "Windows_NT" ]; then
    command -v cygpath >/dev/null 2>&1 || return 1
    lw="$(cygpath -w "$link" 2>/dev/null)" || return 1
    tw="$(cygpath -w "$target" 2>/dev/null)" || return 1
    MSYS_NO_PATHCONV=1 cmd /c mklink /J "$lw" "$tw" >/dev/null 2>&1 || return 1
  else
    ln -s "$target" "$link" 2>/dev/null || return 1
    [ -L "$link" ] || return 1
  fi
  [ -d "$link" ] || return 1
  return 0
}

make_ext_dir() { # <root> <dir-name> <js-body>
  mkdir -p "$1/$2"
  printf '%s' "$3" > "$1/$2/extension.js"
}

run_cli() { # sets CLI_RC / CLI_OUT (stdout+stderr combined)
  CLI_RC=0
  CLI_OUT="$(run_with_timeout 30 node "$SCRIPT" "$@" 2>&1)" || CLI_RC=$?
}

# Separated streams: needed to prove --help lands on stdout and that argument
# errors land on stderr.
run_cli_split() { # sets CLI_RC / CLI_STDOUT / CLI_STDERR
  local ef
  ef="$(mktemp "$TMPROOT/stderr.XXXXXX")"
  CLI_RC=0
  CLI_STDOUT="$(run_with_timeout 30 node "$SCRIPT" "$@" 2>"$ef")" || CLI_RC=$?
  CLI_STDERR="$(cat "$ef")"
}

# Hermetic default-root discovery: main() calls os.homedir(), which reads
# USERPROFILE on win32 and HOME on POSIX. Setting both redirects the whole
# CANDIDATE_ROOTS scan into a fixture tree — the machine's real ~/.vscode*
# extensions are never touched. No source-side env override exists or is needed.
run_cli_home() { # <fixture-home> [args...] ; sets CLI_RC / CLI_OUT
  local h="$1"; shift
  local hn
  hn="$(native_path "$h")"
  CLI_RC=0
  CLI_OUT="$(HOME="$h" USERPROFILE="$hn" run_with_timeout 30 node "$SCRIPT" "$@" 2>&1)" || CLI_RC=$?
}

node_m() { # <js> ; sets NODE_RC / NODE_OUT
  NODE_RC=0
  NODE_OUT="$(cd "$SCRIPT_CHECKOUT_ROOT" && run_with_timeout 30 node -e "$1" 2>&1)" || NODE_RC=$?
}

# First per-directory report line (state token in column 1). Used to prove those
# lines carry a basename only — the absolute path appears once, on the root line.
first_dir_line() { # <cli-output>
  grep -E '^(patched|already|absent|would-patch|refused|failed)[[:space:]]' <<< "$1" | head -1 || true
}

DIR_A="anthropic.claude-code-1.0.0"
DIR_B="anthropic.claude-code-2.0.0"

# Every failure diagnostic is prefixed with this on stderr.
STDERR_PREFIX='[vscode-cc-repair] '

# Real-bundle shape: the key appears twice — once as a destructuring site whose value
# is an identifier, once as the patch target literal inside the `sessionListOptions(){return{`
# anchor literal (#2683: the default classifier only patches inside that anchor). Literal sites: 1.
BODY_FALSY='function f({includeWorktrees:i}){return i}var o={sessionListOptions(){return{includeWorktrees:!1}}};module.exports={f,o};'
BODY_TRUTHY='function f({includeWorktrees:i}){return i}var o={sessionListOptions(){return{includeWorktrees:!0}}};module.exports={f,o};'
# The pre-#2683 synthetic shape: one literal and NO anchor. Default method -> refused;
# only --legacy-single-literal still patches it.
BODY_NOANCHOR_FALSY='function f({includeWorktrees:i}){return i}var o={includeWorktrees:!1};module.exports={f,o};'
BODY_NOANCHOR_TRUTHY='function f({includeWorktrees:i}){return i}var o={includeWorktrees:!0};module.exports={f,o};'
# Extension 2.1.300 shape: the anchor literal plus a resolveSession() call holding its own
# `includeWorktrees:!1`, which must survive the patch. _REV puts the outside site FIRST, so a
# "first falsy wins" offset would splice the wrong one.
BODY_V2130='var c={sessionListOptions(){return{cwd:this.cwd,includeWorktrees:!1}},resolveSession(Y){return listSdkSessions({limit:1,dir:Y.folder,includeWorktrees:!1})}};function listSdkSessions(o){return o}module.exports={c};'
BODY_V2130_PATCHED='var c={sessionListOptions(){return{cwd:this.cwd,includeWorktrees:!0}},resolveSession(Y){return listSdkSessions({limit:1,dir:Y.folder,includeWorktrees:!1})}};function listSdkSessions(o){return o}module.exports={c};'
BODY_V2130_REV='var c={resolveSession(Y){return listSdkSessions({limit:1,dir:Y.folder,includeWorktrees:!1})},sessionListOptions(){return{cwd:this.cwd,includeWorktrees:!1}}};function listSdkSessions(o){return o}module.exports={c};'
# Anchor-method refusal shapes. _KEYLESS: the anchor exists but holds no key; the only
# literal sits outside it (resolveSession), so there is nothing patchable -> refused.
BODY_ANCHOR_KEYLESS='var c={sessionListOptions(){return{cwd:1}},resolveSession(Y){return listSdkSessions({limit:1,dir:Y.folder,includeWorktrees:!1})}};function listSdkSessions(o){return o}module.exports={c};'
# Anchor present, no `includeWorktrees:` anywhere -> absent.
BODY_ANCHOR_NOKEY='var a={sessionListOptions(){return{cwd:1}}};module.exports={a};'
# Nested objects inside the anchor literal. A nested `includeWorktrees:` counts toward the
# in-literal key count (spec: exactly one inside the literal), so both are refused.
BODY_ANCHOR_NESTED_BEFORE='var a={sessionListOptions(){return{opts:{includeWorktrees:!1},dir:this.cwd,includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_NESTED_AFTER='var a={sessionListOptions(){return{dir:this.cwd,includeWorktrees:!1,opts:{includeWorktrees:!1}}}};module.exports={a};'
# A key-free nested object before the target key: the literal's end is found past it.
BODY_ANCHOR_NESTED_NOKEY='var a={sessionListOptions(){return{opts:{dir:1,list:[1,2]},includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_NESTED_NOKEY_PATCHED='var a={sessionListOptions(){return{opts:{dir:1,list:[1,2]},includeWorktrees:!0}}};module.exports={a};'
# Depth-1 rule: a key only in a nested object/array is not the target -> refused, whatever its value.
BODY_ANCHOR_NESTED_ONLY='var a={sessionListOptions(){return{opts:{includeWorktrees:!1},cwd:this.cwd}}};module.exports={a};'
BODY_ANCHOR_NESTED_ONLY_TRUTHY='var a={sessionListOptions(){return{opts:{includeWorktrees:!0},cwd:this.cwd}}};module.exports={a};'
BODY_ANCHOR_ARRAY_NESTED='var a={sessionListOptions(){return{list:[{includeWorktrees:!1}],cwd:this.cwd}}};module.exports={a};'
# String-aware brace scan. _STR_SIBLING: a naive scan counting the `{{` inside the string would
# run past the literal's real end into resolveSession and adopt its key; the string-aware scan
# closes the literal before it, so the anchor holds no key -> refused (no-anchor-key).
BODY_ANCHOR_STR_SIBLING='var a={sessionListOptions(){return{cwd:"{{",x:1}},resolveSession(){return{includeWorktrees:!1}}};module.exports={a};'
# A `}` inside a string (plain, or behind an escaped quote) must not close the literal early.
BODY_ANCHOR_STR_CLOSE='var a={sessionListOptions(){return{cwd:"}",includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_STR_CLOSE_PATCHED='var a={sessionListOptions(){return{cwd:"}",includeWorktrees:!0}}};module.exports={a};'
BODY_ANCHOR_ESC_DQ='var a={sessionListOptions(){return{cwd:"a\"}",includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_ESC_DQ_PATCHED='var a={sessionListOptions(){return{cwd:"a\"}",includeWorktrees:!0}}};module.exports={a};'
BODY_ANCHOR_ESC_SQ="var a={sessionListOptions(){return{cwd:'a\\'}',includeWorktrees:!1}}};module.exports={a};"
BODY_ANCHOR_ESC_SQ_PATCHED="var a={sessionListOptions(){return{cwd:'a\\'}',includeWorktrees:!0}}};module.exports={a};"
# The key text inside a string is still a key site in the literal that is not depth-1 code.
BODY_ANCHOR_KEY_IN_STR='var a={sessionListOptions(){return{s:"includeWorktrees:!1",includeWorktrees:!1}}};module.exports={a};'
# A backtick or `/` before the literal closes is unlexable without a parser -> ambiguous.
BODY_ANCHOR_TEMPLATE='var a={sessionListOptions(){return{cwd:`x`,includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_REGEX='var a={sessionListOptions(){return{r:/}/,includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_UNCLOSED='var a={sessionListOptions(){return{includeWorktrees:!1'
BODY_TWO_ANCHORS='var a={sessionListOptions(){return{includeWorktrees:!1}}},b={sessionListOptions(){return{includeWorktrees:!1}}};module.exports={a,b};'
BODY_ANCHOR_TWO_KEYS='var a={sessionListOptions(){return{includeWorktrees:!1,includeWorktrees:!1}}};module.exports={a};'
BODY_ANCHOR_DYNAMIC='var w=!1,a={sessionListOptions(){return{includeWorktrees:w}}};module.exports={a};'
BODY_ANCHOR_UNKNOWN='var a={sessionListOptions(){return{includeWorktrees:!10}}};module.exports={a};'
BODY_ANCHOR_TRUE='var a={sessionListOptions(){return{includeWorktrees:true}}};module.exports={a};'
BODY_ANCHOR_FALSE='var a={sessionListOptions(){return{includeWorktrees: false}}};module.exports={a};'
# Anchor boundary rule: the lone anchor must follow `{` `}` `,` `;` or open the file. Text
# inside a string or comment follows something else -> refused ambiguous-anchor.
BODY_ANCHOR_IN_DQ='var s="sessionListOptions(){return{includeWorktrees:!1}";module.exports={s};'
BODY_ANCHOR_IN_DQ_TRUTHY='var s="sessionListOptions(){return{includeWorktrees:!0}";module.exports={s};'
BODY_ANCHOR_IN_SQ="var s='sessionListOptions(){return{includeWorktrees:!1}';module.exports={s};"
BODY_ANCHOR_IN_COMMENT='/* sessionListOptions(){return{includeWorktrees:!1}} */module.exports={};'
# Accepted boundaries. _AFTER_RBRACE is the 2.1.300 class-body shape `...}}sessionListOptions`.
BODY_ANCHOR_AFTER_RBRACE='class C{m(){if(this.x){}}sessionListOptions(){return{dir:this.cwd,includeWorktrees:!1}}}module.exports={C};'
BODY_ANCHOR_AFTER_COMMA='var o={a:1,sessionListOptions(){return{includeWorktrees:!1}}};module.exports={o};'
BODY_ANCHOR_AFTER_SEMI='class C{x=1;sessionListOptions(){return{includeWorktrees:!1}}}module.exports={C};'
BODY_ANCHOR_AFTER_LBRACE='class C{sessionListOptions(){return{includeWorktrees:!1}}}module.exports={C};'
BODY_ANCHOR_AT_OFFSET0='sessionListOptions(){return{includeWorktrees:!1}}'
BODY_OUTSIDE_UNKNOWN='var a={sessionListOptions(){return{includeWorktrees:!1}}},b={includeWorktrees:!10};module.exports={a,b};'
BODY_OUTSIDE_TRUE='var a={sessionListOptions(){return{includeWorktrees:!1}}},b={includeWorktrees:true};module.exports={a,b};'
BODY_OUTSIDE_FALSE='var a={sessionListOptions(){return{includeWorktrees:!1}}},b={includeWorktrees: false};module.exports={a,b};'
BODY_TWO_FALSY='var a={includeWorktrees:!1},b={includeWorktrees:!1};module.exports={a,b};'
BODY_MIXED='var a={includeWorktrees:!1},b={includeWorktrees:!0};module.exports={a,b};'
BODY_TWO_TRUTHY='var a={includeWorktrees:!0},b={includeWorktrees:!0};module.exports={a,b};'
BODY_UNSUPPORTED='var a={includeWorktrees: false};module.exports={a};'
BODY_ABSENT='var a={somethingElse:!1};module.exports={a};'
BODY_DYNAMIC='function f({includeWorktrees:i}){return i}module.exports={f};'

# `!10` is valid JS and evaluates to false, but the char after `!1` is a digit, so
# the delimiter rule must reject it as a literal patch site -> unknown -> refused.
BODY_UNKNOWN='var a={includeWorktrees:!10};module.exports={a};'
# Bare `true` (no leading space) — the space in BODY_UNSUPPORTED is optional.
BODY_UNSUPPORTED_TRUE='var a={includeWorktrees:true};module.exports={a};'
# Valid single literal delimited by `)` and by `;` — punctuation other than `,`/`}`
# must not be over-rejected by the delimiter rule. Inside the anchor both keys sit within
# `(...)`, which counts as nesting, so the default method refuses them; --legacy-single-literal patches.
BODY_PAREN_FALSY='var includeWorktrees=1,o={sessionListOptions(){return{z:(0?includeWorktrees:!1)}}};module.exports={o};'
BODY_SEMI_FALSY='var includeWorktrees=1,z=0?includeWorktrees:!1;module.exports={z};'
# `;` delimiter inside an arrow-function body within the anchor literal (nested -> refused by default).
BODY_SEMI_ANCHORED='var includeWorktrees=1,o={sessionListOptions(){return{z:(()=>{var y=0?includeWorktrees:!1;return y})()}}};module.exports={o};'
# Exactly one literal site plus a genuine syntax error (unclosed function body):
# classifies `unpatched`, so only the baseline `node --check` can refuse it.
BODY_BAD_SYNTAX='var a={sessionListOptions(){return{includeWorktrees:!1}}};function g(){module.exports={a};'

# Mixed-site bodies: exactly ONE valid literal (so neither the nLiteral===0 nor the
# nLiteral>=2 test fires) plus one unrecognised site. The `nUnsupported + nUnknown > 0`
# test sits FIRST in the decision order, so all four must classify `refused` — an
# ordering slip would report `unpatched` (and PATCH a file holding a site the tool does
# not understand) or `already` (and silently walk past it).
BODY_FALSY_UNKNOWN='var a={includeWorktrees:!1},b={includeWorktrees:!10};module.exports={a,b};'
BODY_FALSY_UNSUPPORTED='var a={includeWorktrees:!1},b={includeWorktrees: false};module.exports={a,b};'
BODY_TRUTHY_UNKNOWN='var a={includeWorktrees:!0},b={includeWorktrees:!10};module.exports={a,b};'
BODY_TRUTHY_UNSUPPORTED='var a={includeWorktrees:!0},b={includeWorktrees: false};module.exports={a,b};'

# The key is the last thing in the file — classifyValue receives the empty string,
# which falls through every anchored shape to `unknown` -> refused (NOT `absent`).
BODY_KEY_AT_EOF='var a={includeWorktrees:'
# A zero-byte bundle: no key at all -> `absent`, exit 0, nothing written.
BODY_EMPTY=''

# ---- parts -----------------------------------------------------------------

# shellcheck source=./bin-vscode-cc-repair/patch-lifecycle.sh
. "$PARTS_DIR/patch-lifecycle.sh"
# shellcheck source=./bin-vscode-cc-repair/classifier-verdicts.sh
. "$PARTS_DIR/classifier-verdicts.sh"
# shellcheck source=./bin-vscode-cc-repair/guard-cli.sh
. "$PARTS_DIR/guard-cli.sh"
# shellcheck source=./bin-vscode-cc-repair/failclosed-paths.sh
. "$PARTS_DIR/failclosed-paths.sh"
# shellcheck source=./bin-vscode-cc-repair/byte-integrity.sh
. "$PARTS_DIR/byte-integrity.sh"
# shellcheck source=./bin-vscode-cc-repair/cli-args.sh
. "$PARTS_DIR/cli-args.sh"
# shellcheck source=./bin-vscode-cc-repair/root-discovery.sh
. "$PARTS_DIR/root-discovery.sh"
# shellcheck source=./bin-vscode-cc-repair/dir-matching.sh
. "$PARTS_DIR/dir-matching.sh"
# shellcheck source=./bin-vscode-cc-repair/report-format.sh
. "$PARTS_DIR/report-format.sh"
# shellcheck source=./bin-vscode-cc-repair/packaging.sh
. "$PARTS_DIR/packaging.sh"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
