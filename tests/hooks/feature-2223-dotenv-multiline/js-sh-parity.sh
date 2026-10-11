#!/usr/bin/env bash
# tests/hooks/feature-2223-dotenv-multiline/js-sh-parity.sh
# Tests: hooks/lib/load-env.js, hooks/lib/load-env.sh
# Tags: scope:common, TL2, load-env, dotenv, parser, security, parity, pwsh-not-required
# Run as a child process by tests/hooks/feature-2223-dotenv-multiline.sh (separate pass/fail counters).
# js is the reference: each row feeds one .env to both loaders and compares exports and env-blind reads.
# Intended differences: multi-line quoted key (sh drops it), no-node #@if path, js-only .env.local overlay.
# ENFORCE_WORKTREE fails closed in both sh readers; no loader warning ever prints a discarded value.
# TL3 gap (what this test does NOT catch):
# - a real git hook process sourcing load-env.sh with the host's inherited environment
# Closest-to-action mitigation: the pre-commit hook tests that drive a fixture repo.

set -uo pipefail

# The classification table marks this directory sourced, so the root takes the prefixed name.
_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RWT="$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
source "$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
source "$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

TMP_ROOT="$(np "$(make_tmp)")"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset ENFORCE_WORKTREE AGENTS_HOOK_DEBUG
while IFS= read -r v; do [[ "$v" == LEP_* ]] && unset "$v"; done < <(compgen -e)

readonly NEUTRAL="$TMP_ROOT/neutral"
readonly ROWS="$TMP_ROOT/rows"
readonly ERR_FILE="$TMP_ROOT/last.err"
mkdir -p "$NEUTRAL" "$ROWS"
JS_LIB="$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/hooks/lib/load-env.js"
SH_LIB="$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/hooks/lib/load-env.sh"
PROJ_DIR="$NEUTRAL"
LEP_ENV=()

cat >"$TMP_ROOT/print-env.js" <<'PROBE'
const keys = process.argv.slice(2);
process.stdout.write(JSON.stringify(Object.fromEntries(keys.map((k) => [k, process.env[k] !== undefined ? process.env[k] : null]))));
PROBE
cat >"$TMP_ROOT/js-probe.js" <<'PROBE'
const [lib, mode, ...specs] = process.argv.slice(2);
if (process.env.LEP_POSIXIFY_ROOT === "1") {
  const w = process.env.AGENTS_MAIN_ROOT || "";
  if (/^[A-Za-z]:[\\/]/.test(w)) process.env.AGENTS_MAIN_ROOT = "/" + w[0].toLowerCase() + w.slice(2).replace(/\\/g, "/");
}
delete process.env.LEP_POSIXIFY_ROOT;
const m = require(lib);
const split = (s) => { const i = s.indexOf(":-"); return i < 0 ? [s, "__DFLT__"] : [s.slice(0, i), s.slice(i + 2)]; };
const lines = (src) => specs.map((s) => { const [k, d] = split(s); return k + "=<" + (src[k] ? src[k] : d) + ">"; }).join("\n");
if (mode === "export") {
  m.loadDefaultEnv();
  process.stdout.write(JSON.stringify(Object.fromEntries(specs.map((k) => [k, process.env[k] !== undefined ? process.env[k] : null]))));
} else if (mode === "exportval") {
  m.loadDefaultEnv();
  process.stdout.write(lines(process.env));
} else {
  process.stdout.write(lines(m.readDefaultEnvFile()));
}
PROBE
cat >"$TMP_ROOT/sh-probe.sh" <<'PROBE'
. "$1" || exit 90
mode="$2"; printjs="$3"; shift 3
out=""
case "$mode" in
  export) _load_env_file; exec node "$printjs" "$@" ;;
  exportval) _load_env_file ;;
esac
for spec in "$@"; do
  k="${spec%%:-*}"; d="__DFLT__"; [ "$k" = "$spec" ] || d="${spec#*:-}"
  if [ "$mode" = exportval ]; then v="${!k:-$d}"; else v="$(_load_env_only_value "$k:-$d")"; fi
  out="$out${out:+$'\n'}$k=<$v>"
done
printf '%s' "$out"
PROBE

