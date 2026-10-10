# Resolver cases (R1-R10, R20c, R25) for feat-2511-state-root-routing.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

c_r1_pinned() {
  local sid pin
  new_home r1
  sid="$(sid_of 1)"
  pin="$(np "$T/pins/r1")"
  mkdir -p "$LEG/$sid.control" "$pin"
  probe_seed "$LEG" "$sid"
  eq "R1 pinned: a legacy-json sid resolves to the pin" "$(pprobe "$pin" dir "$sid")" "$pin"
  eq "R1 pinned: a fresh sid resolves to the pin" "$(pprobe "$pin" dir "$(sid_of 2)")" "$pin"
  eq "R1 opts.pin wins over the default-path routing" "$(dprobe dir "$sid" "{\"pin\":\"$pin\"}")" "$pin"
}

c_r2_r6_routing() {
  local s2 s3 s4 s5 s5b s5c s6 s6b
  new_home r2
  s2="$(sid_of 2)" s3="$(sid_of 3)" s4="$(sid_of 4)" s5="$(sid_of 5)"
  s5b="$(sid_of 51)" s5c="$(sid_of 52)" s6="$(sid_of 6)" s6b="$(sid_of 61)"
  mkdir -p "$LEG/$s4.control" "$NEW/$s5b.control" "$NEW/$s5c.control" \
    "$LEG/$s6.instructions-loaded" "$NEW/$s6b.instructions-loaded"
  probe_seed "$LEG" "$s3"
  probe_seed "$LEG" "$s5"
  probe_seed "$NEW" "$s5"
  probe_seed "$LEG" "$s5b"
  probe_seed "$LEG" "$s6b"
  eq "R2 no routing file anywhere -> new root" "$(dprobe dir "$s2")" "$NEW"
  eq "R3 legacy <sid>.json -> legacy root" "$(dprobe dir "$s3")" "$LEG"
  eq "R4 legacy <sid>.control/ -> legacy root" "$(dprobe dir "$s4")" "$LEG"
  eq "R5 json in both roots -> new root" "$(dprobe dir "$s5")" "$NEW"
  eq "R5b new control only + legacy json (partial publish) -> legacy" "$(dprobe dir "$s5b")" "$LEG"
  eq "R5c new control only, legacy empty -> new root" "$(dprobe dir "$s5c")" "$NEW"
  eq "R6 legacy instructions-loaded/ only -> new root" "$(dprobe dir "$s6")" "$NEW"
  eq "R6 new-root instructions-loaded/ never outranks a legacy json" "$(dprobe dir "$s6b")" "$LEG"
}

c_r7_cache() {
  local sid
  new_home r7
  sid="$(sid_of 7)"
  probe_seed "$LEG" "$sid"
  eq "R7 legacy, then new after the json moves, then cached new" \
    "$(dprobe dirtwice "$sid" "$NEW" "$LEG")" "$LEG|$NEW|$NEW"
}

c_r8_r9_roots() {
  local pin
  new_home r8
  pin="$(np "$T/pins/r8")"
  mkdir -p "$pin"
  # #2512 C2: listed whether or not it exists, so a root created later is still covered.
  eq "R8 no legacy root -> [new, legacy] all the same" "$(dprobe roots)" "[\"$NEW\",\"$LEG\"]"
  mkdir -p "$LEG"
  eq "R8 legacy root present -> [new, legacy]" "$(dprobe roots)" "[\"$NEW\",\"$LEG\"]"
  eq "R8 pinned -> [pin]" "$(pprobe "$pin" roots)" "[\"$pin\"]"
  probe_seed "$LEG" "$(sid_of 8)"
  eq "R9 getStateRoot is the new root even with legacy sessions" "$(dprobe root)" "$NEW"
  eq "R9 getStateRoot pinned -> pin" "$(pprobe "$pin" root)" "$pin"
  eq "R9 opts.home sets the base" "$(dprobe root "{\"home\":\"$H/alt\"}")" "$H/alt/.workflow-state"
}

c_r10_cli() {
  local cli sid out rc
  new_home r10
  cli="$SCRIPT_CHECKOUT_ROOT/bin/workflow-state-dir"
  sid="$(sid_of 10)"
  probe_seed "$LEG" "$sid"
  out="$(dcli "$cli" --session "$sid" || true)"
  eq "R10 --session prints the routed (legacy) dir" "$(np "$out")" "$LEG"
  out="$(dcli "$cli" --session "$(sid_of 11)" || true)"
  eq "R10 --session prints the new dir for a fresh sid" "$(np "$out")" "$NEW"
  out="$(dcli "$cli" --global || true)"
  eq "R10 --global prints the new root" "$(np "$out")" "$NEW"
  out="$(dcli "$cli" --roots || true)"
  eq "R10 --roots prints new then legacy, one per line" "$(roots_np "$out")" "$NEW,$LEG"
  rc=0
  dcli "$cli" --session "../evil" >/dev/null || rc=$?
  eq "R10 an invalid sid exits 2" "$rc" 2
  rc=0
  dcli "$cli" >/dev/null || rc=$?
  eq "R10 no arguments exits 2" "$rc" 2
}

c_r20c_env_fallback_off() {
  local sid other o
  new_home r20c
  sid="$(sid_of 20)"
  other="$(np "$T/pins/r20c-other")"
  mkdir -p "$other"
  probe_seed "$LEG" "$sid"
  o="{\"pin\":null,\"home\":\"$H\",\"envFallback\":false}"
  eq "R20c envFallback:false ignores the env pin (legacy sid)" "$(pprobe "$other" dir "$sid" "$o")" "$LEG"
  eq "R20c envFallback:false ignores the env pin (fresh sid)" "$(pprobe "$other" dir "$(sid_of 21)" "$o")" "$NEW"
  eq "R20c the default (envFallback on) still honours the env pin" "$(pprobe "$other" dir "$sid")" "$other"
}

c_r25_sid_contract() {
  new_home r25
  eq "R25 a.b-1: state dir ok, control dir ok, getStatePath refuses, assert ok" \
    "$(dprobe validate "a.b-1")" "ok,ok,err,ok"
  eq "R25 a..b is refused everywhere" "$(dprobe validate "a..b")" "err,err,err,err"
  eq "R25 a leading dot is refused everywhere" "$(dprobe validate ".hidden")" "err,err,err,err"
  eq "R25 a plain uuid passes every layer" "$(dprobe validate "$(sid_of 25)")" "ok,ok,ok,ok"
  eq "R25 control-dir keeps its exports and shares the state-root regex" \
    "$(dprobe cdexports)" "true,true,ok,err,true"
}
