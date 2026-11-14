# shellcheck shell=bash
# tests/bin/feature-3015-baseline-timeout-record/_lib.sh
# Tests: bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, timeout, helpers, scope:issue-specific, pwsh-not-required, TL2
# Shared setup of tests/bin/feature-3015-baseline-timeout-record.sh: isolation, one fixture repo,
# and tr_drive, which runs a snippet in a child bash holding the CLI's libs (driver.sh).
# Sourced after tests/lib/harness.sh; never run standalone.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _lib.sh}"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
export WORKFLOW_STATE_DIR="$(np "$TMPROOT/iso/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$TMPROOT/iso/plans")"
unset CLAUDE_CODE_SESSION_ID RTB_BUDGET_TOTAL
mkdir -p "$TMPROOT/home" "$TMPROOT/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
HOME="$(np "$TMPROOT/home")"
export HOME USERPROFILE="$HOME"
export RUN_ALL_CACHE_DIR="$TMPROOT/cache-default"
mkdir -p "$RUN_ALL_CACHE_DIR"

TR_DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3015-baseline-timeout-record/driver.sh"

# tr_body <marker-word> — a multi-line test body, so git's rename detection pairs old and new.
tr_body() {
  printf '#!/usr/bin/env bash\n# fixture test for #3015\n# line a\n# line b\n# line c\n# line d\n# %s\nexit 1\n' "$1"
}

# tr_repo <dir> — main: t.sh, u.sh, old-t.sh; feature: old-t.sh renamed to new-t.sh, added.sh new.
# Sets TR_B2 to main's commit and TR_ANC to its parent (a real ancestor base). Checked out on feature.
tr_repo() {
  local r="$1"
  harness_git_init "$r"
  git -C "$r" config core.hooksPath /dev/null
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name T
  git -C "$r" config commit.gpgsign false
  git -C "$r" config core.autocrlf false
  git -C "$r" symbolic-ref HEAD refs/heads/main
  mkdir -p "$r/tests/bin"
  tr_body t >"$r/tests/bin/t.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m ancestor
  # shellcheck disable=SC2034 # read by base.sh
  TR_ANC="$(git -C "$r" rev-parse HEAD)"
  tr_body t >"$r/tests/bin/t.sh"; tr_body u >"$r/tests/bin/u.sh"; tr_body old >"$r/tests/bin/old-t.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m base
  TR_B2="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" checkout -q -b feature
  git -C "$r" mv tests/bin/old-t.sh tests/bin/new-t.sh
  printf '#!/usr/bin/env bash\necho entirely different content\nexit 3\n' >"$r/tests/bin/added.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m feature
}

# tr_drive <cache> <snippet> [VAR=val...] — the snippet runs in driver.sh against TR_REPO; sets TR_OUT
# (stdout+stderr) and TR_RC.
tr_drive() {
  local cache="$1" snippet="$2"; shift 2
  mkdir -p "$cache"
  TR_RC=0
  TR_OUT="$(cd "$TMPROOT" && env RUN_ALL_CACHE_DIR="$(np "$cache")" TR_B2="$TR_B2" "$@" \
    bash "$RWT" 60 bash "$TR_DRIVER" "$(np "$TR_REPO")" "$snippet" 2>&1)" || TR_RC=$?
}

# tr_line <prefix> — the first TR_OUT line starting with <prefix>, or "(none)".
tr_line() {
  local l
  l="$(printf '%s\n' "$TR_OUT" | grep -m 1 -F -- "$1")" || l="(none)"
  printf '%s' "$l"
}

tr_ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]; rc=$TR_RC out: $TR_OUT"; fi; }
tr_has() { case "$TR_OUT" in *"$2"*) pass "$1" ;; *) fail "$1" "missing [$2] in: $TR_OUT" ;; esac; }
tr_lacks() { case "$TR_OUT" in *"$2"*) fail "$1" "unexpected [$2] in: $TR_OUT" ;; *) pass "$1" ;; esac; }
tr_match() { if printf '%s\n' "$TR_OUT" | grep -qE -- "$2"; then pass "$1"; else fail "$1" "no line matches /$2/ in: $TR_OUT"; fi; }
