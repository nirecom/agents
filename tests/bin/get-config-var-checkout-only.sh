#!/usr/bin/env bash
# tests/bin/get-config-var-checkout-only.sh
# Tests: bin/rtk-cmd, bin/lib/codex-timeout.sh
# Tags: get-config-var, rtk, codex, path-fallback, checkout-root, scope:issue-specific, TL2
# #2561: both callers read config only through their own checkout's bin/get-config-var.
# A PATH-first fake get-config-var (it prints a sentinel value, records the call and says
# "on") must never be used. Without the checkout copy the caller takes its default and
# writes one warning line to stderr; with it, the copy's answer is used silently.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset RTK RTK_BIN CODEX_TIMEOUT_SECS

# PATH-first fakes: get-config-var answers 4242 / exit 1 (= RTK on) and leaves a marker;
# rtk prints RTK-FAKE plus its argv.
FAKE="$TMP_ROOT/fake-path"
mkdir -p "$FAKE"
printf '#!/usr/bin/env bash\ntouch "%s/path-gcv-called"\nprintf "4242\\n"\nexit 1\n' "$TMP_ROOT" >"$FAKE/get-config-var"
printf '#!/usr/bin/env bash\nprintf "RTK-FAKE %%s\\n" "$*"\n' >"$FAKE/rtk"
chmod +x "$FAKE/get-config-var" "$FAKE/rtk"

# make_checkout <label> <absent|present> — a checkout holding the two callers; "present"
# adds a bin/get-config-var that answers 1234 (silent for --is-off) / exit 1. Prints the path.
make_checkout() {
  local co="$TMP_ROOT/co-$1"
  mkdir -p "$co/bin/lib"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/rtk-cmd" "$co/bin/rtk-cmd"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-timeout.sh" "$co/bin/lib/codex-timeout.sh"
  if [ "$2" = present ]; then
    printf '#!/usr/bin/env bash\n[ "$1" = --is-off ] || printf "1234\\n"\nexit 1\n' >"$co/bin/get-config-var"
    chmod +x "$co/bin/get-config-var"
  fi
  printf '%s' "$co"
}

# check_row <label> <rc> <stdout> <want_stdout> <stderr_file> <want_warn_lines>
# Both the value-present path and the fallback path must exit normally (rc 0): a caller that
# dies after printing the right text would otherwise pass.
check_row() {
  local label="$1" rc="$2" out="$3" want="$4" errf="$5" want_warn="$6" lines
  lines="$(grep -c . "$errf")"
  if [ -e "$TMP_ROOT/path-gcv-called" ]; then
    fail "$label" "the PATH get-config-var was called"
  elif [ "$rc" -ne 0 ]; then
    fail "$label" "exit code $rc, want 0: $(cat "$errf")"
  elif [ "$out" != "$want" ]; then
    fail "$label" "stdout=$(printf '%q' "$out") want=$(printf '%q' "$want")"
  elif [ "$lines" != "$want_warn" ]; then
    fail "$label" "stderr has $lines line(s), want $want_warn: $(cat "$errf")"
  elif [ "$want_warn" = 1 ] && ! grep -q 'get-config-var' "$errf"; then
    fail "$label" "the warning does not name get-config-var: $(cat "$errf")"
  else
    pass "$label"
  fi
  rm -f "$TMP_ROOT/path-gcv-called"
}

# Rows: copy|want_stdout|want_warn_lines
RTK_ROWS='absent|hi|1
present|RTK-FAKE echo hi|0'
CODEX_ROWS='absent|900|1
present|1234|0'

case_begin "rtk-cmd-uses-only-its-own-checkout-copy" "bin/rtk-cmd"
while IFS='|' read -r copy want warn; do
  co="$(make_checkout "rtk-$copy" "$copy")"
  rc=0
  out="$(PATH="$FAKE:$PATH" run_with_timeout 20 bash "$co/bin/rtk-cmd" echo hi 2>"$TMP_ROOT/err")" || rc=$?
  check_row "rtk-cmd[$copy]: own checkout copy only, PATH fake unused" "$rc" "$out" "$want" "$TMP_ROOT/err" "$warn"
done <<<"$RTK_ROWS"
case_end

case_begin "codex-timeout-uses-only-its-own-checkout-copy" "bin/lib/codex-timeout.sh"
while IFS='|' read -r copy want warn; do
  co="$(make_checkout "codex-$copy" "$copy")"
  rc=0
  out="$(PATH="$FAKE:$PATH" run_with_timeout 20 bash -c 'source "$1"; codex_timeout_resolve' _ "$co/bin/lib/codex-timeout.sh" 2>"$TMP_ROOT/err")" || rc=$?
  check_row "codex-timeout[$copy]: own checkout copy only, PATH fake unused" "$rc" "$out" "$want" "$TMP_ROOT/err" "$warn"
done <<<"$CODEX_ROWS"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
