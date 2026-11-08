#!/usr/bin/env bash
# tests/skills/feature-2473-gitlab-tracker.sh
# Tests: skills/migrate-tracker/scripts/gitlab-tracker.sh
# Tags: TL2, skills, migrate, gitlab, forge, scope:issue-specific
# Issue #2473: gl_check_board is 0 only when a board exists AND every status:* label has a list,
# 1 when absent or incomplete (missing ids on stderr), 2 when the boards cannot be read.
# gl_ensure_board tolerates a list POST failing for an existing list, but returns 1 with Error:
# when a status:* label still has no list afterwards or the lists cannot be read.
# glab is a fake on PATH answering `api` per endpoint from fixture files (<key>.out / <key>.rc).
# TL3 gap: a real GitLab boards API through real glab; here the responses are fixtures.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "${TMPBASE:?}"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

TRACKER="$SCRIPT_CHECKOUT_ROOT/skills/migrate-tracker/scripts/gitlab-tracker.sh"
FAKE_BIN="$TMPBASE/bin"
export GLT_FX="$TMPBASE/fx"
mkdir -p "$FAKE_BIN" "$GLT_FX"

# Fake glab: `api <endpoint> [-X POST ...]` -> key labels | boards | lists (+ .post for POST);
# prints $GLT_FX/<key>.out when present and exits with $GLT_FX/<key>.rc (default 0).
cat >"$FAKE_BIN/glab" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GLT_FX/calls.log"
[ "${1:-}" = api ] || exit 3
ep="${2:-}"
method=GET
[ "${3:-}" = -X ] && method="${4:-GET}"
case "$ep" in
  */labels\?*) key=labels ;;
  */boards) key=boards ;;
  */boards/*/lists) key=lists ;;
  *) echo "fake glab: unknown endpoint $ep" >&2; exit 4 ;;
esac
[ "$method" = POST ] && key="$key.post"
[ -f "$GLT_FX/$key.out" ] && cat "$GLT_FX/$key.out"
exit "$(cat "$GLT_FX/$key.rc" 2>/dev/null || echo 0)"
FAKE
chmod +x "$FAKE_BIN/glab"

LABELS='[{"id":11,"name":"status:todo"},{"id":12,"name":"status:doing"},{"id":13,"name":"status:done"},{"id":20,"name":"type:task"}]'
BOARD='[{"id":5,"name":"Issues"}]'
LISTS_ALL='[{"id":1,"label":{"id":11}},{"id":2,"label":{"id":12}},{"id":3,"label":{"id":13}}]'
LISTS_NO13='[{"id":1,"label":{"id":11}},{"id":2,"label":{"id":12}}]'

# fx <key> <out> [rc] — the fake's answer for one endpoint key.
fx() { printf '%s' "$2" >"$GLT_FX/$1.out"; printf '%s' "${3:-0}" >"$GLT_FX/$1.rc"; }
fx_reset() { rm -f "$GLT_FX"/*; }

# drive <fn> — runs gitlab-tracker.sh's <fn> o/r under the caller's options (run-issue-setup.sh:
# set -uo pipefail, no -e); sets RC, OUT, ERR.
drive() {
  RC=0
  (
    set +e
    set -uo pipefail
    PATH="$FAKE_BIN:$PATH"
    # shellcheck source=/dev/null
    . "$TRACKER" || exit 91
    "$1" o/r
  ) >"$TMPBASE/out" 2>"$TMPBASE/err" || RC=$?
  OUT="$(cat "$TMPBASE/out")"
  ERR="$(cat "$TMPBASE/err")"
}
# verdict <label> <cond-rc> — pass when the condition held, else fail with the run's detail.
verdict() {
  if [[ "$2" == 0 ]]; then
    pass "$1"
  else
    fail "$1" "rc=$RC out=[$OUT] err=[$ERR] calls=[$(tr '\n' '|' <"$GLT_FX/calls.log" 2>/dev/null || true)]"
  fi
}
ok() { if "$@"; then echo 0; else echo 1; fi; }

case_begin "GLT-check-board-verdicts" "skills/migrate-tracker/scripts/gitlab-tracker.sh"
fx_reset; fx boards '[]'; fx labels "$LABELS"
drive gl_check_board
verdict "gl_check_board: no board -> rc 1" "$(ok test "$RC" = 1)"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists "$LISTS_ALL"
drive gl_check_board
verdict "gl_check_board: board with a list for every status:* label -> rc 0" "$(ok test "$RC" = 0)"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists "$LISTS_NO13"
drive gl_check_board
verdict "gl_check_board: board missing the status:done list -> rc 1 naming id 13 on stderr" \
  "$(ok test "$RC" = 1 -a -n "$(printf '%s' "$ERR" | grep -E 'status label id\(s\): 13$' || true)")"
fx_reset; fx boards 'boom' 1
drive gl_check_board
verdict "gl_check_board: boards API failure -> rc 2" "$(ok test "$RC" = 2)"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists '' 1
drive gl_check_board
verdict "gl_check_board: lists API failure -> rc 1 with Error:" \
  "$(ok test "$RC" = 1 -a -n "$(printf '%s' "$ERR" | grep '^Error:' || true)")"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists '{"message":"404 Not Found"}'
drive gl_check_board
verdict "gl_check_board: lists answer not a JSON array -> rc 1 with Error:" \
  "$(ok test "$RC" = 1 -a -n "$(printf '%s' "$ERR" | grep '^Error:.*not a JSON array' || true)")"
case_end

case_begin "GLT-ensure-board-list-posts" "skills/migrate-tracker/scripts/gitlab-tracker.sh"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists.post '{"message":"already exists"}' 1; fx lists "$LISTS_ALL"
drive gl_ensure_board
verdict "gl_ensure_board: list POSTs fail for existing lists, final lists complete -> rc 0" \
  "$(ok test "$RC" = 0 -a -z "$(printf '%s' "$ERR" | grep '^Error:' || true)")"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists.post '{"message":"forbidden"}' 1; fx lists "$LISTS_NO13"
drive gl_ensure_board
verdict "gl_ensure_board: list POSTs fail and status:done still has no list -> rc 1 with Error:" \
  "$(ok test "$RC" = 1 -a -n "$(printf '%s' "$ERR" | grep '^Error:.*13' || true)")"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists.post '{}'; fx lists '' 1
drive gl_ensure_board
verdict "gl_ensure_board: lists unreadable after creation -> rc 1 with Error:" \
  "$(ok test "$RC" = 1 -a -n "$(printf '%s' "$ERR" | grep '^Error:' || true)")"
fx_reset; fx boards '[]'; fx boards.post '{"id":9}'; fx labels "$LABELS"; fx lists.post '{}'; fx lists "$LISTS_ALL"
drive gl_ensure_board
verdict "gl_ensure_board: no board -> creates one, lists complete -> rc 0" \
  "$(ok test "$RC" = 0 -a -n "$(printf '%s' "$OUT" | grep 'created issue board 9' || true)")"
case_end

# labels_calls_filtered — 0 when calls.log has at least one labels request and every one of them
# carries the server-side status:* search (an unfiltered first page can miss status:* labels).
labels_calls_filtered() {
  local all filtered
  all="$(grep -cE '^api [^ ]*/labels\?' "$GLT_FX/calls.log" || true)"
  filtered="$(grep -cE '^api projects/[^ ]+/labels\?([^ ]*&)?search=status%3A(&[^ ]*)?$' "$GLT_FX/calls.log" || true)"
  [[ "$all" -gt 0 && "$all" == "$filtered" ]]
}

case_begin "GLT-labels-status-search" "skills/migrate-tracker/scripts/gitlab-tracker.sh"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists "$LISTS_ALL"
drive gl_check_board
verdict "gl_check_board: every labels request carries search=status%3A" "$(ok labels_calls_filtered)"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists.post '{}'; fx lists "$LISTS_ALL"
drive gl_ensure_board
verdict "gl_ensure_board: every labels request carries search=status%3A" "$(ok labels_calls_filtered)"
fx_reset; fx boards "$BOARD"; fx labels "$LABELS"; fx lists.post '{}'; fx lists "$LISTS_ALL"
drive gl_ensure_board
verdict "gl_ensure_board: no list POST for the non-status label type:task (client-side ^status: filter)" \
  "$(ok test "$RC" = 0 -a -z "$(grep 'label_id=20' "$GLT_FX/calls.log" || true)")"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
