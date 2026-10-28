#!/usr/bin/env bash
# tests/bin/feature-2631-review-size-bins.sh
# Tests: bin/review-code-size, bin/review-prompt-size, bin/review-doc-size, bin/size-check, hooks/workflow-gate/code-size-gate.js, bin/doc-rotate.py, bin/doc-append.py, rules/docs.md, rules/docs/history.md, rules/docs/architecture.md, rules/docs/glossary.md, skills/review-docs/SKILL.md, skills/_shared/test-design.md, bin/lib/test-route-destination.sh
# Tags: scope:issue-specific, size-limits, review, bin, git, block, shrink, fail-closed, table-driven, layer:TL2, ssot, non-ascii-path, test-lang-exception:text-only
# #2631 stage 2: the three review bins judge through bin/size-check (SSOT hooks/lib/size-limits.js).
# An over-HARD file that shrinks passes, growing or equal still blocks; the HARD boundary counts a
# last line that has no trailing newline; a size-check infrastructure error (rc 3) is a non-SKIPPED
# rc 2, never a pass; and no limit number is left hard-coded outside the SSOT (static cases).
# Every bin runs from a copied agents tree (hooks/ bin/ rules/) so a case can swap bin/size-check.
set -uo pipefail
# TL3 gap (what this test does NOT catch):
# - the real review_code / review_docs skill steps reading these bins' verdicts inside a live session
# - code-size-gate.js fired by the real Claude Code PreToolUse dispatch (it is called directly here)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
harness_assert_isolated
unset CLAUDE_CODE_SESSION_ID CODE_FILE_EXTENSIONS 2>/dev/null || true
export CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on COMMENT_BLOCK_ENFORCE=on

# build_tree <dir> [stub-rc] — a self-contained agents tree; with stub-rc, bin/size-check exits it.
build_tree() {
  local dir="$1" rc="${2:-}"
  mkdir -p "$dir"
  cp -r "$ROOT/hooks" "$ROOT/bin" "$ROOT/rules" "$dir/"
  if [ -n "$rc" ]; then
    printf '#!/usr/bin/env node\nprocess.exit(%s);\n' "$rc" > "$dir/bin/size-check"
    chmod +x "$dir/bin/size-check"
  fi
  printf '%s' "$dir"
}
TREE="$(build_tree "$TMP_ROOT/tree")"
BAD_TREE="$(build_tree "$TMP_ROOT/bad-tree" 3)"

# make_lines <n> [tag] — exactly n newline-terminated lines; make_lines_open omits the last newline.
make_lines() { local i; for ((i = 1; i <= $1; i++)); do printf '%s line %d\n' "${2:-v1}" "$i"; done; }
make_lines_open() { make_lines $(($1 - 1)) "${2:-v1}"; printf '%s line %d' "${2:-v1}" "$1"; }

# TEMPLATE — one repo on main with one commit; hooks disabled, example.com identity. new_repo
# copies it (hooksPath travels with .git), so a scenario spends no spawns on init and config.
TEMPLATE="$TMP_ROOT/template"
mkdir -p "$TEMPLATE"
harness_git_init "$TEMPLATE"
git -C "$TEMPLATE" config user.email test@example.com
git -C "$TEMPLATE" config user.name Test
git -C "$TEMPLATE" config core.autocrlf false
git -C "$TEMPLATE" symbolic-ref HEAD refs/heads/main
echo init > "$TEMPLATE/README.md"
git -C "$TEMPLATE" add README.md
git -C "$TEMPLATE" commit -q -m init
# new_repo — a fresh copy of TEMPLATE (mktemp, not a counter: callers run inside $(...)).
new_repo() {
  local d
  d="$(mktemp -d "$TMP_ROOT/repo.XXXXXX")"
  cp -r "$TEMPLATE/." "$d/"
  printf '%s' "$d"
}

RC=0
OUT=""
# run_bin <tree> <repo> <bin> [args...] — sets RC / OUT (stdout+stderr), from the fixture repo.
run_bin() {
  local tree="$1" repo="$2" bin="$3"
  shift 3
  RC=0
  OUT="$(cd "$repo" && run_with_timeout 60 env AGENTS_MAIN_ROOT="$tree" bash "$tree/bin/$bin" "$@" 2>&1)" || RC=$?
}

