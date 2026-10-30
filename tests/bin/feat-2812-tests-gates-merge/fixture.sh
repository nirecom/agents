# Tests: hooks/pre-commit
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, scope:issue-specific
# Fixture repos, bodies and gate runners for tests/bin/feat-2812-tests-gates-merge.sh (sourced by it,
# after tests/lib/harness.sh, harness_isolate and TMPBASE). A merge fixture is a real
# `git merge --no-commit --no-ff` left in progress, with the resolution staged by the case.
# shellcheck shell=bash
# shellcheck disable=SC2016 # body lines hold literal $(...) text on purpose

# Node takes the checkout root in its own path form (a /c/... path is not one on Windows).
GATE_CFG="$SCRIPT_CHECKOUT_ROOT"
command -v cygpath >/dev/null 2>&1 && GATE_CFG="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
SI_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-self-impl.sh"
LM_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-test-language-match.sh"
FM_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-test-frontmatter.sh"
BODIES="$TMPBASE/bodies"
mkdir -p "$BODIES"
FG=frontmatter-gate
CM=case-markers-gate
LG=language-match-gate
NOTE_HEAD="pre-commit: merge parents "
NOTE_TAIL=" — tests/ gates judge against HEAD only"

# The marker words are split so this file's own reader never takes the fixture lines for markers.
MB="case""_begin"
ME="case""_end"
SRC='source "$(dirname "$0")/../../tests/lib/harness.sh"'

# mcase <name> <target> [<word>] — one marked bash case (three lines).
mcase() { printf '%s "%s" "%s"\necho %s\n%s' "$MB" "$1" "$2" "${3:-$1}" "$ME"; }
# hdr <tests-csv> [<tags>] — the four header lines of a bash test (helper library loaded).
hdr() { printf '%s\n# Tests: %s\n# Tags: %s\n%s' '#!/usr/bin/env bash' "$1" "${2:-scope:issue-specific}" "$SRC"; }
# raw <name> <line>... — $BODIES/<name>, one argument per line.
raw() {
  local out="$BODIES/$1"
  shift
  printf '%s\n' "$@" > "$out"
}

# mkrepo <dir> — a fixture repo whose first commit carries the helper library and the code files.
mkrepo() {
  local d="$1" f
  harness_git_init "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" config core.autocrlf false
  mkdir -p "$d/tests/lib" "$d/tests/bin" "$d/bin"
  printf '\n' > "$d/tests/lib/harness.sh"
  for f in bin/a.sh bin/foo.sh bin/bar.sh bin/foo.js bin/bar.js; do printf '\n' > "$d/$f"; done
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m init >/dev/null 2>&1
}

# apply <repo> <pairs> — each whitespace-separated "<rel>=<body>" writes the body, "<rel>=-" removes rel.
apply() {
  local repo="$1" p rel b
  for p in $2; do
    rel="${p%%=*}"; b="${p#*=}"
    if [ "$b" = "-" ]; then
      rm -f "$repo/$rel"
    else
      mkdir -p "$(dirname "$repo/$rel")"
      cp "$BODIES/$b" "$repo/$rel"
    fi
  done
}
commit_all() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q -m "$2" >/dev/null 2>&1
}

# mergefx <dir> <base-pairs> <up-pairs> <head-pairs> <staged-pairs> — base commit, an `up`
# branch (MERGE_HEAD) and the current branch (HEAD) each with their pairs, an unfinished
# `git merge --no-commit --no-ff up`, then the staged resolution. Fails the case without MERGE_HEAD.
mergefx() {
  local d="$1"
  mkrepo "$d"
  apply "$d" "$2"; commit_all "$d" base
  git -C "$d" checkout -q -b up
  apply "$d" "$3"; printf 'up\n' > "$d/up.txt"; commit_all "$d" up
  git -C "$d" checkout -q -
  apply "$d" "$4"; printf 'head\n' > "$d/head.txt"; commit_all "$d" head
  git -C "$d" merge --no-commit --no-ff -q up >/dev/null 2>&1 || true
  apply "$d" "$5"
  git -C "$d" add -A >/dev/null 2>&1
  if git -C "$d" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    pass "fixture ${d##*/}: merge in progress"
  else
    fail "fixture ${d##*/}" "no MERGE_HEAD after the fixture merge"
  fi
}

