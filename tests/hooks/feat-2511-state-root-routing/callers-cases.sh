# Caller cases (R11-R19, R21) for feat-2511-state-root-routing.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# sid_entries <dir> <sid> — names under <dir> that start with <sid>, comma-joined.
sid_entries() {
  local f out=""
  for f in "$1/$2"*; do
    [[ -e "$f" ]] && out="$out${f##*/},"
  done
  printf '%s' "$out"
}

c_r11_session_start_fresh() {
  local sid
  new_home r11
  sid="$(sid_of 1101)"
  dhook "$AGENTS_DIR/hooks/session-start.js" "{\"session_id\":\"$sid\",\"source\":\"startup\",\"transcript_path\":\"\",\"model\":\"m\"}" >/dev/null
  eq "R11 SessionStart creates ~/.workflow-state/<sid>.json" "$(test -f "$NEW/$sid.json" && echo yes)" "yes"
  eq "R11 SessionStart creates nothing for the sid in the legacy root" "$(sid_entries "$LEG" "$sid")" ""
}

c_r21_state_file_line() {
  local fresh old o
  new_home r21
  fresh="$(sid_of 2101)"
  old="$(sid_of 2102)"
  probe_seed "$LEG" "$old"
  o="$T/r21-out.json"
  dhook "$AGENTS_DIR/hooks/session-start.js" "{\"session_id\":\"$fresh\",\"source\":\"startup\",\"transcript_path\":\"\",\"model\":\"m\"}" >"$o"
  eq "R21 session-start State file (fresh sid) is the new path" "$(dprobe stateline "$(np "$o")")" "$NEW/$fresh.json"
  dhook "$AGENTS_DIR/hooks/session-start.js" "{\"session_id\":\"$old\",\"source\":\"resume\",\"transcript_path\":\"\",\"model\":\"m\"}" >"$o"
  eq "R21 session-start State file (legacy sid) is the legacy path" "$(dprobe stateline "$(np "$o")")" "$LEG/$old.json"
  dhook "$AGENTS_DIR/hooks/post-compact.js" "{\"session_id\":\"$fresh\"}" >"$o"
  eq "R21 post-compact State file (fresh sid) is the new path" "$(dprobe stateline "$(np "$o")")" "$NEW/$fresh.json"
  dhook "$AGENTS_DIR/hooks/post-compact.js" "{\"session_id\":\"$old\"}" >"$o"
  eq "R21 post-compact State file (legacy sid) is the legacy path" "$(dprobe stateline "$(np "$o")")" "$LEG/$old.json"
}

c_r12_legacy_session_hooks() {
  local sid marker before
  new_home r12
  sid="$(sid_of 1201)"
  probe_seed "$LEG" "$sid"
  marker="$(dprobe turnmarker "$sid")"
  eq "R12 the turn marker lands in the legacy root" "${marker%/*}" "$LEG"
  mkdir -p "$NEW"
  : >"$NEW/$sid.workflow-off"
  eq "R12 a new-root-only .workflow-off is not seen for a legacy session" "$(dprobe isoff "$sid")" "false"
  rm -f "$NEW/$sid.workflow-off"
  : >"$LEG/$sid.workflow-off"
  eq "R12 the legacy .workflow-off is seen" "$(dprobe isoff "$sid")" "true"
  rm -f "$LEG/$sid.workflow-off"
  before="$(cat "$LEG/$sid.json" 2>/dev/null || true)"
  dprobe notneeded "$sid" "$(np "$T/cwd")" >/dev/null
  eq "R12 workflow-mark updates the legacy json" \
    "$(test -f "$LEG/$sid.json" && test "$before" != "$(cat "$LEG/$sid.json")" && echo changed)" "changed"
  eq "R12 the new root holds no entry for the legacy session" "$(sid_entries "$NEW" "$sid")" ""
}

c_r13_zombies_both_roots() {
  local old fresh r
  new_home r13
  old="$(sid_of 1301)"
  fresh="$(sid_of 1302)"
  for r in "$NEW" "$LEG"; do
    probe_seed "$r" "$old" '{"created_at":"2020-01-01T00:00:00.000Z"}'
    probe_seed "$r" "$fresh"
    : >"$r/$old.workflow-off"
    touch -d '2020-01-01 00:00:00' "$r/$old.workflow-off" "$r/$old.json"
    : >"$r/$fresh.workflow-off"
  done
  dprobe zombies >/dev/null
  for r in "$NEW" "$LEG"; do
    eq "R13 an old json is collected in ${r##*/.}" "$(test -e "$r/$old.json" || echo gone)" "gone"
    eq "R13 an old marker is collected in ${r##*/.}" "$(test -e "$r/$old.workflow-off" || echo gone)" "gone"
    eq "R13 a fresh json survives in ${r##*/.}" "$(test -f "$r/$fresh.json" && echo kept)" "kept"
    eq "R13 a fresh marker survives in ${r##*/.}" "$(test -f "$r/$fresh.workflow-off" && echo kept)" "kept"
  done
}

