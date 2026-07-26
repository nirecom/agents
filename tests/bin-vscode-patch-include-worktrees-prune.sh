#!/usr/bin/env bash
# tests/bin-vscode-patch-include-worktrees-prune.sh
# Tests: bin/vscode-patch-include-worktrees, bin/lib/vscode-patch-include-worktrees/prune.js, bin/lib/vscode-patch-include-worktrees/prune/verify.js, bin/lib/vscode-patch-include-worktrees/cli.js
# Tags: bin, vscode, prune, session-files, scope:common, pwsh-not-required, TL2
#
# The `--prune-stub-sessions` path: scan ~/.claude/projects for title-only stub
# session files and delete only those whose content is provably a subset of a
# surviving counterpart copy. This is a NEW suite; the shipped patch path keeps its
# own suite (tests/bin-vscode-patch-include-worktrees.sh) which must stay untouched
# so that "the existing 10 parts are still green" remains the evidence that the
# module migration preserved behaviour.
#
# Run wrapper: bin/run-with-timeout.sh 120 bash tests/bin-vscode-patch-include-worktrees-prune.sh
# (every inner CLI / node invocation carries its own shorter timeout below).
#
# ISOLATION CONTRACT (intent.md Constraints — the single most important property
# of this suite). The tool under test deletes files out of the user's own Claude
# Code session storage, so a test that leaks onto the real host is not a flaky
# test, it is data loss. Three overrides are applied on EVERY invocation:
#   1. --extensions-dir <tmp>       — the prune flag is ADDITIVE, so the patch path
#                                     still runs and would otherwise scan ~/.vscode*
#   2. --claude-projects-dir <tmp>  — replaces the ~/.claude/projects default
#   3. HOME / USERPROFILE = <tmp>   — belt and braces: even a dropped override
#                                     lands in a fixture tree, never in the real home
# run_cli_prune supplies all three; run_iso is the lower-level form used by the
# argument-rejection tables and always still supplies 1 and 3.
#
# TL3 gap (what this test does NOT catch):
# - the real ~/.claude/projects tree (164 slugs, 7,196 .jsonl, ~3.3 GB): scan cost,
#   the real distribution of duplicate basenames, and the real record shapes are
#   fixture-approximated here. Only a read-only --dry-run against the live tree
#   (detail plan R10) measures those.
# - a genuinely concurrent writer landing between the re-verification and the
#   unlink syscall (the residual TOCTOU window, detail plan R11). The R-1..R-9 rows
#   in lifecycle-race.sh drive the real deletion path with a deterministic mutation
#   injected between planPruneRoots and executePrunePlan, which is strictly stronger
#   than nothing but is still not a real race.
# - POSIX permission semantics on the Windows host: every EACCES-shaped row
#   (unreadable file, unreadable directory, unlink failure, R-6) degrades to a
#   documented SKIP when chmod is advisory. See the Skipped-Because blocks.
# - `changed` reached through a spawned CLI process: 6.6 of the detail plan rules
#   out timing-dependent injection into a live subprocess as inherently flaky, so
#   the `changed` exit-code row is pinned at the module boundary instead.
# Documented SKIP categories (each increments SKIP and prints why):
# - EACCES rows (D08/D09, F-exit unreadable/scan-error/failed, R-6): chmod is
#   advisory on this host, or the test runs as root
# - symlink rows (D03): `ln -s` yields a copy, not a link, on this host
# - unreadable-by-EISDIR row (A22): the host does not fault on opening a directory
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: installer.

set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/bin/vscode-patch-include-worktrees"
REQUIRE_PATH="./bin/vscode-patch-include-worktrees"
LIB_DIR="$AGENTS_DIR/bin/lib/vscode-patch-include-worktrees"
LIB_REL="bin/lib/vscode-patch-include-worktrees"
PARTS_DIR="$AGENTS_DIR/tests/bin-vscode-patch-include-worktrees-prune"

if [ ! -f "$SCRIPT" ]; then
  echo "SKIP (RED): $SCRIPT not yet implemented — TDD RED phase"
  exit 77
fi

TMPROOT="$(mktemp -d)"
# chmod 000 fixtures would otherwise defeat the teardown.
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
SKIP=0

# ---- helpers ---------------------------------------------------------------

