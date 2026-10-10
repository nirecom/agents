#!/usr/bin/env bash
# tests/bin/feature-2561-target-checkout-root-flags.sh
# Tests: bin/github-issues/backfill-commit-comments.sh, bin/github-issues/find-companion-issues.sh, bin/github-issues/lib/companion-passes.sh
# Tags: github-issues, root-names, target-root, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch):
# - the real gh: every gh call lands on a PATH mock, so no comment is posted and no issue is read
# - a target checkout root handed over as an environment variable: the tools reset the name first
# Closest-to-action mitigation: bin/check-root-names.sh rejects any line that hands it over that way.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# The companion fixture comes first: the harness then owns pass / fail / run_with_timeout.
# shellcheck source=tests/bin/feature-920-companion-issues/_lib.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-920-companion-issues/_lib.sh"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(np "$(make_tmp)")"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'teardown_mock; rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID GH_REPO GH_TOKEN GITHUB_TOKEN GH_MOCK_ISSUE_NUMBERS
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/cwd"
export HOME="$TMP_ROOT/home" USERPROFILE="$TMP_ROOT/home"

readonly BACKFILL="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/backfill-commit-comments.sh"
readonly PASSES_LIB="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/companion-passes.sh"
readonly GH_MOCK_DIR="$SCRIPT_CHECKOUT_ROOT/tests/fixtures/gh-mock"
readonly MOCK_PATH="$GH_MOCK_DIR:$PATH"
export GH_MOCK_SCENARIO=closed_no_sentinel GH_MOCK_COMMENT_LOG="$TMP_ROOT/comments.log"
[[ "$(PATH="$MOCK_PATH" command -v gh)" == "$GH_MOCK_DIR/gh" ]] || { echo "FAIL: setup: gh does not resolve to its mock"; exit 1; }

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }

# Two checkouts whose history names a different commit for #42, and whose names differ.
mkdir -p "$TMP_ROOT/target/docs" "$TMP_ROOT/main/docs"
printf '### FEATURE: fixture (2026-01-02, a1a1a1a, #42)\n' >"$TMP_ROOT/target/docs/history.md"
printf '### FEATURE: fixture (2026-01-02, b2b2b2b, #42)\n' >"$TMP_ROOT/main/docs/history.md"
mkdir -p "$TMP_ROOT/target/skills/tgt-skill" "$TMP_ROOT/target/hooks" "$TMP_ROOT/target/bin"
mkdir -p "$TMP_ROOT/target/agents" "$TMP_ROOT/target/rules" "$TMP_ROOT/main/skills/main-skill"
: >"$TMP_ROOT/target/hooks/tgt-hook.js"
: >"$TMP_ROOT/target/bin/tgt-tool.sh"
: >"$TMP_ROOT/target/agents/tgt-agent.md"
: >"$TMP_ROOT/target/rules/tgt-rule.md"

# with_roots <agents-main dir|-> <command...> — runs it from a neutral cwd; sets OUT and RC.
with_roots() {
  local envs=()
  [[ "$1" == - ]] || envs+=("AGENTS_MAIN_ROOT=$TMP_ROOT/$1")
  shift
  OUT="$(cd "$TMP_ROOT/cwd" && env -u AGENTS_MAIN_ROOT ${envs[@]+"${envs[@]}"} "$@" 2>&1)"
  RC=$?
}

# Columns: case | flag root | agents main root | commit reported for #42 (- = the run fails).
readonly BACKFILL_ROWS='the-flag-wins-over-the-agents-main-root|target|main|a1a1a1a
the-flag-alone-is-enough|target|-|a1a1a1a
the-agents-main-root-is-the-fallback|-|main|b2b2b2b
neither-root-is-an-error|-|-|-'

case_begin "backfill-reads-the-history-of-the-target-checkout-root" "bin/github-issues/backfill-commit-comments.sh"
while IFS='|' read -r name tcr amr hash; do
  flag=()
  [[ "$tcr" == - ]] || flag=(--target-checkout-root "$TMP_ROOT/$tcr")
  : >"$GH_MOCK_COMMENT_LOG"
  with_roots "$amr" env "PATH=$MOCK_PATH" bash "$RWT" 60 bash "$BACKFILL" --dry-run ${flag[@]+"${flag[@]}"}
  if [[ "$hash" == - ]]; then
    expect_eq "$name: the run fails" "$([[ "$RC" -ne 0 ]] && echo failed)" "failed"
    expect_has "$name: the error names both ways in" "$OUT" "give --target-checkout-root <dir> or set AGENTS_MAIN_ROOT"
    expect_lacks "$name: no issue is classified" "$OUT" "[dry-run class="
  else
    expect_eq "$name: exit code" "$RC" "0"
    expect_has "$name: the commit comes from that root" "$OUT" "[dry-run class=hash-from-history] #42 hash=$hash"
  fi
  expect_eq "$name: no comment is posted" "$(cat "$GH_MOCK_COMMENT_LOG")" ""
done <<<"$BACKFILL_ROWS"
case_end

# flag_tail <none|empty|absent> — sets TAIL: the flag with no value, an empty one, a missing dir.
flag_tail() {
  TAIL=(--target-checkout-root)
  case "$1" in empty) TAIL+=("") ;; absent) TAIL+=("$TMP_ROOT/absent") ;; esac
}
# refused <case> <exit code> <text> — the run ended by its own refusal; a timeout is named as one.
refused() {
  if [[ "$RC" -eq 124 ]]; then fail "$1: the run ends by itself" "timed out"; else pass "$1: the run ends by itself"; fi
  expect_eq "$1: exit code" "$RC" "$2"
  expect_has "$1: the refusal names the cause" "$OUT" "$3"
}

