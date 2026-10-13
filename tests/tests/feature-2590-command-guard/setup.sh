#!/usr/bin/env bash
# tests/tests/feature-2590-command-guard/setup.sh — sourced by
# tests/tests/feature-2590-command-guard.sh: helpers and the fixture tree. Functions only.
#
# Layout under $TMP_ROOT (a mktemp dir):
#   run root/   the fixture run root the guard under test allows (its TEST_RUN_ROOT)
#   outside/    repos standing in for "a real repo": outside that run root, never a real checkout
#   host tmp/   the fixture TEST_HOST_TMPDIR, so the guard cache is built here
#   home/       the fixture HOME / USERPROFILE, which must stay empty

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
nlow() { np "$1" | tr 'A-Z\\' 'a-z/'; }
upath() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
# Real git with the guard dirs dropped from PATH: fixture setup and read-only checks only.
rgit() { PATH="$SAFE_PATH" git "$@"; }
rcommit() { rgit -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "${2:-c}"; }

# cg_safe_path — SAFE_PATH: PATH without any command-guard dir and without every dir that
# holds a real gh / glab / codex; node is re-added from a private copy, since a version manager
# may keep node and codex in one dir. A test here can therefore never start the real CLIs.
cg_safe_path() {
  local d t keep node_bin parts=()
  node_bin="$(node -p 'process.execPath')" || return 1
  mkdir -p "$TMP_ROOT/node only" || return 1
  [[ -e "$TMP_ROOT/node only/node${CG_EXE}" ]] || ln "$node_bin" "$TMP_ROOT/node only/node${CG_EXE}" 2>/dev/null \
    || cp "$node_bin" "$TMP_ROOT/node only/node${CG_EXE}" || return 1
  SAFE_PATH="$(upath "$TMP_ROOT/node only")"
  IFS=: read -r -a parts <<<"$PATH"
  for d in "${parts[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    case "$d" in */command-guard/*|*/command-guard) continue ;; esac
    keep=1
    for t in gh gh.exe glab glab.exe codex codex.exe codex.cmd codex.ps1; do [[ -e "$d/$t" ]] && keep=0; done
    [[ "$keep" -eq 1 ]] && SAFE_PATH="$SAFE_PATH:$d"
  done
  PATH="$SAFE_PATH" command -v git >/dev/null 2>&1 || return 1
  PATH="$SAFE_PATH" command -v gh >/dev/null 2>&1 && return 1
  return 0
}

# cg_write_drivers — the ensure driver and the shell-less spawn helper.
cg_write_drivers() {
  cat >"$TMP_ROOT/ensure-driver.sh" <<'DRIVER'
source "$1/tests/lib/command-guard.sh" || exit 90
command_guard_ensure || exit 91
if [[ "${2:-}" == twice ]]; then command_guard_ensure || exit 92; fi
printf 'GDIR=%s\nPATH=%s\n' "${COMMAND_GUARD_DIR:-}" "$PATH"
if [[ "${2:-}" == use-real ]]; then
  command_guard_use_real; printf 'USE_REAL_RC=%s\nREALPATH=%s\nGITNOW=%s\n' "$?" "$PATH" "$(command -v git)"
fi
if [[ "${2:-}" == hits ]]; then
  printf 'HITCOUNT=%s\n' "$(command_guard_hit_count "$COMMAND_GUARD_DIR")"
  command_guard_hits "$COMMAND_GUARD_DIR" | sed 's/^/HITLINE=/'
fi
DRIVER
  printf '%s\n' 'const r = require("child_process").spawnSync(process.argv[2], process.argv.slice(3), { stdio: ["ignore", "pipe", "pipe"] });' \
    'if (r.stdout) process.stdout.write(r.stdout);' \
    'process.exit(r.status === null ? 99 : r.status);' >"$TMP_ROOT/spawn.js"
  SPAWN_JS="$(np "$TMP_ROOT/spawn.js")"
}

# cg_ensure <run root> [twice|use-real|hits] — command_guard_ensure in a clean child: the fixture
# run root, host temp and home, no inherited guard, SAFE_PATH only.
cg_ensure() {
  (cd "$TMP_ROOT" && env -u COMMAND_GUARD_DIR TEST_RUN_ROOT="$1" TEST_HOST_TMPDIR="$HOST" HOME="$FHOME" USERPROFILE="$FHOME" \
    PATH="$SAFE_PATH" bash "$RWT" 120 bash "$TMP_ROOT/ensure-driver.sh" "$SCRIPT_CHECKOUT_ROOT" "${2:-}" 2>&1)
}