run_with_timeout() { "$AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }

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

# Whole-token match so `pruned` never matches `would-prune` and `kept` never
# matches the `kept=0` counter inside the prune-summary line.
check_token() {
  local desc="$1" tok="$2" hay="$3"
  if grep -qE -- "(^|[[:space:]])${tok}([[:space:]]|\$)" <<< "$hay"; then
    echo "PASS: $desc"; PASS=$((PASS + 1))
  else echo "FAIL: $desc -- token [$tok] not in: $hay"; FAIL=$((FAIL + 1)); fi
}

check_no_token() {
  local desc="$1" tok="$2" hay="$3"
  if grep -qE -- "(^|[[:space:]])${tok}([[:space:]]|\$)" <<< "$hay"; then
    echo "FAIL: $desc -- unexpected token [$tok] in: $hay"; FAIL=$((FAIL + 1))
  else echo "PASS: $desc"; PASS=$((PASS + 1)); fi
}

check_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then echo "PASS: $desc"; PASS=$((PASS + 1))
  else echo "FAIL: $desc -- missing: $path"; FAIL=$((FAIL + 1)); fi
}

check_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then echo "FAIL: $desc -- exists: $path"; FAIL=$((FAIL + 1))
  else echo "PASS: $desc"; PASS=$((PASS + 1)); fi
}

skip_case() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

bytes() { wc -c < "$1" | tr -d '[:space:]'; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d '[:space:]'; }

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else cksum "$1" | awk '{print $1"-"$2}'; fi
}

# Native form of a fixture path: on Windows `pwd -W` yields C:/... which is the only
# spelling Node's fs accepts. Never a hardcoded path.
native_path() { (cd "$1" && pwd -W 2>/dev/null || pwd); }

# Native form of a FILE path (the parent directory must already exist).
native_file() { printf '%s/%s' "$(native_path "$(dirname "$1")")" "$(basename "$1")"; }

new_dir() { mktemp -d "$TMPROOT/d.XXXXXX"; }

# size:mtimeMs, read through node so no stat(1) dialect (GNU vs BSD) is assumed.
stat_sig() {
  S_F="$(native_file "$1")" run_with_timeout 30 node -e \
    'const s=require("fs").statSync(process.env.S_F);console.log(s.size+":"+s.mtimeMs);'
}

# POSIX permission denial, with a proof that it actually took effect. On MSYS /
# Windows chmod is advisory and on a root-run CI the bits are ignored, so a naive
# `chmod 000` would produce a false PASS. Returns non-zero in those cases and the
# caller emits a documented SKIP instead.
deny_read() { # <path>
  chmod 000 "$1" 2>/dev/null || return 1
  if [ -d "$1" ]; then
    if ls "$1" >/dev/null 2>&1; then chmod 755 "$1" 2>/dev/null || true; return 1; fi
  else
    if head -c 1 "$1" >/dev/null 2>&1; then chmod 644 "$1" 2>/dev/null || true; return 1; fi
  fi
  return 0
}

# Read-only parent directory: the only portable-ish way to make unlink() fail
# without a fault-injection seam in production code.
deny_unlink() { # <dir>
  chmod 555 "$1" 2>/dev/null || return 1
  if : > "$1/.deny-probe" 2>/dev/null; then
    rm -f "$1/.deny-probe" 2>/dev/null || true
    chmod 755 "$1" 2>/dev/null || true
    return 1
  fi
  return 0
}

allow_read() { chmod -R u+rwx "$1" >/dev/null 2>&1 || true; }

# Directory alias, same mechanism as the patch suite. Returns non-zero when neither
# a POSIX symlink nor a Windows junction is usable, so the caller emits a SKIP.
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

make_file_alias() { # <link> <target>
  ln -s "$2" "$1" 2>/dev/null || return 1
  [ -L "$1" ] || return 1
  return 0
}

# ---- fixture vocabulary ----------------------------------------------------

# Valid session basenames: SESSION_FILE_PATTERN is a plain UUID + .jsonl.
SID_A='11111111-2222-3333-4444-555555555555'
SID_B='66666666-7777-8888-9999-aaaaaaaaaaaa'
SID_C='bbbbbbbb-cccc-dddd-eeee-ffffffffffff'

# A distinctive title string used only by the privacy pin: it must never reach
# stdout or stderr, because the report is expected to carry counts, not titles.
SECRET_TITLE='ZZPRIVATETITLEMARKERZZ'

