#!/usr/bin/env bash
# tests/bin/feature-2849-heading-order-fast-path.sh
# Tests: bin/review-doc-heading-order
# Tags: TL2, docs, review-docs, staged, git, decision-time-limit, commit-gate, scope:issue-specific, pwsh-not-required
# #2849 / #2781: review-doc-heading-order runs inside the commit gate's decision time limit.
# A README that is not staged SKIPs before the SSOT map is parsed, and heading normalization
# forks no `tr` (a PATH stub counts the calls), with the same verdicts as before. A new file
# beside tests/bin/docs-2340-feat-update-docs-readme-md.sh, which carries no case markers.
# TL3 gap (what this test does NOT catch):
# - the wall time of the real review_docs step under a loaded Windows host
# Closest-to-action mitigation: tests/bin/feat-2529-glossary-provenance-accepted.js (the ask at the limit).

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

TOOL="$SCRIPT_CHECKOUT_ROOT/bin/review-doc-heading-order"
TR_LOG="$TMP_ROOT/tr-calls.log"

expect_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then pass "$name"; else fail "$name" "want=[$want] got=[$got]"; fi
}
expect_contains() {
  local name="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"; else fail "$name" "expected [$needle] in: $hay"; fi
}

REPO_SEQ=0
# new_repo — sets REPO to a fresh fixture repo with one baseline commit.
new_repo() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="$TMP_ROOT/repo-$REPO_SEQ"
  mkdir -p "$REPO"
  harness_git_init "$REPO"
  git -C "$REPO" config core.autocrlf false
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "test"
  printf 'baseline\n' > "$REPO/.seed"
  git -C "$REPO" add .seed
  git -C "$REPO" commit -q -m baseline
}
# stage_notes — a staged change without README.md.
stage_notes() {
  printf '# Notes\n\nbody\n' > "$REPO/notes.md"
  git -C "$REPO" add notes.md
}
# stage_readme <heading...> — README.md with exactly these H2 sections in order, staged.
stage_readme() {
  local h
  printf '# Project\n\n' > "$REPO/README.md"
  for h in "$@"; do printf '## %s\n\nbody\n\n' "$h" >> "$REPO/README.md"; done
  git -C "$REPO" add README.md
}
# run_tool <tool> [args...] — sets OUT and RC; CWD is the fixture repo.
run_tool() {
  local tool="$1"; shift
  OUT="$(cd "$REPO" && run_with_timeout 120 bash "$tool" "$@" 2>&1)"
  RC=$?
}
# run_counting_tr [args...] — the real tool with a logging `tr` first on PATH; also sets TR_CALLS.
TR_STUB="$TMP_ROOT/tr-stub"
mkdir -p "$TR_STUB"
printf '%s\n' "#!/usr/bin/env bash" "echo call >> \"$TR_LOG\"" "exec \"$(command -v tr)\" \"\$@\"" > "$TR_STUB/tr"
chmod +x "$TR_STUB/tr"
run_counting_tr() {
  : > "$TR_LOG"
  OUT="$(cd "$REPO" && PATH="$TR_STUB:$PATH" run_with_timeout 120 bash "$TOOL" "$@" 2>&1)"
  RC=$?
  TR_CALLS="$(wc -l < "$TR_LOG")"
  TR_CALLS="${TR_CALLS//[[:space:]]/}"
}
# A copy of the tool beside an SSOT whose order block is empty: a run that parses the map before
# the staged check SKIPs for the SSOT reason instead of the README reason.
FAKE_ROOT="$TMP_ROOT/fakeroot"
mkdir -p "$FAKE_ROOT/bin" "$FAKE_ROOT/rules/docs"
cp "$TOOL" "$FAKE_ROOT/bin/review-doc-heading-order"
printf '%s\n' "# README rules" "<!-- readme-section-order:start -->" "<!-- readme-section-order:end -->" > "$FAKE_ROOT/rules/docs/readme.md"

case_begin "unstaged-readme-skips-before-ssot-parse" "bin/review-doc-heading-order"
new_repo
stage_notes
run_tool "$FAKE_ROOT/bin/review-doc-heading-order" --staged
expect_eq "README not staged, empty SSOT block: exit 0" "0" "$RC"
expect_contains "the SKIP reason is the unstaged README, not the SSOT" "SKIPPED — README.md not in the staged change" "$OUT"
case_end

case_begin "unstaged-readme-forks-no-tr" "bin/review-doc-heading-order"
new_repo
stage_notes
run_counting_tr --staged
expect_eq "README not staged: exit 0" "0" "$RC"
expect_contains "README not staged: SKIP" "README.md not in the staged change" "$OUT"
expect_eq "README not staged: tr is never run" "0" "$TR_CALLS"
case_end

case_begin "staged-readme-normalizes-without-tr" "bin/review-doc-heading-order"
new_repo
stage_readme "What" "Quickstart" "Usage" "Configuration"
run_counting_tr --staged
expect_eq "README staged in canonical order: exit 0" "0" "$RC"
expect_contains "README staged: PERFORMED" "PERFORMED (staged mode)" "$OUT"
expect_eq "README staged: tr is never run" "0" "$TR_CALLS"
case_end

case_begin "normalization-verdicts-unchanged" "bin/review-doc-heading-order"
# Row: "<headings separated by ;>|<exit>|<description>".
TAB=$'\t'
ROWS=(
  "What;QUICK   START;Usage Examples;Configuration|0|upper case and a run of spaces still map"
  "What;Quick${TAB}Start;Usage|0|a tab inside a heading is whitespace"
  "  What  ;Usage   |0|surrounding spaces are trimmed"
  "Usage;Advanced Configuration|0|the longest alias (configuration) wins over advanced"
  "Reference;Advanced Configuration|1|Advanced Configuration ranks as configuration, after reference: inverted"
  "What;Frequently Asked Questions;Usage|0|an unknown heading is skipped"
  "What;ÜBER UNS;Usage|0|a heading with a non-ASCII upper-case letter is skipped as unknown"
  "Configuration;ÜBER QUICK START|1|an upper-case alias next to a non-ASCII upper-case word still maps: inverted"
  "Configuration;quick start|1|inverted order with a lower-case alias: exit 1"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r headings expect desc <<< "$row"
  IFS=';' read -r -a hs <<< "$headings"
  new_repo
  stage_readme "${hs[@]}"
  run_tool "$TOOL" --staged
  expect_eq "$desc" "$expect" "$RC"
done
expect_contains "the violation names the out-of-order heading" "BLOCK: section 'quick start'" "$OUT"
case_end

echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