# put <repo> <path> <writer> <n> [tag] — write <path> with the writer (make_lines / make_lines_open).
put() { mkdir -p "$(dirname "$1/$2")"; "$3" "$4" "${5:-v1}" > "$1/$2"; }

# companion_of <path> — the 10-line sibling every scenario adds beside <path>; never a HARD target.
companion_of() { printf '%s/small.%s' "${1%/*}" "${1##*.}"; }

# scenario <mode> <pre-n|-> <writer> <post-n> <path> [tag] — the repo state the bin judges.
# staged: pre committed, post staged; diff: pre on main, post committed on branch feat.
scenario() {
  local mode="$1" pre="$2" writer="$3" post="$4" path="$5" tag="${6:-v2}" repo small
  small="$(companion_of "$path")"
  repo="$(new_repo)"
  if [ "$pre" != "-" ]; then
    put "$repo" "$path" make_lines "$pre" v1
    git -C "$repo" add -- "$path"
    git -C "$repo" commit -q -m pre
  fi
  [ "$mode" = diff ] && git -C "$repo" checkout -q -b feat
  put "$repo" "$path" "$writer" "$post" "$tag"
  put "$repo" "$small" make_lines 10 v1
  git -C "$repo" add -- "$path" "$small"
  [ "$mode" = diff ] && git -C "$repo" commit -q -m post
  printf '%s' "$repo"
}

# judge <tree> <bin> <mode> <repo> — runs the bin in the mode under test.
judge() {
  if [ "$3" = staged ]; then run_bin "$1" "$4" "$2" --staged
  else run_bin "$1" "$4" "$2" --base main; fi
}

# expect <name> <want-rc> <path> — rc check; rc 0 must still be a PERFORMED run naming the path,
# rc 1 must come from a HARD line naming the path; no HARD line may name the small companion.
expect() {
  local name="$1" want="$2" path="$3" small
  small="$(companion_of "$path")"
  if [ "$RC" != "$want" ]; then
    fail "$name" "want rc=$want got rc=$RC: $(printf '%s' "$OUT" | head -c 400)"
  elif [ "$want" = 0 ] && { printf '%s' "$OUT" | grep -q SKIPPED || ! printf '%s' "$OUT" | grep -qF "$path"; }; then
    fail "$name" "rc 0 but the file was not judged: $(printf '%s' "$OUT" | head -c 400)"
  elif [ "$want" = 1 ] && ! printf '%s\n' "$OUT" | grep -qF "HARD: $path "; then
    fail "$name" "rc 1 but no HARD line names $path: $(printf '%s' "$OUT" | head -c 400)"
  elif printf '%s\n' "$OUT" | grep -F "$small" | grep -q 'HARD:'; then
    fail "$name" "a HARD line names the 10-line $small: $(printf '%s' "$OUT" | head -c 400)"
  else
    pass "$name"
  fi
}

# bin | mode | target path | HARD
TABLE=(
  "review-code-size|staged|bin/big.js|500"
  "review-code-size|diff|bin/big.js|500"
  "review-prompt-size|diff|rules/big.md|200"
  "review-doc-size|staged|docs/big.md|500"
)

case_begin "over-hard-shrink-passes-grow-or-equal-blocks" "bin/review-code-size"
for row in "${TABLE[@]}"; do
  IFS='|' read -r bin mode path hard <<<"$row"
  pre=$((hard + 100))
  repo="$(scenario "$mode" "$pre" make_lines $((hard + 50)) "$path")"
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: over-HARD $pre -> $((hard + 50)) (shrink) exits 0" 0 "$path"
  repo="$(scenario "$mode" "$pre" make_lines "$pre" "$path")"
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: over-HARD $pre -> $pre (equal, edited) exits 1" 1 "$path"
  repo="$(scenario "$mode" "$pre" make_lines $((pre + 10)) "$path")"
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: over-HARD $pre -> $((pre + 10)) (grow) exits 1" 1 "$path"
done
case_end