# crissfx <dir> <base-pairs> <up-pairs> <head-pairs> <staged-pairs> — mergefx with two merge-bases:
# x and y cross-merge each other's first commit before the final x <- y merge.
crissfx() {
  local d="$1" x1
  mkrepo "$d"
  apply "$d" "$2"; commit_all "$d" base
  git -C "$d" checkout -q -b y
  printf 'y1\n' > "$d/y.txt"; commit_all "$d" y1
  git -C "$d" checkout -q -b x HEAD~1
  printf 'x1\n' > "$d/x.txt"; commit_all "$d" x1
  x1="$(git -C "$d" rev-parse HEAD)"
  git -C "$d" merge -q --no-ff -m mx y >/dev/null 2>&1
  git -C "$d" checkout -q y
  git -C "$d" merge -q --no-ff -m my "$x1" >/dev/null 2>&1
  apply "$d" "$3"; commit_all "$d" up
  git -C "$d" checkout -q x
  apply "$d" "$4"; commit_all "$d" head
  git -C "$d" merge --no-commit --no-ff -q y >/dev/null 2>&1 || true
  apply "$d" "$5"
  git -C "$d" add -A >/dev/null 2>&1
  assert_eq "fixture ${d##*/}: merge-bases=$(git -C "$d" merge-base --all HEAD MERGE_HEAD | wc -l | tr -d ' ')" \
    "fixture ${d##*/}: merge-bases=2"
}

# gate <repo> <gate>... — the named Node pre-commit gate modules (FG/CM/LG above), in one process,
# with <repo> as cwd and the context, snapshot and merge detection built as hooks/pre-commit.d/main.js
# builds them. Every staged file goes to the gate (no merge narrowing), so the gate itself must judge
# a merge against its parents. GATE_MP_MODE=fail makes the merge-parents resolver throw; =log appends
# one line per resolver call to GATE_MP_LOG. Sets GATE_RC GATE_OUT GATE_ERR GATE_ALL; GATE_PATH
# replaces PATH. rc 98: a module failed to load.
GATE_DRIVER="$TMPBASE/gate-driver.js"
printf '%s\n' \
  '"use strict";' \
  'const path = require("path");' \
  'const fs = require("fs");' \
  'const cfg = process.argv[2];' \
  'const names = process.argv.slice(3);' \
  'const mode = process.env.GATE_MP_MODE || "";' \
  'let R, output, gates, buildContext, createSnapshot, detect;' \
  'try {' \
  '  if (mode) {' \
  '    const mp = require(path.join(cfg, "hooks/lib/merge-parents"));' \
  '    const real = mp.resolveMergeParents;' \
  '    mp.resolveMergeParents = (...a) => {' \
  '      if (mode === "fail") throw new Error("resolver forced to fail");' \
  '      fs.appendFileSync(process.env.GATE_MP_LOG, "resolve\n");' \
  '      return real(...a);' \
  '    };' \
  '  }' \
  '  R = require(path.join(cfg, "hooks/lib/test-gates/registry"));' \
  '  output = require(path.join(cfg, "hooks/pre-commit.d/output"));' \
  '  ({ buildContext } = require(path.join(cfg, "hooks/pre-commit.d/context")));' \
  '  ({ createSnapshot } = require(path.join(cfg, "hooks/pre-commit.d/snapshot")));' \
  '  ({ detectMergeIncoming: detect } = require(path.join(cfg, "hooks/lib/merge-incoming")));' \
  '  gates = names.map((n) => require(path.join(cfg, "hooks/pre-commit.d/checks/tests-frontmatter", n)).gate);' \
  '} catch (e) { process.stderr.write(`gate-driver: load: ${e.message}\n`); process.exit(98); }' \
  '(async () => {' \
  '  const env = process.env;' \
  '  const repoTop = process.cwd();' \
  '  const context = await buildContext({ cfgDir: cfg, repoTop, env, isTTY: false });' \
  '  const snapshot = await createSnapshot({ repoTop, env });' \
  '  const files = await snapshot.files();' \
  '  context.merge = detect(repoTop, files);' \
  '  let rc = 0;' \
  '  for (const g of gates) {' \
  '    const r = R.withEnv(env, () => g({ context, snapshot, files }));' \
  '    output.writeMessages(r.messages);' \
  '    if (r.block) rc = 1;' \
  '  }' \
  '  return rc;' \
  '})().then((rc) => { process.exitCode = rc; }, (e) => { process.stderr.write(`gate-driver: ${(e && e.stack) || e}\n`); process.exitCode = 97; });' \
  > "$GATE_DRIVER"
