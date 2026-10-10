#!/usr/bin/env bash
# tests/mutation/root-names.sh — detection-power probe for the four root names (never runs
# automatically: tests/mutation/ is outside the run-all categories). Per row of the target table
# it rewrites ONE site of one file to a wrong root name, asks the static check (that file only),
# then the dynamic tests (run_all_exec, root decoy in place), and restores the file.
# Usage: bash tests/mutation/root-names.sh [--dry-run | --verify] [--targets <tsv>] [--test-timeout <s>]
# Output: <verdict> TAB <kind> TAB <file> TAB layer=<...> TAB <detail>, one line per row.
# Exit: 0 all killed by a value; 1 a LIVE row; 2 a NOT RUN (a test over the time limit included)
# or KILLED-CRASH row (no LIVE); 3 refused (usage, main worktree, uncommitted target, unreadable
# table, decoy unavailable) or LEAKED (a test changed the checkout). --dry-run/--verify rewrite no file.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -uo pipefail

refuse() { printf 'root-names mutation: %s\n' "$1" >&2; exit 3; }

DRY_RUN=0
VERIFY=0
TARGETS="$SCRIPT_CHECKOUT_ROOT/tests/mutation/root-names-targets.tsv"
# Seconds one test, one static check or one finder call may take. Above every limit the test
# language registry sets (launch.timeoutSeconds, 180 at most), so a registered limit still ends
# its test first; this one stops what the registry leaves unlimited (every bash test).
TEST_TIMEOUT=600
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --targets) [[ "$#" -ge 2 ]] || refuse "--targets requires a value"; TARGETS="$2"; shift 2 ;;
    --test-timeout) [[ "$#" -ge 2 ]] || refuse "--test-timeout requires a value"; TEST_TIMEOUT="$2"; shift 2 ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
[[ "$TEST_TIMEOUT" =~ ^[1-9][0-9]{0,5}$ ]] || refuse "--test-timeout must be a positive whole number of seconds: $TEST_TIMEOUT"
if command -v cygpath >/dev/null 2>&1; then SCRIPT_CHECKOUT_ROOT="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"; fi
[[ -r "$TARGETS" ]] || refuse "target table is not readable: $TARGETS"

