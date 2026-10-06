# #2512 security-review cases (R26-R28) for feat-2511-state-root-routing.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# R26 (C5): a relative WORKFLOW_STATE_DIR is refused by every reader; absolute values
# are normalized, and an MSYS /c/... spelling is converted on Windows.
c_r26_relative_pin() {
  local sid lib out rc msys acd
  new_home r26
  sid="$(sid_of 2601)"
  mkdir -p "$T/cwd/rel-state"
  like_err() { if [[ "$2" == ERR:*"must be an absolute path"* ]]; then pass "$1"; else fail "$1" "got=[$2]"; fi; }
  like_err "R26 getStateRoot refuses a relative env pin" "$(pprobe rel-state root)"
  like_err "R26 getSessionStateDir refuses a relative env pin" "$(pprobe rel-state dir "$sid")"
  like_err "R26 listStateRoots refuses a relative env pin" "$(pprobe rel-state roots)"
  like_err "R26 a relative opts.pin is refused too" "$(dprobe dir "$sid" '{"pin":"rel-state"}')"
  eq "R26 an absolute pin is normalized" "$(pprobe "$H/a/../pinned" root)" "$H/pinned"
  eq "R26 a blank pin falls back to the default root" "$(pprobe "  " root)" "$NEW"
  if [[ "$H" =~ ^[A-Za-z]:/ ]]; then
    msys="/${H:0:1}"
    msys="${msys,,}${H:2}/pinned"
    eq "R26 an MSYS /c/... pin is converted to the drive form" "$(pprobe "$msys" root)" "$H/pinned"
  else
    skip "R26 MSYS pin conversion (not a drive-letter host)"
  fi
  rc=0
  (cd "$T/cwd" && run_with_timeout 30 env -u "$OLD_TOKEN" WORKFLOW_STATE_DIR=rel-state HOME="$H" USERPROFILE="$H" \
    node "$AGENTS_DIR/bin/workflow-state-dir" --global >/dev/null 2>&1) || rc=$?
  eq "R26 bin/workflow-state-dir exits 1 on a relative pin" "$rc" "1"
  lib="$AGENTS_DIR/bin/lib/safe-state-path.sh"
  rc=0
  (cd "$T/cwd" && run_with_timeout 30 env -u "$OLD_TOKEN" WORKFLOW_STATE_DIR=rel-state HOME="$H" USERPROFILE="$H" \
    bash -c '. "$1"; sp_control_dir "$2"' _ "$lib" "$sid" >/dev/null 2>"$T/r26-sp.err") || rc=$?
  eq "R26 sp_control_dir returns 1 on a relative pin" "$rc" "1"
  eq "R26 sp_control_dir names the rule on stderr" "$(grep -c 'must be an absolute path' "$T/r26-sp.err" || true)" "1"
  lib="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"
  rc=0
  out="$(cd "$T/cwd" && run_with_timeout 30 env -u "$OLD_TOKEN" WORKFLOW_STATE_DIR=rel-state HOME="$H" USERPROFILE="$H" \
    bash -c '. "$1"; _resolve_project_cache_dir "$(dirname "$1")"' _ "$lib" 2>/dev/null)" || rc=$?
  eq "R26 resolve-project has no cache dir for a relative pin" "$rc|$out" "1|"
  eq "R26 gh-env state is not persisted under a relative pin" \
    "$(pprobe rel-state ghsave "$sid")" '{"persisted":false,"failed":true}'
  eq "R26 nothing was written under the cwd-relative dir" "$(ls -A "$T/cwd/rel-state")" ""
  acd="$(np "$T/r26-acd")"
  mkdir -p "$acd"
  printf 'WORKFLOW_STATE_DIR=rel-state\n' >"$acd/.env"
  like_err "R26 the commit-push gate refuses a relative .env pin" "$(dprobe gateenv "$acd" "$sid")"
}

# R26b (round 2 C5): on Windows a driveless pin is cwd-drive-relative to Node, so only a
# drive form is absolute there; POSIX hosts keep every `/...` pin. The bash check keeps
# `/tmp/x` as a named exception because Git Bash hands node children its drive form.
c_r26b_driveless_pin() {
  local sid lib
  new_home r26b
  sid="$(sid_of 2611)"
  like_err() { if [[ "$2" == ERR:*"must be an absolute path"* ]]; then pass "$1"; else fail "$1" "got=[$2]"; fi; }
  if [[ "$(node -p process.platform)" == win32 ]]; then
    like_err "R26b a raw driveless /tmp/x env pin is refused on win32" "$(dprobe rawpin tmp/x)"
    like_err "R26b a raw driveless opts.pin is refused on win32" "$(dprobe dir "$sid" '{"pin":"\\tmp\\x"}')"
    like_err "R26b a raw UNC pin is refused on win32" "$(dprobe root '{"pin":"\\\\host\\share"}')"
    eq "R26b an MSYS /c/x pin is accepted on win32" "$(dprobe rawpin c/x)" "C:/x"
    eq "R26b a C:/x pin is accepted on win32" "$(dprobe root '{"pin":"C:/x"}')" "C:/x"
    eq "R26b a C:\\x pin is accepted on win32" "$(dprobe root '{"pin":"C:\\x"}')" "C:/x"
    eq "R26b Git Bash hands a node child the drive form of /tmp/x (why bash keeps it)" \
      "$(pprobe /tmp/x envpin | grep -cE '^[A-Za-z]:/' || true)" "1"
  else
    eq "R26b a POSIX /tmp/x pin stays absolute off Windows" "$(dprobe rawpin tmp/x)" "/tmp/x"
    skip "R26b win32 drive-form checks (not a win32 host)"
  fi
  lib="$AGENTS_DIR/bin/lib/safe-state-path.sh"
  isabs() { bash -c '. "$1"; _sp_is_abs_path "$2" && echo abs || echo rel' _ "$lib" "$1"; }
  eq "R26b _sp_is_abs_path accepts /c/x" "$(isabs /c/x)" "abs"
  eq "R26b _sp_is_abs_path accepts C:/x" "$(isabs C:/x)" "abs"
  eq "R26b _sp_is_abs_path accepts C:\\x" "$(isabs 'C:\x')" "abs"
  eq "R26b _sp_is_abs_path accepts /tmp/x (named exception)" "$(isabs /tmp/x)" "abs"
  eq "R26b _sp_is_abs_path refuses a relative pin" "$(isabs rel/x)" "rel"
}

