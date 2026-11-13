# shellcheck shell=bash
# tests/bin/feature-2956-baseline-ledger-paths/_lib.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, ledger, helper, scope:issue-specific, pwsh-not-required, TL2
# Fixture for the #2956 S6-S8 path tests. Sourced after feature-2688-branch-rerun/_lib.sh; not run standalone.

LP_LEDGER_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-ledger.sh"

# lp_body <marks> <stem> <base-cases> <base-exit> <branch-cases> <branch-exit> [<detail-suffix>]
# One body for both sides (head.txt, feature only, picks the side), so rtb_test_changed stays false.
# Each listed case writes a FAIL record and the detail `violation <case>[ <suffix>]`; <suffix> is shell text.
lp_body() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'r="$(cd "$(dirname "$0")/../.." && pwd)"; d="${RUN_ALL_RESULT_DIR:-}"' \
    "if [ -f \"\$r/head.txt\" ]; then side=branch; cs='$5'; rc=$6; else side=base; cs='$3'; rc=$4; fi" \
    "touch \"$1/\$side-$2\"" \
    'n=0' \
    'for c in $cs; do n=$((n + 1)); [ -n "$d" ] || continue' \
    "  printf '%s\\tFAIL\\t%s\\t-\\n' \"\$n\" \"\$c\" >>\"\$d/cases.tsv\"" \
    "  printf '%s\\t%s\\t%s\\n' \"\$n\" \"\$c\" \"violation \$c${7:+ $7}\" >>\"\$d/fail-details.tsv\"" \
    'done' \
    'exit "$rc"'
}

# lp_repo <dir> — main@base (README) and feature@head (head.txt), with <dir>.marks for the markers.
lp_repo() {
  local repo="$1"
  mkdir -p "$repo.marks"
  harness_git_init "$repo"
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  mkdir -p "$repo/tests/bin"
  printf 'base\n' > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b feature
  printf 'head\n' > "$repo/head.txt"
  git -C "$repo" add head.txt
  git -C "$repo" commit -q -m head
  git -C "$repo" checkout -q main
}

# lp_publish <repo> <msg> — commit the work tree on main, then merge main into the checked-out feature.
lp_publish() {
  chmod +x "$1"/tests/bin/*.sh 2>/dev/null
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  git -C "$1" checkout -q feature
  git -C "$1" merge -q --no-edit main
}

# lp_lib <cache> <cwd> <script> [arg...] — <script> in a child bash with the ledger lib sourced ($1.. = args).
lp_lib() {
  local c="$1" w="$2"; shift 2
  (cd "$w" && run_with_timeout 60 env RUN_ALL_CACHE_DIR="$(np "$c")" \
    bash -c '. "$1" || exit 98; s="$2"; shift 2; eval "$s"' lp_lib "$LP_LEDGER_LIB" "$@")
}

# lp_field <file-glob-dir> <name-glob> <tag> <nf> <rel> <col> — column <col> of the newest matching row.
lp_field() {
  find "$1" -type f -name "$2" -exec cat {} + 2>/dev/null \
    | awk -F '\t' -v T="$3" -v N="$4" -v P="$5" -v C="$6" '$1 == T && NF == N && $4 == P { v = $C } END { printf "%s", v }'
}

# lp_rows_run <dir> <rows> — one repo, one seeded session and one CLI run (one base worktree) for
# `<stem>|<base-cases>|<base-exit>|<branch-cases>|<branch-exit>` rows; markers in <dir>.marks.
lp_rows_run() {
  local repo="$1" s bc be rc re exits="" sid="rows-${1##*/}-$$"
  local -a paths=()
  lp_repo "$repo"; mkdir -p "$repo.cache"
  while IFS='|' read -r s bc be rc re; do
    lp_body "$(np "$repo.marks")" "$s" "$bc" "$be" "$rc" "$re" > "$repo/tests/bin/$s.sh"
    exits="$exits${exits:+,}\"tests/bin/$s.sh\":$re"; paths+=("tests/bin/$s.sh")
  done <<<"$2"
  lp_publish "$repo" "rows"
  seed "$sid" "{$exits}" "${paths[@]}"
  rtb "$repo.cache" "$repo" "$sid"
}

lp_sha() { if [ -f "$1" ]; then sha256sum "$1" | cut -c1-64; else printf '(none)'; fi; }