title_line() { # <sessionId> <customTitle>
  printf '{"type":"custom-title","sessionId":"%s","customTitle":"%s"}\n' "$1" "$2"
}
# A custom-title record carrying a field outside KNOWN_TITLE_FIELDS: the extra
# information cannot be proven present in a counterpart, so it must block `stub`.
title_line_extra() { # <sessionId> <customTitle>
  printf '{"type":"custom-title","sessionId":"%s","customTitle":"%s","pinnedAt":123}\n' "$1" "$2"
}
ai_title_line() { # <sessionId> <title>
  printf '{"type":"ai-title","sessionId":"%s","aiTitle":"%s"}\n' "$1" "$2"
}
content_line() { # <sessionId> [type]
  printf '{"type":"%s","sessionId":"%s","message":{"role":"user","content":"hello"}}\n' \
    "${2:-user}" "$1"
}
# A content record with no sessionId at all — the "malformed content line" shape.
content_line_nosid() { printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'; }
# The codex-review audit-log shape: a well-formed object with no `type` field.
notype_line() { printf '{"role":"user","content":"audit entry"}\n'; }
broken_line() { printf '{"type":"user","sessionId":\n'; }
nonobject_line() { printf '"a bare string, not an object"\n'; }
blank_line() { printf '\n'; }

# Writes a session file named <sid>.jsonl into <dir>; the body arrives on stdin.
mk_session() { # <dir> <sid>
  mkdir -p "$1"
  cat > "$1/$2.jsonl"
}
session_path() { printf '%s/%s.jsonl' "$1" "$2"; }

# Large fixtures are generated by node, not by a bash loop: the scan-cap tests must
# land on an EXACT byte boundary (CLASSIFY_MAX_SCAN = 1 MiB), and 8k+ shell-issued
# writes are far too slow. Every filler line is padded to exactly 128 bytes
# (newline included) so <filler-bytes> is hit precisely.
gen_big() { # <path> <sid> <filler-bytes> <kind:title|garbage> <lead:content|none> <tail:content|none>
  G_PATH="$(native_file "$1")" G_SID="$2" G_BYTES="$3" G_KIND="$4" G_LEAD="$5" G_TAIL="$6" \
    run_with_timeout 120 node -e '
const fs = require("fs");
const sid = process.env.G_SID;
const want = Number(process.env.G_BYTES);
const LINEW = 128;
const content =
  JSON.stringify({ type: "user", sessionId: sid, message: { role: "user", content: "hello" } }) + "\n";
let line;
if (process.env.G_KIND === "title") {
  const base = JSON.stringify({ type: "custom-title", sessionId: sid, customTitle: "" });
  line = JSON.stringify({
    type: "custom-title", sessionId: sid, customTitle: "t".repeat(LINEW - 1 - base.length),
  }) + "\n";
} else {
  line = "{" + "x".repeat(LINEW - 2) + "\n";
}
if (Buffer.byteLength(line) !== LINEW) {
  console.error("filler line width " + Buffer.byteLength(line) + " != " + LINEW);
  process.exit(1);
}
if (want % LINEW !== 0) { console.error("filler byte count is not a multiple of " + LINEW); process.exit(1); }
const fd = fs.openSync(process.env.G_PATH, "w");
if (process.env.G_LEAD === "content") fs.writeSync(fd, content);
const block = line.repeat(512);
let filled = 0;
while (filled + block.length <= want) { fs.writeSync(fd, block); filled += block.length; }
while (filled < want) { fs.writeSync(fd, line); filled += LINEW; }
if (process.env.G_TAIL === "content") fs.writeSync(fd, content);
fs.closeSync(fd);
'
}

CLASSIFY_MAX_SCAN=1048576
VERIFY_MAX_SCAN=67108864

# ---- invocation helpers ----------------------------------------------------

# The fixture HOME shared by every direct module call. Created once; nothing in
# this suite ever reads the real home.
ISO_HOME="$TMPROOT/iso-home"
mkdir -p "$ISO_HOME"
ISO_HOME_NATIVE="$(native_path "$ISO_HOME")"

# Direct module access. HOME/USERPROFILE are redirected here too: resolvePruneRoots
# falls back to os.homedir() when no override is passed, and a bug there must not be
# able to reach the real ~/.claude/projects.
node_m() { # <js> ; sets NODE_RC / NODE_OUT
  NODE_RC=0
  NODE_OUT="$(cd "$AGENTS_DIR" && HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
    run_with_timeout 120 node -e "$1" 2>&1)" || NODE_RC=$?
}