# R26c (round 2 #4): a rejected relative pin must not open the other-session gate: the
# detection direction falls back to the default roots; the allow direction stays closed.
c_r26c_marker_gate_relative_pin() {
  local own other
  new_home r26c
  own="$(sid_of 2621)"
  other="$(sid_of 2622)"
  mkdir -p "$NEW" "$LEG" "$T/cwd/rel-state"
  eq "R26c premise: the relative pin is refused" \
    "$(pprobe rel-state root | grep -c 'must be an absolute path' || true)" "1"
  eq "R26c another session's new-root state is still blocked under a relative pin" \
    "$(pprobe rel-state markergate "$NEW/$other.json" "$own")" "false,true"
  eq "R26c another session's legacy-root state is still blocked under a relative pin" \
    "$(pprobe rel-state markergate "$LEG/$other.workflow-off" "$own")" "false,true"
  eq "R26c the own session's file is not allowed by the fast path under a relative pin" \
    "$(pprobe rel-state markergate "$NEW/$own.note" "$own")" "false,false"
}

# R27 (C2): the legacy root is listed when absent, and every caller treats it as empty.
c_r27_absent_legacy_root() {
  local own a out
  new_home r27
  own="$(sid_of 2700)"
  a="$(sid_of 2701)"
  eq "R27 a missing primary (new) root still makes the enumeration incomplete" "$(dprobe activecomplete "$own")" "false"
  probe_seed "$NEW" "$a"
  eq "R27 premise: no legacy root" "$(test -e "$LEG" || echo absent)" "absent"
  eq "R27 active ids still enumerate the new root" "$(dprobe active "$own")" "$own,$a"
  eq "R27 an absent legacy root keeps the enumeration complete" "$(dprobe activecomplete "$own")" "true"
  eq "R27 zombie cleanup tolerates the absent root" "$(dprobe zombies)" "done"
  out="$(dcli "$AGENTS_DIR/bin/workflow-state-dir" --roots || true)"
  eq "R27 --roots lists the absent legacy root" "$(roots_np "$out")" "$NEW,$LEG"
  eq "R27 a write into the not-yet-created legacy root is still control-dir" \
    "$(dprobe placement "$LEG/$a.json")" "control-dir"
  eq "R27 checking created no legacy root" "$(test -e "$LEG" || echo absent)" "absent"
}

# R28 (C6): a symlink or junction into a state root is the same write as the direct path.
c_r28_linked_placement() {
  local lnk out
  new_home r28
  mkdir -p "$NEW" "$LEG" "$H/elsewhere"
  lnk="$H/to-new"
  if [[ "$(dprobe link "$NEW" "$lnk")" != linked ]]; then
    skip "R28 linked placement (no symlink or junction on this host)"
    return 0
  fi
  dprobe link "$LEG" "$H/to-leg" >/dev/null
  dprobe link "$H/elsewhere" "$H/to-elsewhere" >/dev/null
  eq "R28 a write through a link to the new root is control-dir" "$(dprobe placement "$lnk/s1.json")" "control-dir"
  eq "R28 a write through a link to the legacy root is control-dir" "$(dprobe placement "$H/to-leg/s1.json")" "control-dir"
  eq "R28 a write into a linked control dir path is control-dir" \
    "$(dprobe placement "$lnk/s1.control/supervisor-state.json")" "control-dir"
  out="$(dprobe bashplacement "echo x > $lnk/\$UNSET_R28_VAR" "$(np "$T/cwd")")"
  eq "R28 a dynamic tail under a linked root is control-dir" "$out" "control-dir"
  eq "R28 a link to an unrelated dir stays allowed" "$(dprobe placement "$H/to-elsewhere/s1.json")" "null"
  eq "R28 a dynamic tail under an unrelated link stays allowed" \
    "$(dprobe bashplacement "echo x > $H/to-elsewhere/\$UNSET_R28_VAR" "$(np "$T/cwd")")" "null"
}