case_begin "hard-boundary-counts-the-open-last-line" "bin/size-check"
for row in "${TABLE[@]}"; do
  IFS='|' read -r bin mode path hard <<<"$row"
  repo="$(scenario "$mode" - make_lines $((hard + 1)) "$path")"
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: new file at HARD+1 ($((hard + 1))) exits 1" 1 "$path"
  repo="$(scenario "$mode" - make_lines "$hard" "$path")"
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: new file at exactly HARD ($hard) exits 0" 0 "$path"
  if printf '%s\n' "$OUT" | grep -F "$path" | grep -q WARN; then
    pass "$bin $mode: exactly HARD prints a WARN line naming the file"
  else
    fail "$bin $mode: exactly HARD prints a WARN line naming the file" "$(printf '%s' "$OUT" | head -c 400)"
  fi
  repo="$(scenario "$mode" - make_lines_open $((hard + 1)) "$path")"
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: HARD+1 lines without a trailing newline exits 1" 1 "$path"
done
case_end

case_begin "size-check-infra-error-is-rc2" "bin/review-doc-size"
for row in "${TABLE[@]}"; do
  IFS='|' read -r bin mode path hard <<<"$row"
  repo="$(scenario "$mode" - make_lines 10 "$path")"
  judge "$BAD_TREE" "$bin" "$mode" "$repo"
  if [ "$RC" = 2 ] && [ -n "$OUT" ] && ! printf '%s' "$OUT" | grep -q SKIPPED; then
    pass "$bin $mode: size-check rc 3 -> rc 2 with a non-SKIPPED diagnostic"
  else
    fail "$bin $mode: size-check rc 3 -> rc 2 with a non-SKIPPED diagnostic" "rc=$RC out=$(printf '%s' "$OUT" | head -c 300)"
  fi
  judge "$TREE" "$bin" "$mode" "$repo"
  expect "$bin $mode: control: the real size-check judges the same 10-line file" 0 "$path"
done
case_end

# Trees whose copied SSOT says code 50/100 and 700/900: a bin keeping its own numbers disagrees.
MUTATE="$ROOT/tests/hooks/feature-2631-size-limits/mutate-limits.js"
LOW_TREE="$(build_tree "$TMP_ROOT/low-tree")"
HIGH_TREE="$(build_tree "$TMP_ROOT/high-tree")"

case_begin "ssot-limit-change-propagates-review-code-size" "bin/review-code-size"
for spec in "$LOW_TREE|50|100" "$HIGH_TREE|700|900"; do
  IFS='|' read -r tree warn hard <<<"$spec"
  if node "$MUTATE" "$tree" code "$warn" "$hard"; then pass "premise: the copied SSOT says code $warn/$hard"
  else fail "premise: the copied SSOT says code $warn/$hard"; fi
done
repo="$(scenario staged - make_lines 150 bin/mid.js)"
judge "$LOW_TREE" review-code-size staged "$repo"
expect "lowered HARD 100: a new 150-line bin/mid.js exits 1" 1 bin/mid.js
judge "$TREE" review-code-size staged "$repo"
expect "control: the repo SSOT passes the same 150-line file" 0 bin/mid.js
repo="$(scenario staged - make_lines 750 bin/big.js)"
judge "$HIGH_TREE" review-code-size staged "$repo"
expect "raised HARD 900: a new 750-line bin/big.js exits 0" 0 bin/big.js
judge "$TREE" review-code-size staged "$repo"
expect "control: the repo SSOT blocks the same 750-line file" 1 bin/big.js
case_end

# A hard-coded limit: "HARD 500", "WARN: 300", "500-line", "= 500", "MAX_LINES=200",
# "300 lines", "--threshold-warn 500", "(( lines > 500". "<100 lines" prose is not one.
LIMIT_PATTERNS=(
  -e 'HARD[ :]*[0-9]{3}' -e 'WARN[ :]*[0-9]{3}' -e '[0-9]{3}-line' -e '= *500\b'
  -e '(LIMIT|LINES|MAX[A-Z_]*) *= *[0-9]{3}' -e '\b(300|500|800)( |-)lines?\b'
  -e '--threshold-warn [0-9]' -e '\(\( *lines *> *[0-9]+'
)
# "300/500"-style WARN/HARD pairs, built from the SSOT rows so a dated or path-like a/b is not one.
SLASH_PAIRS=""
while IFS='|' read -r _ _ _ _ warn hard _; do
  warn="${warn//[[:space:]]/}"
  hard="${hard//[[:space:]]/}"
  [[ "$warn" =~ ^[0-9]+$ && "$hard" =~ ^[0-9]+$ ]] || continue
  SLASH_PAIRS="${SLASH_PAIRS:+$SLASH_PAIRS|}$warn/$hard"
