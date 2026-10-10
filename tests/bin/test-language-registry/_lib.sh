# Shared helpers for tests/bin/test-language-registry.sh. Sourced by the dispatcher.
# shellcheck shell=bash
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"

TLR_CASES="$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry"
FIXTURES="$TLR_CASES/fixtures"
CLI="$SCRIPT_CHECKOUT_ROOT/bin/test-language-registry"
LOADER="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
READER="$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.js"
TABLE="$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json"
CLI_M="$(np "$CLI")"
READER_M="$(np "$READER")"
DRIVER_M="$(np "$TLR_CASES/driver.js")"

# drv <command> <reader.js> [arg] — node driver.js; paths are normalized here.
drv() {
  local cmd="$1" reader="$2" arg="${3:-}"
  if [ -n "$arg" ] && [ -e "$arg" ]; then arg="$(np "$arg")"; fi
  node "$DRIVER_M" "$cmd" "$(np "$reader")" "$arg"
}

# cli <args...> — the registry CLI; sets CLI_OUT / CLI_ERR / CLI_RC.
cli() {
  CLI_RC=0
  node "$CLI_M" "$@" >"$TMPBASE/cli.out" 2>"$TMPBASE/cli.err" || CLI_RC=$?
  CLI_OUT="$(cat "$TMPBASE/cli.out")"
  CLI_ERR="$(cat "$TMPBASE/cli.err")"
  # A CLI that is not there exits 1 too; never let that pass as "invalid table".
  case "$CLI_ERR" in *MODULE_NOT_FOUND* | *"Cannot find module"*) CLI_RC="missing-cli" ;; esac
}

# fx_root_decoy <dir> — the root decoy a checkout's launcher refuses to run without: the
# library, its builder, and the file the builder reads the retired names from.
fx_root_decoy() {
  local d="$1" f
  mkdir -p "$d/tests/lib" "$d/tests/bin"
  for f in tests/lib/root-decoy.sh tests/lib/root-decoy-build.js tests/bin/feature-2561-root-names-residue.sh; do
    cp "$SCRIPT_CHECKOUT_ROOT/$f" "$d/$f"
  done
}

# fx_checkout <dir> [<table.json>] — a minimal agents checkout in a git repo:
# bin/lib, the registry CLI/reader/table and the scripts the cases launch. A given
# table replaces the default one: the reader and loader have no env override.
fx_checkout() {
  local d="$1" t="${2:-}" f
  mkdir -p "$d/bin" "$d/hooks/lib" "$d/tests/lib"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$d/bin/lib"
  for f in check-table-driven.sh mutation-probe.sh run-with-timeout.sh normalize-harness-position.py; do
    if [ -f "$SCRIPT_CHECKOUT_ROOT/bin/$f" ]; then cp "$SCRIPT_CHECKOUT_ROOT/bin/$f" "$d/bin/$f"; fi
  done
  install_test_language_registry "$d" "$SCRIPT_CHECKOUT_ROOT"
  cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh" "$d/tests/lib/harness.sh"
  fx_root_decoy "$d"
  if [ -n "$t" ]; then cp "$t" "$d/hooks/lib/test-language-registry.json"; fi
  harness_git_init "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
}

# fx_table_edit <src> <dst> <js> — copy a table, applying <js> to its parsed object `t`.
fx_table_edit() {
  node -e '
const fs = require("fs");
const [src, dst, body] = process.argv.slice(1);
const t = JSON.parse(fs.readFileSync(src, "utf8"));
new Function("t", body)(t);
fs.writeFileSync(dst, JSON.stringify(t, null, 1));
' "$(np "$1")" "$(np "$(dirname "$2")")/${2##*/}" "$3"
}

# json_ids <table.json> [<status>] — "id id ... " read straight from the JSON (no reader
# under test), in table order; the expected side whenever a case must not pin the entry set.
json_ids() {
  node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const s = process.argv[2] || "";
process.stdout.write(t.entries.filter((e) => !s || e.status === s).map((e) => e.id + " ").join(""));
' "$(np "$1")" "${2:-}"
}

# path_without <tool> — PATH minus every directory that holds <tool> or <tool>.exe.
path_without() {
  local out="" d
  local IFS=:
  for d in $PATH; do
    if [ -e "$d/$1" ] || [ -e "$d/$1.exe" ]; then continue; fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# same_text <label> <got-file> <want-file> — one pass/fail; the first differences on failure.
same_text() {
  if ! grep -q . "$3"; then
    fail "$1" "expected side is empty (its producer failed)"
  elif cmp -s "$2" "$3"; then
    pass "$1 ($(grep -c . "$3") lines)"
  else
    fail "$1" "$(diff "$3" "$2" | head -n 8 | tr '\n' ' ')"
  fi
}

# has_line <label> <haystack> <exact-line>
has_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then
    pass "$1"
  else
    fail "$1" "missing line [$3]"
  fi
}

# tlr_bash <checkout> <script> [args...] — run <script> in a fresh bash that has
# sourced <checkout>'s loader; prints its stdout (stderr goes to $TMPBASE/tlr.err).
tlr_bash() {
  local co="$1" body="$2"
  shift 2
  run_with_timeout 180 bash -c '. "$1/bin/lib/test-language-registry.sh" || exit 97; shift; '"$body" _ "$co" "$@" 2>"$TMPBASE/tlr.err"
}
