# remaining and session-close cases (M9-M12) for feat-2511-session-relocation.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# line_for <sid> — the remaining output line that names <sid>.
line_for() { grep -F "$1" <<<"$MV_OUT" | head -1 || true; }

c_m9_remaining() {
  local u m i
  new_home m9
  u="$(sid_of 901)" m="$(sid_of 902)" i="$(sid_of 903)"
  mkdir -p "$LEG/wr1.control" "$LEG/c1-sid.control" "$LEG/cache" "$LEG/$i.instructions-loaded"
  printf '{}\n' >"$LEG/$u.json"
  printf '{}\n' >"$LEG/20260101-120000.json"
  printf 'x\n' >"$LEG/$m.turn-marker"
  printf 'log\n' >"$LEG/control-migration.log"
  mv_run remaining
  eq "M9 sessions left -> exit 1" "$MV_RC" "1"
  eq "M9 REMAINING_SIDS counts every discriminator-file shape" "$(grep -c '^REMAINING_SIDS=4$' <<<"$MV_OUT" || true)" "1"
  like "M9 the uuid sid is classified uuid" "$(line_for "$u")" "*uuid*"
  like "M9 the timestamp fallback sid is classified timestamp" "$(line_for 20260101-120000)" "*timestamp*"
  like "M9 wr1 is classified other" "$(line_for wr1)" "*other*"
  like "M9 c1-sid is classified other" "$(line_for c1-sid)" "*other*"
  eq "M9 a marker-only sid is not counted" "$(line_for "$m")" ""
  eq "M9 an instructions-loaded-only sid is not counted" "$(line_for "$i")" ""
  eq "M9 global files are not counted" "$(grep -cE 'control-migration|cache' <<<"$MV_OUT" || true)" "0"
  rm -rf "$LEG"
  mkdir -p "$LEG"
  printf 'x\n' >"$LEG/$m.turn-marker"
  mv_run remaining
  eq "M9 nothing left -> exit 0" "$MV_RC" "0"
  eq "M9 nothing left -> REMAINING_SIDS=0" "$(grep -c '^REMAINING_SIDS=0$' <<<"$MV_OUT" || true)" "1"
}

# close_tree — a config tree whose bin/ holds a call-recording supervisor-report stub
# and a pass-through state-dir-relocation; the script under test is copied in, so
# either way it resolves bin/ it reaches the stubs. Sets CFG and STUB_LOG.
close_tree() {
  CFG="$T/cfg-$1"
  STUB_LOG="$(np "$T/stub-$1.log")"
  mkdir -p "$CFG/bin" "$CFG/skills/session-close/scripts"
  : >"$STUB_LOG"
  cp "$SCRIPT_CHECKOUT_ROOT/skills/session-close/scripts/relocate-session-state.sh" \
    "$CFG/skills/session-close/scripts/" 2>/dev/null || true
  printf '%s\n' '#!/usr/bin/env node' \
    "\":\" //; exec node \"$A/bin/state-dir-relocation\" \"\$@\"" \
    "const r = require(\"child_process\").spawnSync(process.execPath, [\"$A/bin/state-dir-relocation\", ...process.argv.slice(2)], { stdio: \"inherit\" });" \
    'process.exit(r.status === null ? 1 : r.status);' >"$CFG/bin/state-dir-relocation"
  printf '%s\n' '#!/usr/bin/env node' \
    "\":\" //; printf '%s\\n' \"\$*\" >>\"\$STUB_LOG\"; exit 0" \
    'require("fs").appendFileSync(process.env.STUB_LOG, process.argv.slice(2).join(" ") + "\n");' \
    >"$CFG/bin/supervisor-report"
  chmod +x "$CFG/bin/state-dir-relocation" "$CFG/bin/supervisor-report"
}

# close_run <sid> — the session-close relocation script; FAULT as for mv_run.
close_run() {
  MV_RC=0
  MV_OUT="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
    AGENTS_MAIN_ROOT="$(np "$CFG")" STUB_LOG="$STUB_LOG" ${FAULT:+"STATE_RELOCATION_FAULT=$FAULT"} \
    bash "$CFG/skills/session-close/scripts/relocate-session-state.sh" "$1" 2>/dev/null)" || MV_RC=$?
  MV_OUT="${MV_OUT//$'\r'/}"
}

c_m10_report_once() {
  local sid
  new_home m10
  sid="$(sid_of 1001)"
  seed_session "$LEG" "$sid"
  close_tree m10
  FAULT=json-rename close_run "$sid"
  eq "M10 first failure exits 0" "$MV_RC" "0"
  like "M10 first failure says report=first" "$MV_OUT" "*RELOCATE_FAILED*report=first*"
  FAULT=json-rename close_run "$sid"
  eq "M10 second failure exits 0" "$MV_RC" "0"
  like "M10 second failure says report=dup" "$MV_OUT" "*RELOCATE_FAILED*report=dup*"
  eq "M10 supervisor-report ran exactly once" "$(grep -c '' "$STUB_LOG" || true)" "1"
  like "M10 the report is a workflow warning" "$(cat "$STUB_LOG")" "*--categories workflow*--severity warning*"
  eq "M10 the dedupe marker lives in the legacy control dir" \
    "$(test -f "$LEG/$sid.control/relocation-failure-reported" && echo present)" "present"
}