done < <(node "$ROOT/bin/print-size-limits" --markdown-table)
[[ -n "$SLASH_PAIRS" ]] && LIMIT_PATTERNS+=(-e "\\b($SLASH_PAIRS)\\b")
# no_limits <repo path> — the file exists and names no limit number (it reads the SSOT).
no_limits() {
  local f="$1" hits
  if [ ! -f "$ROOT/$f" ]; then fail "$f exists" "missing"; return; fi
  hits="$(grep -nE "${LIMIT_PATTERNS[@]}" "$ROOT/$f" | head -n 3)"
  if [ -z "$hits" ]; then pass "$f names no limit number (reads the SSOT)"
  else fail "$f names no limit number (reads the SSOT)" "$hits"; fi
}

case_begin "limit-patterns-premise" "bin/size-check"
if [[ "$SLASH_PAIRS" == *"300/500"* && "$SLASH_PAIRS" == *"500/800"* ]]; then
  pass "premise: the SSOT rows yield the slash pairs ($SLASH_PAIRS)"
else fail "premise: the SSOT rows yield the slash pairs" "got '$SLASH_PAIRS'"; fi
while IFS='|' read -r name probe want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  probe="${probe#"${probe%%[![:space:]]*}"}"
  probe="${probe%"${probe##*[![:space:]]}"}"
  want="${want//[[:space:]]/}"
  if printf '%s\n' "$probe" | grep -qE "${LIMIT_PATTERNS[@]}"; then got=hit; else got=clean; fi
  if [[ "$got" == "$want" ]]; then pass "premise $name: '$probe' -> $want"
  else fail "premise $name: '$probe'" "want=$want got=$got"; fi
done <<'TABLE'
hard-colon        | HARD: 500                        | hit
n-line            | exceeds 300-line warn            | hit
arith-compare     | if (( lines > 500 ))             | hit
threshold-flag    | --threshold-warn 500             | hit
assign            | HARD_LIMIT=500                   | hit
slash-code        | code files are capped at 300/500 | hit
slash-history     | history rotates at 500/800       | hit
slash-prompt      | prompt 100/200 lines             | hit
lt-prose          | keep it <100 lines               | clean
date              | released 2026/10/27              | clean
ratio-not-ssot    | a 300/600 split                  | clean
longer-number     | ids 1300/5000 in the log         | clean
url-path          | see /api/v1/items/42             | clean
TABLE
SLASH_FIXTURE="$TMP_ROOT/slash-fixture.md"
printf 'intro\nWARN/HARD stay at 300/500 lines.\n' > "$SLASH_FIXTURE"
if grep -nE "${LIMIT_PATTERNS[@]}" "$SLASH_FIXTURE" | grep -q '^2:'; then
  pass "fixture: a file quoting 300/500 fails the no_limits scan (line 2)"
else fail "fixture: a file quoting 300/500 fails the no_limits scan"; fi
case_end

case_begin "no-hard-coded-limit-review-code-size" "bin/review-code-size"
no_limits bin/review-code-size
case_end
case_begin "no-hard-coded-limit-review-prompt-size" "bin/review-prompt-size"
no_limits bin/review-prompt-size
case_end
case_begin "no-hard-coded-limit-review-doc-size" "bin/review-doc-size"
no_limits bin/review-doc-size
case_end
case_begin "no-hard-coded-limit-code-size-gate" "hooks/workflow-gate/code-size-gate.js"
no_limits hooks/workflow-gate/code-size-gate.js
case_end
case_begin "no-hard-coded-limit-doc-rotate" "bin/doc-rotate.py"
no_limits bin/doc-rotate.py
case_end
case_begin "no-hard-coded-limit-doc-append" "bin/doc-append.py"
no_limits bin/doc-append.py
case_end
case_begin "no-hard-coded-limit-rules-docs" "rules/docs.md"
no_limits rules/docs.md
case_end
case_begin "no-hard-coded-limit-rules-docs-history" "rules/docs/history.md"
no_limits rules/docs/history.md
case_end
case_begin "no-hard-coded-limit-rules-docs-architecture" "rules/docs/architecture.md"
no_limits rules/docs/architecture.md
case_end
case_begin "no-hard-coded-limit-rules-docs-glossary" "rules/docs/glossary.md"
no_limits rules/docs/glossary.md
case_end
case_begin "no-hard-coded-limit-review-docs-skill" "skills/review-docs/SKILL.md"
no_limits skills/review-docs/SKILL.md
case_end
case_begin "no-hard-coded-limit-test-design" "skills/_shared/test-design.md"
no_limits skills/_shared/test-design.md
case_end
case_begin "no-hard-coded-limit-test-route-destination" "bin/lib/test-route-destination.sh"
no_limits bin/lib/test-route-destination.sh
case_end
# Stage 6 documents and the progress rule: every sibling, not only the one found to drift (CPR-E2C).
case_begin "no-hard-coded-limit-workflow-runtime" "docs/architecture/claude-code/workflow-runtime.md"
no_limits docs/architecture/claude-code/workflow-runtime.md
case_end
case_begin "no-hard-coded-limit-settings-hooks" "docs/architecture/claude-code/settings/hooks.md"
no_limits docs/architecture/claude-code/settings/hooks.md
case_end
case_begin "no-hard-coded-limit-marker-bypass-contract" "docs/architecture/claude-code/marker-bypass-contract.md"
no_limits docs/architecture/claude-code/marker-bypass-contract.md
case_end
case_begin "no-hard-coded-limit-progress-file" "docs/architecture/claude-code/progress-file.md"
no_limits docs/architecture/claude-code/progress-file.md
case_end
case_begin "no-hard-coded-limit-e2e-testing" "docs/architecture/claude-code/e2e-testing.md"
no_limits docs/architecture/claude-code/e2e-testing.md
case_end
case_begin "no-hard-coded-limit-progress-update-rule" "rules/progress-update.md"
no_limits rules/progress-update.md
case_end
# next-step's verdict text quotes the limits to the model too: a sibling consumer (CPR-E2C).
case_begin "no-hard-coded-limit-next-step-verdict" "bin/workflow/lib/next-step/verdict.js"
no_limits bin/workflow/lib/next-step/verdict.js
case_end

# shellcheck source=feature-2631-review-size-bins/all-scan.sh
. "$ROOT/tests/bin/feature-2631-review-size-bins/all-scan.sh"
XFAIL_ISSUE="#2631"
# shellcheck source=../lib/xfail.sh
. "$ROOT/tests/lib/xfail.sh"
case_begin "all-scan-empty-tree-is-advisory-rc0" "bin/review-prompt-size"
as_case_empty_tree
case_end
case_begin "all-scan-mixed-warn-hard-tree-is-advisory-rc0" "bin/review-code-size"
as_case_mixed_tree
case_end
case_begin "all-scan-newline-named-over-hard-file" "bin/review-code-size"
as_case_newline_name
case_end

# shellcheck source=feature-2631-review-size-bins/unicode-diff.sh
. "$ROOT/tests/bin/feature-2631-review-size-bins/unicode-diff.sh"
case_begin "diff-mode-non-ascii-path-review-code-size" "bin/review-code-size"
ud_case_non_ascii_diff_path review-code-size "bin/$(printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e').js" 500
case_end
case_begin "diff-mode-non-ascii-path-review-prompt-size" "bin/review-prompt-size"
ud_case_non_ascii_diff_path review-prompt-size "rules/$(printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e').md" 200
case_end

# shellcheck source=feature-2631-review-size-bins/records-integrity.sh
. "$ROOT/tests/bin/feature-2631-review-size-bins/records-integrity.sh"
case_begin "forged-targets-line-in-filename-is-rejected" "bin/review-code-size"
ri_case_forged_targets_line
case_end
case_begin "size-check-rc1-without-hard-record-is-rc2" "bin/review-code-size"
ri_case_disagree rc1-no-hard 1 OK
case_end
case_begin "size-check-rc0-with-hard-record-is-rc2" "bin/review-code-size"
ri_case_disagree rc0-hard 0 HARD
case_end

xfail_summary
echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