c_r14_active_union() {
  local a b c d own
  new_home r14
  a="$(sid_of 1401)" b="$(sid_of 1402)" c="$(sid_of 1403)" d="$(sid_of 1404)" own="$(sid_of 1400)"
  probe_seed "$NEW" "$a"
  probe_seed "$LEG" "$a"
  probe_seed "$LEG" "$b"
  probe_seed "$NEW" "$d"
  : >"$NEW/$c.off-clearance"
  eq "R14 active ids are the union of both roots, deduplicated, without the clearance-only sid" \
    "$(dprobe active "$own")" "$own,$a,$b,$d"
}

c_r15_marker_gate() {
  local own other
  new_home r15
  own="$(sid_of 1500)"
  other="$(sid_of 1501)"
  mkdir -p "$NEW" "$LEG"
  eq "R15 a new-root descendant is allowed" "$(dprobe markergate "$NEW/$own.note" "$own")" "true,false"
  eq "R15 a legacy-root descendant is allowed" "$(dprobe markergate "$LEG/$own.note" "$own")" "true,false"
  eq "R15 the new root itself is denied" "$(dprobe markergate "$NEW" "$own")" "false,false"
  eq "R15 the legacy root itself is denied" "$(dprobe markergate "$LEG" "$own")" "false,false"
  eq "R15 another session's stem is caught in the new root" "$(dprobe markergate "$NEW/$other.json" "$own")" "true,true"
  eq "R15 another session's stem is caught in the legacy root" "$(dprobe markergate "$LEG/$other.json" "$own")" "true,true"
}

c_r16_placement() {
  new_home r16
  mkdir -p "$NEW" "$LEG"
  eq "R16 placement: a legacy-root path is control-dir" "$(dprobe placement "$LEG/s1.off-clearance")" "control-dir"
  eq "R16 placement: a new-root path is control-dir" "$(dprobe placement "$NEW/s1.off-clearance")" "control-dir"
  eq "R16 bash scan: a legacy-root glob write is caught" "$(dprobe scan "echo x > $LEG/s1*")" "workflow-glob"
  eq "R16 bash scan: a new-root glob write is caught" "$(dprobe scan "echo x > $NEW/s1*")" "workflow-glob"
  # Allow direction: a path outside both roots, including a sibling sharing a root's
  # prefix, is not a control-dir placement and not a protected write.
  mkdir -p "$H/elsewhere" "$H/.workflow-state2"
  eq "R16 placement: a path outside both roots is allowed" "$(dprobe placement "$H/elsewhere/s1.off-clearance")" "null"
  eq "R16 placement: a prefix-sharing sibling of the new root is allowed" \
    "$(dprobe placement "$H/.workflow-state2/s1.off-clearance")" "null"
  eq "R16 bash scan: a glob write outside both roots is allowed" "$(dprobe scan "echo x > $H/elsewhere/s1*")" "null"
}

c_r17_expand() {
  local pin
  new_home r17
  pin="$(np "$T/pins/r17")"
  mkdir -p "$pin"
  eq "R17 pinned: \$WORKFLOW_STATE_DIR expands to the pin" "$(pprobe "$pin" expand '$WORKFLOW_STATE_DIR/x')" "$pin/x|false"
  eq "R17 unpinned: \$WORKFLOW_STATE_DIR expands to getStateRoot()" "$(dprobe expand '$WORKFLOW_STATE_DIR/x')" "$NEW/x|false"
}

c_r18_sp_control_dir() {
  local old fresh lib
  new_home r18
  old="$(sid_of 1801)"
  fresh="$(sid_of 1802)"
  probe_seed "$LEG" "$old"
  lib="$AGENTS_DIR/bin/lib/safe-state-path.sh"
  eq "R18 sp_control_dir: a legacy session gets the legacy control dir" "$(np "$(dsh "$lib" sp_control_dir "$old")")" "$LEG/$old.control"
  eq "R18 sp_control_dir: a fresh session gets the new control dir" "$(np "$(dsh "$lib" sp_control_dir "$fresh")")" "$NEW/$fresh.control"
}

c_r19_sweep_both_roots() {
  local r i=0 out
  new_home r19
  for r in "$NEW" "$LEG"; do
    i=$((i + 1))
    mkdir -p "$r/$(sid_of "190$i").control"
    printf '%s\n' '{"layer1":{"findings":[]},"last_updated":"2020-01-01T00:00:00.000Z"}' \
      >"$r/$(sid_of "190$i").control/supervisor-state.json"
  done
  out="$(drun "$AGENTS_DIR/bin/sweep-supervisor-state.sh" --ci-mode)"
  eq "R19 sweep scans the control dirs of both roots" "$(grep -o '"scanned":[0-9]*' <<<"$out")" '"scanned":2'
}
