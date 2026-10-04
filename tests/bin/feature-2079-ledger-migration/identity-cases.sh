# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/identity-cases.sh
# Tests: bin/lib/run-all-parallelism.sh
# Tags: tests, bin, ledger, host-identity, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n16 (#2079 S6): the Windows key no longer carries the launch path or build, every other
# OS keeps its key byte-for-byte, and both ledgers write the OS attribute the plan names.
# Sourced by the dispatcher (parent side) and by _driver.sh (child side).

OS_ATTR_RE='^[A-Za-z0-9._-]{1,32}/[A-Za-z0-9._-]{1,64}$'

# ---- child side ---------------------------------------------------------------

c_ident() {
  local dig compose
  dig="$(run_all_id_digest "$LM_HOST")"
  compose="$(run_all_host_id_compose "$LM_STUB_S" "$(run_all_id_field "$LM_ARCH")" "$dig" 2>/dev/null)"
  say tok "$(lm_tok)"
  say hid "$(run_all_host_id)"
  say attr "$(run_all_os_attr 2>/dev/null)"
  say compose "$compose"
  say tokc "$(run_all_dur_pad16 "$(run_all_id_digest "$compose")")"
  say old "$(lm_oldtok "$LM_STUB_S")"
  say dig "$dig"
}

c_writer() {
  local seg
  run_all_dur_writer_init "$LM_REPO"
  run_all_dur_append "id/a.sh" 7
  seg="$RUN_ALL_DUR_SEGMENT"
  say name "${seg##*/}"
  say first "$(head -n 1 "$seg" 2>/dev/null)"
  say tok "$(lm_tok)"
  say val "$(lm_get id/a.sh)"
}

c_base() {
  local seg
  rtb_ledger_append "abcdef1234567" "tests/x.sh" fail
  seg="$RTB_LEDGER_SEGMENT"
  say name "${seg##*/}"
  say tok "$(lm_tok)"
  say line "$(head -n 1 "$seg" 2>/dev/null | tr '\t' '~')"
  say same "$(rtb_ledger_lookup_same_base abcdef1234567 tests/x.sh)"
}

# ---- parent side --------------------------------------------------------------

# id_of <uname-s> <host> [uname-r] — c_ident output for one stubbed host.
id_of() {
  local LM_S="$1" LM_HOST="$2" LM_R="${3-3.5.4-0.x86_64}" LM_LIBSET=dur
  lm_run "$(lm_cache)" c_ident
}

run_identity_windows_cases() {
  local s out toks="" fields="" hids="" first="" want_hid
  for s in "$LM_W26300" "$LM_M26200" "MINGW32_NT-10.0-26300" "CYGWIN_NT-10.0-26300"; do
    out="$(id_of "$s" stubhost)"
    toks="$toks $(lm_v "$out" tok)"
    fields="$fields $(lm_v "$out" hid | cut -d'|' -f1)"
    want_hid="Windows|$LM_ARCH|$(lm_v "$out" dig)"
    [ "$(lm_v "$out" hid)" = "$want_hid" ] || hids="$hids $s"
    [ -n "$first" ] || first="$(lm_v "$out" tok)"
  done
  ck "n16/1/windows-os-field" " Windows Windows Windows Windows" "$fields"
  ck "n16/1/windows-one-token" " $first $first $first $first" "$toks"
  ck "n16/1/windows-host-id-shape" "" "$hids"
  out="$(id_of "$LM_W26300" stubhost)"
  if [ -n "$(lm_v "$out" tok)" ] && [ "$(lm_v "$out" tok)" != "$(lm_v "$out" old)" ]; then
    pass "n16/1/windows-key-changed-from-pre-2079"
  else
    fail "n16/1/windows-key-changed-from-pre-2079" "tok=$(lm_v "$out" tok) old=$(lm_v "$out" old)"
  fi
}

run_identity_other_os_cases() {
  local s out lin win
  for s in Linux Darwin; do
    out="$(id_of "$s" stubhost)"
    ck "n16/2/$s-os-field-raw" "$s" "$(lm_v "$out" hid | cut -d'|' -f1)"
    ck "n16/2/$s-token-unchanged" "$(lm_v "$out" old)" "$(lm_v "$out" tok)"
    ck "n16/2/$s-compose-is-the-key" "$(lm_v "$out" hid)" "$(lm_v "$out" compose)"
    ck "n16/2/$s-token-from-compose" "$(lm_v "$out" tok)" "$(lm_v "$out" tokc)"
  done
  lin="$(lm_v "$(id_of Linux stubhost)" tok)"
  win="$(lm_v "$(id_of "$LM_W26300" stubhost)" tok)"
  if [ -n "$lin" ] && [ -n "$win" ] && [ "$lin" != "$win" ]; then
    pass "n16/3/wsl-and-windows-are-separate-keys"
  else
    fail "n16/3/wsl-and-windows-are-separate-keys" "linux=$lin windows=$win"
  fi
  lin="$(lm_v "$(id_of "$LM_W26300" otherhost)" tok)"
  if [ -n "$lin" ] && [ -n "$win" ] && [ "$lin" != "$win" ]; then
    pass "n16/4/windows-hostname-still-separates"
  else
    fail "n16/4/windows-hostname-still-separates" "stubhost=$win otherhost=$lin"
  fi
}