GATE_RC=0; GATE_OUT=""; GATE_ERR=""; GATE_ALL=""; GATE_PATH=""
gate() {
  local repo="$1"
  shift
  GATE_RC=0
  (
    cd "$repo" || exit 99
    [ -n "$GATE_PATH" ] && PATH="$GATE_PATH"
    bash "$RWT" 90 node "$GATE_DRIVER" "$GATE_CFG" "$@"
  ) >"$TMPBASE/gate.out" 2>"$TMPBASE/gate.err" || GATE_RC=$?
  GATE_OUT="$(cat "$TMPBASE/gate.out")"
  GATE_ERR="$(cat "$TMPBASE/gate.err")"
  GATE_ALL="$GATE_OUT"$'\n'"$GATE_ERR"
}

# cli <repo> <script> <arg>... — a checker CLI with <repo> as cwd. Sets CLI_RC CLI_OUT CLI_ERR.
CLI_RC=0; CLI_OUT=""; CLI_ERR=""
cli() {
  local repo="$1" script="$2"
  shift 2
  CLI_RC=0
  (
    cd "$repo" || exit 99
    bash "$RWT" 90 bash "$script" "$@"
  ) >"$TMPBASE/cli.out" 2>"$TMPBASE/cli.err" || CLI_RC=$?
  CLI_OUT="$(cat "$TMPBASE/cli.out")"
  CLI_ERR="$(cat "$TMPBASE/cli.err")"
}

# count_code <text> <code> — lines of <text> naming the code (code=<code> or a leading <code>:).
count_code() {
  local line n=0
  while IFS= read -r line; do
    case "$line" in
      *"code=$2"*|"$2:"*) n=$((n + 1)) ;;
    esac
  done <<< "$1"
  printf '%s' "$n"
}
# count_note <text> — lines that are the mp_note fallback line.
count_note() {
  local line n=0
  while IFS= read -r line; do
    case "$line" in
      "$NOTE_HEAD"*"$NOTE_TAIL") n=$((n + 1)) ;;
    esac
  done <<< "$1"
  printf '%s' "$n"
}

# expect_rc <label> <want> <got> <detail>
expect_rc() {
  if [ "$3" = "$2" ]; then pass "$1: rc=$2"; else fail "$1" "want rc=$2 got rc=$3: $4"; fi
}
# expect_codes <label> <text> <code> <want-count>
expect_codes() {
  local n
  n="$(count_code "$2" "$3")"
  if [ "$n" = "$4" ]; then pass "$1: $3 x$4"; else fail "$1" "want $3 x$4 got x$n: $2"; fi
}
# has <label> <haystack> <fixed-string>
has() {
  case "$2" in
    *"$3"*) pass "$1: has [$3]" ;;
    *) fail "$1" "lacks [$3]: $2" ;;
  esac
}