# run <js|sh> <export|exportval|guard> <settings-root|-> <key-or-spec...>; stderr lands in $ERR_FILE.
run() {
  local impl="$1" mode="$2" cfg="$3"; shift 3
  local args=(-u AGENTS_MAIN_ROOT -u ENFORCE_WORKTREE "CLAUDE_PROJECT_DIR=$PROJ_DIR" ${LEP_ENV[@]+"${LEP_ENV[@]}"})
  [[ "$cfg" != "-" ]] && args+=("AGENTS_MAIN_ROOT=$cfg")
  if [[ "$impl" == js ]]; then
    (cd "$NEUTRAL" && env "${args[@]}" bash "$RWT" 60 node "$TMP_ROOT/js-probe.js" "$(np "$JS_LIB")" "$mode" "$@" 2>"$ERR_FILE")
  else
    (cd "$NEUTRAL" && env "${args[@]}" bash "$RWT" 60 bash "$TMP_ROOT/sh-probe.sh" "$SH_LIB" "$mode" "$TMP_ROOT/print-env.js" "$@" 2>"$ERR_FILE")
  fi
}

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$3") got=$(printf '%q' "$2")"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
ACTIVE="$(node -e 'process.stdout.write(process.platform === "win32" ? "windows" : "posix")')"
if [[ "$ACTIVE" == windows ]]; then INACTIVE=posix; else INACTIVE=windows; fi
decode() {
  local s="$1"
  s="${s//@NL@/$'\n'}"; s="${s//@CR@/$'\r'}"; s="${s//@SP@/ }"; s="${s//@TAB@/$'\t'}"
  s="${s//@ACTIVE@/$ACTIVE}"; s="${s//@INACTIVE@/$INACTIVE}"
  printf '%s' "$s"
}
# row_cfg <name> <encoded .env> — prints a fresh settings root holding exactly that .env.
row_cfg() { mkdir -p "$ROWS/$1"; printf '%s\n' "$(decode "$2")" >"$ROWS/$1/.env"; printf '%s' "$ROWS/$1"; }
set_env() { LEP_ENV=(); [[ "$1" == "-" ]] || IFS=',' read -r -a LEP_ENV <<<"$1"; }
plant_raw_filter() { mkdir -p "$1/bin"; printf '#!/usr/bin/env bash\ncat "$1"\n' >"$1/bin/env-os-filter"; chmod +x "$1/bin/env-os-filter"; }