# attr_ok <name> <value> — the value has the S6 shape and none of the ledger separators.
attr_ok() {
  if printf '%s\n' "$2" | grep -qE "$OS_ATTR_RE" && [ "$(printf '%s' "$2" | wc -l)" -eq 0 ]; then
    pass "$1"
  else
    fail "$1" "value [$2] breaks $OS_ATTR_RE"
  fi
}

run_identity_attr_cases() {
  local long40 long100
  long40="ABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJ"
  long100="$(printf 'a%.0s' $(seq 1 100))"
  ck "n16/5/windows-build" "Windows/10.0.26300" "$(lm_v "$(id_of "$LM_W26300" stubhost 3.5.4-0.x86_64)" attr)"
  ck "n16/5/windows-no-build" "Windows/10.0" "$(lm_v "$(id_of MINGW64_NT-10.0 stubhost)" attr)"
  ck "n16/5/linux-kernel" "Linux/6.8.0-45-generic" "$(lm_v "$(id_of Linux stubhost 6.8.0-45-generic)" attr)"
  ck "n16/5/darwin-release" "Darwin/23.4.0" "$(lm_v "$(id_of Darwin stubhost 23.4.0)" attr)"
  ck "n16/5/linux-no-release" "Linux/unknown" "$(lm_v "$(id_of Linux stubhost "")" attr)"
  attr_ok "n16/5/separators-sanitised" "$(lm_v "$(id_of Linux stubhost "6.8 0|x$(printf '\t')y")" attr)"
  attr_ok "n16/5/version-capped-at-64" "$(lm_v "$(id_of Linux stubhost "$long100")" attr)"
  attr_ok "n16/5/family-capped-at-32" "$(lm_v "$(id_of "$long40" stubhost 1.0)" attr)"
}

run_identity_writer_cases() {
  local out tok LM_S="$LM_W26300" LM_HOST=stubhost LM_R="3.5.4-0.x86_64" LM_LIBSET=dur
  out="$(lm_run "$(lm_cache)" c_writer)"
  tok="$(lm_v "$out" tok)"
  if [ -n "$tok" ] && printf '%s\n' "$(lm_v "$out" name)" | grep -qE "^dur\\.2\\.$tok\\.[0-9]{8}T[0-9]{6}-[0-9]+\\.log\$"; then
    pass "n16/6/segment-named-dur-2"
  else
    fail "n16/6/segment-named-dur-2" "name=$(lm_v "$out" name) tok=$tok"
  fi
  ck "n16/6/segment-header" "#os Windows/10.0.26300" "$(lm_v "$out" first)"
  ck "n16/6/reader-skips-header" "7" "$(lm_v "$out" val)"
}

run_identity_baseline_cases() {
  local out tok line LM_S="$LM_W26300" LM_HOST=stubhost LM_R="3.5.4-0.x86_64" LM_LIBSET=base
  out="$(lm_run "$(lm_cache)" c_base)"
  tok="$(lm_v "$out" tok)"
  if [ -n "$tok" ] && printf '%s\n' "$(lm_v "$out" name)" | grep -qE "^v2\\.$tok-[0-9]+-[0-9]+\\.seg\$"; then
    pass "n16/7/baseline-segment-named-v2"
  else
    fail "n16/7/baseline-segment-named-v2" "name=$(lm_v "$out" name) tok=$tok"
  fi
  line="$(lm_v "$out" line)"
  if printf '%s\n' "$line" | grep -qE "^v2~abcdef1234567~$tok~tests/x\\.sh~fail~[0-9]+~Windows/10\\.0\\.26300\$"; then
    pass "n16/7/baseline-line-7-fields-with-attr"
  else
    fail "n16/7/baseline-line-7-fields-with-attr" "line=[$line]"
  fi
  ck "n16/7/baseline-record-readable" "fail" "$(lm_v "$out" same)"
}