KINDS=" script-to-main main-to-script target-checkout-to-script target-main-to-target-checkout bare-main-assign export-script-root "
ROW_KIND=()
ROW_FILE=()
ROW_NTH=()
ROW_TESTS=()
TAB=$'\t'
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -n "${line//[[:space:]]/}" && "${line#\#}" == "$line" ]] || continue
  kind="${line%%"$TAB"*}"
  rest=""
  [[ "$line" == *"$TAB"* ]] && rest="${line#*"$TAB"}"
  file="${rest%%"$TAB"*}"
  tests=""
  [[ "$rest" == *"$TAB"* ]] && tests="${rest#*"$TAB"}"
  tests="${tests//[,$TAB]/ }"
  nth=1
  if [[ "$file" =~ ^(.+)#([1-9][0-9]*)$ ]]; then file="${BASH_REMATCH[1]}"; nth="${BASH_REMATCH[2]}"; fi
  [[ "$KINDS" == *" $kind "* ]] || refuse "unknown mistake kind in $TARGETS: $kind"
  [[ -n "$file" && "$file" != /* && "$file" != *..* ]] || refuse "target must be a path inside the checkout: $file"
  [[ -f "$SCRIPT_CHECKOUT_ROOT/$file" ]] || refuse "target file does not exist: $file"
  ROW_KIND+=("$kind")
  ROW_FILE+=("$file")
  ROW_NTH+=("$nth")
  ROW_TESTS+=("$tests")
done <"$TARGETS"
[[ "${#ROW_KIND[@]}" -gt 0 ]] || refuse "target table has no rows: $TARGETS"

if [[ "$DRY_RUN" -eq 1 ]]; then
  for i in "${!ROW_KIND[@]}"; do
    printf 'PLAN\t%s\t%s\t%s\n' "${ROW_KIND[$i]}" "${ROW_FILE[$i]}" "${ROW_TESTS[$i]:-(bin/find-tests-for-source.sh)}"
  done
  exit 0
fi

# apply_mutation <kind> <file> <nth> [check] — rewrites the nth line holding a site and prints
# "<line> TAB <resolved|unresolved> TAB <rewritten line>"; exit 3 when the file holds no such
# site. "unresolved" = the rewrite leaves a name the file never defines, so the mutant can only
# crash. With "check" the site is located and rewritten in memory only.
apply_mutation() {
  node - "$1" "$SCRIPT_CHECKOUT_ROOT" "$2" "$3" "${4:-write}" <<'MUTATE_JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [kind, root, rel, nth, mode] = process.argv.slice(2);
const file = path.join(root, rel);
const SCRIPT = ["SCRIPT", "CHECKOUT", "ROOT"].join("_");
const MAIN = ["AGENTS", "MAIN", "ROOT"].join("_");
const T_CHECKOUT = ["TARGET", "CHECKOUT", "ROOT"].join("_");
const T_MAIN = ["TARGET", "MAIN", "ROOT"].join("_");
const camel = (s) => s.toLowerCase().replace(/_([a-z])/g, (_, c) => c.toUpperCase());
const text = fs.readFileSync(file, "utf8");
const eol = text.includes("\r\n") ? "\r\n" : "\n";
const lines = text.split(eol);
const first = lines[0] || "";
const isBash = /\.(sh|bash)$/.test(file) || /^#!.*\b(ba)?sh\b/.test(first);
const isJs = /\.(js|cjs|mjs)$/.test(file) || /^#!.*\bnode\b/.test(first);
const isComment = (l) => /^\s*(#|\/\/|\*|\/\*)/.test(l);
// What stands in for a name the file never defines: an expression with the value that name
// would hold, so the mutant computes a wrong value instead of dying on the missing name.
const up = path.relative(path.dirname(file), root).replace(/\\/g, "/") || ".";
const TOPLEVEL_JS = 'require("child_process").execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim()';
const BASH_EXPR = {
  [SCRIPT]: '$(cd "$(dirname "${BASH_SOURCE[0]}")/' + up + '" && pwd)',
  [T_CHECKOUT]: "$(git rev-parse --show-toplevel 2>/dev/null)",
};
const JS_EXPR = {
  [SCRIPT]: 'require("path").resolve(__dirname, "' + up + '")',
  [T_CHECKOUT]: TOPLEVEL_JS,
  [camel(T_CHECKOUT)]: TOPLEVEL_JS,
};
let resolved = true;
// Rewrite the nth line that matches and is neither a comment nor vetoed by `skip`.
function replaceNth(re, to, skip) {
  let seen = 0;
  for (let i = 0; i < lines.length; i++) {
    if (isComment(lines[i]) || (skip && skip(lines[i]))) continue;
    if (!re.test(lines[i])) continue;
    seen += 1;
    if (seen < Number(nth)) continue;
    lines[i] = lines[i].replace(re, to);
    return i + 1;
  }
  return 0;
}
const anyLine = (re) => lines.some((l) => !isComment(l) && re.test(l));
// A JS line that introduces the name rather than reading it.
const jsDeclares = (name) => (l) =>
  new RegExp("\\b(const|let|var)\\s+" + name + "\\b").test(l) ||
  new RegExp("\\bfunction\\b[^)]*\\b" + name + "\\b").test(l) ||
  new RegExp("\\b" + name + "\\b[^=]*=>").test(l) ||
  new RegExp("\\b" + name + "\\s*=[^=]").test(l);
const jsWord = (name) => new RegExp("\\b" + name + "\\b");
const jsKnows = (name) =>
  name.startsWith("process.env.") ||
  anyLine(new RegExp("\\b(const|let|var)\\b[^=;]*\\b" + name + "\\b")) ||
  lines.some((l) => !isComment(l) && jsDeclares(name)(l));
const bashKnows = (name) => name === MAIN || anyLine(new RegExp("(^|[^A-Za-z0-9_])" + name + "="));
// A bash read of `from` becomes a read of `to`; the sourced-library prefix is allowed for the
// script root. A ${NAME:-default} form keeps the name: an undefined name takes the default.
function bashRewrite(from, to, prefixed) {
  const re = new RegExp("\\$(\\{?)" + (prefixed ? "(?:_[A-Z0-9_]+_)?" : "") + from + "\\b(\\}|:?[-+])?");
  return replaceNth(re, (_m, brace, tail = "") => {
    const renamed = "$" + brace + to + tail;
    if (bashKnows(to) || (brace && tail !== "" && tail !== "}")) return renamed;
    if (BASH_EXPR[to] && (!brace || tail === "}")) return BASH_EXPR[to] + (brace ? "" : tail);
    resolved = false;
    return renamed;
  });
}
function jsRewrite(re, to, skip) {
  return replaceNth(re, () => {
    if (jsKnows(to)) return to;
    if (JS_EXPR[to]) return JS_EXPR[to];
    resolved = false;
    return to;
  }, skip);
}
let at = 0;
if (kind === "script-to-main") {
  if (isBash) at = bashRewrite(SCRIPT, MAIN, true);
  else if (isJs) at = jsRewrite(jsWord(SCRIPT), "process.env." + MAIN, jsDeclares(SCRIPT));
} else if (kind === "main-to-script") {
  if (isBash) at = bashRewrite(MAIN, SCRIPT, false);
  else if (isJs) at = jsRewrite(new RegExp("\\bprocess\\.env(\\." + MAIN + "\\b|\\[[\"']" + MAIN + "[\"']\\])"), SCRIPT);
} else if (kind === "target-checkout-to-script" || kind === "target-main-to-target-checkout") {
  const from = kind === "target-checkout-to-script" ? T_CHECKOUT : T_MAIN;
  const to = kind === "target-checkout-to-script" ? SCRIPT : T_CHECKOUT;
  if (isBash) at = bashRewrite(from, to, false);
  else if (isJs) {
    at = jsRewrite(jsWord(camel(from)), to === SCRIPT ? SCRIPT : camel(to), jsDeclares(camel(from)));
    if (!at) at = jsRewrite(jsWord(from), to, jsDeclares(from));
  }
} else if (kind === "bare-main-assign") {
  if (isBash) {
    at = /^#!/.test(first) ? 2 : 1;
    lines.splice(at - 1, 0, MAIN + '="/nonexistent/root-names-mutation"');
  }
} else if (kind === "export-script-root") {
  if (isBash) at = replaceNth(new RegExp("^(\\s*)((?:_[A-Z0-9_]+_)?" + SCRIPT + "=)"), "$1export $2");
}
if (!at) process.exit(3);
if (mode !== "check") fs.writeFileSync(file, lines.join(eol));
process.stdout.write([at, resolved ? "resolved" : "unresolved", lines[at - 1]].join("\t") + "\n");
MUTATE_JS
}
# split_site <apply_mutation output> — sets SITE_LINE, SITE_STATE, SITE_TEXT.
split_site() {
  local rest="${1#*"$TAB"}"
  SITE_LINE="${1%%"$TAB"*}"
  SITE_STATE="${rest%%"$TAB"*}"
  SITE_TEXT="${rest#*"$TAB"}"
  SITE_TEXT="${SITE_TEXT%$'\r'}"
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t root-names-mutation)" || refuse "cannot create a work directory"
if command -v cygpath >/dev/null 2>&1; then WORK="$(cygpath -m "$WORK")"; fi
readonly WORK
ACTIVE=""
CHILD_PID=""
restore() {
  if [[ -n "$ACTIVE" ]]; then
    cp -p "$WORK/backup" "$SCRIPT_CHECKOUT_ROOT/$ACTIVE" && ACTIVE=""
  fi
}
# kill_child — ends the running test with everything it started: dyn_run gives the test its own
# process group, so the signal goes to the group (to the one process where there is no group).
kill_child() {
  local n=0
  [[ -n "$CHILD_PID" ]] || return 0
  kill -TERM -- "-$CHILD_PID" 2>/dev/null || kill -TERM "$CHILD_PID" 2>/dev/null
  while kill -0 "$CHILD_PID" 2>/dev/null && [[ "$n" -lt 10 ]]; do sleep 0.2; n=$((n + 1)); done
  kill -KILL -- "-$CHILD_PID" 2>/dev/null || kill -KILL "$CHILD_PID" 2>/dev/null
  return 0
}
finish() {
  kill_child
  restore
  if [[ -n "$ACTIVE" ]]; then
    printf 'root-names mutation: RESTORE FAILED for %s; backup kept at %s/backup\n' "$ACTIVE" "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Nothing below may reach the real home: the finder and every test it launches write their
# caches, lanes and transcripts under the work directory. The identity keeps `git commit` usable.
unset CLAUDE_CODE_SESSION_ID
[[ -f "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" ]] || refuse "bin/run-with-timeout.sh is missing; nothing would be time-limited"
mkdir -p "$WORK/home" "$WORK/cache" "$WORK/transcripts" "$WORK/state/workflow" "$WORK/state/plans" \
  || refuse "cannot prepare the work directory"
export WORKFLOW_STATE_DIR="$WORK/state/workflow" WORKFLOW_PLANS_DIR="$WORK/state/plans"
printf '[user]\n\tname = root-names-mutation\n\temail = root-names-mutation@example.com\n' >"$WORK/home/.gitconfig"
export HOME="$WORK/home" USERPROFILE="$WORK/home"
export RUN_ALL_CACHE_DIR="$WORK/cache" CLAUDE_TRANSCRIPT_BASE_DIR="$WORK/transcripts"
# limited <command...> — the command under the time limit; 124 (142 without `timeout`) when over.
limited() { bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$TEST_TIMEOUT" "$@"; }

# select_tests <row index> — sets TESTS to the row's tests, else to what the finder names.
select_tests() {
  local found t
  TESTS="${ROW_TESTS[$1]}"
  [[ -z "$TESTS" ]] || return 0
  found="$(limited bash "$SCRIPT_CHECKOUT_ROOT/bin/find-tests-for-source.sh" --sources "${ROW_FILE[$1]}" --root "$SCRIPT_CHECKOUT_ROOT" 2>/dev/null | cut -f4 | tr -d '\r')" || found=""
  for t in $found; do [[ "$t" == "-" ]] || TESTS="$TESTS $t"; done
}

# --verify: a row is sound when it has a site, the rewrite leaves no undefined name, its listed
# tests exist, and (empty test column) the finder names at least one test.
if [[ "$VERIFY" -eq 1 ]]; then
  bad=0
  for i in "${!ROW_KIND[@]}"; do
    row="${ROW_KIND[$i]}$TAB${ROW_FILE[$i]}"
    bad=$((bad + 1))
    if ! site="$(apply_mutation "${ROW_KIND[$i]}" "${ROW_FILE[$i]}" "${ROW_NTH[$i]}" check)"; then
      printf 'NO-SITE\t%s\n' "$row"
      continue
    fi
    split_site "$site"
    if [[ "$SITE_STATE" != resolved ]]; then
      printf 'UNRESOLVED\t%s\tline %s\t%s\n' "$row" "$SITE_LINE" "$SITE_TEXT"
      continue
    fi
    missing=""
    for t in ${ROW_TESTS[$i]}; do
      [[ -f "$SCRIPT_CHECKOUT_ROOT/$t" ]] || missing="$missing $t"
    done
    if [[ -n "$missing" ]]; then
      printf 'MISSING-TEST\t%s\t%s\n' "$row" "${missing# }"
      continue
    fi
    select_tests "$i"
    if [[ -z "${TESTS// /}" ]]; then
      printf 'NO-TEST\t%s\tbin/find-tests-for-source.sh names no test for this file\n' "$row"
      continue
    fi
    bad=$((bad - 1))
    printf 'VERIFIED\t%s\tline %s\t%s\n' "$row" "$SITE_LINE" "$SITE_TEXT"
  done
  [[ "$bad" -eq 0 ]] || exit 1
  exit 0
fi

git_dir="$(git -C "$SCRIPT_CHECKOUT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || refuse "not a git checkout: $SCRIPT_CHECKOUT_ROOT"
common_dir="$(git -C "$SCRIPT_CHECKOUT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || refuse "cannot read the git common dir"
[[ "$git_dir" != "$common_dir" ]] || refuse "this checkout is a main worktree; run from a linked worktree"
for i in "${!ROW_FILE[@]}"; do
  [[ -z "$(git -C "$SCRIPT_CHECKOUT_ROOT" status --porcelain -- "${ROW_FILE[$i]}")" ]] \
    || refuse "target has uncommitted changes: ${ROW_FILE[$i]}"
done

# shellcheck source=bin/lib/run-all-launch.sh
source "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh" || refuse "cannot load bin/lib/run-all-launch.sh"
# shellcheck source=tests/lib/root-decoy.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh" || refuse "cannot load tests/lib/root-decoy.sh"
run_all_pin_state_dirs "$WORK/state" || refuse "cannot pin the workflow state directories"
export ROOT_DECOY_DIR="$WORK/decoy"
root_decoy_ensure || refuse "the root decoy is unavailable"

# tree_print — the checkout as git sees it: the status list plus a digest of the tracked edits.
tree_print() {
  git -C "$SCRIPT_CHECKOUT_ROOT" status --porcelain
  git -C "$SCRIPT_CHECKOUT_ROOT" diff --no-ext-diff | git hash-object --stdin
}
TREE_BEFORE="$(tree_print)"
readonly TREE_BEFORE

# static_rc <file> — the static check on that file only; 127 when the check does not exist.
static_rc() {
  local rc=0
  [[ -f "$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh" ]] || { printf '127'; return; }
  (cd "$SCRIPT_CHECKOUT_ROOT" && limited bash bin/check-root-names.sh "$1") >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

DYN_SEQ=0
# dyn_run <test> — sets DYN_RC, DYN_LAUNCHED, DYN_HITS (decoy hits recorded during the run),
# DYN_RES (the run's output is in $DYN_RES.out and $DYN_RES.err) and DYN_TIMED_OUT (1 when the
# test was stopped at the time limit; its rc and hits then say nothing).
dyn_run() {
  local res deadline
  DYN_SEQ=$((DYN_SEQ + 1))
  res="$WORK/run-$DYN_SEQ"
  DYN_RES="$res"
  DYN_TIMED_OUT=0
  rm -f "$ROOT_DECOY_DIR"/main/hits/*.hit "$ROOT_DECOY_DIR"/old/hits/*.hit
  # Job control on for the launch only: it makes the test the leader of its own process group.
  set -m
  (
    set +m
    cd "$SCRIPT_CHECKOUT_ROOT" || exit 2
    export ROOT_DECOY_TEST_ID="$1"
    rc=0
    run_all_exec "$1" "$res.out" "$res.err" || rc=$?
    printf '%s %s\n' "$rc" "$RUN_ALL_EXEC_LAUNCHED" >"$res.res"
  ) &
  CHILD_PID=$!
  set +m
  deadline=$((SECONDS + TEST_TIMEOUT))
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then DYN_TIMED_OUT=1; break; fi
    sleep 0.2
  done
  # stderr is dropped here because bash reports a job it had to kill.
  { [[ "$DYN_TIMED_OUT" == 0 ]] || kill_child; wait "$CHILD_PID"; } 2>/dev/null
  CHILD_PID=""
  [[ "$DYN_TIMED_OUT" == 0 ]] || rm -f "$res.res"
  DYN_RC=2
  DYN_LAUNCHED=0
  [[ -f "$res.res" ]] && read -r DYN_RC DYN_LAUNCHED <"$res.res"
  DYN_HITS=$(($(root_decoy_hit_count "$ROOT_DECOY_DIR/main") + $(root_decoy_hit_count "$ROOT_DECOY_DIR/old")))
}

# A failure that gained one of these lines (or follows an unresolved rewrite) proves only that
# the mutant died: a test that asserts no value fails just the same. The words that also occur
# in prose are matched only in the shape node or bash itself prints ("Error: Command failed: ",
# "<script>: line <n>: <word>: ..."), so a test's own sentence or another tool's message
# ("cat: x: No such file or directory") is no match.
readonly CRASH_RE='ReferenceError|unbound variable|TypeError|ERR_INVALID_ARG_TYPE|Error: Command failed: |: line [0-9]+: .*: (command not found|No such file or directory)'
# crash_lines <result prefix> — how many output lines of that run match CRASH_RE.
crash_lines() { cat "$1.out" "$1.err" 2>/dev/null | grep -c -E "$CRASH_RE"; }

BASE_TEST=()
BASE_STATE=()
BASE_CRASH=()
# baseline_state <test> — sets BASELINE to green / timed-out / not-launched / red for the
# unmutated checkout, and BASELINE_CRASH to the crash-shaped lines that run already printed.
baseline_state() {
  local i state
  for i in "${!BASE_TEST[@]}"; do
    [[ "${BASE_TEST[$i]}" == "$1" ]] && { BASELINE="${BASE_STATE[$i]}"; BASELINE_CRASH="${BASE_CRASH[$i]}"; return; }
  done
  dyn_run "$1"
  if [[ "$DYN_TIMED_OUT" == 1 ]]; then state="timed-out"
  elif [[ "$DYN_LAUNCHED" != 1 ]]; then state="not-launched"
  elif [[ "$DYN_RC" == 0 && "$DYN_HITS" == 0 ]]; then state="green"
  else state="red"; fi
  BASE_TEST+=("$1")
  BASE_STATE+=("$state")
  BASE_CRASH+=("$(crash_lines "$DYN_RES")")
  BASELINE="$state"
  BASELINE_CRASH="${BASE_CRASH[${#BASE_CRASH[@]} - 1]}"
}

N_STATIC=0
N_DYNAMIC=0
N_CRASH=0
N_LIVE=0
N_NOT_RUN=0
# report <verdict> <kind> <file> <layer> <detail> — called once per row, after the restore. A
# checkout that no longer matches its state before the run ends the probe: some test wrote into it.
report() {
  if [[ "$(tree_print)" != "$TREE_BEFORE" ]]; then
    printf 'LEAKED\t%s\t%s\tlayer=none\t%s; a test of this row changed the checkout (see git status); verdict before the check: %s\n' "$2" "$3" "$5" "$1"
    exit 3
  fi
  printf '%s\t%s\t%s\tlayer=%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
  case "$1" in
    KILLED-STATIC) N_STATIC=$((N_STATIC + 1)) ;;
    KILLED-DYNAMIC) N_DYNAMIC=$((N_DYNAMIC + 1)) ;;
    KILLED-CRASH) N_CRASH=$((N_CRASH + 1)) ;;
    LIVE) N_LIVE=$((N_LIVE + 1)) ;;
    *) N_NOT_RUN=$((N_NOT_RUN + 1)) ;;
  esac
}

for i in "${!ROW_KIND[@]}"; do
  kind="${ROW_KIND[$i]}"
  file="${ROW_FILE[$i]}"
  select_tests "$i"
  usable=()
  skipped=""
  for t in $TESTS; do
    baseline_state "$t"
    if [[ "$BASELINE" == green ]]; then usable+=("$t"); else skipped="$skipped $t:$BASELINE"; fi
  done
  static_before="$(static_rc "$file")"
  cp -p "$SCRIPT_CHECKOUT_ROOT/$file" "$WORK/backup" || refuse "cannot back up $file"
  ACTIVE="$file"
  if ! site="$(apply_mutation "$kind" "$file" "${ROW_NTH[$i]}")"; then
    restore
    report "NOT RUN" "$kind" "$file" none "no site of this kind in the file"
    continue
  fi
  split_site "$site"
  site="$SITE_LINE"
  static_after="$(static_rc "$file")"
  case "$static_before:$static_after" in
    0:1) static_note="static=detected" ;;
    0:0) static_note="static=clean" ;;
    127:*) static_note="static=unavailable(no bin/check-root-names.sh)" ;;
    *) static_note="static=unusable(before=$static_before,after=$static_after)" ;;
  esac
  if [[ "$static_note" == "static=detected" ]]; then
    restore
    report "KILLED-STATIC" "$kind" "$file" static "line $site; bin/check-root-names.sh exit 1"
    continue
  fi
  killer=""
  crash=""
  layer=""
  timed=""
  for t in ${usable[@]+"${usable[@]}"}; do
    baseline_state "$t"
    dyn_run "$t"
    # A test stopped at the limit checked no value: it is neither a killer nor a pass.
    if [[ "$DYN_TIMED_OUT" == 1 ]]; then timed="${timed:-$t}"; continue; fi
    if [[ "$DYN_LAUNCHED" != 1 ]]; then continue; fi
    if [[ "$DYN_RC" != 0 && "$DYN_RC" != 77 ]]; then
      # A crash-shaped line the test prints on the unmutated checkout too is not the mutant's.
      if [[ "$SITE_STATE" != resolved || "$(crash_lines "$DYN_RES")" -gt "$BASELINE_CRASH" ]]; then
        crash="${crash:-$t (exit $DYN_RC)}"
        continue
      fi
      killer="$t (exit $DYN_RC)"; layer="dynamic-test"; break
    fi
    if [[ "$DYN_HITS" != 0 ]]; then killer="$t ($DYN_HITS decoy hit(s))"; layer="decoy-hit"; break; fi
  done
  restore
  [[ -z "$ACTIVE" ]] || exit 3
  if [[ -n "$killer" ]]; then
    report "KILLED-DYNAMIC" "$kind" "$file" "$layer" "line $site; $static_note; $killer"
  elif [[ -n "$crash" ]]; then
    report "KILLED-CRASH" "$kind" "$file" crash "line $site; $static_note; $crash; rewrite=$SITE_STATE; the mutant died (missing name, wrong type or a command that could not start), so no value was checked"
  elif [[ -n "$timed" ]]; then
    report "NOT RUN" "$kind" "$file" none "line $site; $static_note; timed out after ${TEST_TIMEOUT}s: $timed; a test stopped at the time limit checked no value"
  elif [[ "${#usable[@]}" -eq 0 ]]; then
    report "NOT RUN" "$kind" "$file" none "line $site; $static_note; no dynamic test was launched green before the rewrite:${skipped:- (none selected)}"
  else
    report "LIVE" "$kind" "$file" none "line $site; $static_note; passed: ${usable[*]}"
  fi
done

printf 'SUMMARY: KILLED-STATIC=%s KILLED-DYNAMIC=%s KILLED-CRASH=%s LIVE=%s NOT-RUN=%s\n' "$N_STATIC" "$N_DYNAMIC" "$N_CRASH" "$N_LIVE" "$N_NOT_RUN"
if [[ "$N_LIVE" -gt 0 ]]; then exit 1; fi
if [[ "$((N_NOT_RUN + N_CRASH))" -gt 0 ]]; then exit 2; fi
exit 0
