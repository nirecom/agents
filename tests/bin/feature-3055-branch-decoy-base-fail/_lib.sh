# shellcheck shell=bash
# tests/bin/feature-3055-branch-decoy-base-fail/_lib.sh
# Tests: bin/lib/run-tests-baseline-classify.sh, bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, classify, helpers, scope:issue-specific, pwsh-not-required, TL2
# Shared setup of tests/bin/feature-3055-branch-decoy-base-fail.sh: one fixture repo and bd_drive, which
# runs a snippet in feature-3015's driver.sh (the CLI's libs, sourced in the CLI's order).
# feature-3015's _lib.sh is not sourced: it and feature-2688-branch-rerun/_lib.sh both make TMPROOT readonly.
# Sourced after tests/lib/harness.sh and feature-2688-branch-rerun/_lib.sh; never run standalone.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _lib.sh}"
BD_DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3015-baseline-timeout-record/driver.sh"

# bd_repo <dir> — main: tests/bin/{t,u,old-d}.sh (all exit 1); feature: head.txt, old-d.sh renamed to
# new-d.sh (content unchanged) and a new added.sh. Sets BD_B2 to main's commit. Checked out on feature.
bd_repo() {
  local r="$1"
  harness_git_init "$r"
  git -C "$r" config core.hooksPath /dev/null
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name T
  git -C "$r" config commit.gpgsign false
  git -C "$r" config core.autocrlf false
  git -C "$r" symbolic-ref HEAD refs/heads/main
  mkdir -p "$r/tests/bin"
  printf '#!/usr/bin/env bash\n# t\nexit 1\n' >"$r/tests/bin/t.sh"
  printf '#!/usr/bin/env bash\n# u\nexit 1\n' >"$r/tests/bin/u.sh"
  printf '#!/usr/bin/env bash\n# old-d\n# a\n# b\n# c\nexit 1\n' >"$r/tests/bin/old-d.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m base
  BD_B2="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" checkout -q -b feature
  printf 'head\n' >"$r/head.txt"
  git -C "$r" mv tests/bin/old-d.sh tests/bin/new-d.sh
  printf '#!/usr/bin/env bash\necho new on the branch\nexit 1\n' >"$r/tests/bin/added.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m feature
}

# bd_drive <cache> <snippet> — the snippet runs in driver.sh against BD_REPO with rtb_compare stubbed
# to announce itself (COMPARE-CALLED) and EMPTY_BASE set to an empty base result dir; R<i> / N0 lines
# follow. Sets BD_OUT (stdout+stderr) and BD_RC.
bd_drive() {
  local cache="$1" snippet
  snippet='rtb_compare() { echo "COMPARE-CALLED"; RTB_CMP_VERDICT=same RTB_CMP_NEW_COUNT=0 RTB_CMP_NEW_HEAD="[]"; return 0; }
mkdir -p "$TMP_BASE/empty-base.res"; EMPTY_BASE="$TMP_BASE/empty-base.res"
'"$2"'
for i in "${!TESTS[@]}"; do echo "R$i cls=${CLS[i]:-} det=${DET[i]:-}"; done
echo "N0 newc=${NEWC[0]:-} newh=${NEWH[0]:-}"'
  mkdir -p "$cache"
  BD_RC=0
  BD_OUT="$(cd "$TMPROOT/cwd" && env RUN_ALL_CACHE_DIR="$(np "$cache")" TR_B2="$BD_B2" \
    bash "$RWT" 60 bash "$BD_DRIVER" "$(np "$BD_REPO")" "$snippet" 2>&1)" || BD_RC=$?
}

# bd_line <prefix> — the first BD_OUT line containing <prefix>, or "(none)".
bd_line() {
  local l
  l="$(printf '%s\n' "$BD_OUT" | grep -m 1 -F -- "$1")" || l="(none)"
  printf '%s' "$l"
}
bd_tail() { if [ "${#BD_OUT}" -gt 800 ]; then printf '%s' "${BD_OUT: -800}"; else printf '%s' "$BD_OUT"; fi; }
bd_ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]; rc=$BD_RC out(tail): $(bd_tail)"; fi; }
bd_lacks() { case "$BD_OUT" in *"$2"*) fail "$1" "unexpected [$2] in (tail): $(bd_tail)" ;; *) pass "$1" ;; esac; }