# Lower-level CLI form: fixture HOME + a fixture --extensions-dir, nothing else.
# Used by rows that deliberately omit --prune-stub-sessions or pass a deliberately
# bad --claude-projects-dir. The --extensions-dir override is NOT optional even
# there: --prune-stub-sessions is additive, so the patch path always runs.
run_iso() { # <fixture-home> <ext-root> [args...] ; sets CLI_RC / CLI_OUT
  local h="$1" e="$2"; shift 2
  CLI_RC=0
  CLI_OUT="$(HOME="$h" USERPROFILE="$(native_path "$h")" run_with_timeout 60 \
    node "$SCRIPT" --extensions-dir "$(native_path "$e")" "$@" 2>&1)" || CLI_RC=$?
}

run_iso_split() { # <fixture-home> <ext-root> [args...] ; sets CLI_RC / CLI_STDOUT / CLI_STDERR
  local h="$1" e="$2"; shift 2
  local ef
  ef="$(mktemp "$TMPROOT/stderr.XXXXXX")"
  CLI_RC=0
  CLI_STDOUT="$(HOME="$h" USERPROFILE="$(native_path "$h")" run_with_timeout 60 \
    node "$SCRIPT" --extensions-dir "$(native_path "$e")" "$@" 2>"$ef")" || CLI_RC=$?
  CLI_STDERR="$(cat "$ef")"
}

# The standard prune invocation: all three isolation overrides, every time.
run_cli_prune() { # <fixture-home> <ext-root> <projects-root> [args...]
  local h="$1" e="$2" p="$3"; shift 3
  run_iso "$h" "$e" --prune-stub-sessions --claude-projects-dir "$(native_path "$p")" "$@"
}

run_cli_prune_split() { # <fixture-home> <ext-root> <projects-root> [args...]
  local h="$1" e="$2" p="$3"; shift 3
  run_iso_split "$h" "$e" --prune-stub-sessions --claude-projects-dir "$(native_path "$p")" "$@"
}

# A fixture home with no .claude/projects and no .vscode* — the default-root scan
# finds nothing, so a dropped override can only ever report zero roots.
new_home() { local h; h="$(mktemp -d "$TMPROOT/home.XXXXXX")"; printf '%s' "$h"; }
new_ext_root() { local e; e="$(mktemp -d "$TMPROOT/ext.XXXXXX")"; printf '%s' "$e"; }
new_proj_root() { local p; p="$(mktemp -d "$TMPROOT/proj.XXXXXX")"; printf '%s' "$p"; }

# First report line for a given prune state token.
prune_line() { # <state> <cli-output>
  grep -E "^$1[[:space:]]" <<< "$2" | head -1 || true
}
prune_roots_lines() { grep -E '^prune-root: ' <<< "$1" || true; }

EXT_DIR_A="anthropic.claude-code-1.0.0"
# Exactly one patchable literal — the patch path reports `patched`.
BODY_FALSY='function f({includeWorktrees:i}){return i}var o={includeWorktrees:!1};module.exports={f,o};'
# Two literals — the patch path refuses, contributing 1 to the exit code.
BODY_TWO_FALSY='var a={includeWorktrees:!1},b={includeWorktrees:!1};module.exports={a,b};'

make_ext_dir() { # <root> <dir-name> <js-body>
  mkdir -p "$1/$2"
  printf '%s' "$3" > "$1/$2/extension.js"
}

STDERR_PREFIX='[vscode-patch-include-worktrees] '

# ---- parts -----------------------------------------------------------------

# shellcheck source=./bin-vscode-patch-include-worktrees-prune/classifier.sh
. "$PARTS_DIR/classifier.sh"
# shellcheck source=./bin-vscode-patch-include-worktrees-prune/planner-verify.sh
. "$PARTS_DIR/planner-verify.sh"
# shellcheck source=./bin-vscode-patch-include-worktrees-prune/scan.sh
. "$PARTS_DIR/scan.sh"
# shellcheck source=./bin-vscode-patch-include-worktrees-prune/lifecycle-race.sh
. "$PARTS_DIR/lifecycle-race.sh"
# shellcheck source=./bin-vscode-patch-include-worktrees-prune/cli-exit-codes.sh
. "$PARTS_DIR/cli-exit-codes.sh"
# shellcheck source=./bin-vscode-patch-include-worktrees-prune/packaging-structural.sh
. "$PARTS_DIR/packaging-structural.sh"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