# Columns: case | what follows the flag | refusal. The agents main root is set and must not be used.
readonly BACKFILL_REFUSE_ROWS='the-flag-without-a-value|none|Error: --target-checkout-root needs a directory
the-flag-with-an-empty-value|empty|Error: --target-checkout-root needs a directory
the-flag-naming-a-missing-directory|absent|Error: cannot enter the target checkout root'

# No --dry-run here: a run that fell back to the agents main root would post to the mock.
case_begin "backfill-refuses-a-target-checkout-root-it-cannot-use" "bin/github-issues/backfill-commit-comments.sh"
while IFS='|' read -r name kind text; do
  flag_tail "$kind"
  : >"$GH_MOCK_COMMENT_LOG"
  with_roots main env "PATH=$MOCK_PATH" bash "$RWT" 20 bash "$BACKFILL" "${TAIL[@]}"
  refused "$name" 1 "$text"
  expect_lacks "$name: no issue is classified" "$OUT" "class="
  expect_eq "$name: no comment is posted" "$(cat "$GH_MOCK_COMMENT_LOG")" ""
done <<<"$BACKFILL_REFUSE_ROWS"
case_end

readonly TARGET_NAMES="tgt-agent,tgt-hook,tgt-rule,tgt-skill,tgt-tool"
# Columns: case | root argument | agents main root | identifier set, comma-joined.
readonly IDENT_ROWS="the-argument-wins-over-the-agents-main-root|target|main|$TARGET_NAMES
the-argument-alone-is-enough|target|-|$TARGET_NAMES
the-agents-main-root-is-the-fallback|-|main|main-skill
neither-root-leaves-the-set-empty|-|-|
a-missing-argument-root-does-not-fall-back|absent|main|"

# shellcheck disable=SC2016  # the snippet is expanded by the child shell
readonly IDENT_SNIPPET='source "$1"; shift; companion_pass_b_identifiers "$@"; printf "%s" "$IDENTIFIER_SET"'

case_begin "the-identifier-namespace-is-read-from-the-root-argument" "bin/github-issues/lib/companion-passes.sh"
while IFS='|' read -r name arg amr want; do
  root=()
  [[ "$arg" == - ]] || root=("$TMP_ROOT/$arg")
  with_roots "$amr" bash "$RWT" 60 bash -c "$IDENT_SNIPPET" _ "$PASSES_LIB" ${root[@]+"${root[@]}"}
  expect_eq "$name: exit code" "$RC" "0"
  expect_eq "$name: identifier set" "$(printf '%s' "$OUT" | tr '\n' ',')" "$want"
done <<<"$IDENT_ROWS"
case_end

# Three roots, one name each: the script copy's own checkout knows supervisor-report, the
# other root zebra-crossing, the third root lantern-keeper — so each source is told apart.
setup_mock
readonly FIND_COPY="$TMP/agents-root/bin/github-issues/find-companion-issues.sh"
mkdir -p "$TMP/other-root/skills/zebra-crossing" "$TMP/other-root/rules"
mkdir -p "$TMP/third-root/skills/lantern-keeper" "$TMP/third-root/rules"
export GH_MOCK_VIEW_100='{"number":100,"title":"Add supervisor-report to zebra-crossing and lantern-keeper","body":""}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"","comments":[]}' GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_SEARCH_supervisor_report='[{"number":201}]' GH_MOCK_SEARCH_zebra_crossing='[{"number":202}]'
export GH_MOCK_SEARCH_lantern_keeper='[{"number":203}]'
export GH_MOCK_CAND_201='{"number":201,"title":"Improve supervisor-report output","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Repaint zebra-crossing lines","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_203='{"number":203,"title":"Polish lantern-keeper glass","labels":[],"state":"OPEN"}'

# Columns: case | flag root | agents main root | issue found (- = none) | its reason.
readonly FIND_ROWS='the-flag-wins-over-the-agents-main-root|third-root|other-root|203|ident:lantern-keeper
the-flag-alone-is-enough|third-root|-|203|ident:lantern-keeper
the-agents-main-root-is-the-fallback|-|other-root|202|ident:zebra-crossing
neither-root-finds-nothing|-|-|-|'

case_begin "companions-are-matched-against-the-target-checkout-root" "bin/github-issues/find-companion-issues.sh"
while IFS='|' read -r name tcr amr found reason; do
  flag=()
  envs=()
  [[ "$tcr" == - ]] || flag=(--target-checkout-root "$TMP/$tcr")
  [[ "$amr" == - ]] || envs+=("AGENTS_MAIN_ROOT=$TMP/$amr")
  OUT="$(cd "$TMP_ROOT/cwd" && env -u AGENTS_MAIN_ROOT ${envs[@]+"${envs[@]}"} bash "$RWT" 60 bash "$FIND_COPY" --primary 100 ${flag[@]+"${flag[@]}"} 2>/dev/null)"
  RC=$?
  expect_eq "$name: exit code" "$RC" "0"
  if [[ "$found" == - ]]; then
    expect_eq "$name: no issue is listed" "$OUT" ""
  else
    expect_eq "$name: issues listed" "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ',')" "$found,"
    expect_eq "$name: reason" "$(reason_col3 "$OUT")" "$reason"
  fi
done <<<"$FIND_ROWS"
for kind in none empty; do
  flag_tail "$kind"
  with_roots - bash "$RWT" 20 bash "$FIND_COPY" --primary 100 "${TAIL[@]}"
  refused "the-flag-with-$kind-value" 2 "[find-companion-issues] --target-checkout-root needs a directory"
done
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
