# shellcheck shell=bash
# tests/bin/feature-2688-branch-rerun/_lib.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, branch-rerun, helper, scope:issue-specific, pwsh-not-required, TL2
# Shared fixture for #2688 T2 (isolation, seed, repo creation, CLI execution). Sourced by feature-2688-branch-rerun.sh and
# feature-2688-branch-cache.sh. Not run standalone.
# The caller must set SCRIPT_CHECKOUT_ROOT and source tests/lib/harness.sh before sourcing this file.

: "${SCRIPT_CHECKOUT_ROOT:?set SCRIPT_CHECKOUT_ROOT before sourcing}"
declare -F harness_isolate >/dev/null || { echo "FAIL: source tests/lib/harness.sh before _lib.sh"; exit 1; }

BASELINE_CLI="$SCRIPT_CHECKOUT_ROOT/bin/run-tests-baseline"
BRANCH_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-branch.sh"

TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
export WORKFLOW_STATE_DIR="$(np "$TMPROOT/iso/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$TMPROOT/iso/plans")"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$TMPROOT/transcripts" "$TMPROOT/home" "$TMPROOT/cwd"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
HOME="$(np "$TMPROOT/home")"
export HOME USERPROFILE="$HOME"
export RUN_ALL_CACHE_DIR="$TMPROOT/cache-default"
mkdir -p "$RUN_ALL_CACHE_DIR"
# Make the merge base / input_version resolution target explicit (do not rely on defaults).
export DEFAULT_BRANCHES=main
unset RTB_BUDGET_TOTAL
AGENTS_WIN="$(np "$SCRIPT_CHECKOUT_ROOT")"

SEED_JS="$TMPROOT/seed.js"
cat > "$SEED_JS" <<'JSCODE'
"use strict";
// argv: agents sid paths-json exits-json - failing_test_exits is not written when exits-json is "none".
const [agents, sid, paths, exits] = process.argv.slice(2);
const a = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });
try {
  const ev = [{ kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" },
    a("run_outcome", "fail"), a("failing_tests", JSON.parse(paths)), a("unrunnable_count", 0)];
  if (exits !== "none") ev.push(a("failing_test_exits", JSON.parse(exits)));
  require(agents + "/hooks/workflow-state/state-io/events").appendEvents(sid, ev);
} catch (e) { process.stderr.write("seed-error: " + e.message + "\n"); process.exit(1); }
JSCODE

READ_JS="$TMPROOT/read.js"
cat > "$READ_JS" <<'JSCODE'
"use strict";
try {
  const s = require(process.argv[2] + "/hooks/workflow-state").readState(process.argv[3]);
  const v = s && s.steps && s.steps.run_tests ? s.steps.run_tests[process.argv[4]] : undefined;
  process.stdout.write(v === undefined || v === null ? "(absent)" : (typeof v === "string" ? v : JSON.stringify(v)));
} catch (err) { process.stdout.write("(absent)"); }
JSCODE

ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }
field() { run_with_timeout 20 node "$(np "$READ_JS")" "$AGENTS_WIN" "$1" "$2" 2>/dev/null || echo "(absent)"; }
has_line() { case "$RTB_OUT" in *"$2"*) pass "$1" ;; *) fail "$1" "missing [$2] in: $RTB_OUT" ;; esac; }
lacks_line() { case "$RTB_OUT" in *"$2"*) fail "$1" "unexpected [$2] in: $RTB_OUT" ;; *) pass "$1" ;; esac; }
present() { [ -e "$2" ] && pass "$1" || fail "$1" "absent: $2"; }
absent() { [ -e "$2" ] && fail "$1" "present: $2" || pass "$1"; }

# seed <sid> <exits-json|none> <path...>
seed() {
  local sid="$1" exits="$2" list="" p; shift 2
  for p in "$@"; do list="$list${list:+,}\"$p\""; done
  run_with_timeout 30 node "$(np "$SEED_JS")" "$AGENTS_WIN" "$sid" "[$list]" "$exits" >/dev/null 2>&1 \
    || fail "fixture: seed wrote no state for $sid"
}

# mk_test_body <marker-path> <exit> - a test that, when run, touches the marker and exits with <exit>.
mk_test_body() { printf '#!/usr/bin/env bash\ntouch "%s"\nexit %s\n' "$1" "$2"; }

# mk_repo <dir> <branch-exit> - main@base: tests/bin/t.sh creates the base marker and exits 1.
# feature@HEAD: the same test creates the branch marker and exits with <branch-exit>. M=<dir>.marks
mk_repo() {
  local repo="$1" bexit="$2" m="$1.marks"
  mkdir -p "$m"
  harness_git_init "$repo"
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  mkdir -p "$repo/tests/bin"
  mk_test_body "$(np "$m")/base" 1 > "$repo/tests/bin/t.sh"
  chmod +x "$repo/tests/bin/t.sh"
  git -C "$repo" add tests
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b feature
  mk_test_body "$(np "$m")/branch" "$bexit" > "$repo/tests/bin/t.sh"
  printf 'head\n' > "$repo/head.txt"
  git -C "$repo" add tests head.txt
  git -C "$repo" commit -q -m head
}

# seg_variant <variant> <saved-seg> <out> - corrupt a valid branch.v1 segment (b1 TAB iv TAB host TAB path TAB result TAB epoch).
# garbage=content is not a segment, old-tag=version b0, old-layout=last column missing, unknown-result=result column has an unknown value.
seg_variant() {
  case "$1" in
    garbage) printf 'not a segment\nb1\t\n' > "$3" ;;
    old-tag) awk 'BEGIN { FS = OFS = "\t" } { $1 = "b0"; print }' "$2" > "$3" ;;
    old-layout) awk 'BEGIN { FS = OFS = "\t" } { NF = NF - 1; print }' "$2" > "$3" ;;
    unknown-result) awk 'BEGIN { FS = OFS = "\t" } { $5 = "pass-maybe"; print }' "$2" > "$3" ;;
    *) return 1 ;;
  esac
}

# add_test <repo> <name> <base-exit> <branch-exit> - add tests/bin/<name> to both main and feature.
# The main side creates a base-<stem> marker, the feature side a branch-<stem> marker (<stem> is the name without .sh).
add_test() {
  local repo="$1" name="$2" m stem="${2%.sh}"
  m="$(np "$1.marks")"
  git -C "$repo" checkout -q main
  mk_test_body "$m/base-$stem" "$3" > "$repo/tests/bin/$name"
  chmod +x "$repo/tests/bin/$name"
  git -C "$repo" add tests
  git -C "$repo" commit -q -m "base $name"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  mk_test_body "$m/branch-$stem" "$4" > "$repo/tests/bin/$name"
  git -C "$repo" add tests
  git -C "$repo" commit -q -m "head $name"
}

# rtb <cache> <repo> <sid> [VAR=val...] - run the baseline CLI, passing env to the child process only.
rtb() {
  local cache="$1" repo="$2" sid="$3"; shift 3
  RTB_RC=0
  RTB_OUT="$(cd "$TMPROOT/cwd" && env RUN_ALL_CACHE_DIR="$(np "$cache")" "$@" bash "$RWT" 120 \
    bash "$BASELINE_CLI" --session "$sid" --worktree "$(np "$repo")" --per-test-timeout 10 2>&1)" || RTB_RC=$?
}