case_begin "parity-table-export-and-guard" "hooks/lib/load-env.sh"
# Columns: name | pre-exported env (- or A=1,B=) | .env (@NL@ @CR@ @SP@ @TAB@) | keys | js export anchor
ROWS_SEEN=0
while IFS='|' read -r name envs content keys want; do
  name="$(trim "$name")"
  [[ -z "$name" || "$name" == \#* ]] && continue
  ROWS_SEEN=$((ROWS_SEEN + 1))
  set_env "$(trim "$envs")"
  cfg="$(row_cfg "$name" "$(trim "$content")")"
  IFS=',' read -r -a K <<<"$(trim "$keys")"
  js="$(run js export "$cfg" "${K[@]}")"
  expect_eq "$name: js export anchor" "$js" "$(trim "$want")"
  expect_eq "$name: sh export equals js" "$(run sh export "$cfg" "${K[@]}")" "$js"
  jsg="$(run js guard "$cfg" "${K[@]}")"
  expect_has "$name: js guard answered" "$jsg" "${K[0]}=<"
  expect_eq "$name: sh guard reader equals js" "$(run sh guard "$cfg" "${K[@]}")" "$jsg"
done <<'TABLE'
q-dq-trailing-comment  | -              | LEP_A="a" # c                                  | LEP_A             | {"LEP_A":"a"}
q-sq-trailing-comment  | -              | LEP_A='a' # c                                  | LEP_A             | {"LEP_A":"a"}
q-dq-escapes           | -              | LEP_A="x\ty\\z\"w"                             | LEP_A             | {"LEP_A":"x\ty\\z\"w"}
q-dq-newline-escape    | -              | LEP_A="l1\nl2"                                 | LEP_A             | {"LEP_A":"l1\nl2"}
q-dq-unknown-escape    | -              | LEP_A="a\qb"                                   | LEP_A             | {"LEP_A":"a\\qb"}
q-sq-no-escape         | -              | LEP_A='a\nb'                                   | LEP_A             | {"LEP_A":"a\\nb"}
q-dq-escaped-then-close| -              | LEP_A="a\"b" tail"                             | LEP_A             | {"LEP_A":"a\"b"}
q-bare-hash-kept       | -              | LEP_A=bare # x                                 | LEP_A             | {"LEP_A":"bare # x"}
q-dq-empty             | -              | LEP_A=""@NL@LEP_B=after                        | LEP_A,LEP_B       | {"LEP_A":"","LEP_B":"after"}
ml-closed-surrounded   | -              | LEP_B=before@NL@LEP_ML="l1@NL@l2"@NL@LEP_A=after | LEP_B,LEP_A     | {"LEP_B":"before","LEP_A":"after"}
ml-inner-kv-dq         | -              | LEP_ML="l1@NL@LEP_OTHER=x@NL@l3"@NL@LEP_A=after | LEP_OTHER,LEP_A  | {"LEP_OTHER":null,"LEP_A":"after"}
ml-inner-kv-sq         | -              | LEP_ML='l1@NL@LEP_OTHER=x@NL@l3'@NL@LEP_A=after | LEP_OTHER,LEP_A  | {"LEP_OTHER":null,"LEP_A":"after"}
ml-close-line-tail     | -              | LEP_ML="l1@NL@l2" LEP_X=y@NL@LEP_A=after       | LEP_X,LEP_A       | {"LEP_X":null,"LEP_A":"after"}
ml-escaped-quote-runs  | -              | LEP_ML="a\"@NL@LEP_OTHER=x@NL@"@NL@LEP_A=after | LEP_OTHER,LEP_A   | {"LEP_OTHER":null,"LEP_A":"after"}
ml-unclosed-drops-tail | -              | LEP_P=ok@NL@LEP_U="open@NL@LEP_LATER=x@NL@LEP_LAST=y | LEP_P,LEP_U,LEP_LATER,LEP_LAST | {"LEP_P":"ok","LEP_U":null,"LEP_LATER":null,"LEP_LAST":null}
dup-last-wins          | -              | LEP_D=first@NL@LEP_D=second                    | LEP_D             | {"LEP_D":"second"}
pre-empty-loses        | LEP_E=         | LEP_E=fromfile                                 | LEP_E             | {"LEP_E":"fromfile"}
pre-empty-dup          | LEP_E=         | LEP_E=a@NL@LEP_E=b                             | LEP_E             | {"LEP_E":"b"}
pre-nonempty-wins      | LEP_E=shell    | LEP_E=a@NL@LEP_E=b                             | LEP_E             | {"LEP_E":"shell"}
ws-leading-spaces      | -              | @SP@@SP@LEP_W=v                                | LEP_W             | {"LEP_W":"v"}
ws-leading-tab         | -              | @TAB@LEP_W=v                                   | LEP_W             | {"LEP_W":"v"}
ws-trailing-spaces     | -              | LEP_W=v@SP@@SP@@NL@LEP_X="q"@SP@               | LEP_W,LEP_X       | {"LEP_W":"v","LEP_X":"q"}
ws-crlf                | -              | LEP_W=v@CR@@NL@LEP_X="q"@CR@@NL@LEP_Y=z@CR@    | LEP_W,LEP_X,LEP_Y | {"LEP_W":"v","LEP_X":"q","LEP_Y":"z"}
ws-indented-comment    | -              | @SP@@SP@# LEP_W=v@NL@LEP_X=1                   | LEP_W,LEP_X       | {"LEP_W":null,"LEP_X":"1"}
ws-around-equals       | -              | LEP_W = v                                      | LEP_W             | {"LEP_W":"v"}
os-block-with-node     | -              | LEP_O=1@NL@#@if @ACTIVE@@NL@LEP_ON=a@NL@#@endif@NL@#@if @INACTIVE@@NL@LEP_OFF=b@NL@#@endif | LEP_O,LEP_ON,LEP_OFF | {"LEP_O":"1","LEP_ON":"a","LEP_OFF":null}
empty-value            | -              | LEP_V=                                         | LEP_V             | {"LEP_V":""}
empty-then-set         | -              | LEP_V=@NL@LEP_V=x                              | LEP_V             | {"LEP_V":"x"}
set-then-empty         | -              | LEP_V=x@NL@LEP_V=                              | LEP_V             | {"LEP_V":""}
TABLE
expect_eq "the parity table asserted every one of its rows" "$ROWS_SEEN" "29"
set_env -
case_end

case_begin "multi-line-key-is-the-only-intended-difference" "hooks/lib/load-env.sh"
ML_CFG="$(row_cfg ml-key 'LEP_B=before@NL@LEP_ML="MLSECRET1@NL@MLSECRET2"@NL@LEP_A=after')"
U_CFG="$(row_cfg unclosed-key 'LEP_P=ok@NL@LEP_U="USECRET@NL@LEP_LATER=x')"
expect_eq "js keeps the multi-line value" "$(run js export "$ML_CFG" LEP_ML)" '{"LEP_ML":"MLSECRET1\nMLSECRET2"}'
expect_eq "sh exports no multi-line key" "$(run sh export "$ML_CFG" LEP_ML LEP_B LEP_A)" '{"LEP_ML":null,"LEP_B":"before","LEP_A":"after"}'
SH_ERR="$(cat "$ERR_FILE")"
expect_has "sh names the dropped key and why" "$SH_ERR" "load-env.sh: LEP_ML discarded — multi-line quoted value not supported"
expect_eq "sh warns exactly once for the key" "$(grep -c 'LEP_ML' "$ERR_FILE")" "1"
expect_lacks "sh never prints the dropped value" "$SH_ERR" "MLSECRET"
expect_eq "the sh guard reader has no multi-line key either" "$(run sh guard "$ML_CFG" LEP_ML:-dflt)" "LEP_ML=<dflt>"
expect_eq "sh drops an unclosed key and every later line" "$(run sh export "$U_CFG" LEP_P LEP_U LEP_LATER)" '{"LEP_P":"ok","LEP_U":null,"LEP_LATER":null}'
SH_ERR="$(cat "$ERR_FILE")"
expect_has "sh names the unclosed key" "$SH_ERR" "load-env.sh: LEP_U discarded — unterminated quote"
expect_lacks "sh never prints the unclosed value" "$SH_ERR" "USECRET"
# Symmetric to the sh checks above: the js warning names the discarded key but never its value,
# on the export path and the env-blind reader alike, and AGENTS_HOOK_DEBUG=1 widens neither.
for dbg in - AGENTS_HOOK_DEBUG=1; do
  set_env "$dbg"
  run js export "$U_CFG" LEP_P LEP_U >/dev/null
  JS_ERR="$(cat "$ERR_FILE")"
  expect_has "js export [$dbg] names the unclosed key" "$JS_ERR" "LEP_U"
  expect_lacks "js export [$dbg] never prints the unclosed value" "$JS_ERR" "USECRET"
  run js guard "$U_CFG" LEP_P LEP_U >/dev/null
  expect_lacks "js guard reader [$dbg] never prints the unclosed value" "$(cat "$ERR_FILE")" "USECRET"
  run js export "$ML_CFG" LEP_ML >/dev/null
  expect_lacks "js export [$dbg] stderr never carries the multi-line value" "$(cat "$ERR_FILE")" "MLSECRET"
  run sh export "$U_CFG" LEP_P LEP_U >/dev/null
  expect_lacks "sh export [$dbg] never prints the unclosed value" "$(cat "$ERR_FILE")" "USECRET"
  run sh export "$ML_CFG" LEP_ML >/dev/null
  expect_lacks "sh export [$dbg] never prints the multi-line value" "$(cat "$ERR_FILE")" "MLSECRET"
done
set_env -
case_end

case_begin "os-block-without-node-filter-is-dropped" "hooks/lib/load-env.sh"
cfg="$(row_cfg raw-filter 'LEP_O=1@NL@#@if windows@NL@LEP_WIN=w@NL@#@endif@NL@#@if posix@NL@LEP_POS=p@NL@#@endif@NL@LEP_T=t')"
plant_raw_filter "$cfg"
expect_eq "sh exports neither OS block when the filter passed the markers through" "$(run sh export "$cfg" LEP_O LEP_WIN LEP_POS LEP_T)" '{"LEP_O":"1","LEP_WIN":null,"LEP_POS":null,"LEP_T":"t"}'
expect_has "sh warns that the OS filter did not run" "$(cat "$ERR_FILE")" "load-env.sh"
expect_eq "the sh guard reader drops both OS blocks too" "$(run sh guard "$cfg" LEP_WIN LEP_POS LEP_T)" $'LEP_WIN=<__DFLT__>\nLEP_POS=<__DFLT__>\nLEP_T=<t>'
expect_has "js (node path) keeps the active OS block — the intended difference" "$(run js export "$cfg" LEP_WIN LEP_POS)" "\"$([[ "$ACTIVE" == windows ]] && echo w || echo p)\""
case_end

case_begin "guard-enforce-worktree-fails-closed" "hooks/lib/load-env.sh"
# Columns: name | pre-exported env | .env | js export,js guard,sh export,sh guard (value of ENFORCE_WORKTREE:-on)
FC_ROWS=0
while IFS='|' read -r name envs content want; do
  name="$(trim "$name")"
  [[ -z "$name" || "$name" == \#* ]] && continue
  FC_ROWS=$((FC_ROWS + 1))
  set_env "$(trim "$envs")"
  cfg="$(row_cfg "$name" "$(trim "$content")")"
  [[ "$name" == fc-filter-failed-* ]] && plant_raw_filter "$cfg"
  IFS=',' read -r w_je w_jg w_se w_sg <<<"$(trim "$want")"
  if [[ "$w_je" != "-" ]]; then
    expect_eq "$name: js export anchor" "$(run js exportval "$cfg" ENFORCE_WORKTREE:-on)" "ENFORCE_WORKTREE=<$w_je>"
    expect_eq "$name: js guard anchor" "$(run js guard "$cfg" ENFORCE_WORKTREE:-on)" "ENFORCE_WORKTREE=<$w_jg>"
  fi
  expect_eq "$name: sh export path" "$(run sh exportval "$cfg" ENFORCE_WORKTREE:-on)" "ENFORCE_WORKTREE=<$w_se>"
  expect_eq "$name: sh guard reader" "$(run sh guard "$cfg" ENFORCE_WORKTREE:-on)" "ENFORCE_WORKTREE=<$w_sg>"
done <<'TABLE'
fc-ml-quoted-off           | -                  | ENFORCE_WORKTREE="off@NL@"                             | off,off,on,on
fc-inside-dq               | -                  | NOTE="line1@NL@ENFORCE_WORKTREE=off@NL@line3"          | on,on,on,on
fc-inside-sq               | -                  | NOTE='line1@NL@ENFORCE_WORKTREE=off@NL@line3'          | on,on,on,on
fc-escaped-quote-closed    | -                  | NOTE="a\"@NL@ENFORCE_WORKTREE=off@NL@"                 | on,on,on,on
fc-escaped-quote-unclosed  | -                  | NOTE="a\"@NL@ENFORCE_WORKTREE=off                      | on,on,on,on
fc-unclosed-dq-then-off    | -                  | NOTE="abc@NL@ENFORCE_WORKTREE=off                      | on,on,on,on
fc-unclosed-sq-then-off    | -                  | NOTE='abc@NL@ENFORCE_WORKTREE=off                      | on,on,on,on
fc-filter-failed-active    | -                  | #@if @ACTIVE@@NL@ENFORCE_WORKTREE=off@NL@#@endif       | -,-,on,on
fc-filter-failed-inactive  | -                  | #@if @INACTIVE@@NL@ENFORCE_WORKTREE=off@NL@#@endif     | -,-,on,on
fc-empty-export-file-on    | ENFORCE_WORKTREE=  | ENFORCE_WORKTREE=on                                    | on,on,on,on
fc-empty-export-no-key     | ENFORCE_WORKTREE=  | OTHER_KEY=1                                            | on,on,on,on
fc-empty-export-file-off   | ENFORCE_WORKTREE=  | ENFORCE_WORKTREE=off                                   | off,off,off,off
fc-ambient-off-guard-blind | ENFORCE_WORKTREE=off | ENFORCE_WORKTREE=on                                  | off,on,off,on
TABLE
expect_eq "the fail-closed table asserted every one of its rows" "$FC_ROWS" "13"
set_env -
case_end

case_begin "overlay-is-js-only" "hooks/lib/load-env.js"
cfg="$(row_cfg overlay 'LEP_OV=global')"
PROJ_DIR="$TMP_ROOT/overlay-project"
mkdir -p "$PROJ_DIR"
printf 'LEP_OV=local\n' >"$PROJ_DIR/.env"".local"
expect_eq "js export applies the project overlay" "$(run js export "$cfg" LEP_OV)" '{"LEP_OV":"local"}'
expect_eq "sh export has no overlay — the intended difference" "$(run sh export "$cfg" LEP_OV)" '{"LEP_OV":"global"}'
expect_eq "both env-blind readers read the global file only" "$(run sh guard "$cfg" LEP_OV)" "$(run js guard "$cfg" LEP_OV)"
PROJ_DIR="$NEUTRAL"
case_end

# Items 1, 2: the settings root itself. These need copies of the loaders so the module-relative
# candidate is a fixture, not this checkout.
readonly FAKE="$TMP_ROOT/copied checkout"
if ! script_checkout_fixture_copy "$FAKE" hooks/lib bin/env-os-filter; then
  echo "FAIL: fixture checkout copy — script_checkout_fixture_copy failed"
  exit 1
fi
printf 'LEP_R=checkout\n' >"$FAKE/.env"

case_begin "whitespace-root-reads-as-unset-in-every-reader" "hooks/lib/load-env.js"
JS_LIB="$FAKE/hooks/lib/load-env.js"
SH_LIB="$FAKE/hooks/lib/load-env.sh"
expect_eq "js guard reader" "$(run js guard "   " LEP_R)" "LEP_R=<checkout>"
expect_eq "js export" "$(run js exportval "   " LEP_R)" "LEP_R=<checkout>"
expect_eq "sh guard reader" "$(run sh guard "   " LEP_R)" "LEP_R=<checkout>"
expect_eq "sh export" "$(run sh exportval "   " LEP_R)" "LEP_R=<checkout>"
case_end

case_begin "symlinked-install-falls-back-to-the-physical-checkout" "hooks/lib/load-env.sh"
readonly LINKED="$TMP_ROOT/linked install"
mkdir -p "$LINKED"
rm -f "$FAKE/.env"
printf 'LEP_R=physical\n' >"$FAKE/.env"
MSYS=winsymlinks:nativestrict ln -s "$FAKE/hooks" "$LINKED/hooks" 2>/dev/null
if [[ ! -L "$LINKED/hooks" ]]; then
  skip "symlinked install (this host cannot create a symbolic link)"
else
  JS_LIB="$LINKED/hooks/lib/load-env.js"
  SH_LIB="$LINKED/hooks/lib/load-env.sh"
  expect_eq "js reads the .env behind the link" "$(run js guard - LEP_R)" "LEP_R=<physical>"
  expect_eq "sh guard reader reads the .env behind the link" "$(run sh guard - LEP_R)" "LEP_R=<physical>"
  expect_eq "sh export reads the .env behind the link" "$(run sh exportval - LEP_R)" "LEP_R=<physical>"
fi
JS_LIB="$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/hooks/lib/load-env.js"
SH_LIB="$_JS_SH_PARITY_SCRIPT_CHECKOUT_ROOT/hooks/lib/load-env.sh"
case_end

case_begin "posix-drive-letter-root-parity" "hooks/lib/load-env.js"
if ! command -v cygpath >/dev/null 2>&1; then
  skip "POSIX drive-letter root (the /c/... form only exists on Windows)"
else
  cfg="$(row_cfg msys 'LEP_M=msys')"
  LEP_ENV=("LEP_POSIXIFY_ROOT=1")
  expect_eq "js guard reader normalizes /c/..." "$(run js guard "$cfg" LEP_M)" "LEP_M=<msys>"
  expect_eq "js export normalizes /c/..." "$(run js exportval "$cfg" LEP_M)" "LEP_M=<msys>"
  set_env -
  expect_eq "sh guard reader reads /c/... natively" "$(run sh guard "$(cygpath -u "$cfg")" LEP_M)" "LEP_M=<msys>"
  expect_eq "sh export reads /c/... natively" "$(run sh exportval "$(cygpath -u "$cfg")" LEP_M)" "LEP_M=<msys>"
fi
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