# gx <cwd> <command...> — runs with the fixture guard first on PATH; sets RC, OUT_TEXT, ERR_TEXT.
gx() {
  local cwd="$1"
  shift
  RC=0
  (cd "$cwd" && PATH="$GBIN_U:$SAFE_PATH" ROOT_DECOY_TEST_ID="$CG_TID" HOME="$FHOME" USERPROFILE="$FHOME" \
    bash "$RWT" 60 "$@") >"$TMP_ROOT/gx.out" 2>"$TMP_ROOT/gx.err" || RC=$?
  OUT_TEXT="$(cat "$TMP_ROOT/gx.out")"
  ERR_TEXT="$(cat "$TMP_ROOT/gx.err")"
}

hits_now() { find "$GDIR/hits" -type f -name '*.hit' 2>/dev/null | wc -l | tr -d ' '; }
newest_hit() { ls -t "$GDIR/hits"/*.hit 2>/dev/null | head -n 1; }

# expect_reject <label> <cwd> <command...> — exit 97 and exactly one new hit.
expect_reject() {
  local label="$1" cwd="$2" before
  shift 2
  before="$(hits_now)"
  gx "$cwd" "$@"
  expect_eq "$label: exits 97" "$RC" "97"
  expect_eq "$label: records one hit" "$(hits_now)" "$((before + 1))"
}

# expect_allow <label> <cwd> <command...> — exit 0 and no new hit.
expect_allow() {
  local label="$1" cwd="$2" before
  shift 2
  before="$(hits_now)"
  gx "$cwd" "$@"
  expect_eq "$label: exits 0" "$RC" "0"
  expect_eq "$label: records no hit" "$(hits_now)" "$before"
}

# cg_require <label> — one FAIL and a non-zero return while the guard is not built, so no case
# below ever runs a command that the guard should have intercepted.
cg_require() {
  [[ "$GUARD_READY" -eq 1 ]] && return 0
  fail "$1" "command guard not installed (${ENSURE_OUT:-no output})"
  return 1
}

cg_setup() {
  CG_EXE=""
  [[ "$(node -p 'process.platform')" == "win32" ]] && CG_EXE=".exe"
  RR="$TMP_ROOT/run root"
  OUTSIDE="$TMP_ROOT/outside"
  HOST="$TMP_ROOT/host tmp"
  FHOME="$TMP_ROOT/home"
  CG_TID="cg-run:tests/tests/fixture-$$.sh"
  mkdir -p "$RR" "$OUTSIDE/plain" "$HOST" "$FHOME" || return 1
  cg_safe_path || { echo "cannot build a PATH without the real CLIs" >&2; return 1; }
  cg_write_drivers
  OUT_REPO="$OUTSIDE/real repo"
  IN_REPO="$RR/in repo"
  BARE="$OUTSIDE/bare.git"
  PATH="$SAFE_PATH" harness_git_init "$OUT_REPO" && rcommit "$OUT_REPO" init || return 1
  PATH="$SAFE_PATH" harness_git_init "$IN_REPO" && rcommit "$IN_REPO" init || return 1
  rgit init -q --bare "$BARE" || return 1
  rgit -C "$OUT_REPO" config alias.zz status || return 1
  rgit -C "$OUT_REPO" worktree add -q -b linked "$RR/linked" || return 1
  rgit -C "$IN_REPO" worktree add -q -b away "$OUTSIDE/wt of inner" || return 1
  PATH="$SAFE_PATH" harness_git_init "$RR/split" || return 1
  rgit -C "$RR/split" config core.worktree "$(np "$OUTSIDE/plain")" || return 1
  printf 'x\n' >"$OUTSIDE/plain/file.txt"
  OUT_HEAD="$(rgit -C "$OUT_REPO" rev-parse HEAD)"
  # Read back, not "/dev/null": MSYS argument conversion stores it as "nul" on Windows.
  OUT_HOOKS="$(rgit -C "$OUT_REPO" config --get core.hooksPath)"
  [[ -n "$OUT_HOOKS" ]] || return 1
  ENSURE_OUT="$(cg_ensure "$RR")"
  GDIR="$(field "$ENSURE_OUT" GDIR)"
  GBIN_U="$(upath "${GDIR:-$TMP_ROOT/no guard}/bin")"
  GUARD_READY=0
  [[ -n "$GDIR" && -f "$GDIR/bin/gh$CG_EXE" && -f "$GDIR/bin/git$CG_EXE" && -f "$GDIR/guard.conf" ]] && GUARD_READY=1
  return 0
}
