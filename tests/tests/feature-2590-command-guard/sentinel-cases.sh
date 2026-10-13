#!/usr/bin/env bash
# tests/tests/feature-2590-command-guard/sentinel-cases.sh — sourced by
# tests/tests/feature-2590-command-guard.sh: gh / glab / codex never run for real. Functions only.

# One network CLI through one route: exit 97, one hit naming the stub, and the hit carries the
# fixture test id. The real binaries are absent from SAFE_PATH, so a missing stub shows as 127.
cg_sentinel_route() {
  local tool="$1" route="$2" before hit
  before="$(hits_now)"
  case "$route" in
    bash) gx "$RR" bash -c "$tool api repos/x/y" ;;
    node) gx "$RR" node "$SPAWN_JS" "$tool" api repos/x/y ;;
    cmd)
      if [[ -n "$CG_EXE" ]]; then gx "$RR" cmd //d //c "$tool api repos/x/y"; else gx "$RR" sh -c "$tool api repos/x/y"; fi ;;
  esac
  expect_eq "$tool via $route: exits 97" "$RC" "97"
  expect_eq "$tool via $route: one hit" "$(hits_now)" "$((before + 1))"
  hit="$(cat "$(newest_hit)" 2>/dev/null)"
  expect_eq "$tool via $route: hit names the stub" "$(field "$hit" stub)" "$tool"
  expect_eq "$tool via $route: hit carries the test id" "$(field "$hit" test_id)" "$CG_TID"
  expect_has "$tool via $route: hit keeps the argv" "$(field "$hit" argv)" "repos/x/y"
}

cg_case_sentinels_every_route() {
  cg_require "network CLIs stop at the guard" || return 0
  local tool route
  for tool in gh glab codex; do
    for route in bash node cmd; do cg_sentinel_route "$tool" "$route"; done
  done
}

# Windows resolves bare names through PATHEXT, so the guard ships one .exe per CLI and nothing a
# cmd / PowerShell lookup could prefer instead. `ls` is used because MSYS `test -e x` also
# matches x.exe.
cg_case_bin_layout() {
  cg_require "guard bin holds one launcher per CLI" || return 0
  local listing tool
  listing=" $(ls -1 "$GDIR/bin" | tr '\n' ' ')"
  for tool in gh glab codex git; do
    if [[ -n "$CG_EXE" ]]; then
      expect_has "bin has $tool.exe" "$listing" " $tool.exe "
      expect_lacks "bin has no $tool.cmd" "$listing" " $tool.cmd "
      expect_lacks "bin has no extensionless $tool" "$listing" " $tool "
    else
      expect_has "bin has $tool" "$listing" " $tool "
      expect_eq "$tool is executable" "$([[ -x "$GDIR/bin/$tool" ]] && echo yes)" "yes"
    fi
  done
}

# A stripped environment keeps whatever PATH it is handed: the guard still answers first.
cg_case_env_stripped() {
  cg_require "env -i keeps the guard" || return 0
  local before
  before="$(hits_now)"
  gx "$RR" env -i "PATH=$GBIN_U:$SAFE_PATH" "ROOT_DECOY_TEST_ID=$CG_TID" gh auth status
  expect_eq "env -i gh: exits 97" "$RC" "97"
  expect_eq "env -i gh: one hit" "$(hits_now)" "$((before + 1))"
}

# A test's own CLI stub, placed ahead of the guard, keeps answering: the guard is a backstop.
cg_case_own_stub_wins() {
  cg_require "a test's own stub wins over the guard" || return 0
  local before
  mkdir -p "$TMP_ROOT/own stub"
  printf '#!/usr/bin/env bash\necho STUB-ANSWER\n' >"$TMP_ROOT/own stub/gh"
  chmod +x "$TMP_ROOT/own stub/gh"
  before="$(hits_now)"
  gx "$RR" bash -c 'PATH="$1:$PATH" gh api x' _ "$(upath "$TMP_ROOT/own stub")"
  expect_eq "own stub: exits 0" "$RC" "0"
  expect_eq "own stub: answers" "$OUT_TEXT" "STUB-ANSWER"
  expect_eq "own stub: no hit" "$(hits_now)" "$before"
}

# The same for glab and codex on every route, including Node's shell-less lookup, which on
# Windows sees only <name>.exe: tests/lib/cli-stub.sh makes node-copy stubs for exactly that.
cg_case_own_stub_wins_every_cli() {
  cg_require "own glab and codex stubs win over the guard" || return 0
  local tool route before log="$TMP_ROOT/own-cli-stub.log"
  . "$SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
  cli_stub_make "$TMP_ROOT/own cli stub" glab codex || { fail "own cli stubs" "cli_stub_make failed"; return 0; }
  local run=(env "PATH=$CLI_STUB_DIR:$GBIN_U:$SAFE_PATH" "NODE_OPTIONS=--require \"$CLI_STUB_PRELOAD\""
    "CLI_STUB_OUT=STUB-ANSWER" "CLI_STUB_LOG=$(np "$log")")
  for tool in glab codex; do
    for route in bash node cmd; do
      : >"$log"
      before="$(hits_now)"
      case "$route" in
        bash) gx "$RR" "${run[@]}" bash -c "$tool api x" ;;
        node) gx "$RR" "${run[@]}" node "$SPAWN_JS" "$tool" api x ;;
        cmd) if [[ -n "$CG_EXE" ]]; then gx "$RR" "${run[@]}" cmd //d //c "$tool api x"; else gx "$RR" "${run[@]}" sh -c "$tool api x"; fi ;;
      esac
      expect_eq "own $tool stub via $route: exits 0" "$RC" "0"
      expect_eq "own $tool stub via $route: answers" "$OUT_TEXT" "STUB-ANSWER"
      expect_eq "own $tool stub via $route: the stub ran once" "$(grep -c "^$tool api x" "$log")" "1"
      expect_eq "own $tool stub via $route: no hit" "$(hits_now)" "$before"
    done
  done
}