c_m10b_success_quiet() {
  local sid
  new_home m10b
  sid="$(sid_of 1011)"
  seed_session "$LEG" "$sid"
  close_tree m10b
  close_run "$sid"
  like "M10b a successful move is RELOCATED" "$MV_OUT" "*RELOCATED sid=$sid*"
  eq "M10b success exits 0" "$MV_RC" "0"
  close_run "$sid"
  like "M10b a repeat is SKIPPED" "$MV_OUT" "*RELOCATE_SKIPPED*"
  eq "M10b SKIPPED exits 0" "$MV_RC" "0"
  eq "M10b supervisor-report was never called" "$(grep -c '' "$STUB_LOG" || true)" "0"
}

c_m11_skill() {
  local md sc8 sc9 last body
  md="$SCRIPT_CHECKOUT_ROOT/skills/session-close/SKILL.md"
  sc8="$(grep -n '^## SC-8' "$md" | head -1 | cut -d: -f1 || true)"
  sc9="$(grep -n '^## SC-9' "$md" | head -1 | cut -d: -f1 || true)"
  last="$(grep -n '^## SC-' "$md" | tail -1 | cut -d: -f1 || true)"
  eq "M11 SKILL.md has an SC-9 section" "$(test -n "$sc9" && echo present)" "present"
  eq "M11 SC-9 comes after SC-8" "$(test -n "$sc9" && test -n "$sc8" && test "$sc9" -gt "$sc8" && echo after)" "after"
  eq "M11 SC-9 is the last SC section" "$last" "$sc9"
  body="$(awk '/^## SC-9/ { on = 1; next } /^## / { on = 0 } on' "$md")"
  like "M11 SC-9 runs relocate-session-state.sh from AGENTS_MAIN_ROOT" "$body" \
    '*"$AGENTS_MAIN_ROOT/skills/session-close/scripts/relocate-session-state.sh"*'
}

c_m12_blocks() {
  local rc=0
  (cd "$SCRIPT_CHECKOUT_ROOT" && run_with_timeout 120 bash bin/check-migration-blocks.sh --all >/dev/null 2>&1) || rc=$?
  eq "M12 check-migration-blocks --all passes" "$rc" "0"
  eq "M12 bin/state-dir-relocation is wrapped in a temporary block" \
    "$(grep -c 'BEGIN temporary:' "$SCRIPT_CHECKOUT_ROOT/bin/state-dir-relocation" 2>/dev/null || true)" "1"
  eq "M12 relocate-session-state.sh is wrapped in a temporary block" \
    "$(grep -c 'BEGIN temporary:' "$SCRIPT_CHECKOUT_ROOT/skills/session-close/scripts/relocate-session-state.sh" 2>/dev/null || true)" "1"
}

# deny_list <dir> / allow_list <dir> — take away / give back the right to list <dir>.
# Windows: a deny ACE for the current user (chmod does not deny there); else chmod.
deny_list() {
  if command -v icacls >/dev/null 2>&1 && [[ -n "${USERNAME:-}" ]]; then
    MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$1")" /deny "${USERNAME}:(RD)" >/dev/null 2>&1 || true
  else
    chmod 000 "$1" 2>/dev/null || true
  fi
}

allow_list() {
  if command -v icacls >/dev/null 2>&1 && [[ -n "${USERNAME:-}" ]]; then
    MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$1")" /remove:d "${USERNAME}" >/dev/null 2>&1 || true
  else
    chmod 755 "$1" 2>/dev/null || true
  fi
}

# Codex C5: `remaining` is the deletion-condition check. A legacy root that exists but
# cannot be read must not read as "nothing left" (exit 0, REMAINING_SIDS=0): that would
# license deleting the routing block while sessions still live there. A missing root
# (ENOENT) is the only clean empty answer. Skipped per case where the host cannot deny
# the listing (e.g. running as root).
c_m9b_unreadable_legacy() {
  local u
  new_home m9b
  u="$(sid_of 911)"
  mkdir -p "$LEG"
  printf '{}\n' >"$LEG/$u.json"
  deny_list "$LEG"
  if ls "$LEG" >/dev/null 2>&1; then
    allow_list "$LEG"
    skip "M9b this host cannot deny listing the legacy root"
    return 0
  fi
  mv_run remaining
  allow_list "$LEG"
  eq "M9b premise: the legacy root lists again after the ACL is restored" "$(ls "$LEG" 2>/dev/null || true)" "$u.json"
  eq "M9b an unreadable legacy root does not exit 0" "$(test "$MV_RC" -ne 0 && echo nonzero || echo "rc=$MV_RC")" "nonzero"
  eq "M9b an unreadable legacy root does not claim REMAINING_SIDS=0" \
    "$(grep -c '^REMAINING_SIDS=0$' <<<"$MV_OUT" || true)" "0"
  rm -rf "$LEG"
  mv_run remaining
  eq "M9b control: a missing legacy root exits 0" "$MV_RC" "0"
  eq "M9b control: a missing legacy root says REMAINING_SIDS=0" "$(grep -c '^REMAINING_SIDS=0$' <<<"$MV_OUT" || true)" "1"
}

case_begin "m9b-remaining-unreadable-legacy" "hooks/lib/temporary-migrations/state-dir-relocation/remaining.js"
c_m9b_unreadable_legacy
case_end
